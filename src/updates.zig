//! Updates: the version, "Check for updates", and automatic updates
//! (Settings → About & updates).
//!
//! Releases publish one signed `latest.json` (Ed25519, checked against the
//! public key built into the app; oriel.updater verifies it). How an update
//! applies depends on how GhostPen was installed:
//!
//! - Windows (the installer's per-user folder), an AppImage, a macOS `.app`:
//!   GhostPen replaces itself and restarts.
//! - A Linux package (deb/rpm: the package manager owns the files) or a
//!   build from source: it says a new version exists and links to it.
//!
//! With automatic updates on (the default), GhostPen checks a minute after
//! it starts and then every 12 hours; an update it can install is
//! downloaded and installed in the background and applies on the next start
//! (a notification says so); otherwise it notifies once per version.

const std = @import("std");
const builtin = @import("builtin");
const oriel = @import("oriel");
const app = @import("oriel_app");
const main = @import("main.zig");
const settings_mod = @import("settings.zig");

const updater = oriel.updater;
const log = std.log.scoped(.updates);
const gpa = std.heap.smp_allocator;

pub const version: []const u8 = @import("ghostpen_build").version;
pub const releases_url = "https://github.com/highercomve/GhostPen/releases/latest";
const default_manifest_url = "https://github.com/highercomve/GhostPen/releases/latest/download/latest.json";
/// `GHOSTPEN_UPDATE_MANIFEST` points the updater elsewhere (testing a
/// release before publishing it); signatures are still checked against the
/// built-in key, so it can't install anything unsigned.
var manifest_url: []const u8 = default_manifest_url;

/// How this copy was installed (decides how an update applies).
pub const InstallKind = enum {
    /// Windows installer (per-user, writable): replaced in place.
    windows,
    /// A Linux AppImage: the AppImage file is replaced.
    appimage,
    /// A macOS `.app` bundle: swapped for the new one.
    macos_app,
    /// A deb/rpm package: updates come through the package manager.
    package,
    /// A build run from anywhere else (e.g. zig-out, ~/.local): not touched.
    source,

    pub fn canInstall(self: InstallKind) bool {
        return switch (self) {
            .windows, .appimage, .macos_app => true,
            .package, .source => false,
        };
    }
};

pub fn installKind() InstallKind {
    if (builtin.os.tag == .windows) return .windows;
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = std.process.executablePath(main.io, &buf) catch return .source;
    const exe = buf[0..n];
    if (builtin.os.tag == .macos) {
        return if (std.mem.indexOf(u8, exe, ".app/Contents/MacOS/") != null) .macos_app else .source;
    }
    if (updater.runningAsAppImage(main.io, gpa) catch false) return .appimage;
    if (std.mem.startsWith(u8, exe, "/usr/") or std.mem.startsWith(u8, exe, "/opt/")) return .package;
    return .source;
}

pub fn init(env: *const std.process.Environ.Map) void {
    if (env.get("GHOSTPEN_UPDATE_MANIFEST")) |url| {
        if (gpa.dupe(u8, url)) |owned| {
            manifest_url = owned;
        } else |_| {}
    }
    // $APPIMAGE / $APPDIR (for replacing an AppImage), and removes a
    // replaced Windows exe left from the last update.
    updater.init(main.io, gpa, env) catch |err| log.warn("updater: {s}", .{@errorName(err)});
    const t = std.Thread.spawn(.{}, autoLoop, .{}) catch return;
    t.detach();
}

fn config() updater.Config {
    return .{
        .app_id = settings_mod.app_id,
        .manifest_url = manifest_url,
        .current_version = version,
        .public_key_b64 = app.update_public_key orelse "",
    };
}

// ---- state ------------------------------------------------------------------------------

var mutex: std.Io.Mutex = .init;
/// The last verified update found (owned; its arena holds the strings).
var pending: ?updater.Update = null;
/// An update already downloaded and installed: applies on the next start.
var installed_version: ?[]u8 = null;
var busy: std.atomic.Value(bool) = .init(false);
var notified_version: ?[]u8 = null;

// ---- commands ---------------------------------------------------------------------------

pub const AppInfo = struct {
    version: []const u8,
    install_kind: []const u8,
    can_install: bool,
    releases_url: []const u8,
    /// An update was installed and applies when GhostPen restarts.
    installed_version: ?[]const u8,
};

pub const CheckResult = struct {
    available: bool,
    version: ?[]const u8 = null,
    can_install: bool,
    installed: bool = false,
    releases_url: []const u8 = releases_url,
};

pub const Progress = struct { downloaded: u64, total: ?u64 };

pub const Commands = struct {
    pub fn app_info(arena: std.mem.Allocator) !AppInfo {
        const kind = installKind();
        mutex.lockUncancelable(main.io);
        defer mutex.unlock(main.io);
        return .{
            .version = version,
            .install_kind = @tagName(kind),
            .can_install = kind.canInstall(),
            .releases_url = releases_url,
            .installed_version = if (installed_version) |v| try arena.dupe(u8, v) else null,
        };
    }

    pub fn update_check(arena: std.mem.Allocator) !CheckResult {
        const kind = installKind();
        const found = check() catch |err| return oriel.ipc.fail("Couldn't check for updates ({s}).", .{errorText(err)});
        mutex.lockUncancelable(main.io);
        defer mutex.unlock(main.io);
        const already = if (installed_version) |v| (if (found) |f| std.mem.eql(u8, v, f) else false) else false;
        return .{
            .available = found != null,
            .version = if (found) |f| try arena.dupe(u8, f) else null,
            .can_install = kind.canInstall(),
            .installed = already,
        };
    }

    /// Download and install the update found by the last check; progress
    /// as `ghostpen://update-progress`.
    pub fn update_install(_: std.mem.Allocator) !void {
        if (!installKind().canInstall()) return oriel.ipc.fail("This copy of GhostPen is updated through its package manager (or a new download).", .{});
        install() catch |err| return oriel.ipc.fail("The update failed: {s}", .{errorText(err)});
    }

    /// Start the installed version (after `update_install`).
    pub fn update_restart(_: std.mem.Allocator) !void {
        const dest = updater.resolveDestPath(main.io, gpa, null) catch |err| return oriel.ipc.fail("Can't restart: {s}", .{@errorName(err)});
        defer gpa.free(dest);
        updater.restart(main.io, dest) catch |err| return oriel.ipc.fail("Can't restart: {s}", .{@errorName(err)});
    }
};

// ---- check / install --------------------------------------------------------------------

/// Check the release manifest; the version found (owned by `pending`), or
/// null when this is the newest.
fn check() !?[]const u8 {
    var found = try updater.checkForUpdate(main.io, gpa, config());
    mutex.lockUncancelable(main.io);
    defer mutex.unlock(main.io);
    if (pending) |*p| p.deinit();
    pending = null;
    if (found) |*f| {
        pending = f.*;
        return f.version;
    }
    return null;
}

fn install() !void {
    if (busy.swap(true, .acq_rel)) return error.UpdateInProgress;
    defer busy.store(false, .release);
    mutex.lockUncancelable(main.io);
    const update = pending orelse {
        mutex.unlock(main.io);
        return error.NoUpdateChecked;
    };
    pending = null; // ours now: a check meanwhile won't free it
    mutex.unlock(main.io);
    var u = update;
    defer u.deinit();

    const Progress_ = struct {
        fn cb(_: ?*anyopaque, downloaded: u64, total: ?u64) void {
            oriel.App.emit("ghostpen://update-progress", Progress{ .downloaded = downloaded, .total = total });
        }
    };
    const dest = try updater.download(main.io, gpa, u, null, .{ .callback = Progress_.cb });
    gpa.free(dest);

    mutex.lockUncancelable(main.io);
    defer mutex.unlock(main.io);
    if (installed_version) |v| gpa.free(v);
    installed_version = gpa.dupe(u8, u.version) catch null;
    log.info("installed GhostPen {s}; it applies on the next start", .{u.version});
}

// ---- automatic updates ------------------------------------------------------------------

fn autoLoop() void {
    main.io.sleep(.fromSeconds(60), .awake) catch return;
    while (true) {
        autoCheck();
        main.io.sleep(.fromSeconds(12 * 60 * 60), .awake) catch return;
    }
}

fn autoCheck() void {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const s = main.shared.get(main.io, arena_state.allocator()) catch return;
    if (!s.autoUpdate) return;
    const found = check() catch |err| {
        log.info("update check: {s}", .{errorText(err)});
        return;
    };
    const v = found orelse return;
    const owned_version = gpa.dupe(u8, v) catch return;
    defer gpa.free(owned_version);

    mutex.lockUncancelable(main.io);
    const seen = if (notified_version) |n| std.mem.eql(u8, n, owned_version) else false;
    const done = if (installed_version) |i| std.mem.eql(u8, i, owned_version) else false;
    mutex.unlock(main.io);
    if (seen or done) return;

    const kind = installKind();
    if (kind.canInstall()) {
        install() catch |err| {
            log.warn("automatic update to {s} failed: {s}", .{ owned_version, errorText(err) });
            return;
        };
        notify("GhostPen {s} is installed", "It starts the next time you open GhostPen (or restart it from Settings).", owned_version);
    } else {
        notify("GhostPen {s} is available", "Download it from the GhostPen website (Settings → About & updates).", owned_version);
    }
    mutex.lockUncancelable(main.io);
    defer mutex.unlock(main.io);
    if (notified_version) |n| gpa.free(n);
    notified_version = gpa.dupe(u8, owned_version) catch null;
}

/// A desktop notification, from the main thread.
fn notify(comptime title_fmt: []const u8, body: []const u8, v: []const u8) void {
    const Ctx = struct { title: []u8, body: []const u8 };
    const title = std.fmt.allocPrint(gpa, title_fmt, .{v}) catch return;
    const Show = struct {
        fn run(c: Ctx) void {
            defer gpa.free(c.title);
            oriel.notification.notify(.{ .id = "ghostpen-update", .title = c.title, .body = c.body }) catch |err|
                log.warn("notification: {s}", .{@errorName(err)});
        }
    };
    oriel.App.runOnMain(Ctx{ .title = title, .body = body }, Show.run);
}

/// A short reason for the UI and the log.
fn errorText(err: anyerror) []const u8 {
    return switch (err) {
        error.ConnectionRefused, error.UnknownHostName, error.NetworkUnreachable, error.ConnectionTimedOut, error.TemporaryNameServerFailure => "no connection to GitHub",
        error.Timeout => "the server took too long",
        error.InvalidSignature, error.SignatureVerificationFailed => "the release's signature doesn't match (not installed)",
        error.HashMismatch, error.Sha256Mismatch => "the download was damaged (not installed)",
        error.AccessDenied, error.PermissionDenied => "GhostPen's files can't be replaced by this user",
        error.NoUpdateChecked => "check for updates first",
        error.UpdateInProgress => "an update is already downloading",
        else => @errorName(err),
    };
}

test InstallKind {
    try std.testing.expect(InstallKind.windows.canInstall());
    try std.testing.expect(!InstallKind.package.canInstall());
    try std.testing.expect(!InstallKind.source.canInstall());
}
