//! Read Oriel's persistent application log without starting the runtime.
const std = @import("std");
const builtin = @import("builtin");

const usage =
    \\Usage: ghostpen logs [-f | --follow]
    \\
    \\Print the application log. --follow waits for new entries; Ctrl+C exits.
    \\
;

pub fn run(init: std.process.Init, args: []const [:0]const u8, app_id: []const u8) !u8 {
    var follow = false;
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            std.debug.print("{s}", .{usage});
            return 0;
        } else if (std.mem.eql(u8, arg, "--follow") or std.mem.eql(u8, arg, "-f")) {
            follow = true;
        } else {
            std.debug.print("error: unknown logs option: {s}\n{s}", .{ arg, usage });
            return 2;
        }
    }
    const path = logPath(init.arena.allocator(), init.environ_map, app_id) catch |err| {
        std.debug.print("error: cannot locate application log: {s}\n", .{@errorName(err)});
        return 1;
    };
    const file = std.Io.Dir.cwd().openFile(init.io, path, .{}) catch |err| {
        std.debug.print("error: cannot open {s}: {s}\n", .{ path, @errorName(err) });
        if (err == error.FileNotFound)
            std.debug.print("Run GhostPen first to create its log.\n", .{});
        return 1;
    };
    defer file.close(init.io);
    copyLog(init.io, file, follow) catch |err| {
        std.debug.print("error: reading {s}: {s}\n", .{ path, @errorName(err) });
        return 1;
    };
    return 0;
}

fn copyLog(io: std.Io, file: std.Io.File, follow: bool) !void {
    var buffer: [8192]u8 = undefined;
    var out_buffer: [8192]u8 = undefined;
    var out = std.Io.File.stdout().writerStreaming(io, &out_buffer);
    var offset: u64 = 0;
    while (true) {
        const n = try file.readPositional(io, &.{&buffer}, offset);
        if (n > 0) {
            try out.interface.writeAll(buffer[0..n]);
            try out.interface.flush();
            offset += n;
            continue;
        }
        if (!follow) return;
        try io.sleep(.fromMilliseconds(250), .awake);
        // Also recover when the user truncates the log while following it.
        if ((try file.stat(io)).size < offset) offset = 0;
    }
}

/// Match oriel.log.init's platform directories, without opening a second
/// writer (Windows only permits concurrent readers) or creating an empty log.
fn logPath(gpa: std.mem.Allocator, env: *const std.process.Environ.Map, app_id: []const u8) ![]const u8 {
    if (builtin.os.tag == .windows) {
        const base = nonEmpty(env, "LOCALAPPDATA") orelse nonEmpty(env, "APPDATA") orelse return error.NoDataDirectory;
        return std.fs.path.join(gpa, &.{ base, app_id, "app.log" });
    }
    const home = nonEmpty(env, "HOME");
    if (builtin.os.tag == .macos) {
        return std.fs.path.join(gpa, &.{ home orelse return error.NoHomeDirectory, "Library", "Logs", app_id, "app.log" });
    }
    if (nonEmpty(env, "XDG_DATA_HOME")) |base|
        return std.fs.path.join(gpa, &.{ base, app_id, "app.log" });
    return std.fs.path.join(gpa, &.{ home orelse return error.NoHomeDirectory, ".local", "share", app_id, "app.log" });
}

fn nonEmpty(env: *const std.process.Environ.Map, name: []const u8) ?[]const u8 {
    const value = env.get(name) orelse return null;
    return if (value.len > 0) value else null;
}
