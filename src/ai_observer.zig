//! Request-scoped AI telemetry. Unknown provider measurements stay null.
pub const Stats = struct {
    model: []const u8 = "",
    backend: []const u8 = "",
    contextTokens: u32 = 0,
    elapsedMs: u64 = 0,
    loadMs: u64 = 0,
    queueMs: u64 = 0,
    conversationMs: u64 = 0,
    prefillMs: ?u64 = null,
    generationMs: ?u64 = null,
    promptTokens: ?u64 = null,
    evaluatedTokens: ?u64 = null,
    cachedTokens: ?u64 = null,
    generatedTokens: ?u64 = null,
    firstTokenMs: ?u64 = null,
    requests: u32 = 0,
};

pub fn combine(a: Stats, b: Stats) Stats {
    var out = a;
    if (b.model.len > 0) out.model = b.model;
    if (b.backend.len > 0) out.backend = b.backend;
    if (b.contextTokens > 0) out.contextTokens = b.contextTokens;
    out.loadMs += b.loadMs;
    out.prefillMs = sum(a.prefillMs, b.prefillMs);
    out.generationMs = sum(a.generationMs, b.generationMs);
    out.promptTokens = sum(a.promptTokens, b.promptTokens);
    out.evaluatedTokens = sum(a.evaluatedTokens, b.evaluatedTokens);
    out.cachedTokens = sum(a.cachedTokens, b.cachedTokens);
    out.generatedTokens = sum(a.generatedTokens, b.generatedTokens);
    out.requests += b.requests;
    return out;
}

fn sum(a: ?u64, b: ?u64) ?u64 {
    if (a == null and b == null) return null;
    return (a orelse 0) + (b orelse 0);
}

test "request stats accumulate without inventing unknown provider usage" {
    const testing = @import("std").testing;
    const a: Stats = .{ .promptTokens = 100, .cachedTokens = 80, .evaluatedTokens = 20, .prefillMs = 10, .requests = 1 };
    const b: Stats = .{ .promptTokens = 50, .cachedTokens = 0, .evaluatedTokens = 50, .prefillMs = 20, .requests = 1 };
    const combined = combine(a, b);
    try testing.expectEqual(@as(?u64, 150), combined.promptTokens);
    try testing.expectEqual(@as(?u64, 70), combined.evaluatedTokens);
    try testing.expectEqual(@as(?u64, 30), combined.prefillMs);
    try testing.expectEqual(@as(u32, 2), combined.requests);
    try testing.expect(combined.generatedTokens == null);
    try testing.expect(combine(.{}, .{}).prefillMs == null);
}

pub const Stage = enum { loading_conversation, waiting, loading_model, prefilling, generating, complete };
pub const Progress = struct {
    stage: Stage,
    stats: Stats = .{},
    prefilledTokens: ?u64 = null,
};
pub const Observer = struct {
    context: *anyopaque,
    callback: *const fn (*anyopaque, Progress) void,

    pub fn emit(self: Observer, progress: Progress) void {
        self.callback(self.context, progress);
    }
};
