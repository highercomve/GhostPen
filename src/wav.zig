//! 16-bit PCM WAV files for meeting recordings: a writer that streams a
//! track to disk as it is captured (the header's sizes are patched as it
//! goes, so a crash leaves a playable file), header repair, reading back,
//! and merging two mono tracks into one stereo file.

const std = @import("std");

const header_len = 44;

/// The 44-byte RIFF header for `frames` frames of 16-bit PCM.
fn header(channels: u16, rate: u32, frames: u64) [header_len]u8 {
    const block: u32 = @as(u32, channels) * 2;
    const total = std.math.mul(u64, frames, block) catch std.math.maxInt(u64);
    const data: u32 = @intCast(@min(total, std.math.maxInt(u32) - 36));
    var h: [header_len]u8 = undefined;
    @memcpy(h[0..4], "RIFF");
    std.mem.writeInt(u32, h[4..8], 36 + data, .little);
    @memcpy(h[8..16], "WAVEfmt ");
    std.mem.writeInt(u32, h[16..20], 16, .little);
    std.mem.writeInt(u16, h[20..22], 1, .little); // PCM
    std.mem.writeInt(u16, h[22..24], channels, .little);
    std.mem.writeInt(u32, h[24..28], rate, .little);
    std.mem.writeInt(u32, h[28..32], rate * block, .little);
    std.mem.writeInt(u16, h[32..34], @intCast(block), .little);
    std.mem.writeInt(u16, h[34..36], 16, .little);
    @memcpy(h[36..40], "data");
    std.mem.writeInt(u32, h[40..44], data, .little);
    return h;
}

fn toI16(x: f32) i16 {
    const v = if (std.math.isNan(x)) 0 else std.math.clamp(x, -1.0, 1.0);
    return @intFromFloat(@round(v * 32767.0));
}

/// A mono track being recorded. Not thread-safe: one capture thread owns it.
pub const Writer = struct {
    file: std.Io.File,
    io: std.Io,
    rate: u32,
    frames: u64 = 0,
    /// Data bytes on disk (the rest is in `buf`).
    written: u64 = 0,
    /// Frames at the last header patch.
    patched: u64 = 0,
    buf: [8192]u8 = undefined,
    buf_len: usize = 0,

    pub fn create(io: std.Io, path: []const u8, rate: u32) !Writer {
        const file = try std.Io.Dir.cwd().createFile(io, path, .{});
        errdefer file.close(io);
        const h = header(1, rate, 0);
        try file.writePositionalAll(io, &h, 0);
        return .{ .file = file, .io = io, .rate = rate };
    }

    /// Append silence (a track that opened late, to stay in step).
    pub fn writeSilence(w: *Writer, frames: u64) !void {
        var left = frames;
        const zeros = [_]f32{0} ** 256;
        while (left > 0) {
            const n: usize = @intCast(@min(left, zeros.len));
            try w.write(zeros[0..n]);
            left -= n;
        }
    }

    pub fn write(w: *Writer, samples: []const f32) !void {
        for (samples) |x| {
            if (w.buf_len + 2 > w.buf.len) try w.flush();
            std.mem.writeInt(i16, w.buf[w.buf_len..][0..2], toI16(x), .little);
            w.buf_len += 2;
        }
        w.frames += samples.len;
        // The header follows every ~10 s, so a crash loses at most that.
        if (w.frames - w.patched >= @as(u64, w.rate) * 10) try w.patch();
    }

    fn flush(w: *Writer) !void {
        if (w.buf_len == 0) return;
        try w.file.writePositionalAll(w.io, w.buf[0..w.buf_len], header_len + w.written);
        w.written += w.buf_len;
        w.buf_len = 0;
    }

    fn patch(w: *Writer) !void {
        try w.flush();
        const h = header(1, w.rate, w.frames);
        try w.file.writePositionalAll(w.io, &h, 0);
        w.patched = w.frames;
    }

    pub fn seconds(w: *const Writer) f64 {
        return @as(f64, @floatFromInt(w.frames)) / @as(f64, @floatFromInt(w.rate));
    }

    /// Flush, write the final header, close.
    pub fn finish(w: *Writer) !void {
        defer w.file.close(w.io);
        try w.patch();
    }
};

pub const Info = struct {
    channels: u16,
    rate: u32,
    /// Where the samples start, and how many bytes of them.
    data_offset: u64,
    data_len: u64,

    pub fn frames(i: Info) u64 {
        return i.data_len / (@as(u64, i.channels) * 2);
    }
};

/// Read a 16-bit PCM WAV header (chunks other than fmt and data skipped).
/// A data size past the end of the file (a crashed recording) is read as
/// what the file holds.
pub fn info(io: std.Io, file: std.Io.File) !Info {
    const size = try file.length(io);
    var h: [12]u8 = undefined;
    if (try file.readPositionalAll(io, &h, 0) != 12) return error.NotWav;
    if (!std.mem.eql(u8, h[0..4], "RIFF") or !std.mem.eql(u8, h[8..12], "WAVE")) return error.NotWav;
    var at: u64 = 12;
    var channels: u16 = 0;
    var rate: u32 = 0;
    while (at + 8 <= size) {
        var ch: [8]u8 = undefined;
        _ = try file.readPositionalAll(io, &ch, at);
        const len = std.mem.readInt(u32, ch[4..8], .little);
        if (std.mem.eql(u8, ch[0..4], "fmt ")) {
            var f: [16]u8 = undefined;
            if (len < 16 or try file.readPositionalAll(io, &f, at + 8) != 16) return error.NotWav;
            if (std.mem.readInt(u16, f[0..2], .little) != 1 or std.mem.readInt(u16, f[14..16], .little) != 16) return error.UnsupportedFormat;
            channels = std.mem.readInt(u16, f[2..4], .little);
            if (channels > 2) return error.UnsupportedFormat;
            rate = std.mem.readInt(u32, f[4..8], .little);
        } else if (std.mem.eql(u8, ch[0..4], "data")) {
            if (channels == 0 or rate == 0) return error.NotWav;
            const avail = size - (at + 8);
            const block = @as(u64, channels) * 2;
            const data_len = @min(@as(u64, len), avail);
            // len 0 with data after it: a header never patched.
            const n = if (len == 0) avail else data_len;
            return .{ .channels = channels, .rate = rate, .data_offset = at + 8, .data_len = n - n % block };
        }
        at += 8 + @as(u64, len) + (@as(u64, len) & 1);
    }
    return error.NotWav;
}

/// Patch a crashed recording's header to what the file holds.
pub fn repair(io: std.Io, path: []const u8) !void {
    const file = try std.Io.Dir.cwd().openFile(io, path, .{ .mode = .read_write });
    defer file.close(io);
    const i = try info(io, file);
    if (i.data_offset != header_len) return; // not one of ours: leave it
    const h = header(i.channels, i.rate, i.frames());
    try file.writePositionalAll(io, &h, 0);
}

/// Read one channel (0 = left/mono) of frames `[from, from + count)` as
/// floats. Caller frees.
pub fn readChannel(io: std.Io, gpa: std.mem.Allocator, file: std.Io.File, i: Info, channel: u16, from: u64, count: u64) ![]f32 {
    if (i.channels == 0 or channel >= i.channels) return error.BadChannel;
    const block: usize = @as(usize, i.channels) * 2;
    var buf: [64 * 1024]u8 = undefined;
    if (block > buf.len) return error.UnsupportedFormat;
    const total = i.frames();
    const start = @min(from, total);
    const n: usize = @intCast(@min(count, total - start));
    const out = try gpa.alloc(f32, n);
    errdefer gpa.free(out);
    const per = buf.len / block;
    var done: usize = 0;
    while (done < n) {
        const k = @min(per, n - done);
        const got = try file.readPositionalAll(io, buf[0 .. k * block], i.data_offset + (start + done) * block);
        if (got < k * block) return error.Truncated;
        for (0..k) |j| {
            const v = std.mem.readInt(i16, buf[j * block + channel * 2 ..][0..2], .little);
            out[done + j] = @as(f32, @floatFromInt(v)) / 32768.0;
        }
        done += k;
    }
    return out;
}

/// Merge two mono tracks into a stereo file (left: `left`, right:
/// `right`), the shorter padded with silence.
pub fn mergeStereo(io: std.Io, left_path: []const u8, right_path: []const u8, out_path: []const u8) !void {
    const cwd = std.Io.Dir.cwd();
    const l = try cwd.openFile(io, left_path, .{});
    defer l.close(io);
    const r = try cwd.openFile(io, right_path, .{});
    defer r.close(io);
    const li = try info(io, l);
    const ri = try info(io, r);
    if (li.channels != 1 or ri.channels != 1 or li.rate != ri.rate) return error.UnsupportedFormat;
    const frames = @max(li.frames(), ri.frames());
    const out = try cwd.createFile(io, out_path, .{});
    defer out.close(io);
    const h = header(2, li.rate, frames);
    try out.writePositionalAll(io, &h, 0);

    const step = 8192;
    var lb: [step * 2]u8 = undefined;
    var rb: [step * 2]u8 = undefined;
    var ob: [step * 4]u8 = undefined;
    var at: u64 = 0;
    while (at < frames) {
        const k: usize = @intCast(@min(step, frames - at));
        @memset(lb[0 .. k * 2], 0);
        @memset(rb[0 .. k * 2], 0);
        if (at < li.frames()) _ = try l.readPositionalAll(io, lb[0..@intCast(@min(k, li.frames() - at) * 2)], li.data_offset + at * 2);
        if (at < ri.frames()) _ = try r.readPositionalAll(io, rb[0..@intCast(@min(k, ri.frames() - at) * 2)], ri.data_offset + at * 2);
        for (0..k) |j| {
            @memcpy(ob[j * 4 ..][0..2], lb[j * 2 ..][0..2]);
            @memcpy(ob[j * 4 + 2 ..][0..2], rb[j * 2 ..][0..2]);
        }
        try out.writePositionalAll(io, ob[0 .. k * 4], header_len + at * 4);
        at += k;
    }
}

test "Writer streams a track; info, readChannel and mergeStereo read it back" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(io, &path_buf);
    const root = path_buf[0..n];
    const a = try std.fs.path.join(gpa, &.{ root, "a.wav" });
    defer gpa.free(a);
    const b = try std.fs.path.join(gpa, &.{ root, "b.wav" });
    defer gpa.free(b);
    const m = try std.fs.path.join(gpa, &.{ root, "m.wav" });
    defer gpa.free(m);

    var w = try Writer.create(io, a, 16000);
    var samples: [10000]f32 = undefined;
    for (&samples, 0..) |*x, i| x.* = if (i % 2 == 0) 0.5 else -0.5;
    try w.write(&samples);
    try w.writeSilence(5000);
    try std.testing.expectEqual(@as(u64, 15000), w.frames);
    try w.finish();

    var w2 = try Writer.create(io, b, 16000);
    try w2.write(samples[0..100]);
    try w2.finish();

    const f = try std.Io.Dir.cwd().openFile(io, a, .{});
    const i = try info(io, f);
    try std.testing.expectEqual(@as(u64, 15000), i.frames());
    const back = try readChannel(io, gpa, f, i, 0, 9998, 4);
    f.close(io);
    defer gpa.free(back);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), back[0], 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, -0.5), back[1], 0.001);
    try std.testing.expectEqual(@as(f32, 0), back[2]);

    try mergeStereo(io, a, b, m);
    const mf = try std.Io.Dir.cwd().openFile(io, m, .{});
    defer mf.close(io);
    const mi = try info(io, mf);
    try std.testing.expectEqual(@as(u16, 2), mi.channels);
    try std.testing.expectEqual(@as(u64, 15000), mi.frames());
    const right = try readChannel(io, gpa, mf, mi, 1, 99, 2);
    defer gpa.free(right);
    try std.testing.expectApproxEqAbs(@as(f32, -0.5), right[0], 0.001);
    try std.testing.expectEqual(@as(f32, 0), right[1]);
}

test "repair: a header never patched reads as what the file holds" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var data: [44 + 200]u8 = undefined;
    const h = header(1, 16000, 0);
    @memcpy(data[0..44], &h);
    @memset(data[44..], 1);
    try tmp.dir.writeFile(io, .{ .sub_path = "c.wav", .data = &data });
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(io, &path_buf);
    const p = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..n], "c.wav" });
    defer std.testing.allocator.free(p);
    try repair(io, p);
    const f = try std.Io.Dir.cwd().openFile(io, p, .{});
    defer f.close(io);
    var hb: [44]u8 = undefined;
    _ = try f.readPositionalAll(io, &hb, 0);
    try std.testing.expectEqual(@as(u32, 200), std.mem.readInt(u32, hb[40..44], .little));
}

test "info rejects an overflowing chunk length before data" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var data: [52]u8 = undefined;
    const h = header(1, 16000, 0);
    @memcpy(data[0..36], h[0..36]);
    @memcpy(data[36..40], "JUNK");
    std.mem.writeInt(u32, data[40..44], 0xffffffff, .little);
    @memcpy(data[44..52], h[36..44]);
    try tmp.dir.writeFile(io, .{ .sub_path = "bad.wav", .data = &data });
    const f = try tmp.dir.openFile(io, "bad.wav", .{});
    defer f.close(io);
    try std.testing.expectError(error.NotWav, info(io, f));
}

test "info rejects more than two channels" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const h = header(3, 16000, 0);
    try tmp.dir.writeFile(io, .{ .sub_path = "bad.wav", .data = &h });
    const f = try tmp.dir.openFile(io, "bad.wav", .{});
    defer f.close(io);
    try std.testing.expectError(error.UnsupportedFormat, info(io, f));
}

test "readChannel rejects invalid channels and oversized frames" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const h = header(1, 16000, 0);
    try tmp.dir.writeFile(io, .{ .sub_path = "mono.wav", .data = &h });
    const f = try tmp.dir.openFile(io, "mono.wav", .{});
    defer f.close(io);
    var i = try info(io, f);
    try std.testing.expectError(error.BadChannel, readChannel(io, std.testing.allocator, f, i, 1, 0, 1));
    i.channels = 0;
    try std.testing.expectError(error.BadChannel, readChannel(io, std.testing.allocator, f, i, 0, 0, 1));
    i.channels = 32769;
    try std.testing.expectError(error.UnsupportedFormat, readChannel(io, std.testing.allocator, f, i, 0, 0, 1));
}
