//! ghostpen-cli: run a GhostPen action from the terminal, with the app's
//! settings and AI client and no GUI or OS interaction.
//!
//!     ghostpen-cli <action> [--lang L] [--level subtle|balanced|strong]
//!                  [--profile ID] [--model M] [--stream] [-v] [TEXT...]
//!     ghostpen-cli prompt <instruction> [options] [TEXT...]
//!     ghostpen-cli profiles
//!
//! TEXT defaults to stdin. Settings: $GHOSTPEN_SETTINGS, else the app's
//! settings.json (the store file of the GUI app).

const std = @import("std");
const builtin = @import("builtin");
const ai = @import("ai.zig");
const settings = @import("settings.zig");

const usage =
    \\Usage: ghostpen-cli <action> [OPTIONS] [TEXT...]
    \\       ghostpen-cli prompt <instruction> [OPTIONS] [TEXT...]
    \\       ghostpen-cli profiles
    \\
    \\Actions: proofread, professional, casual, concise, expand, translate,
    \\         or the id of a custom action from the settings.
    \\
    \\Options:
    \\  --lang <language>     Target language for translate (default: Spanish)
    \\  --level <level>       subtle | balanced | strong (default: balanced)
    \\  --profile <id>        AI profile to use (default: the active one)
    \\  --model <model>       Override the profile's model
    \\  --stream              Print the answer as it streams in
    \\  -v, --verbose         Diagnostics on stderr
    \\  -h, --help            This help
    \\
    \\TEXT is read from stdin when not given. Settings come from
    \\$GHOSTPEN_SETTINGS or the GhostPen app's settings.json.
    \\
;

pub fn main(init: std.process.Init) !u8 {
    const io = init.io;
    const gpa = init.gpa;
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);

    var out_buf: [4096]u8 = undefined;
    var out = std.Io.File.stdout().writerStreaming(io, &out_buf);
    var err_buf: [1024]u8 = undefined;
    var err = std.Io.File.stderr().writerStreaming(io, &err_buf);
    defer out.interface.flush() catch {};
    defer err.interface.flush() catch {};

    var action: ?[]const u8 = null;
    var instruction: ?[]const u8 = null;
    var lang: []const u8 = "Spanish";
    var level: ai.Level = .balanced;
    var profile_id: ?[]const u8 = null;
    var model: ?[]const u8 = null;
    var stream = false;
    var verbose = false;
    var text_parts: std.ArrayList([]const u8) = .empty;

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        const value = struct {
            fn get(all: []const [:0]const u8, idx: *usize, e: *std.Io.Writer, name: []const u8) ?[]const u8 {
                idx.* += 1;
                if (idx.* >= all.len) {
                    e.print("error: {s} needs a value\n", .{name}) catch {};
                    return null;
                }
                return all[idx.*];
            }
        }.get;
        if (std.mem.eql(u8, a, "-h") or std.mem.eql(u8, a, "--help")) {
            try out.interface.writeAll(usage);
            return 0;
        } else if (std.mem.eql(u8, a, "--lang")) {
            lang = value(args, &i, &err.interface, a) orelse return 2;
        } else if (std.mem.eql(u8, a, "--level")) {
            const v = value(args, &i, &err.interface, a) orelse return 2;
            level = std.meta.stringToEnum(ai.Level, v) orelse {
                try err.interface.print("error: --level must be subtle, balanced or strong\n", .{});
                return 2;
            };
        } else if (std.mem.eql(u8, a, "--profile")) {
            profile_id = value(args, &i, &err.interface, a) orelse return 2;
        } else if (std.mem.eql(u8, a, "--model")) {
            model = value(args, &i, &err.interface, a) orelse return 2;
        } else if (std.mem.eql(u8, a, "--stream")) {
            stream = true;
        } else if (std.mem.eql(u8, a, "-v") or std.mem.eql(u8, a, "--verbose")) {
            verbose = true;
        } else if (std.mem.startsWith(u8, a, "-") and a.len > 1) {
            try err.interface.print("error: unknown option {s}\n\n{s}", .{ a, usage });
            return 2;
        } else if (action == null) {
            action = a;
        } else if (std.mem.eql(u8, action.?, "prompt") and instruction == null) {
            instruction = a;
        } else {
            try text_parts.append(arena, a);
        }
    }

    const s = loadSettings(io, gpa, arena, init.environ_map, if (verbose) &err.interface else null) catch |e| {
        try err.interface.print("error: can't read the settings: {s}\n", .{@errorName(e)});
        return 1;
    };

    const act = action orelse {
        try err.interface.writeAll(usage);
        return 2;
    };

    if (std.mem.eql(u8, act, "profiles")) {
        for (s.profiles) |p| {
            try out.interface.print("{s} {s}\t{s}\t{s}\t{s}\n", .{ if (std.mem.eql(u8, p.id, s.activeProfileId)) "*" else " ", p.id, p.name, p.model, p.baseUrl });
        }
        return 0;
    }

    var profile = s.activeProfile();
    if (profile_id) |id| {
        for (s.profiles) |p| {
            if (std.mem.eql(u8, p.id, id)) {
                profile = p;
                break;
            }
        } else {
            try err.interface.print("error: no profile '{s}' (see `ghostpen-cli profiles`)\n", .{id});
            return 1;
        }
    }

    const system: []const u8 = if (std.mem.eql(u8, act, "prompt")) blk: {
        const ins = instruction orelse {
            try err.interface.writeAll("error: `prompt` needs an instruction\n");
            return 2;
        };
        break :blk try ai.instructionPrompt(arena, ins);
    } else if (try ai.builtinPrompt(arena, act, lang, level)) |p| p else blk: {
        for (s.customActions) |c| if (std.mem.eql(u8, c.id, act)) {
            if (c.model.len > 0) profile.model = c.model;
            break :blk c.prompt;
        };
        try err.interface.print("error: Unknown action: {s}\n", .{act});
        return 1;
    };
    if (model) |m| profile.model = m;

    const text = if (text_parts.items.len > 0)
        try std.mem.join(arena, " ", text_parts.items)
    else
        try readStdin(io, arena);
    if (std.mem.trim(u8, text, " \t\r\n").len == 0) {
        try err.interface.writeAll("error: no text (give TEXT or pipe it on stdin)\n");
        return 2;
    }

    if (verbose) try err.interface.print("profile {s} · model {s} · {s}\n", .{ profile.id, profile.model, profile.baseUrl });

    var diag: ai.Diag = .{};
    const req: ai.Request = .{ .profile = profile, .system = system, .user = .{ .text = text } };
    const result = if (stream) blk: {
        const Print = struct {
            w: *std.Io.Writer,
            streamed: std.ArrayList(u8) = .empty,
            arena: std.mem.Allocator,
            fn chunk(self: *@This(), delta: []const u8) void {
                self.streamed.appendSlice(self.arena, delta) catch {};
                self.w.writeAll(delta) catch {};
                self.w.flush() catch {};
            }
        };
        var p: Print = .{ .w = &out.interface, .arena = arena };
        const final = ai.completeStream(io, gpa, arena, req, &p, Print.chunk, &diag) catch |e| return report(&err.interface, e, diag);
        try out.interface.writeAll("\n");
        // The stream was the model's reasoning and a retry replaced it: print the answer.
        if (!std.mem.eql(u8, std.mem.trim(u8, p.streamed.items, " \t\r\n"), final)) {
            try out.interface.print("--- answer:\n{s}\n", .{final});
        }
        break :blk final;
    } else ai.complete(io, gpa, arena, req, &diag) catch |e| return report(&err.interface, e, diag);

    if (!stream) try out.interface.print("{s}\n", .{result});
    return 0;
}

fn readStdin(io: std.Io, arena: std.mem.Allocator) ![]u8 {
    var buf: [4096]u8 = undefined;
    var r = std.Io.File.stdin().readerStreaming(io, &buf);
    return stripBom(try r.interface.allocRemaining(arena, .limited(4 * 1024 * 1024)));
}

/// Without a leading UTF-8 byte-order mark: Windows PowerShell pipes one to
/// native programs, and it would reach the model as part of the text.
fn stripBom(text: []u8) []u8 {
    const bom = "\xEF\xBB\xBF";
    return if (std.mem.startsWith(u8, text, bom)) text[bom.len..] else text;
}

test stripBom {
    var with = "\xEF\xBB\xBFteh text".*;
    try std.testing.expectEqualStrings("teh text", stripBom(&with));
    var without = "teh text".*;
    try std.testing.expectEqualStrings("teh text", stripBom(&without));
    var empty = "".*;
    try std.testing.expectEqualStrings("", stripBom(&empty));
}

fn report(w: *std.Io.Writer, e: ai.Error, diag: ai.Diag) u8 {
    w.print("error: {s}\n", .{if (e == error.AiFailed) diag.message else @errorName(e)}) catch {};
    return 1;
}

/// $GHOSTPEN_SETTINGS, else the GUI app's store file (Oriel's config dir for
/// the app id), else the defaults.
fn loadSettings(io: std.Io, gpa: std.mem.Allocator, arena: std.mem.Allocator, env: *const std.process.Environ.Map, verbose: ?*std.Io.Writer) !settings.Settings {
    _ = gpa;
    const path = env.get("GHOSTPEN_SETTINGS") orelse try defaultPath(arena, env) orelse {
        if (verbose) |v| try v.writeAll("settings: no config dir; using defaults\n");
        return .{};
    };
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(4 * 1024 * 1024)) catch |e| switch (e) {
        error.FileNotFound => {
            if (verbose) |v| try v.print("settings: {s} not found; using defaults\n", .{path});
            return .{};
        },
        else => return e,
    };
    if (verbose) |v| try v.print("settings: {s}\n", .{path});
    if (std.mem.trim(u8, bytes, " \t\r\n").len == 0) return .{};
    const value = try std.json.parseFromSliceLeaky(std.json.Value, arena, bytes, .{});
    return settings.parse(arena, value);
}

/// Where Oriel's store keeps `settings.json` for the app id.
fn defaultPath(arena: std.mem.Allocator, env: *const std.process.Environ.Map) !?[]const u8 {
    const id = settings.app_id;
    return switch (builtin.os.tag) {
        .windows => if (env.get("APPDATA")) |d| try std.fs.path.join(arena, &.{ d, id, "settings.json" }) else null,
        .macos => if (env.get("HOME")) |h| try std.fs.path.join(arena, &.{ h, "Library", "Application Support", id, "settings.json" }) else null,
        else => if (env.get("XDG_CONFIG_HOME")) |d|
            try std.fs.path.join(arena, &.{ d, id, "settings.json" })
        else if (env.get("HOME")) |h|
            try std.fs.path.join(arena, &.{ h, ".config", id, "settings.json" })
        else
            null,
    };
}
