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
