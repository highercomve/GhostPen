const std = @import("std");
const oriel = @import("oriel");

/// GhostPen's version: the packages, `ghostpen --version`, Settings → About
/// and the updater all read it from here.
const version = "0.2.4";

/// Public half of the release signing key (the private half is the
/// GHOSTPEN_UPDATE_KEY secret the release workflow signs latest.json with).
const update_public_key = "1DqVHiw6bT4PjHafhfXcXS9jyw+XOPNwTllXlfHLtFQ=";

pub fn build(b: *std.Build) void {
    // macOS: runs on macOS 13+ and any Mac CPU (Oriel's default), for the
    // CLI and zigimg too, not only the app.
    const target = oriel.resolveTarget(b, b.standardTargetOptions(.{}));
    const optimize = b.standardOptimizeOption(.{});

    // Oriel's built-in modules and plugins. Switch on what the app uses:
    // anything left off is neither compiled nor linked.
    const dep = b.dependency("oriel", .{
        .target = target,
        .optimize = optimize,
        // GhostPen: tray + global hotkeys + clipboard + synthetic copy/paste,
        // settings store, notifications, and whisper captions/dictation.
        .tray = true,
        .store = true,
        .notification = true,
        .global_shortcut = true,
        .input = true,
        .clipboard = true,
        .whisper = true,
        // The local model runner ("This computer" profiles; src/llm_helper.zig).
        .llama = true,
        .audio_capture = true,
        // Whisper and the local model on an NVIDIA GPU: `oriel build -Dcuda` (Linux, CUDA toolkit).
        .ggml_cuda = b.option(bool, "cuda", "Run whisper and the local model on an NVIDIA GPU (libggml-cuda.so; needs the CUDA toolkit)") orelse false,
        // ... or on any GPU through Vulkan: `oriel build -Dvulkan` (Linux; Vulkan headers, glslc).
        .ggml_vulkan = b.option(bool, "vulkan", "Run whisper and the local model on any GPU through Vulkan (libggml-vulkan.so; needs Vulkan headers and glslc)") orelse false,
        // Wayland: the menu, captions and dictation overlays as layer surfaces
        // (always on top, anchored) where the compositor supports them.
        .layer_shell = target.result.os.tag == .linux and
            (b.option(bool, "layer_shell", "Wayland overlays via gtk4-layer-shell (default on)") orelse true),
        .menu = false,
        .dialog = false,
        // Updates (Settings → About & updates; src/updates.zig).
        .updater = true,
        .sql = false,
        .fs_watch = false,
        .media_server = false,
    });

    // Frontend in frontend/ (npm install if needed, vite build, embed).
    // zig build          production build
    // zig build run      run it
    // zig build dev      Vite dev server + hot reload
    // zig build types    regenerate frontend/src/oriel.ts
    // zig build check    type-check src/ without building
    // zig build package  installers: deb/rpm/AppImage (Linux), setup.exe (Windows), .app/.dmg (macOS)
    // PNG decode/resize/encode for clipboard images (OCR, previews).
    const zigimg = b.dependency("zigimg", .{ .target = target, .optimize = optimize }).module("zigimg");
    // `@import("ghostpen_build").version`, for the app and the CLI.
    const build_info = b.addOptions();
    build_info.addOption([]const u8, "version", version);
    const build_info_mod = build_info.createModule();

    // ghostpen-cli: an action from the terminal (no GUI, no GTK).
    const cli = b.addExecutable(.{
        .name = "ghostpen-cli",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/cli.zig"),
            .target = target,
            .optimize = if (optimize == .Debug) .ReleaseSafe else optimize,
        }),
    });
    _ = oriel.addApp(b, dep, .{
        .name = "ghostpen",
        .root_source_file = b.path("src/main.zig"),
        .icon = b.path("icon.png"), // High-resolution PNG (1024x1024 recommended)
        .imports = &.{
            .{ .name = "zigimg", .module = zigimg },
            .{ .name = "ghostpen_build", .module = build_info_mod },
        },
        .update_public_key = update_public_key,
        .frontend = .{ .dir = "frontend" },
        .package = .{
            .id = "dev.ghostpen.Oriel",
            .name = "GhostPen",
            // .publisher = "Your Name <you@example.com>", // default: from the app id
            .summary = "AI text editing anywhere on your desktop",
            .version = version,
            // The CLI ships in every package, next to the app (and in /usr/bin on Linux).
            .contents = .{ .executables = &.{cli} },
            // The Rust/Tauri GhostPen's packages were named ghost-pen (and
            // installed /usr/bin/ghostpen): installing this one upgrades them.
            .replaces = &.{"ghost-pen"},
            .conflicts = &.{"ghost-pen"},
        },
        .permissions = .{
            .microphone = "GhostPen transcribes your voice for dictation.",
            .accessibility = "GhostPen copies your selection and pastes the result by sending keystrokes to the app you're using.",
            .system_audio = "GhostPen captions the audio other apps play.",
        },
    });

    b.installArtifact(cli);
    const run_cli = b.addRunArtifact(cli);
    if (b.args) |a| run_cli.addArgs(a);
    b.step("cli", "Run ghostpen-cli (pass arguments after --)").dependOn(&run_cli.step);

    // Unit tests of the app's own modules (AI client, settings, images).
    const tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/tests.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "oriel", .module = dep.module("oriel") },
            .{ .name = "zigimg", .module = zigimg },
        },
    }),
        // Recent glibc/GCC crt1.o needs LLD (Zig's own linker can't read its
        // .sframe); LLD can't link Mach-O, so macOS keeps Zig's linker.
        .use_llvm = true,
        .use_lld = target.result.ofmt != .macho,
    });
    b.step("test", "Run the unit tests").dependOn(&b.addRunArtifact(tests).step);
}
