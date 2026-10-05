//! Performance counters of the built-in model, for the model service's
//! `GET /metrics` (model_server.zig): totals over the app's lifetime, the
//! last finished request, and the one running now. `local_llm` records what
//! the runner reports — tokens and wall-clock milliseconds of the prompt and
//! the generation, with progress lines while it generates (llm_helper.zig).
//! No clocks here: the caller passes the numbers it already has, so tests
//! don't need an io beyond the mutex's. All access is mutex-guarded: the
//! model service answers on other threads while a request runs.

const std = @import("std");

const gpa = std.heap.smp_allocator;

var mutex: std.Io.Mutex = .init;

var requests: u64 = 0;
var failed_requests: u64 = 0;
var prompt_tokens: u64 = 0;
var prompt_ms: u64 = 0;
var gen_tokens: u64 = 0;
var gen_ms: u64 = 0;

var last: ?Last = null;
var loaded: ?Info = null;
var current: ?InFlight = null;

/// A request's numbers (the runner's `done` line).
pub const Usage = struct {
    prompt_tokens: u64 = 0,
    gen_tokens: u64 = 0,
    prompt_ms: u64 = 0,
    gen_ms: u64 = 0,
};

pub const Last = struct {
    usage: Usage = .{},
    /// Seconds since the epoch when the answer finished.
    finished: i64 = 0,
};

/// A runner's model: what it is, where it runs and what it loaded with.
pub const Info = struct {
    /// The model file's basename ("" for the embedding runner).
    model: []const u8 = "",
    gpu: []const u8 = "",
    ctx: u32 = 0,
    load_ms: u64 = 0,
};

/// The request running now. `gen_ms` counts from the generation's start, so
/// its speed so far is `gen_tokens * 1000 / gen_ms` (the prompt part is the
/// one-time eval: don't add the two ms together for a rate).
pub const InFlight = struct {
    info: Info = .{},
    usage: Usage = .{},
};

/// What `snapshot` hands the model service (strings point into its arena).
pub const Snapshot = struct {
    requests: u64 = 0,
    failed_requests: u64 = 0,
    prompt_tokens: u64 = 0,
    prompt_ms: u64 = 0,
    gen_tokens: u64 = 0,
    gen_ms: u64 = 0,
    last: ?Last = null,
    loaded: ?Info = null,
    in_flight: ?InFlight = null,
};

/// The request reached the runner (the model may still have to load).
pub fn requestStarted(io: std.Io, model: []const u8, gpu: []const u8, ctx: u32) void {
    mutex.lockUncancelable(io);
    defer mutex.unlock(io);
    freeCurrent(current);
    current = .{ .info = dupeInfo(gpa, .{
        .model = model,
        .gpu = gpu,
        .ctx = ctx,
        .load_ms = if (loaded) |l| l.load_ms else 0,
    }) catch .{} };
}

/// The runner's progress: the prompt's size right after its eval, then the
/// generation's count so far (the fields it sends are used as they arrive).
pub fn requestProgress(io: std.Io, usage: Usage) void {
    mutex.lockUncancelable(io);
    defer mutex.unlock(io);
    if (current) |*c| {
        if (usage.prompt_tokens > 0) {
            c.usage.prompt_tokens = usage.prompt_tokens;
            c.usage.prompt_ms = usage.prompt_ms;
        }
        if (usage.gen_tokens > 0) {
            c.usage.gen_tokens = usage.gen_tokens;
            c.usage.gen_ms = usage.gen_ms;
        }
    }
}

/// A request finished (cancelled counts: it generated what it generated).
pub fn requestDone(io: std.Io, finished: i64, usage: Usage) void {
    mutex.lockUncancelable(io);
    defer mutex.unlock(io);
    requests += 1;
    prompt_tokens += usage.prompt_tokens;
    prompt_ms += usage.prompt_ms;
    gen_tokens += usage.gen_tokens;
    gen_ms += usage.gen_ms;
    last = .{ .usage = usage, .finished = finished };
    freeCurrent(current);
    current = null;
}

/// The request failed (runner died, out of memory, took too long).
pub fn requestFailed(io: std.Io) void {
    mutex.lockUncancelable(io);
    defer mutex.unlock(io);
    failed_requests += 1;
    freeCurrent(current);
    current = null;
}

/// The runner (re)loaded its model.
pub fn modelLoaded(io: std.Io, model: []const u8, gpu: []const u8, ctx: u32, load_ms: u64) void {
    mutex.lockUncancelable(io);
    defer mutex.unlock(io);
    freeInfo(loaded);
    loaded = dupeInfo(gpa, .{ .model = model, .gpu = gpu, .ctx = ctx, .load_ms = load_ms }) catch .{};
}

/// A copy of the counters for the model service to turn into JSON.
pub fn snapshot(io: std.Io, arena: std.mem.Allocator) Snapshot {
    mutex.lockUncancelable(io);
    defer mutex.unlock(io);
    return .{
        .requests = requests,
        .failed_requests = failed_requests,
        .prompt_tokens = prompt_tokens,
        .prompt_ms = prompt_ms,
        .gen_tokens = gen_tokens,
        .gen_ms = gen_ms,
        .last = last,
        .loaded = if (loaded) |l| dupeInfo(arena, l) catch null else null,
        .in_flight = if (current) |c| .{
            .info = dupeInfo(arena, c.info) catch .{},
            .usage = c.usage,
        } else null,
    };
}

fn dupeInfo(arena: std.mem.Allocator, info: Info) !Info {
    return .{
        .model = try arena.dupe(u8, info.model),
        .gpu = try arena.dupe(u8, info.gpu),
        .ctx = info.ctx,
        .load_ms = info.load_ms,
    };
}

/// The strings are owned by the registry: free them before replacing.
fn freeInfo(info: ?Info) void {
    const i = info orelse return;
    if (i.model.len > 0) gpa.free(i.model);
    if (i.gpu.len > 0) gpa.free(i.gpu);
}

fn freeCurrent(in_flight: ?InFlight) void {
    freeInfo(if (in_flight) |c| c.info else null);
}

test "record, fail and snapshot" {
    const io = std.testing.io;
    requestStarted(io, "m.gguf", "CPU", 4096);
    requestProgress(io, .{ .prompt_tokens = 10, .prompt_ms = 5 });
    requestProgress(io, .{ .gen_tokens = 20, .gen_ms = 100 });
    requestDone(io, 1759, .{ .prompt_tokens = 10, .gen_tokens = 42, .prompt_ms = 5, .gen_ms = 200 });
    requestStarted(io, "m.gguf", "NVIDIA GeForce RTX 4070", 8192);
    requestProgress(io, .{ .gen_tokens = 3, .gen_ms = 250 });
    requestFailed(io);
    modelLoaded(io, "m.gguf", "NVIDIA GeForce RTX 4070", 8192, 2100);

    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const s = snapshot(io, arena_state.allocator());
    try std.testing.expectEqual(@as(u64, 1), s.requests);
    try std.testing.expectEqual(@as(u64, 1), s.failed_requests);
    try std.testing.expectEqual(@as(u64, 10), s.prompt_tokens);
    try std.testing.expectEqual(@as(u64, 42), s.gen_tokens);
    try std.testing.expectEqual(@as(u64, 200), s.gen_ms);
    try std.testing.expectEqual(@as(i64, 1759), s.last.?.finished);
    try std.testing.expectEqualStrings("m.gguf", s.loaded.?.model);
    try std.testing.expectEqual(@as(u32, 8192), s.loaded.?.ctx);
    try std.testing.expectEqual(@as(u64, 2100), s.loaded.?.load_ms);
    try std.testing.expect(s.in_flight == null); // it failed, so it's gone
}
