//! Read GGUF context metadata without loading tensors or a tokenizer.
const std = @import("std");

const Entry = struct {
    path: [4096]u8 = undefined,
    len: usize = 0,
    inode: std.Io.File.INode = 0,
    size: u64 = 0,
    mtime: i96 = 0,
    ctime: i96 = 0,
    ctx: u32 = 0,
};
var entries: [32]Entry = @splat(.{});
var next: usize = 0;
var mutex: std.Io.Mutex = .init;

pub fn trainedCtx(io: std.Io, path: []const u8) u32 {
    const file = std.Io.Dir.cwd().openFile(io, path, .{}) catch return 0;
    defer file.close(io);
    const stat = file.stat(io) catch return 0;
    mutex.lockUncancelable(io);
    defer mutex.unlock(io);
    for (&entries) |*entry| {
        if (entry.len == 0 or !std.mem.eql(u8, entry.path[0..entry.len], path)) continue;
        if (entry.inode == stat.inode and entry.size == stat.size and
            entry.mtime == stat.mtime.nanoseconds and entry.ctime == stat.ctime.nanoseconds) return entry.ctx;
        entry.len = 0;
    }
    var buffer: [4096]u8 = undefined;
    var reader = file.reader(io, &buffer);
    const ctx = readContext(&reader) catch 0;
    if (path.len > 0 and path.len <= entries[0].path.len) {
        const entry = &entries[next];
        entry.* = .{ .len = path.len, .inode = stat.inode, .size = stat.size, .mtime = stat.mtime.nanoseconds, .ctime = stat.ctime.nanoseconds, .ctx = ctx };
        @memcpy(entry.path[0..path.len], path);
        next = (next + 1) % entries.len;
    }
    return ctx;
}

fn readContext(file_reader: *std.Io.File.Reader) !u32 {
    const r = &file_reader.interface;
    var arch_buf: [128]u8 = undefined;
    var arch_len: usize = 0;
    // Architecture and context keys may appear in either order.
    for (0..2) |pass| {
        try file_reader.seekTo(0);
        if (try r.takeInt(u32, .little) != 0x46554747) return error.InvalidGguf;
        const version = try r.takeInt(u32, .little);
        if (version != 2 and version != 3) return error.InvalidGguf;
        _ = try r.takeInt(u64, .little); // tensors
        const count = try r.takeInt(u64, .little);
        if (count > 1_000_000) return error.InvalidGguf;
        for (0..count) |_| {
            var key_buf: [256]u8 = undefined;
            const key = try readString(r, &key_buf);
            const kind = try r.takeInt(u32, .little);
            if (pass == 0 and std.mem.eql(u8, key, "general.architecture")) {
                if (kind != 8) return error.InvalidGguf;
                const arch = try readString(r, &arch_buf);
                if (arch.len == 0) return error.InvalidGguf;
                arch_len = arch.len;
                break;
            }
            if (pass == 1 and key.len == arch_len + ".context_length".len and
                std.mem.startsWith(u8, key, arch_buf[0..arch_len]) and
                std.mem.endsWith(u8, key, ".context_length")) return readInteger(r, kind);
            try skipValue(r, kind);
        }
        if (arch_len == 0) return 0;
    }
    return 0;
}

fn readString(r: *std.Io.Reader, buffer: []u8) ![]const u8 {
    const len = try r.takeInt(u64, .little);
    if (len > buffer.len) {
        try r.discardAll64(len);
        return "";
    }
    const bytes = try r.take(@intCast(len));
    @memcpy(buffer[0..bytes.len], bytes);
    return buffer[0..bytes.len];
}

fn readInteger(r: *std.Io.Reader, kind: u32) !u32 {
    return switch (kind) {
        0 => try r.takeInt(u8, .little),
        1 => std.math.cast(u32, try r.takeInt(i8, .little)) orelse 0,
        2 => try r.takeInt(u16, .little),
        3 => std.math.cast(u32, try r.takeInt(i16, .little)) orelse 0,
        4 => try r.takeInt(u32, .little),
        5 => std.math.cast(u32, try r.takeInt(i32, .little)) orelse 0,
        10 => std.math.cast(u32, try r.takeInt(u64, .little)) orelse 0,
        11 => std.math.cast(u32, try r.takeInt(i64, .little)) orelse 0,
        else => error.InvalidGguf,
    };
}

fn scalarSize(kind: u32) !u64 {
    return switch (kind) {
        0, 1, 7 => 1,
        2, 3 => 2,
        4, 5, 6 => 4,
        10, 11, 12 => 8,
        else => error.InvalidGguf,
    };
}

fn skipValue(r: *std.Io.Reader, kind: u32) !void {
    switch (kind) {
        8 => try r.discardAll64(try r.takeInt(u64, .little)),
        9 => {
            const element = try r.takeInt(u32, .little);
            const count = try r.takeInt(u64, .little);
            if (element == 8) {
                if (count > 10_000_000) return error.InvalidGguf;
                for (0..count) |_| try r.discardAll64(try r.takeInt(u64, .little));
            } else {
                const bytes = std.math.mul(u64, count, try scalarSize(element)) catch return error.InvalidGguf;
                try r.discardAll64(bytes);
            }
        },
        else => try r.discardAll64(try scalarSize(kind)),
    }
}

/// What llama.cpp's `llama_model_meta_val_str` leaves out (it skips every
/// array): per-layer metadata such as Gemma 4's KV head counts and
/// sliding-window pattern, and the size of a tensor. Read from the file's
/// header alone.
pub const Header = struct {
    /// Integers and booleans of the array (or scalar) under `key`, booleans
    /// as 0/1, into `out`: the values read, empty when the key is absent or
    /// holds something else (strings, floats). Longer arrays are cut at
    /// `out.len`.
    pub fn ints(io: std.Io, path: []const u8, key: []const u8, out: []u32) []const u32 {
        const file = std.Io.Dir.cwd().openFile(io, path, .{}) catch return out[0..0];
        defer file.close(io);
        var buffer: [4096]u8 = undefined;
        var reader = file.reader(io, &buffer);
        return readInts(&reader.interface, key, out) catch out[0..0];
    }

    /// A tensor's element count and ggml type, or null when the file has no
    /// tensor `name`.
    pub fn tensor(io: std.Io, path: []const u8, name: []const u8) ?Tensor {
        const file = std.Io.Dir.cwd().openFile(io, path, .{}) catch return null;
        defer file.close(io);
        var buffer: [4096]u8 = undefined;
        var reader = file.reader(io, &buffer);
        return findTensor(&reader.interface, name) catch null;
    }
};

pub const Tensor = struct { elements: u64, type: u32 };

/// The header's counts, after checking the magic and version.
fn readCounts(r: *std.Io.Reader) !struct { tensors: u64, kvs: u64 } {
    if (try r.takeInt(u32, .little) != 0x46554747) return error.InvalidGguf;
    const version = try r.takeInt(u32, .little);
    if (version != 2 and version != 3) return error.InvalidGguf;
    const tensors = try r.takeInt(u64, .little);
    const kvs = try r.takeInt(u64, .little);
    if (kvs > 1_000_000 or tensors > 10_000_000) return error.InvalidGguf;
    return .{ .tensors = tensors, .kvs = kvs };
}

fn readInts(r: *std.Io.Reader, want: []const u8, out: []u32) ![]const u32 {
    const counts = try readCounts(r);
    for (0..counts.kvs) |_| {
        var key_buf: [256]u8 = undefined;
        const key = try readString(r, &key_buf);
        const kind = try r.takeInt(u32, .little);
        if (!std.mem.eql(u8, key, want)) {
            try skipValue(r, kind);
            continue;
        }
        if (kind != 9) {
            if (out.len == 0) return out[0..0];
            out[0] = if (kind == 7) try r.takeInt(u8, .little) else try readInteger(r, kind);
            return out[0..1];
        }
        const element = try r.takeInt(u32, .little);
        const count = try r.takeInt(u64, .little);
        if (element == 8 or element == 6 or element == 12) return out[0..0];
        if (count > 1_000_000) return error.InvalidGguf;
        var n: usize = 0;
        for (0..count) |_| {
            const v: u32 = if (element == 7) try r.takeInt(u8, .little) else try readInteger(r, element);
            if (n < out.len) {
                out[n] = v;
                n += 1;
            }
        }
        return out[0..n];
    }
    return out[0..0];
}

fn findTensor(r: *std.Io.Reader, want: []const u8) !?Tensor {
    const counts = try readCounts(r);
    for (0..counts.kvs) |_| {
        var key_buf: [256]u8 = undefined;
        _ = try readString(r, &key_buf);
        try skipValue(r, try r.takeInt(u32, .little));
    }
    for (0..counts.tensors) |_| {
        var name_buf: [256]u8 = undefined;
        const name = try readString(r, &name_buf);
        const dims = try r.takeInt(u32, .little);
        if (dims > 8) return error.InvalidGguf;
        var elements: u64 = 1;
        for (0..dims) |_| elements = std.math.mul(u64, elements, try r.takeInt(u64, .little)) catch return error.InvalidGguf;
        const kind = try r.takeInt(u32, .little);
        _ = try r.takeInt(u64, .little); // offset
        if (std.mem.eql(u8, name, want)) return .{ .elements = elements, .type = kind };
    }
    return null;
}

fn writeString(w: *std.Io.Writer, text: []const u8) !void {
    try w.writeInt(u64, text.len, .little);
    try w.writeAll(text);
}

fn fixture(w: *std.Io.Writer, ctx: u32, reverse: bool) !void {
    try w.writeInt(u32, 0x46554747, .little);
    try w.writeInt(u32, 3, .little);
    try w.writeInt(u64, 0, .little);
    try w.writeInt(u64, 4, .little);
    // Tokenizer strings must be skipped without allocation.
    try writeString(w, "tokenizer.ggml.tokens");
    try w.writeInt(u32, 9, .little);
    try w.writeInt(u32, 8, .little);
    try w.writeInt(u64, 2, .little);
    try writeString(w, "token one");
    try writeString(w, "token two");
    try writeString(w, "other.context_length");
    try w.writeInt(u32, 4, .little);
    try w.writeInt(u32, 42, .little);
    for (0..2) |i| {
        if ((i == 0) != reverse) {
            try writeString(w, "general.architecture");
            try w.writeInt(u32, 8, .little);
            try writeString(w, "qwen35");
        } else {
            try writeString(w, "qwen35.context_length");
            try w.writeInt(u32, 4, .little);
            try w.writeInt(u32, ctx, .little);
        }
    }
}

test "context metadata order, tokenizer skipping, cache refresh and malformed files" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [4096]u8 = undefined;
    const dir_len = try tmp.dir.realPath(io, &path_buf);
    const dir = path_buf[0..dir_len];
    const path = try std.fmt.allocPrint(std.testing.allocator, "{s}/model.gguf", .{dir});
    defer std.testing.allocator.free(path);
    var data = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer data.deinit();
    try fixture(&data.writer, 131072, false);
    try tmp.dir.writeFile(io, .{ .sub_path = "model.gguf", .data = data.written() });
    try std.testing.expectEqual(@as(u32, 131072), trainedCtx(io, path));
    try std.testing.expectEqual(@as(u32, 131072), trainedCtx(io, path));
    data.clearRetainingCapacity();
    try fixture(&data.writer, 262144, true);
    // Replace the file with the same length: inode invalidates the cache.
    try tmp.dir.deleteFile(io, "model.gguf");
    try tmp.dir.writeFile(io, .{ .sub_path = "model.gguf", .data = data.written() });
    try std.testing.expectEqual(@as(u32, 262144), trainedCtx(io, path));
    for (0..data.written().len) |len| {
        try tmp.dir.writeFile(io, .{ .sub_path = "model.gguf", .data = data.written()[0..len] });
        try std.testing.expectEqual(@as(u32, 0), trainedCtx(io, path));
    }
    try tmp.dir.writeFile(io, .{ .sub_path = "model.gguf", .data = "not GGUF" });
    try std.testing.expectEqual(@as(u32, 0), trainedCtx(io, path));
    try tmp.dir.deleteFile(io, "model.gguf");
    try std.testing.expectEqual(@as(u32, 0), trainedCtx(io, path));
}

test "arrays, scalars and tensors from the header" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var data = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer data.deinit();
    const w = &data.writer;
    try w.writeInt(u32, 0x46554747, .little);
    try w.writeInt(u32, 3, .little);
    try w.writeInt(u64, 2, .little); // tensors
    try w.writeInt(u64, 4, .little); // kvs
    try writeString(w, "tokenizer.ggml.tokens");
    try w.writeInt(u32, 9, .little);
    try w.writeInt(u32, 8, .little);
    try w.writeInt(u64, 1, .little);
    try writeString(w, "a");
    try writeString(w, "gemma4.attention.head_count_kv");
    try w.writeInt(u32, 9, .little);
    try w.writeInt(u32, 5, .little); // i32
    try w.writeInt(u64, 3, .little);
    for ([_]i32{ 8, 8, 1 }) |v| try w.writeInt(i32, v, .little);
    try writeString(w, "gemma4.attention.sliding_window_pattern");
    try w.writeInt(u32, 9, .little);
    try w.writeInt(u32, 7, .little); // bool
    try w.writeInt(u64, 3, .little);
    for ([_]u8{ 1, 1, 0 }) |v| try w.writeInt(u8, v, .little);
    try writeString(w, "qwen35.attention.head_count_kv");
    try w.writeInt(u32, 4, .little); // u32
    try w.writeInt(u32, 4, .little);
    try writeString(w, "token_embd.weight");
    try w.writeInt(u32, 2, .little);
    try w.writeInt(u64, 4096, .little);
    try w.writeInt(u64, 1000, .little);
    try w.writeInt(u32, 12, .little); // q4_K
    try w.writeInt(u64, 0, .little);
    try writeString(w, "output.weight");
    try w.writeInt(u32, 1, .little);
    try w.writeInt(u64, 7, .little);
    try w.writeInt(u32, 0, .little);
    try w.writeInt(u64, 0, .little);
    try tmp.dir.writeFile(io, .{ .sub_path = "m.gguf", .data = data.written() });
    var path_buf: [4096]u8 = undefined;
    const dir_len = try tmp.dir.realPath(io, &path_buf);
    const path = try std.fmt.allocPrint(std.testing.allocator, "{s}/m.gguf", .{path_buf[0..dir_len]});
    defer std.testing.allocator.free(path);

    var out: [8]u32 = undefined;
    try std.testing.expectEqualSlices(u32, &.{ 8, 8, 1 }, Header.ints(io, path, "gemma4.attention.head_count_kv", &out));
    try std.testing.expectEqualSlices(u32, &.{ 1, 1, 0 }, Header.ints(io, path, "gemma4.attention.sliding_window_pattern", &out));
    try std.testing.expectEqualSlices(u32, &.{4}, Header.ints(io, path, "qwen35.attention.head_count_kv", &out));
    try std.testing.expectEqual(@as(usize, 0), Header.ints(io, path, "tokenizer.ggml.tokens", &out).len);
    try std.testing.expectEqual(@as(usize, 0), Header.ints(io, path, "missing", &out).len);
    try std.testing.expectEqual(Tensor{ .elements = 4096 * 1000, .type = 12 }, Header.tensor(io, path, "token_embd.weight").?);
    try std.testing.expectEqual(Tensor{ .elements = 7, .type = 0 }, Header.tensor(io, path, "output.weight").?);
    try std.testing.expectEqual(@as(?Tensor, null), Header.tensor(io, path, "nope"));
}
