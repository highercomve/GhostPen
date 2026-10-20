//! Normalize exposed model output into answer/thinking once, at the producer
//! boundary. No prose or model-name heuristics: implicit thoughts require
//! template metadata; explicit blocks are recognized only before the answer.
const std = @import("std");
const chat_format = @import("chat_format.zig");

pub const Channel = enum { answer, thinking };
pub const Delta = struct { channel: Channel, text: []const u8 };
pub const max_bytes = 1024 * 1024;
pub const limit_message = "The model's output exceeded the 1 MiB limit. Try a shorter summary.";
pub const Error = error{ OutOfMemory, TooLarge };
const marker_bytes = blk: {
    var n: usize = 0;
    for (chat_format.reasoning_blocks) |r| n = @max(n, @max(r.open.len, r.close.len));
    break :blk n;
};

pub const Stream = struct {
    arena: std.mem.Allocator,
    answer: std.ArrayList(u8) = .empty,
    thinking: std.ArrayList(u8) = .empty,
    received: usize = 0,
    limit: usize = max_bytes,
    failed: bool = false,
    mode: enum { prefix, thought, answer } = .prefix,
    close: []const u8 = "",
    // Fixed control-marker lookahead is the entire scanner buffer;
    // no suffix search or full-history scan occurs on a subsequent delta.
    pending: [marker_bytes]u8 = undefined,
    held: usize = 0,

    pub fn init(arena: std.mem.Allocator, initial: ?chat_format.Reasoning) Stream {
        return .{ .arena = arena, .mode = if (initial != null) .thought else .prefix, .close = if (initial) |r| r.close else "" };
    }

    pub fn forPrompt(arena: std.mem.Allocator, format: chat_format.Format, think: bool) Stream {
        const r = chat_format.reasoning(format);
        return init(arena, if (think and r != null and r.?.opened_by_prompt) r else null);
    }

    fn reserve(self: *Stream, n: usize) Error!void {
        if (self.failed or n > self.limit - self.received) {
            self.failed = true;
            return error.TooLarge;
        }
        self.received += n;
    }

    fn append(self: *Stream, channel: Channel, text: []const u8) error{OutOfMemory}!void {
        const target = if (channel == .answer) &self.answer else &self.thinking;
        try target.appendSlice(self.arena, text);
    }

    fn emit(self: *Stream, answer_at: usize, thinking_at: usize, ctx: anytype, comptime on_chunk: fn (@TypeOf(ctx), Delta) void) void {
        if (self.thinking.items.len > thinking_at) on_chunk(ctx, .{ .channel = .thinking, .text = self.thinking.items[thinking_at..] });
        if (self.answer.items.len > answer_at) on_chunk(ctx, .{ .channel = .answer, .text = self.answer.items[answer_at..] });
    }

    /// Provider-declared fields are authoritative, including literal control
    /// tokens in content. They never pass through the inline-token scanner.
    pub fn field(self: *Stream, delta: Delta, ctx: anytype, comptime on_chunk: fn (@TypeOf(ctx), Delta) void) Error!void {
        try self.reserve(delta.text.len);
        const a = self.answer.items.len;
        const t = self.thinking.items.len;
        try self.append(delta.channel, delta.text);
        self.emit(a, t, ctx, on_chunk);
    }

    pub fn feed(self: *Stream, bytes: []const u8, ctx: anytype, comptime on_chunk: fn (@TypeOf(ctx), Delta) void) Error!void {
        try self.reserve(bytes.len);
        const a = self.answer.items.len;
        const t = self.thinking.items.len;
        for (bytes, 0..) |byte, i| {
            if (self.mode == .answer) {
                try self.append(.answer, bytes[i..]);
                break;
            }
            if (self.mode == .prefix and self.held == 0 and std.ascii.isWhitespace(byte)) {
                try self.append(.answer, &.{byte});
                continue;
            }
            self.pending[self.held] = byte;
            self.held += 1;
            if (self.mode == .prefix) {
                var prefix = false;
                for (chat_format.reasoning_blocks) |r| {
                    if (std.mem.startsWith(u8, r.open, self.pending[0..self.held])) {
                        prefix = true;
                        if (self.held == r.open.len) {
                            self.mode = .thought;
                            self.close = r.close;
                            self.held = 0;
                        }
                        break;
                    }
                }
                if (!prefix) {
                    try self.append(.answer, self.pending[0..self.held]);
                    self.held = 0;
                    self.mode = .answer;
                }
            } else {
                // Each byte is inspected against one fixed-length closing
                // marker. At most marker_bytes move; work is linear in input size.
                while (self.held > 0 and !std.mem.startsWith(u8, self.close, self.pending[0..self.held])) {
                    try self.append(.thinking, self.pending[0..1]);
                    std.mem.copyForwards(u8, self.pending[0 .. self.held - 1], self.pending[1..self.held]);
                    self.held -= 1;
                }
                if (self.held == self.close.len) {
                    self.held = 0;
                    self.mode = .prefix;
                }
            }
        }
        self.emit(a, t, ctx, on_chunk);
    }

    /// Completed literal marker prefixes survive; an unfinished thought never
    /// becomes an answer. Cancellation keeps ambiguous opener fragments hidden.
    pub fn finish(self: *Stream, ctx: anytype, comptime on_chunk: fn (@TypeOf(ctx), Delta) void) Error!void {
        return self.end(true, ctx, on_chunk);
    }

    pub fn cancel(self: *Stream, ctx: anytype, comptime on_chunk: fn (@TypeOf(ctx), Delta) void) Error!void {
        return self.end(false, ctx, on_chunk);
    }

    fn end(self: *Stream, completed: bool, ctx: anytype, comptime on_chunk: fn (@TypeOf(ctx), Delta) void) Error!void {
        if (self.failed) return error.TooLarge;
        const a = self.answer.items.len;
        const t = self.thinking.items.len;
        if (completed or self.mode == .thought) try self.append(if (self.mode == .thought) .thinking else .answer, self.pending[0..self.held]);
        self.held = 0;
        self.emit(a, t, ctx, on_chunk);
    }
};

fn ignore(_: void, _: Delta) void {}

test "live Summary formatting request matches the current production prompt" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const Fixture = struct { formatted_request: struct { system: []const u8 } };
    const fixture = try std.json.parseFromSliceLeaky(Fixture, a, @embedFile("fixtures/summary-gemma4-e4b.json"), .{ .ignore_unknown_fields = true });
    try std.testing.expectEqualStrings(try @import("web_page.zig").summaryPrompt(a, .standard), fixture.formatted_request.system);
}

test "live E4B thinking-on output keeps thoughts separate through completion" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const Fixture = struct {
        thinking_on: struct {
            producer: struct { format: chat_format.Format, initial_thinking: bool },
            chunks: []const []const u8,
            completion: struct { truncated: bool, cancelled: bool },
        },
    };
    const fixture = try std.json.parseFromSliceLeaky(Fixture, a, @embedFile("fixtures/summary-gemma4-e4b.json"), .{ .ignore_unknown_fields = true });
    const run = fixture.thinking_on;
    try std.testing.expect(run.producer.initial_thinking);
    try std.testing.expect(!run.completion.truncated and !run.completion.cancelled);
    var s = Stream.forPrompt(a, run.producer.format, true);
    var raw: std.ArrayList(u8) = .empty;
    const close = chat_format.reasoning(run.producer.format).?.close;
    for (run.chunks) |chunk| {
        try raw.appendSlice(a, chunk);
        try s.feed(chunk, {}, ignore);
        if (std.mem.indexOf(u8, raw.items, close) == null)
            try std.testing.expectEqualStrings("", s.answer.items);
    }
    try s.finish({}, ignore);
    const boundary = std.mem.indexOf(u8, raw.items, close).?;
    try std.testing.expect(boundary > 0);
    try std.testing.expectEqualStrings(raw.items[0..boundary], s.thinking.items);
    try std.testing.expectEqualStrings(raw.items[boundary + close.len ..], s.answer.items);
    try std.testing.expect(std.mem.indexOf(u8, s.answer.items, "## Key points") != null);
    try std.testing.expect(std.mem.indexOf(u8, s.answer.items, "## Details") != null);
}

test "original live E4B Summary fixture preserves the thinking-off output and initial channel" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const Fixture = struct {
        request: struct { system: []const u8, user: []const u8, think: bool },
        producer: struct { format: chat_format.Format, initial_thinking: bool },
        chunks: []const []const u8,
        completion: struct { truncated: bool, cancelled: bool },
    };
    const fixture = try std.json.parseFromSliceLeaky(Fixture, a, @embedFile("fixtures/summary-gemma4-e4b.json"), .{ .ignore_unknown_fields = true });
    try std.testing.expect(!fixture.request.think);
    try std.testing.expect(!fixture.producer.initial_thinking);
    try std.testing.expect(!fixture.completion.truncated and !fixture.completion.cancelled);
    const prompt = (try chat_format.render(a, fixture.producer.format, fixture.request.system, fixture.request.user, fixture.request.think)).?;
    try std.testing.expect(std.mem.endsWith(u8, prompt, "<|turn>model\n"));

    // Actual helper deltas, not an invented implicit-thinking channel. The
    // captured production combination is Gemma E4B + think=false.
    var s = Stream.forPrompt(a, fixture.producer.format, fixture.request.think);
    try std.testing.expectEqual(fixture.producer.initial_thinking, s.mode == .thought);
    var raw: std.ArrayList(u8) = .empty;
    for (fixture.chunks) |chunk| {
        try raw.appendSlice(a, chunk);
        try s.feed(chunk, {}, ignore);
        try std.testing.expectEqualStrings(raw.items, s.answer.items);
        try std.testing.expectEqualStrings("", s.thinking.items);
    }
    try s.finish({}, ignore);
    try std.testing.expectEqualStrings(raw.items, s.answer.items);
    try std.testing.expect(std.mem.indexOf(u8, s.answer.items, "## Key points") != null);
    try std.testing.expect(std.mem.indexOf(u8, s.answer.items, "## Details") != null);
    try std.testing.expect(std.mem.indexOf(u8, s.answer.items, "<channel|>") == null);
}

test "implicit template channel: every prefix and cancellation keep reasoning out of the answer" {
    const raw = "Analyze the request. Private reasoning<channel|>## Summary\nAnswer.";
    const end = std.mem.indexOf(u8, raw, "<channel|>").? + "<channel|>".len;
    for (0..raw.len + 1) |n| {
        var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
        defer arena.deinit();
        var s = Stream.init(arena.allocator(), chat_format.reasoning(.gemma4));
        for (raw[0..n]) |byte| try s.feed(&.{byte}, {}, ignore);
        try s.cancel({}, ignore);
        try std.testing.expectEqualStrings(if (n <= end) "" else raw[end..n], s.answer.items);
    }
}

test "ordinary headings, literal markers and incomplete literals survive completion" {
    const samples = [_][]const u8{
        "## Thinking Process:\n\nThis article describes how people solve problems.",
        "Thinking Process:\nAn ordinary heading, without producer metadata.",
        "The literal `<think>` and `<channel|>` tokens are documented here.",
        "```xml\n<think>example</think>\n```",
        "<thi",
        "2 < 3",
    };
    for (samples) |raw| {
        var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
        defer arena.deinit();
        var s = Stream.init(arena.allocator(), null);
        for (raw) |byte| try s.feed(&.{byte}, {}, ignore);
        try s.finish({}, ignore);
        try std.testing.expectEqualStrings(raw, s.answer.items);
        try std.testing.expectEqualStrings("", s.thinking.items);
    }
}

test "explicit channels: streaming and whole-response snapshots agree at every split" {
    for (chat_format.reasoning_blocks) |r| {
        var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
        defer arena.deinit();
        const raw = try std.fmt.allocPrint(arena.allocator(), "{s}Plan.{s}Summary.", .{ r.open, r.close });
        for (0..raw.len + 1) |n| {
            var s = Stream.init(arena.allocator(), null);
            try s.feed(raw[0..n], {}, ignore);
            if (n <= r.open.len + 5 + r.close.len) try std.testing.expectEqualStrings("", s.answer.items);
            var stopped = Stream.init(arena.allocator(), null);
            try stopped.feed(raw[0..n], {}, ignore);
            try stopped.cancel({}, ignore);
            if (n <= r.open.len + 5 + r.close.len) try std.testing.expectEqualStrings("", stopped.answer.items);
            try s.feed(raw[n..], {}, ignore);
            try s.finish({}, ignore);
            try std.testing.expectEqualStrings("Summary.", s.answer.items);
            try std.testing.expectEqualStrings("Plan.", s.thinking.items);
        }
    }
}

test "repeated blocks consume a fixed byte budget and overflow is sticky" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var s = Stream.init(arena.allocator(), null);
    const block = "<think>x</think>";
    const raw = try arena.allocator().alloc(u8, 16000 * block.len);
    for (0..16000) |i| @memcpy(raw[i * block.len ..][0..block.len], block);
    try s.feed(raw, {}, ignore);
    try std.testing.expectEqual(raw.len, s.received);
    try std.testing.expectEqual(@as(usize, 16000), s.thinking.items.len);
    try std.testing.expectEqualStrings("", s.answer.items);
    s.limit = s.received;
    try std.testing.expectError(error.TooLarge, s.feed("more", {}, ignore));
    try std.testing.expectError(error.TooLarge, s.feed("", {}, ignore));
    try std.testing.expectError(error.TooLarge, s.finish({}, ignore));
    try std.testing.expectEqualStrings("", s.answer.items);
}

test "initial channels agree with the rendered producer prompt, not answer prose" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    for ([_]chat_format.Format{ .gemma4, .gemma3, .chatml, .chatml_think, .builtin }) |format| {
        for ([_]bool{ false, true }) |think| {
            var s = Stream.forPrompt(arena.allocator(), format, think);
            const r = chat_format.reasoning(format);
            const prompt = try chat_format.render(arena.allocator(), format, "System", "User", think);
            if (think and r != null and r.?.opened_by_prompt) {
                try std.testing.expect(std.mem.endsWith(u8, std.mem.trimEnd(u8, prompt.?, "\n"), r.?.open));
                try s.feed("Analyze the request. Private reasoning", {}, ignore);
                try std.testing.expectEqualStrings("", s.answer.items);
                try s.feed(r.?.close, {}, ignore);
                try s.feed("Answer.", {}, ignore);
                try s.finish({}, ignore);
                try std.testing.expectEqualStrings("Answer.", s.answer.items);
            } else {
                const text = "## Thinking Process:\nA legitimate article about problem solving.";
                try s.feed(text, {}, ignore);
                try s.finish({}, ignore);
                try std.testing.expectEqualStrings(text, s.answer.items);
                try std.testing.expectEqualStrings("", s.thinking.items);
            }
        }
    }
}
