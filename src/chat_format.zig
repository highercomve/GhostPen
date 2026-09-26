//! Prompt formats for the local runner: one system + one user turn, with the
//! model's reasoning switched on or off, rendered the way each family's chat
//! template does. The family is recognized from the GGUF's
//! `tokenizer.chat_template` (a Jinja template llama.cpp can't run itself);
//! anything else goes through llama.cpp's built-in templates.

const std = @import("std");

pub const Format = enum {
    /// Gemma 4: `<|turn>role … <turn|>`, thinking in `<|channel>thought … <channel|>`.
    gemma4,
    /// Gemma 2/3: `<start_of_turn>`; no system role (merged into the user turn).
    gemma3,
    /// ChatML (Qwen and most others): `<|im_start|>role … <|im_end|>`.
    chatml,
    /// ChatML with a `<think>` block (Qwen3, Qwen3.5).
    chatml_think,
    /// Whatever llama.cpp's `llama_chat_apply_template` recognizes.
    builtin,
};

pub fn detect(template: ?[]const u8) Format {
    const t = template orelse return .builtin;
    const has = struct {
        fn f(s: []const u8, needle: []const u8) bool {
            return std.mem.indexOf(u8, s, needle) != null;
        }
    }.f;
    if (has(t, "<|turn>")) return .gemma4;
    if (has(t, "<start_of_turn>")) return .gemma3;
    if (has(t, "<|im_start|>")) return if (has(t, "<think>")) .chatml_think else .chatml;
    return .builtin;
}

/// Where the model's reasoning starts and ends in its output, for a format
/// whose reasoning can be switched on.
pub const Reasoning = struct {
    open: []const u8,
    close: []const u8,
    /// The prompt already opened the block: the output starts inside it.
    opened_by_prompt: bool,
};

pub fn reasoning(format: Format) ?Reasoning {
    return switch (format) {
        .gemma4 => .{ .open = "<|channel>thought", .close = "<channel|>", .opened_by_prompt = false },
        .chatml_think => .{ .open = "<think>", .close = "</think>", .opened_by_prompt = true },
        else => null,
    };
}

/// The prompt text (special tokens as text: tokenize with `parse_special`),
/// or null for `.builtin`. BOS is not included (the tokenizer adds it).
pub fn render(arena: std.mem.Allocator, format: Format, system: []const u8, user: []const u8, think: bool) !?[]const u8 {
    const sys = std.mem.trim(u8, system, " \t\r\n");
    const usr = std.mem.trim(u8, user, " \t\r\n");
    return switch (format) {
        .gemma4 => try std.fmt.allocPrint(arena, "<|turn>system\n{s}{s}<turn|>\n<|turn>user\n{s}<turn|>\n<|turn>model\n{s}", .{
            if (think) "<|think|>\n" else "", sys, usr, if (think) "" else "<|channel>thought\n<channel|>",
        }),
        .gemma3 => try std.fmt.allocPrint(arena, "<start_of_turn>user\n{s}{s}{s}<end_of_turn>\n<start_of_turn>model\n", .{
            sys, if (sys.len > 0) "\n\n" else "", usr,
        }),
        .chatml, .chatml_think => try std.fmt.allocPrint(arena, "<|im_start|>system\n{s}<|im_end|>\n<|im_start|>user\n{s}<|im_end|>\n<|im_start|>assistant\n{s}", .{
            sys, usr, if (format == .chatml) "" else if (think) "<think>\n" else "<think>\n\n</think>\n\n",
        }),
        .builtin => null,
    };
}

/// Hides the reasoning block from generated text as it streams: `feed` the
/// output as it grows, `visible` is what the user sees.
pub const ReasoningFilter = struct {
    r: ?Reasoning,
    /// Inside the block (its end not seen yet).
    inside: bool,
    /// Decided whether the output opens a block (formats where the model does).
    decided: bool,
    /// The visible text starts here in the output.
    start: usize = 0,

    pub fn init(format: Format, think: bool) ReasoningFilter {
        const r = if (think) reasoning(format) else null;
        const by_prompt = if (r) |x| x.opened_by_prompt else false;
        return .{ .r = r, .inside = by_prompt, .decided = r == null or by_prompt };
    }

    /// The visible part of `out` (the whole output so far). While the answer
    /// may still be reasoning, returns null (hold back).
    pub fn visible(self: *ReasoningFilter, out: []const u8) ?[]const u8 {
        const r = self.r orelse return out;
        if (!self.decided) {
            const head = std.mem.trimStart(u8, out, " \t\r\n");
            if (head.len < r.open.len and std.mem.startsWith(u8, r.open, head)) return null;
            self.decided = true;
            self.inside = std.mem.startsWith(u8, head, r.open);
        }
        if (self.inside) {
            const close = std.mem.indexOf(u8, out, r.close) orelse return null;
            self.inside = false;
            var s = close + r.close.len;
            while (s < out.len and std.ascii.isWhitespace(out[s])) s += 1;
            self.start = s;
        }
        return out[@min(self.start, out.len)..];
    }
};

/// Length of the longest prefix of `bytes` that doesn't end inside a UTF-8
/// sequence (so a streamed delta never splits a character).
pub fn completeUtf8(bytes: []const u8) usize {
    var i = bytes.len;
    var back: usize = 0;
    while (i > 0 and back < 4) {
        i -= 1;
        back += 1;
        const b = bytes[i];
        if (b & 0x80 == 0) return bytes.len; // ASCII: complete
        if (b & 0xC0 == 0xC0) { // lead byte: complete if its sequence fits
            const need: usize = if (b & 0xE0 == 0xC0) 2 else if (b & 0xF0 == 0xE0) 3 else 4;
            return if (back >= need) bytes.len else i;
        }
    }
    return bytes.len;
}

/// `bytes` as valid UTF-8: each invalid sequence becomes U+FFFD (a model's
/// byte-level tokens can split or garble a character). `bytes` itself when
/// it is already valid.
pub fn validUtf8(arena: std.mem.Allocator, bytes: []const u8) ![]const u8 {
    if (std.unicode.utf8ValidateSlice(bytes)) return bytes;
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < bytes.len) {
        const n = std.unicode.utf8ByteSequenceLength(bytes[i]) catch 0;
        if (n > 0 and i + n <= bytes.len and std.unicode.utf8ValidateSlice(bytes[i..][0..n])) {
            try out.appendSlice(arena, bytes[i..][0..n]);
            i += n;
        } else {
            try out.appendSlice(arena, "\u{FFFD}");
            i += 1;
        }
    }
    return out.items;
}

test validUtf8 {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings("héllo", try validUtf8(a, "héllo"));
    try std.testing.expectEqualStrings("a\u{FFFD}b", try validUtf8(a, "a\xe2b"));
    try std.testing.expectEqualStrings("x\u{FFFD}", try validUtf8(a, "x\xc3"));
}

test detect {
    try std.testing.expectEqual(Format.gemma4, detect("{{- '<|turn>model\\n' -}}"));
    try std.testing.expectEqual(Format.gemma3, detect("<start_of_turn>user"));
    try std.testing.expectEqual(Format.chatml_think, detect("<|im_start|>assistant\n<think>"));
    try std.testing.expectEqual(Format.chatml, detect("<|im_start|>assistant"));
    try std.testing.expectEqual(Format.builtin, detect(null));
}

test render {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings(
        "<|turn>system\nS<turn|>\n<|turn>user\nU<turn|>\n<|turn>model\n<|channel>thought\n<channel|>",
        (try render(a, .gemma4, "S", " U\n", false)).?,
    );
    try std.testing.expectEqualStrings(
        "<|im_start|>system\nS<|im_end|>\n<|im_start|>user\nU<|im_end|>\n<|im_start|>assistant\n<think>\n\n</think>\n\n",
        (try render(a, .chatml_think, "S", "U", false)).?,
    );
    try std.testing.expectEqualStrings("<start_of_turn>user\nS\n\nU<end_of_turn>\n<start_of_turn>model\n", (try render(a, .gemma3, "S", "U", false)).?);
    try std.testing.expect((try render(a, .builtin, "S", "U", true)) == null);
}

test ReasoningFilter {
    var f: ReasoningFilter = .init(.chatml_think, true);
    try std.testing.expect(f.visible("Let me think") == null);
    try std.testing.expectEqualStrings("Hi", f.visible("Let me think</think>\n\nHi").?);
    var g: ReasoningFilter = .init(.gemma4, true);
    try std.testing.expect(g.visible("<|chan") == null);
    try std.testing.expect(g.visible("<|channel>thought\nhmm") == null);
    try std.testing.expectEqualStrings("Ok", g.visible("<|channel>thought\nhmm<channel|>Ok").?);
    var h: ReasoningFilter = .init(.gemma4, true);
    try std.testing.expectEqualStrings("Plain", h.visible("Plain").?);
    var off: ReasoningFilter = .init(.chatml_think, false);
    try std.testing.expectEqualStrings("x", off.visible("x").?);
}

test completeUtf8 {
    try std.testing.expectEqual(@as(usize, 3), completeUtf8("abc"));
    try std.testing.expectEqual(@as(usize, 1), completeUtf8("a\xc3"));
    try std.testing.expectEqual(@as(usize, 3), completeUtf8("a\xc3\xa9"));
    try std.testing.expectEqual(@as(usize, 1), completeUtf8("a\xe2\x82"));
    try std.testing.expectEqual(@as(usize, 5), completeUtf8("a\xf0\x9f\x98\x80"));
}
