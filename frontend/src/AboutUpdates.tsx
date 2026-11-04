import { useEffect, useState, type ReactNode } from "react";
import { listen } from "./events";
import { openExternal } from "./oriel";
import {
  AppInfo,
  UpdateCheck,
  UpdateProgress,
  appInfo,
  updateCheck,
  updateInstall,
  updateRestart,
  formatBytes,
  systemInfo,
  copyText,
  type SystemInfo,
} from "./api";

const KIND_TEXT: Record<string, string> = {
  windows: "Windows installer: GhostPen updates itself.",
  appimage: "AppImage: GhostPen updates itself.",
  macos_app: "macOS app: GhostPen updates itself.",
  package: "Installed by your package manager (deb/rpm): update it there.",
  source: "Source build: GhostPen tells you about new releases. Update it the way you installed it.",
};

/**
 * Settings → About & updates: the version, "Check for updates", installing
 * one (where GhostPen can replace itself), and the automatic-updates switch (saved like any setting).
 * `extra` is a card Settings puts beside them.
 */
/** How the graphics backend reads to a person: on or off, and which one when it is named. */
function gpuText(backend: string): string {
  const b = (backend || "").trim();
  const low = b.toLowerCase();
  if (!b || low === "cpu" || low === "none") return "Off (CPU only)";
  if (low === "gpu") return "On";
  const names: Record<string, string> = { cuda: "CUDA", vulkan: "Vulkan", metal: "Metal", rocm: "ROCm", opencl: "OpenCL" };
  return `On (${names[low] ?? b})`;
}

const SESSION_NAMES: Record<string, string> = {
  wayland: "Wayland",
  x11: "X11",
  windows: "Windows",
  macos: "macOS",
  android: "Android",
};

export default function AboutUpdates(props: {
  autoUpdate: boolean;
  onAutoUpdate: (on: boolean) => void | Promise<void>;
  extra?: ReactNode;
}) {
  const [info, setInfo] = useState<AppInfo | null>(null);
  const [sys, setSys] = useState<SystemInfo | null>(null);
  const [copied, setCopied] = useState(false);
  const [check, setCheck] = useState<UpdateCheck | null>(null);
  const [message, setMessage] = useState("");
  const [busy, setBusy] = useState<"" | "checking" | "installing">("");
  const [progress, setProgress] = useState<UpdateProgress | null>(null);

  useEffect(() => {
    appInfo().then(setInfo).catch(() => {});
    systemInfo().then(setSys).catch(() => {});
    const un = listen<UpdateProgress>("ghostpen://update-progress", (e) => setProgress(e.payload));
    return () => {
      un.then((f) => f());
    };
  }, []);

  const doCheck = async () => {
    setBusy("checking");
    setMessage("");
    setCheck(null);
    try {
      setCheck(await updateCheck());
    } catch (e) {
      setMessage(String(e));
    } finally {
      setBusy("");
    }
  };

  const doInstall = async () => {
    setBusy("installing");
    setMessage("");
    setProgress(null);
    try {
      await updateInstall();
      setInfo(await appInfo());
    } catch (e) {
      setMessage(String(e));
    } finally {
      setBusy("");
      setProgress(null);
    }
  };

  const restart = () => updateRestart().catch((e) => setMessage(String(e)));

  const installed = info?.installed_version;
  const pct = progress && progress.total ? Math.min(100, (progress.downloaded / progress.total) * 100) : 0;

  const rows: [string, string][] = sys
    ? [
        ["GhostPen", sys.version],
        ["Oriel", sys.oriel],
        ["System", [sys.os, sys.os_version].filter(Boolean).join(" ")],
        ...(sys.device.trim() ? [["Device", sys.device] as [string, string]] : []),
        ["Architecture", `${sys.arch} (${sys.abi})`],
        ["Build", sys.build],
        ["CPU cores", String(sys.cpus)],
        ...(sys.memory_mb > 0 ? [["Memory", `${(sys.memory_mb / 1024).toFixed(1)} GB`] as [string, string]] : []),
        ["GPU acceleration", gpuText(sys.gpu)],
        ["Window layout", sys.layout === "single" ? "One app window" : "A window per tool"],
        ["Display system", SESSION_NAMES[sys.session] ?? sys.session],
        // The phone's own engines, listed only where the device has them: a computer has none to
        // report (it uses GhostPen's built-in models and voices, set under their own sections).
        ...(sys.system_ai || sys.speech_recognition || sys.system_voice
          ? [["Provided by this device", [sys.system_ai && "Gemini Nano", sys.speech_recognition && "speech recognition", sys.system_voice && "voices"].filter(Boolean).join(", ")] as [string, string]]
          : []),
      ]
    : [];
  const copyDetails = async () => {
    await copyText(rows.map(([k, v]) => `${k}: ${v}`).join("\n")).catch(() => {});
    setCopied(true);
    window.setTimeout(() => setCopied(false), 1500);
  };

  return (
    <div className="settings-grid">
    <section className="card">
      <h2>Updates</h2>
      <div className="about-row">
        <div>
          <b>GhostPen {info?.version ?? ""}</b>
          <span className="muted small about-kind">{info ? KIND_TEXT[info.install_kind] ?? "" : ""}</span>
        </div>
        <button className="btn" type="button" onClick={doCheck} disabled={busy !== ""}>
          {busy === "checking" ? "Checking…" : "Check for updates"}
        </button>
      </div>

      {installed && (
        <div className="update-box">
          <span>GhostPen {installed} is installed. It starts the next time GhostPen opens.</span>
          <button className="btn primary" type="button" onClick={restart}>Restart now</button>
        </div>
      )}

      {check && !installed && (
        check.available ? (
          <div className="update-box">
            <span>GhostPen {check.version} is available (you have {info?.version}).</span>
            {check.can_install ? (
              <button className="btn primary" type="button" onClick={doInstall} disabled={busy !== ""}>
                {busy === "installing" ? "Installing…" : "Update"}
              </button>
            ) : (
              <button className="btn primary" type="button" onClick={() => openExternal(check.releases_url)}>
                Download
              </button>
            )}
          </div>
        ) : (
          <p className="muted small">You have the latest version.</p>
        )
      )}

      {busy === "installing" && progress && (
        <div className="llm-progress">
          <div className="llm-bar"><div style={{ width: `${pct}%` }} /></div>
          <span className="muted small">{formatBytes(progress.downloaded)}{progress.total ? ` of ${formatBytes(progress.total)}` : ""}</span>
        </div>
      )}

      {message && <p className="muted small llm-message">{message}</p>}

      <label className="checkbox">
        <input type="checkbox" checked={props.autoUpdate} onChange={(e) => props.onAutoUpdate(e.target.checked)} />
        {info?.can_install === false ? (
          <span>
            Check for updates automatically
            <span className="checkbox-help">Tells you when a new version is out.</span>
          </span>
        ) : (
          <span>
            Update automatically
            <span className="checkbox-help">Installs new versions in the background; they start the next time GhostPen opens.</span>
          </span>
        )}
      </label>
      <p className="muted small">
        {info?.can_install !== false && "Releases are signed; GhostPen only installs an update whose signature matches. "}
        <a href="#" onClick={(e) => { e.preventDefault(); if (info) openExternal(info.releases_url); }}>Release notes</a>
      </p>
    </section>
    {props.extra}
    {sys && (
      <section className="card">
        <h2>This build</h2>
        <dl className="about-sys">
          {rows.map(([k, v]) => (
            <div key={k}>
              <dt>{k}</dt>
              <dd>{v}</dd>
            </div>
          ))}
        </dl>
        <button className="btn" type="button" onClick={copyDetails}>{copied ? "Copied ✓" : "Copy details"}</button>
      </section>
    )}
    </div>
  );
}
