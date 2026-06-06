#!/usr/bin/env node
// Wrapper around the Tauri CLI that auto-enables the `captions` Cargo feature (ADR-008)
// on machines that actually have its build deps — so `npm run tauri dev|build` (and the
// `bundle:*` scripts) "just work" with captions on a capable box (e.g. the Arch desktop)
// while a box that lacks the deps (Chromebook/Crostini, ADR-007) — and release CI — quietly
// builds without it. No per-machine config, no feature flag to remember.
//
// The probe checks the three things the `captions` feature pulls in:
//   - ALSA           (cpal loopback capture; Linux only — macOS=CoreAudio, Windows=WASAPI)
//   - libclang       (whisper-rs's bindgen)
//   - a C/C++ compiler (whisper.cpp is built from source)
// All present -> add `--features captions`. Anything missing -> build without (degrade,
// never break the build).
//
// Override the probe explicitly with:
//   GHOSTPEN_CAPTIONS=1|on|true|yes   force captions ON
//   GHOSTPEN_CAPTIONS=0|off|false|no  force captions OFF   (release CI uses tauri-action
//                                                            directly, so it never hits this)

import { spawn, spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import path from "node:path";
import fs from "node:fs";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const args = process.argv.slice(2);

const ok = (cmd, cmdArgs = ["--version"]) => {
  try {
    return spawnSync(cmd, cmdArgs, { stdio: "ignore" }).status === 0;
  } catch {
    return false;
  }
};

function hasAlsa() {
  if (process.platform !== "linux") return true; // cpal uses CoreAudio / WASAPI off Linux
  return ok("pkg-config", ["--exists", "alsa"]);
}

function hasLibclang() {
  const envPath = process.env.LIBCLANG_PATH;
  if (envPath && fs.existsSync(envPath)) return true;
  if (process.platform === "linux") {
    try {
      if (spawnSync("sh", ["-c", "ldconfig -p 2>/dev/null | grep -q libclang"], { stdio: "ignore" }).status === 0)
        return true;
    } catch {
      /* fall through */
    }
  }
  return ok("clang"); // decent proxy on macOS/Windows dev boxes
}

const hasToolchain = () => ok("cc") || ok("gcc") || ok("clang") || ok("cl", []);

// ---- GPU backend probes (cuda > vulkan > cpu) ----------------------------------------

function findNvcc() {
  const candidates = [
    process.env.CUDA_PATH && path.join(process.env.CUDA_PATH, "bin", "nvcc"),
    "/opt/cuda/bin/nvcc",
    "/usr/local/cuda/bin/nvcc",
  ].filter(Boolean);
  for (const c of candidates) if (fs.existsSync(c)) return c;
  const r = spawnSync(process.platform === "win32" ? "where" : "which", ["nvcc"], { encoding: "utf8" });
  if (r.status === 0) return (r.stdout || "").split(/\r?\n/)[0].trim() || null;
  return null;
}

function hasNvidiaGpu() {
  if (ok("nvidia-smi", ["-L"])) return true;
  try {
    return process.platform === "linux" && fs.existsSync("/proc/driver/nvidia/gpus");
  } catch {
    return false;
  }
}

function hasVulkan() {
  if (!ok("glslc")) return false; // glslc/shaderc compiles ggml's Vulkan shaders at build time
  if (process.platform === "linux") {
    try {
      if (spawnSync("sh", ["-c", "ldconfig -p 2>/dev/null | grep -q libvulkan"], { stdio: "ignore" }).status === 0)
        return true;
    } catch {
      /* fall through */
    }
    return ["/usr/lib/libvulkan.so.1", "/usr/lib/libvulkan.so"].some((p) => fs.existsSync(p));
  }
  return true; // assume the loader is present alongside glslc on macOS/Windows dev boxes
}

// Decide whether captions are built and, if so, which whisper backend feature to use.
// Returns { feature: null | "captions" | "captions-cuda" | "captions-vulkan", why }.
function captionsDecision() {
  const env = (process.env.GHOSTPEN_CAPTIONS || "").toLowerCase();
  if (["0", "false", "off", "no"].includes(env)) return { feature: null, why: "GHOSTPEN_CAPTIONS forces off" };

  if (!["1", "true", "on", "yes"].includes(env)) {
    const checks = { alsa: hasAlsa(), libclang: hasLibclang(), toolchain: hasToolchain() };
    const missing = Object.entries(checks).filter(([, v]) => !v).map(([k]) => k);
    if (missing.length) return { feature: null, why: `missing build deps: ${missing.join(", ")}` };
  }

  // Captions are on — pick a compute backend. Preference cuda > vulkan > cpu, overridable
  // with GHOSTPEN_CAPTIONS_GPU=cuda|vulkan|cpu|auto.
  const want = (process.env.GHOSTPEN_CAPTIONS_GPU || "auto").toLowerCase();
  const nvcc = findNvcc();
  const cudaOk = !!nvcc && hasNvidiaGpu();
  const vulkanOk = hasVulkan();

  if (want === "cpu") return { feature: "captions", why: "GPU disabled (GHOSTPEN_CAPTIONS_GPU=cpu)" };
  if (want === "cuda") {
    if (cudaOk) return { feature: "captions-cuda", why: `CUDA (${nvcc})` };
    return vulkanOk
      ? { feature: "captions-vulkan", why: "CUDA requested but unavailable → Vulkan" }
      : { feature: "captions", why: "CUDA requested but unavailable → CPU" };
  }
  if (want === "vulkan") {
    return vulkanOk
      ? { feature: "captions-vulkan", why: "Vulkan" }
      : { feature: "captions", why: "Vulkan requested but unavailable → CPU" };
  }
  // auto
  if (cudaOk) return { feature: "captions-cuda", why: `CUDA auto-detected (${nvcc})` };
  if (vulkanOk) return { feature: "captions-vulkan", why: "Vulkan auto-detected (no usable CUDA)" };
  return { feature: "captions", why: "no GPU backend found → CPU" };
}

// CUDA's whisper.cpp build (cmake) needs to find the toolkit; nvcc often isn't on PATH.
function cudaBuildEnv(nvcc) {
  const root_ = nvcc ? path.dirname(path.dirname(nvcc)) : "/opt/cuda";
  return {
    CUDA_PATH: process.env.CUDA_PATH || root_,
    CUDAToolkit_ROOT: process.env.CUDAToolkit_ROOT || root_,
    CUDACXX: process.env.CUDACXX || nvcc || path.join(root_, "bin", "nvcc"),
    // Build kernels for the GPU actually installed (CMake 3.24+; cmake 4.x here).
    CMAKE_CUDA_ARCHITECTURES: process.env.CMAKE_CUDA_ARCHITECTURES || "native",
    PATH: `${path.join(root_, "bin")}${path.delimiter}${process.env.PATH || ""}`,
  };
}

// Only inject the feature for subcommands that actually compile Rust.
const compiles = args[0] === "dev" || args[0] === "build";
const alreadyRequested = args.some((a, i) => {
  if (a === "--features" || a === "-f") return (args[i + 1] || "").includes("captions");
  if (a.startsWith("--features=")) return a.includes("captions");
  return false;
});

const final = [...args];
let extraEnv = {};
if (compiles && !alreadyRequested) {
  const { feature, why } = captionsDecision();
  console.error(`[tauri] captions: ${feature || "off"} — ${why}`);
  if (feature) {
    final.push("--features", feature);
    if (feature === "captions-cuda") extraEnv = cudaBuildEnv(findNvcc());
  }
}

const isWin = process.platform === "win32";
const bin = path.join(root, "node_modules", ".bin", isWin ? "tauri.cmd" : "tauri");
// Node >=18.20 / 20.12 throws `spawn EINVAL` when launching a Windows `.cmd` shim without a
// shell (the CVE-2024-27980 hardening). Run the `.cmd` through cmd.exe on Windows; the bin path
// is quoted for spaces, and our args are controlled (target triples / feature names, no spaces).
const child = isWin
  ? spawn(`"${bin}"`, final, { stdio: "inherit", env: { ...process.env, ...extraEnv }, shell: true })
  : spawn(bin, final, { stdio: "inherit", env: { ...process.env, ...extraEnv } });
child.on("exit", (code, signal) => {
  if (signal) process.kill(process.pid, signal);
  else process.exit(code ?? 0);
});
child.on("error", (err) => {
  console.error(`[tauri] failed to launch ${bin}: ${err.message}`);
  process.exit(1);
});
