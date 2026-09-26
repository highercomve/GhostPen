//! The built-in model: the client of GhostPen's own runner (`llm_helper.zig`).
//!
//! The runner is GhostPen's executable in helper mode, started on the first
//! request with the chosen model, kept loaded between requests (a menu
//! action shouldn't pay the load time) and stopped after `idle_minutes`
//! without use, or when the model or its settings change. Plain std: the CLI
//! uses it too.

const std = @import("std");
const builtin = @import("builtin");

const log = std.log.scoped(.local_llm);

pub const Config = struct {
    /// The executable to run in helper mode (`--llm-helper`).
    exe: []const u8,
    /// The model file (.gguf).
    model: []const u8,
    ctx: u32 = 8192,
    gpu: bool = true,
    idle_minutes: u32 = 10,
};

pub const Chat = struct {
    system: []const u8,
    user: []const u8,
    temperature: f64 = 0.2,
    think: bool = false,
    max_tokens: u32 = 2048,
};

pub const Result = struct {
    text: []const u8,
    truncated: bool,
    cancelled: bool,
};

pub const Error = error{ LocalFailed, OutOfMemory };

/// The model load may read gigabytes from a cold disk.
const load_timeout_ms = 10 * 60 * 1000;
/// One answer, however slow the machine: then it's stopped (and the helper
/// killed if it doesn't stop).
const generate_timeout_ms = 5 * 60 * 1000;
/// Request lines the helper accepts (its line buffer is 256 KiB).
const max_request_bytes = 240 * 1024;

const Runner = struct {
    child: std.process.Child,
    /// What it was started with (compared to decide on a restart).
    key: []u8,
    stdout_buf: []u8,
    reader: std.Io.File.Reader,
    stdin_buf: [4096]u8 = undefined,
    stdin: std.Io.File.Writer,
    stderr_thread: ?std.Thread = null,
    gpu: []u8,
    ctx: u32,
    next_id: u64 = 1,
    last_used: std.Io.Clock.Timestamp,
    idle_minutes: u32,
};

var mutex: std.Io.Mutex = .init;
var runner: ?*Runner = null;
/// Serializes writes to the runner's stdin (a cancel can come from another thread).
var stdin_mutex: std.Io.Mutex = .init;
var stdin_writer: ?*std.Io.File.Writer = null;
var busy: std.atomic.Value(bool) = .init(false);
var is_loaded: std.atomic.Value(bool) = .init(false);
var watchdog: ?std.Thread = null;
var gpa_global: std.mem.Allocator = undefined;

/// The last lines llama.cpp wrote to stderr, for error messages.
var tail_mutex: std.Io.Mutex = .init;
var tail_buf: [2048]u8 = undefined;
var tail_len: usize = 0;

fn keyOf(arena: std.mem.Allocator, cfg: Config) ![]u8 {
    return std.fmt.allocPrint(arena, "{s}\x00{s}\x00{d}\x00{}", .{ cfg.exe, cfg.model, cfg.ctx, cfg.gpu });
}

/// Run one chat request; `on_chunk(ctx, delta)` for each piece of visible text.
pub fn chat(
    io: std.Io,
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    cfg: Config,
    req: Chat,
    ctx: anytype,
    comptime on_chunk: fn (@TypeOf(ctx), []const u8) void,
    diag: *[]const u8,
) Error!Result {
    mutex.lockUncancelable(io);
    defer mutex.unlock(io);
    busy.store(true, .release);
    defer busy.store(false, .release);

    // Before loading anything (escaping only makes the line longer).
    if (req.system.len + req.user.len > max_request_bytes) {
        diag.* = "The text is too long for the built-in model (about 200 KB at most): select less.";
        return error.LocalFailed;
    }
    const r = try ensure(io, gpa, arena, cfg, diag);
    const id = r.next_id;
    r.next_id += 1;
    const line_out = try std.json.Stringify.valueAlloc(arena, .{
        .id = id,
        .cmd = "chat",
        .system = req.system,
        .user = req.user,
        .max_tokens = req.max_tokens,
        .temperature = req.temperature,
        .think = req.think,
    }, .{});
    if (line_out.len > max_request_bytes) {
        diag.* = "The text is too long for the built-in model (about 200 KB at most): select less.";
        return error.LocalFailed;
    }
    {
        stdin_mutex.lockUncancelable(io);
        defer stdin_mutex.unlock(io);
        const w = &r.stdin.interface;
        w.writeAll(line_out) catch return lost(io, arena, diag);
        w.writeByte('\n') catch return lost(io, arena, diag);
        w.flush() catch return lost(io, arena, diag);
    }

    // Too slow: ask it to stop, then kill it.
    var deadline: Deadline = .{ .child = &r.child, .cancel_after_ms = generate_timeout_ms, .kill_after_ms = generate_timeout_ms + 30_000 };
    deadline.start(io);
    defer deadline.finish();

    var text: std.ArrayList(u8) = .empty;
    const Line = struct {
        id: u64 = 0,
        delta: ?[]const u8 = null,
        done: bool = false,
        @"error": ?[]const u8 = null,
        truncated: bool = false,
        cancelled: bool = false,
    };
    while (true) {
        const line = (r.reader.interface.takeDelimiter('\n') catch null) orelse {
            deadline.finish();
            if (deadline.timed_out.load(.acquire)) {
                stop(io);
                diag.* = "The built-in model took too long and was stopped.";
                return error.LocalFailed;
            }
            return lost(io, arena, diag);
        };
        const msg = std.json.parseFromSliceLeaky(Line, arena, line, .{ .ignore_unknown_fields = true }) catch continue;
        // Id 0: an error about a request it couldn't read (only one runs at a time).
        if (msg.id != id and !(msg.id == 0 and msg.@"error" != null)) continue;
        if (msg.@"error") |e| {
            diag.* = try arena.dupe(u8, e);
            r.last_used = .now(io, .awake);
            return error.LocalFailed;
        }
        if (msg.delta) |d| {
            try text.appendSlice(arena, d);
            on_chunk(ctx, d);
        }
        if (msg.done) {
            r.last_used = .now(io, .awake);
            if (msg.cancelled and deadline.timed_out.load(.acquire)) {
                diag.* = "The built-in model took too long (over 5 minutes) and was stopped.";
                return error.LocalFailed;
            }
            return .{ .text = text.items, .truncated = msg.truncated, .cancelled = msg.cancelled };
        }
    }
}

/// Stop the running request (it returns what it has so far).
pub fn cancel(io: std.Io) void {
    if (!busy.load(.acquire)) return;
    stdin_mutex.lockUncancelable(io);
    defer stdin_mutex.unlock(io);
    const w = stdin_writer orelse return;
    w.interface.writeAll("{\"cmd\":\"cancel\"}\n") catch return;
    w.interface.flush() catch {};
}

/// Stop the runner (frees the model's memory).
pub fn unload(io: std.Io) void {
    mutex.lockUncancelable(io);
    defer mutex.unlock(io);
    stop(io);
}

/// The model is loaded right now.
pub fn loaded() bool {
    return is_loaded.load(.acquire);
}

/// The runner died or the pipe broke: stop it and explain.
fn lost(io: std.Io, arena: std.mem.Allocator, diag: *[]const u8) Error {
    stop(io);
    const why = tail(io, arena);
    diag.* = std.fmt.allocPrint(arena, "GhostPen's built-in model stopped (crash or out of memory){s}{s}", .{ if (why.len > 0) ": " else ".", why }) catch "GhostPen's built-in model stopped.";
    return error.LocalFailed;
}

fn tail(io: std.Io, arena: std.mem.Allocator) []const u8 {
    tail_mutex.lockUncancelable(io);
    defer tail_mutex.unlock(io);
    const t = std.mem.trim(u8, tail_buf[0..tail_len], " \t\r\n");
    // The last line is usually the one that explains.
    const last = if (std.mem.lastIndexOfScalar(u8, t, '\n')) |i| t[i + 1 ..] else t;
    return arena.dupe(u8, last) catch "";
}

/// The runner for `cfg`, started (and the model loaded) if needed. Caller holds `mutex`.
fn ensure(io: std.Io, gpa: std.mem.Allocator, arena: std.mem.Allocator, cfg: Config, diag: *[]const u8) Error!*Runner {
    const key = try keyOf(arena, cfg);
    if (runner) |r| {
        if (std.mem.eql(u8, r.key, key)) {
            r.idle_minutes = cfg.idle_minutes;
            return r;
        }
        stop(io);
    }
    std.Io.Dir.cwd().access(io, cfg.model, .{}) catch {
        diag.* = std.fmt.allocPrint(arena, "The model file is missing: {s}. Download it in Settings → Built-in models.", .{cfg.model}) catch "The model file is missing.";
        return error.LocalFailed;
    };
    return start(io, gpa, arena, cfg, key, diag) catch |err| {
        // The GPU ran out of memory mid-load (another app took it: llama.cpp
        // aborts then): once more on the CPU. The key stays the requested one.
        switch (err) {
            error.GpuFailed => {},
            error.LocalFailed => return error.LocalFailed,
            error.OutOfMemory => return error.OutOfMemory,
        }
        log.warn("GPU load failed ({s}); loading on the CPU", .{diag.*});
        var cpu = cfg;
        cpu.gpu = false;
        return start(io, gpa, arena, cpu, key, diag) catch |e| switch (e) {
            error.GpuFailed => error.LocalFailed,
            else => |x| x,
        };
    };
}

/// Start the helper for `cfg` and wait until its model is loaded.
fn start(io: std.Io, gpa: std.mem.Allocator, arena: std.mem.Allocator, cfg: Config, key: []const u8, diag: *[]const u8) (Error || error{GpuFailed})!*Runner {
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(arena, &.{ cfg.exe, "--llm-helper", "--model", cfg.model, "--ctx", try std.fmt.allocPrint(arena, "{d}", .{cfg.ctx}) });
    if (!cfg.gpu) try argv.append(arena, "--cpu");
    var child = std.process.spawn(io, .{
        .argv = argv.items,
        .stdin = .pipe,
        .stdout = .pipe,
        .stderr = .pipe,
        .create_no_window = true,
    }) catch |err| {
        diag.* = std.fmt.allocPrint(arena, "Could not start GhostPen's built-in model runner ({s}).", .{@errorName(err)}) catch "Could not start GhostPen's built-in model runner.";
        return error.LocalFailed;
    };

    const r = gpa.create(Runner) catch {
        child.kill(io);
        return error.OutOfMemory;
    };
    const buf = gpa.alloc(u8, 256 * 1024) catch {
        gpa.destroy(r);
        child.kill(io);
        return error.OutOfMemory;
    };
    const owned_key = gpa.dupe(u8, key) catch {
        gpa.free(buf);
        gpa.destroy(r);
        child.kill(io);
        return error.OutOfMemory;
    };
    r.* = .{
        .child = child,
        .key = owned_key,
        .stdout_buf = buf,
        .reader = undefined,
        .stdin = undefined,
        .gpu = &.{},
        .ctx = 0,
        .last_used = .now(io, .awake),
        .idle_minutes = cfg.idle_minutes,
    };
    r.reader = r.child.stdout.?.readerStreaming(io, r.stdout_buf);
    r.stdin = r.child.stdin.?.writerStreaming(io, &r.stdin_buf);
    gpa_global = gpa;
    tail_mutex.lockUncancelable(io);
    tail_len = 0;
    tail_mutex.unlock(io);
    runner = r;
    r.stderr_thread = std.Thread.spawn(.{}, drainStderr, .{ io, r.child.stderr.? }) catch {
        // Nothing would drain stderr: the helper could block on it.
        stop(io);
        diag.* = "Could not start GhostPen's built-in model runner (no thread).";
        return error.LocalFailed;
    };
    {
        stdin_mutex.lockUncancelable(io);
        defer stdin_mutex.unlock(io);
        stdin_writer = &r.stdin;
    }

    // Wait for the ready line (the model loads in the helper); anything else
    // a GPU backend prints on stdout first is skipped.
    const Ready = struct { ready: bool = false, ctx: u32 = 0, gpu: ?[]const u8 = null };
    var deadline: Deadline = .{ .child = &r.child, .kill_after_ms = load_timeout_ms };
    deadline.start(io);
    const ready: Ready = while (true) {
        const line = (r.reader.interface.takeDelimiter('\n') catch null) orelse {
            deadline.finish();
            stop(io);
            const why = tail(io, arena);
            diag.* = if (deadline.timed_out.load(.acquire))
                "The built-in model took more than 10 minutes to load and was stopped."
            else
                std.fmt.allocPrint(arena, "The built-in model could not be loaded{s}{s}", .{ if (why.len > 0) ": " else ".", why }) catch "The built-in model could not be loaded.";
            const gpu_error = std.mem.indexOf(u8, why, "CUDA error") != null or std.mem.indexOf(u8, why, "out of memory") != null or
                std.mem.indexOf(u8, why, "cudaMalloc") != null or std.mem.indexOf(u8, why, "Metal") != null;
            if (cfg.gpu and gpu_error and !deadline.timed_out.load(.acquire)) return error.GpuFailed;
            return error.LocalFailed;
        };
        const parsed = std.json.parseFromSliceLeaky(Ready, arena, line, .{ .ignore_unknown_fields = true }) catch continue;
        if (parsed.ready) break parsed;
    };
    deadline.finish();
    r.ctx = ready.ctx;
    r.gpu = gpa.dupe(u8, ready.gpu orelse "CPU") catch &.{};
    is_loaded.store(true, .release);
    log.info("built-in model loaded: {s} ({d}-token context, {s})", .{ std.fs.path.basename(cfg.model), r.ctx, if (r.gpu.len > 0) r.gpu else "CPU" });

    if (watchdog == null) watchdog = std.Thread.spawn(.{}, idleWatch, .{io}) catch null;
    return r;
}

/// A watchdog for a blocking read from the helper: after `cancel_after_ms`
/// it asks the running request to stop; after `kill_after_ms` it kills the
/// helper (which ends the read with EOF).
const Deadline = struct {
    child: *std.process.Child,
    cancel_after_ms: ?u64 = null,
    kill_after_ms: u64,
    done: std.atomic.Value(bool) = .init(false),
    timed_out: std.atomic.Value(bool) = .init(false),
    thread: ?std.Thread = null,

    fn start(self: *Deadline, io: std.Io) void {
        self.thread = std.Thread.spawn(.{}, run, .{ self, io }) catch null;
    }

    /// Stop watching (idempotent).
    fn finish(self: *Deadline) void {
        self.done.store(true, .release);
        if (self.thread) |t| t.join();
        self.thread = null;
    }

    fn run(self: *Deadline, io: std.Io) void {
        var waited: u64 = 0;
        var cancelled = false;
        while (!self.done.load(.acquire)) : (waited += 100) {
            std.Io.sleep(io, .fromMilliseconds(100), .awake) catch {};
            if (self.cancel_after_ms) |ms| if (!cancelled and waited >= ms) {
                cancelled = true;
                self.timed_out.store(true, .release);
                cancel(io);
            };
            if (waited >= self.kill_after_ms) {
                self.timed_out.store(true, .release);
                killOnly(self.child);
                return;
            }
        }
    }
};

/// Send the process a kill signal without reaping it (`stop` waits for it).
fn killOnly(child: *std.process.Child) void {
    const id = child.id orelse return;
    switch (builtin.os.tag) {
        .windows => _ = std.os.windows.ntdll.NtTerminateProcess(id, @enumFromInt(1)),
        else => std.posix.kill(id, std.posix.SIG.KILL) catch {},
    }
}

/// Kill the runner and free it. Caller holds `mutex`.
fn stop(io: std.Io) void {
    const r = runner orelse return;
    {
        stdin_mutex.lockUncancelable(io);
        defer stdin_mutex.unlock(io);
        stdin_writer = null;
    }
    runner = null;
    is_loaded.store(false, .release);
    // Kill, let the stderr drain see EOF and end, then reap (which closes
    // the pipes): never close a pipe another thread still reads.
    killOnly(&r.child);
    if (r.stderr_thread) |t| t.join();
    r.child.kill(io);
    gpa_global.free(r.key);
    gpa_global.free(r.stdout_buf);
    if (r.gpu.len > 0) gpa_global.free(r.gpu);
    gpa_global.destroy(r);
    log.info("built-in model unloaded", .{});
}

fn drainStderr(io: std.Io, file: std.Io.File) void {
    var buf: [4096]u8 = undefined;
    var reader = file.readerStreaming(io, &buf);
    while (true) {
        const line = reader.interface.takeDelimiter('\n') catch |err| switch (err) {
            error.StreamTooLong => {
                reader.interface.toss(reader.interface.buffered().len);
                continue;
            },
            else => return,
        } orelse return;
        log.debug("runner: {s}", .{line});
        tail_mutex.lockUncancelable(io);
        defer tail_mutex.unlock(io);
        const keep = @min(line.len + 1, tail_buf.len);
        if (tail_len + keep > tail_buf.len) {
            const drop = tail_len + keep - tail_buf.len;
            std.mem.copyForwards(u8, tail_buf[0 .. tail_len - drop], tail_buf[drop..tail_len]);
            tail_len -= drop;
        }
        @memcpy(tail_buf[tail_len..][0 .. keep - 1], line[line.len - (keep - 1) ..]);
        tail_buf[tail_len + keep - 1] = '\n';
        tail_len += keep;
    }
}

/// Unload the model after `idle_minutes` without a request.
fn idleWatch(io: std.Io) void {
    while (true) {
        io.sleep(.fromSeconds(30), .awake) catch return;
        if (busy.load(.acquire)) continue;
        mutex.lockUncancelable(io);
        defer mutex.unlock(io);
        const r = runner orelse continue;
        if (r.idle_minutes == 0) continue;
        const idle = r.last_used.durationTo(.now(io, .awake));
        if (idle.raw.toSeconds() >= @as(i64, r.idle_minutes) * 60) stop(io);
    }
}

test keyOf {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = try keyOf(arena.allocator(), .{ .exe = "x", .model = "m", .ctx = 8192 });
    const b = try keyOf(arena.allocator(), .{ .exe = "x", .model = "m", .ctx = 4096 });
    try std.testing.expect(!std.mem.eql(u8, a, b));
}
