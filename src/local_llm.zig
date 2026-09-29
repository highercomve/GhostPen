//! The built-in model: the client of GhostPen's own runner (`llm_helper.zig`).
//!
//! The runner is GhostPen's executable in helper mode, started on the first
//! request with the chosen model, kept loaded between requests (a menu
//! action shouldn't pay the load time) and stopped after `idle_minutes`
//! without use, or when the model or its settings change. Plain std: the CLI
//! uses it too.
//!
//! Two runners, each started only when needed and stopped on its own: one
//! for chat (the model and its vision projector), one for embeddings (a small
//! model: a search never loads the chat model). A request's `keep_alive_ms`
//! (the model service's `keep_alive`) overrides the idle time: 0 stops the
//! runner as soon as it answers.

const std = @import("std");
const builtin = @import("builtin");

const log = std.log.scoped(.local_llm);

pub const Config = struct {
    /// The executable to run in helper mode (`--llm-helper`).
    exe: []const u8,
    /// The model file (.gguf).
    model: []const u8,
    /// Its vision projector (mmproj .gguf): images in `Chat.image`.
    mmproj: ?[]const u8 = null,
    /// A small embedding model (.gguf) for `embed`.
    embed_model: ?[]const u8 = null,
    ctx: u32 = 8192,
    gpu: bool = true,
    /// MoE models: the percentage of blocks whose expert weights stay in
    /// system RAM (100 = every expert; 0 = all on the GPU).
    moe_pct: u8 = 0,
    /// KV cache precision: f16, q8_0 or q4_0.
    kv_type: []const u8 = "q8_0",
    /// auto, on or off.
    flash_attn: []const u8 = "auto",
    idle_minutes: u32 = 10,
};

pub const Chat = struct {
    system: []const u8,
    user: []const u8,
    temperature: f64 = 0.2,
    think: bool = false,
    max_tokens: u32 = 2048,
    /// An image (PNG/JPEG bytes) before the text; needs `Config.mmproj`.
    image: ?[]const u8 = null,
    /// A JSON Schema the answer must match ("" = free text).
    schema: []const u8 = "",
    /// Keep the runner this long after the answer (0: stop it now); null:
    /// `Config.idle_minutes`.
    keep_alive_ms: ?u64 = null,
    /// The context this request needs, when more than `Config.ctx`: the
    /// runner restarts with it (and keeps it until it stops).
    ctx: ?u32 = null,
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
/// killed if it doesn't stop). Long enough for a 128k-token prompt to be read
/// on a slow machine; when it fires, the request is cancelled first, which
/// returns the text generated so far.
const generate_timeout_ms = 15 * 60 * 1000;
/// Text the helper accepts in one request.
const max_request_bytes = 240 * 1024;
/// A request line with an image in base64 (the helper's line buffer is 32 MiB).
const max_image_line_bytes = 30 * 1024 * 1024;

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
    /// A request's keep_alive: this long after the last answer, not
    /// `idle_minutes`.
    idle_override_ms: ?u64 = null,
    /// The context it was started with (what it got can be less: the helper
    /// halves it when the memory runs out; asking again won't help).
    requested_ctx: u32 = 0,
};

/// One runner's state: chat or embeddings.
const Slot = struct {
    name: []const u8,
    mutex: std.Io.Mutex = .init,
    runner: ?*Runner = null,
    /// Serializes writes to the runner's stdin (a cancel can come from another thread).
    stdin_mutex: std.Io.Mutex = .init,
    stdin_writer: ?*std.Io.File.Writer = null,
    busy: std.atomic.Value(bool) = .init(false),
    is_loaded: std.atomic.Value(bool) = .init(false),
    /// The last lines llama.cpp wrote to stderr, for error messages.
    tail_mutex: std.Io.Mutex = .init,
    tail_buf: [2048]u8 = undefined,
    tail_len: usize = 0,
};

var chat_slot: Slot = .{ .name = "built-in model" };
var embed_slot: Slot = .{ .name = "embedding model" };
var watchdog: ?std.Thread = null;
var gpa_global: std.mem.Allocator = undefined;

/// The chat runner's configuration (no embedding model).
fn chatConfig(cfg: Config) Config {
    var c = cfg;
    c.embed_model = null;
    return c;
}

/// The embedding runner's configuration (the embedding model only).
fn embedConfig(cfg: Config) Config {
    var c = cfg;
    c.model = "";
    c.mmproj = null;
    return c;
}

/// After an answer: the request's keep_alive (0: stop the runner now).
fn keepAlive(io: std.Io, s: *Slot, r: *Runner, keep_ms: ?u64) void {
    const ms = keep_ms orelse return;
    if (ms == 0) return stop(io, s);
    r.idle_override_ms = ms;
}

/// What a runner was started with, except the context size (a runner with
/// at least the context a request needs serves it: `ensure`).
fn keyOf(arena: std.mem.Allocator, cfg: Config) ![]u8 {
    return std.fmt.allocPrint(arena, "{s}\x00{s}\x00{s}\x00{s}\x00{}\x00{}\x00{s}\x00{s}", .{ cfg.exe, cfg.model, cfg.mmproj orelse "", cfg.embed_model orelse "", cfg.gpu, cfg.moe_pct, cfg.kv_type, cfg.flash_attn });
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
    const s = &chat_slot;
    s.mutex.lockUncancelable(io);
    defer s.mutex.unlock(io);
    s.busy.store(true, .release);
    defer s.busy.store(false, .release);

    // Before loading anything (escaping only makes the line longer).
    if (req.system.len + req.user.len > max_request_bytes) {
        diag.* = "The text is too long for the built-in model (about 200 KB at most): select less.";
        return error.LocalFailed;
    }
    if (req.image) |img| if (std.base64.standard.Encoder.calcSize(img.len) + req.system.len + req.user.len > max_image_line_bytes) {
        diag.* = "The image is too large for the built-in model.";
        return error.LocalFailed;
    };
    if (req.image != null and cfg.mmproj == null) {
        diag.* = "This built-in model can't read images: download its image projector in Settings → Built-in models, or pick a model that has one.";
        return error.LocalFailed;
    }
    var ccfg = chatConfig(cfg);
    if (req.ctx) |n| ccfg.ctx = @max(ccfg.ctx, n);
    const r = try ensure(io, s, gpa, arena, ccfg, diag);
    const id = r.next_id;
    r.next_id += 1;
    const image_b64: []const u8 = if (req.image) |img| blk: {
        const enc = std.base64.standard.Encoder;
        const out = try arena.alloc(u8, enc.calcSize(img.len));
        break :blk enc.encode(out, img);
    } else "";
    const line_out = try std.json.Stringify.valueAlloc(arena, .{
        .id = id,
        .cmd = "chat",
        .system = req.system,
        .user = req.user,
        .max_tokens = req.max_tokens,
        .temperature = req.temperature,
        .think = req.think,
        .image = image_b64,
        .schema = req.schema,
    }, .{});
    if (image_b64.len > 0 and line_out.len > max_image_line_bytes) {
        diag.* = "The image is too large for the built-in model.";
        return error.LocalFailed;
    }
    if (image_b64.len == 0 and line_out.len > max_request_bytes) {
        diag.* = "The text is too long for the built-in model (about 200 KB at most): select less.";
        return error.LocalFailed;
    }
    {
        s.stdin_mutex.lockUncancelable(io);
        defer s.stdin_mutex.unlock(io);
        const w = &r.stdin.interface;
        w.writeAll(line_out) catch return lost(io, s, arena, diag);
        w.writeByte('\n') catch return lost(io, s, arena, diag);
        w.flush() catch return lost(io, s, arena, diag);
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
        prompt_tokens: u64 = 0,
        gen_tokens: u64 = 0,
        prompt_ms: u64 = 0,
        gen_ms: u64 = 0,
    };
    while (true) {
        const line = (r.reader.interface.takeDelimiter('\n') catch null) orelse {
            deadline.finish();
            if (deadline.timed_out.load(.acquire)) {
                stop(io, s);
                diag.* = "The built-in model took too long and was stopped.";
                return error.LocalFailed;
            }
            return lost(io, s, arena, diag);
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
            // The generation speed, for the log: what to blame when a big
            // model crawls (GPU layers, expert offload, context size).
            if (msg.gen_ms >= 100 and msg.gen_tokens > 0) {
                log.info("built-in model: {d} tokens in {d} ms ({d:.1} tok/s); prompt {d} tokens in {d} ms", .{
                    msg.gen_tokens, msg.gen_ms, @as(f64, @floatFromInt(msg.gen_tokens)) * 1000.0 / @as(f64, @floatFromInt(msg.gen_ms)), msg.prompt_tokens, msg.prompt_ms,
                });
            }
            if (msg.cancelled and deadline.timed_out.load(.acquire)) {
                diag.* = "The built-in model took too long (over 15 minutes) and was stopped.";
                return error.LocalFailed;
            }
            deadline.finish(); // before a keep_alive of 0 kills the runner
            keepAlive(io, s, r, req.keep_alive_ms);
            return .{ .text = text.items, .truncated = msg.truncated, .cancelled = msg.cancelled };
        }
    }
}

/// Embed `texts` with the runner's embedding model (`cfg.embed_model`), one
/// L2-normalized vector each; the model's name in `model_out`. Results point
/// into `arena`.
pub fn embed(
    io: std.Io,
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    cfg: Config,
    texts: []const []const u8,
    model_out: *[]const u8,
    keep_alive_ms: ?u64,
    diag: *[]const u8,
) Error![]const []const f32 {
    if (cfg.embed_model == null) {
        diag.* = "No embedding model is set up.";
        return error.LocalFailed;
    }
    const s = &embed_slot;
    s.mutex.lockUncancelable(io);
    defer s.mutex.unlock(io);
    s.busy.store(true, .release);
    defer s.busy.store(false, .release);
    const r = try ensure(io, s, gpa, arena, embedConfig(cfg), diag);
    const id = r.next_id;
    r.next_id += 1;
    const line_out = try std.json.Stringify.valueAlloc(arena, .{ .id = id, .cmd = "embed", .texts = texts }, .{});
    {
        s.stdin_mutex.lockUncancelable(io);
        defer s.stdin_mutex.unlock(io);
        const w = &r.stdin.interface;
        w.writeAll(line_out) catch return lost(io, s, arena, diag);
        w.writeByte('\n') catch return lost(io, s, arena, diag);
        w.flush() catch return lost(io, s, arena, diag);
    }
    const Line = struct {
        id: u64 = 0,
        done: bool = false,
        @"error": ?[]const u8 = null,
        embeddings: []const []const f32 = &.{},
        model: []const u8 = "",
    };
    while (true) {
        const line = (r.reader.interface.takeDelimiter('\n') catch null) orelse return lost(io, s, arena, diag);
        const msg = std.json.parseFromSliceLeaky(Line, arena, line, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch continue;
        if (msg.id != id and !(msg.id == 0 and msg.@"error" != null)) continue;
        r.last_used = .now(io, .awake);
        if (msg.@"error") |e| {
            diag.* = try arena.dupe(u8, e);
            return error.LocalFailed;
        }
        if (msg.done) {
            model_out.* = msg.model;
            keepAlive(io, s, r, keep_alive_ms);
            return msg.embeddings;
        }
    }
}

/// Stop the running request (it returns what it has so far).
pub fn cancel(io: std.Io) void {
    const s = &chat_slot;
    if (!s.busy.load(.acquire)) return;
    s.stdin_mutex.lockUncancelable(io);
    defer s.stdin_mutex.unlock(io);
    const w = s.stdin_writer orelse return;
    w.interface.writeAll("{\"cmd\":\"cancel\"}\n") catch return;
    w.interface.flush() catch {};
}

/// Stop both runners (frees the models' memory).
pub fn unload(io: std.Io) void {
    unloadChat(io);
    unloadEmbeddings(io);
}

/// Stop the chat runner (waits for an answer being written).
pub fn unloadChat(io: std.Io) void {
    chat_slot.mutex.lockUncancelable(io);
    defer chat_slot.mutex.unlock(io);
    stop(io, &chat_slot);
}

/// Stop the embedding runner.
pub fn unloadEmbeddings(io: std.Io) void {
    embed_slot.mutex.lockUncancelable(io);
    defer embed_slot.mutex.unlock(io);
    stop(io, &embed_slot);
}

/// The chat model is loaded right now.
pub fn loaded() bool {
    return chat_slot.is_loaded.load(.acquire);
}

/// The embedding model is loaded right now.
pub fn embeddingsLoaded() bool {
    return embed_slot.is_loaded.load(.acquire);
}

/// The runner died or the pipe broke: stop it and explain.
fn lost(io: std.Io, s: *Slot, arena: std.mem.Allocator, diag: *[]const u8) Error {
    stop(io, s);
    const why = tail(io, s, arena);
    diag.* = std.fmt.allocPrint(arena, "GhostPen's {s} stopped (crash or out of memory){s}{s}", .{ s.name, if (why.len > 0) ": " else ".", why }) catch "GhostPen's built-in model stopped.";
    return error.LocalFailed;
}

fn tail(io: std.Io, s: *Slot, arena: std.mem.Allocator) []const u8 {
    s.tail_mutex.lockUncancelable(io);
    defer s.tail_mutex.unlock(io);
    const t = std.mem.trim(u8, s.tail_buf[0..s.tail_len], " \t\r\n");
    // The last line is usually the one that explains.
    const last = if (std.mem.lastIndexOfScalar(u8, t, '\n')) |i| t[i + 1 ..] else t;
    return arena.dupe(u8, last) catch "";
}

/// The slot's runner for `cfg`, started (and the model loaded) if needed.
/// Caller holds `s.mutex`.
fn ensure(io: std.Io, s: *Slot, gpa: std.mem.Allocator, arena: std.mem.Allocator, cfg: Config, diag: *[]const u8) Error!*Runner {
    const key = try keyOf(arena, cfg);
    if (s.runner) |r| {
        if (std.mem.eql(u8, r.key, key) and r.requested_ctx >= cfg.ctx) {
            r.idle_minutes = cfg.idle_minutes;
            return r;
        }
        if (std.mem.eql(u8, r.key, key)) log.info("restarting the {s} for a {d}-token context", .{ s.name, cfg.ctx });
        stop(io, s);
    }
    const file = if (cfg.model.len > 0) cfg.model else cfg.embed_model orelse "";
    std.Io.Dir.cwd().access(io, file, .{}) catch {
        diag.* = std.fmt.allocPrint(arena, "The model file is missing: {s}. Download it in Settings → Built-in models.", .{file}) catch "The model file is missing.";
        return error.LocalFailed;
    };
    return start(io, s, gpa, arena, cfg, key, diag) catch |err| {
        // The GPU ran out of memory mid-load (llama.cpp aborts then). Two
        // strikes before the CPU: the first failure is often the previous
        // runner's VRAM not released yet (a kill returns before the driver
        // frees), so wait a moment and try the same plan once more.
        switch (err) {
            error.GpuFailed => {},
            error.LocalFailed => return error.LocalFailed,
            error.OutOfMemory => return error.OutOfMemory,
        }
        log.warn("GPU load failed ({s}); retrying after the previous runner's memory release", .{diag.*});
        std.Io.sleep(io, .fromSeconds(3), .awake) catch {};
        if (start(io, s, gpa, arena, cfg, key, diag)) |r| return r else |again| switch (again) {
            error.GpuFailed => {},
            error.LocalFailed => return error.LocalFailed,
            error.OutOfMemory => return error.OutOfMemory,
        }
        log.warn("GPU load failed again ({s}); loading on the CPU", .{diag.*});
        var cpu = cfg;
        cpu.gpu = false;
        return start(io, s, gpa, arena, cpu, key, diag) catch |e| switch (e) {
            error.GpuFailed => error.LocalFailed,
            else => |x| x,
        };
    };
}

/// Start the helper for `cfg` and wait until its model is loaded.
fn start(io: std.Io, s: *Slot, gpa: std.mem.Allocator, arena: std.mem.Allocator, cfg: Config, key: []const u8, diag: *[]const u8) (Error || error{GpuFailed})!*Runner {
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(arena, &.{ cfg.exe, "--llm-helper", "--ctx", try std.fmt.allocPrint(arena, "{d}", .{cfg.ctx}) });
    if (cfg.model.len > 0) try argv.appendSlice(arena, &.{ "--model", cfg.model });
    if (cfg.mmproj) |m| try argv.appendSlice(arena, &.{ "--mmproj", m });
    if (cfg.embed_model) |m| try argv.appendSlice(arena, &.{ "--embed-model", m });
    try argv.appendSlice(arena, &.{ "--kv-type", cfg.kv_type, "--flash-attn", cfg.flash_attn });
    if (!cfg.gpu) try argv.append(arena, "--cpu");
    if (cfg.moe_pct > 0) try argv.appendSlice(arena, &.{ "--moe-pct", try std.fmt.allocPrint(arena, "{d}", .{cfg.moe_pct}) });
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
    // A reply is one line: a batch of embeddings (768 floats each) is large;
    // pages are only touched as used.
    const buf = gpa.alloc(u8, 16 * 1024 * 1024) catch {
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
        .requested_ctx = cfg.ctx,
    };
    r.reader = r.child.stdout.?.readerStreaming(io, r.stdout_buf);
    r.stdin = r.child.stdin.?.writerStreaming(io, &r.stdin_buf);
    gpa_global = gpa;
    s.tail_mutex.lockUncancelable(io);
    s.tail_len = 0;
    s.tail_mutex.unlock(io);
    s.runner = r;
    r.stderr_thread = std.Thread.spawn(.{}, drainStderr, .{ io, s, r.child.stderr.? }) catch {
        // Nothing would drain stderr: the helper could block on it.
        stop(io, s);
        diag.* = "Could not start GhostPen's built-in model runner (no thread).";
        return error.LocalFailed;
    };
    {
        s.stdin_mutex.lockUncancelable(io);
        defer s.stdin_mutex.unlock(io);
        s.stdin_writer = &r.stdin;
    }

    // Wait for the ready line (the model loads in the helper); anything else
    // a GPU backend prints on stdout first is skipped.
    const Ready = struct { ready: bool = false, ctx: u32 = 0, gpu: ?[]const u8 = null };
    var deadline: Deadline = .{ .child = &r.child, .kill_after_ms = load_timeout_ms };
    deadline.start(io);
    const ready: Ready = while (true) {
        const line = (r.reader.interface.takeDelimiter('\n') catch null) orelse {
            deadline.finish();
            stop(io, s);
            const why = tail(io, s, arena);
            diag.* = if (deadline.timed_out.load(.acquire))
                "The built-in model took more than 10 minutes to load and was stopped."
            else
                std.fmt.allocPrint(arena, "The built-in model could not be loaded{s}{s}", .{ if (why.len > 0) ": " else ".", why }) catch "The built-in model could not be loaded.";
            const gpu_error = std.mem.indexOf(u8, why, "CUDA error") != null or std.mem.indexOf(u8, why, "out of memory") != null or
                std.mem.indexOf(u8, why, "cudaMalloc") != null or std.mem.indexOf(u8, why, "Metal") != null or
                // An allocation that failed (GPU memory taken by another app).
                std.mem.indexOf(u8, why, "GGML_ASSERT(buffer)") != null or std.mem.indexOf(u8, why, "failed to allocate") != null or
                std.mem.indexOf(u8, why, "ErrorOutOfDeviceMemory") != null;
            if (cfg.gpu and gpu_error and !deadline.timed_out.load(.acquire)) return error.GpuFailed;
            return error.LocalFailed;
        };
        const parsed = std.json.parseFromSliceLeaky(Ready, arena, line, .{ .ignore_unknown_fields = true }) catch continue;
        if (parsed.ready) break parsed;
    };
    deadline.finish();
    r.ctx = ready.ctx;
    r.gpu = gpa.dupe(u8, ready.gpu orelse "CPU") catch &.{};
    s.is_loaded.store(true, .release);
    if (cfg.model.len > 0)
        log.info("built-in model loaded: {s} ({d}-token context, {s})", .{ std.fs.path.basename(cfg.model), r.ctx, if (r.gpu.len > 0) r.gpu else "CPU" })
    else
        log.info("embedding model loaded: {s} ({s})", .{ std.fs.path.basename(cfg.embed_model orelse ""), if (r.gpu.len > 0) r.gpu else "CPU" });

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

/// Kill the slot's runner and free it. Caller holds `s.mutex`.
fn stop(io: std.Io, s: *Slot) void {
    const r = s.runner orelse return;
    {
        s.stdin_mutex.lockUncancelable(io);
        defer s.stdin_mutex.unlock(io);
        s.stdin_writer = null;
    }
    s.runner = null;
    s.is_loaded.store(false, .release);
    // Kill, let the stderr drain see EOF and end, then reap (which closes
    // the pipes): never close a pipe another thread still reads.
    killOnly(&r.child);
    if (r.stderr_thread) |t| t.join();
    r.child.kill(io);
    gpa_global.free(r.key);
    gpa_global.free(r.stdout_buf);
    if (r.gpu.len > 0) gpa_global.free(r.gpu);
    gpa_global.destroy(r);
    log.info("{s} unloaded", .{s.name});
}

fn drainStderr(io: std.Io, s: *Slot, file: std.Io.File) void {
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
        // Errors and the load's own notes (GPU split, expert offload): the
        // only trace of a failed load, and low volume (the helper filters
        // llama.cpp's chatter to errors).
        log.info("runner: {s}", .{line});
        s.tail_mutex.lockUncancelable(io);
        defer s.tail_mutex.unlock(io);
        const keep = @min(line.len + 1, s.tail_buf.len);
        if (s.tail_len + keep > s.tail_buf.len) {
            const drop = s.tail_len + keep - s.tail_buf.len;
            std.mem.copyForwards(u8, s.tail_buf[0 .. s.tail_len - drop], s.tail_buf[drop..s.tail_len]);
            s.tail_len -= drop;
        }
        @memcpy(s.tail_buf[s.tail_len..][0 .. keep - 1], line[line.len - (keep - 1) ..]);
        s.tail_buf[s.tail_len + keep - 1] = '\n';
        s.tail_len += keep;
    }
}

/// Stop each runner once it's been idle long enough: its request's
/// keep_alive, else `idle_minutes` (0: never). Never while a request runs.
fn idleWatch(io: std.Io) void {
    while (true) {
        io.sleep(.fromSeconds(5), .awake) catch return;
        for ([_]*Slot{ &chat_slot, &embed_slot }) |s| {
            if (s.busy.load(.acquire)) continue;
            s.mutex.lockUncancelable(io);
            defer s.mutex.unlock(io);
            const r = s.runner orelse continue;
            const limit_ms: i64 = if (r.idle_override_ms) |ms| @intCast(ms) else if (r.idle_minutes == 0) continue else @as(i64, r.idle_minutes) * 60_000;
            const idle = r.last_used.durationTo(.now(io, .awake));
            if (idle.raw.toMilliseconds() >= limit_ms) stop(io, s);
        }
    }
}

test keyOf {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = try keyOf(arena.allocator(), .{ .exe = "x", .model = "m", .ctx = 8192 });
    const b = try keyOf(arena.allocator(), .{ .exe = "x", .model = "m", .ctx = 4096 });
    const c = try keyOf(arena.allocator(), .{ .exe = "x", .model = "n", .ctx = 8192 });
    // The context size is compared apart (at least as much is fine).
    try std.testing.expectEqualStrings(a, b);
    try std.testing.expect(!std.mem.eql(u8, a, c));
}
