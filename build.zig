const std = @import("std");
const oriel = @import("oriel");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
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
        .audio_capture = true,
        .menu = false,
        .dialog = false,
        .updater = false,
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

    _ = oriel.addApp(b, dep, .{
        .name = "ghostpen-oriel",
        .root_source_file = b.path("src/main.zig"),
        .icon = b.path("icon.png"), // High-resolution PNG (1024x1024 recommended)
        .imports = &.{.{ .name = "zigimg", .module = zigimg }},
        .frontend = .{ .dir = "frontend" },
        .package = .{
            .id = "dev.ghostpen.Oriel",
            .name = "GhostPen",
            // .publisher = "Your Name <you@example.com>", // default: from the app id
            .summary = "AI text editing anywhere on your desktop",
            .version = "0.1.0",
        },
    });

    // ghostpen-cli: an action from the terminal (no GUI, no GTK).
    const cli = b.addExecutable(.{
        .name = "ghostpen-cli",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/cli.zig"),
            .target = target,
            .optimize = if (optimize == .Debug) .ReleaseSafe else optimize,
        }),
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
        // Recent glibc/GCC crt1.o needs LLD (Zig's own linker can't read its .sframe).
        .use_llvm = true,
        .use_lld = true,
    });
    b.step("test", "Run the unit tests").dependOn(&b.addRunArtifact(tests).step);
}
