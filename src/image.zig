//! PNG helpers for clipboard images: the menu preview (512 px) and the OCR
//! input (`ocr.maxDimension`). Ported from GhostPen's image_util.rs.

const std = @import("std");
const zigimg = @import("zigimg");

pub const Size = struct { width: u32, height: u32 };

/// Width and height from the PNG header (IHDR), without decoding.
pub fn pngSize(png: []const u8) ?Size {
    const sig = "\x89PNG\r\n\x1a\n";
    if (png.len < 24 or !std.mem.eql(u8, png[0..8], sig) or !std.mem.eql(u8, png[12..16], "IHDR")) return null;
    return .{
        .width = std.mem.readInt(u32, png[16..20], .big),
        .height = std.mem.readInt(u32, png[20..24], .big),
    };
}

/// `png` scaled down so neither side exceeds `max` (aspect kept), as PNG.
/// Returns a copy of the input when it already fits. Caller owns the result.
pub fn fitWithin(gpa: std.mem.Allocator, png: []const u8, max: u32) ![]u8 {
    const size = pngSize(png) orelse return error.NotPng;
    if (size.width <= max and size.height <= max) return gpa.dupe(u8, png);

    var img = try zigimg.Image.fromMemory(gpa, png);
    defer img.deinit(gpa);
    try img.convert(gpa, .rgba32);

    const scale = @as(f64, @floatFromInt(max)) / @as(f64, @floatFromInt(@max(img.width, img.height)));
    const w: usize = @max(1, @as(usize, @intFromFloat(@round(@as(f64, @floatFromInt(img.width)) * scale))));
    const h: usize = @max(1, @as(usize, @intFromFloat(@round(@as(f64, @floatFromInt(img.height)) * scale))));

    var dst = try zigimg.Image.create(gpa, w, h, .rgba32);
    defer dst.deinit(gpa);
    downsample(img.pixels.rgba32, img.width, img.height, dst.pixels.rgba32, w, h);

    const buf = try gpa.alloc(u8, w * h * 4 + 64 * 1024);
    defer gpa.free(buf);
    const encoded = try dst.writeToMemory(gpa, buf, .{ .png = .{} });
    return gpa.dupe(u8, encoded);
}

/// Area average: each destination pixel is the mean of the source pixels it
/// covers (sharp, alias-free text for OCR).
fn downsample(src: []const zigimg.color.Rgba32, sw: usize, sh: usize, dst: []zigimg.color.Rgba32, dw: usize, dh: usize) void {
    for (0..dh) |y| {
        const y0 = y * sh / dh;
        const y1 = @max(y0 + 1, (y + 1) * sh / dh);
        for (0..dw) |x| {
            const x0 = x * sw / dw;
            const x1 = @max(x0 + 1, (x + 1) * sw / dw);
            var r: u64 = 0;
            var g: u64 = 0;
            var b: u64 = 0;
            var a: u64 = 0;
            for (y0..y1) |sy| for (x0..x1) |sx| {
                const p = src[sy * sw + sx];
                r += p.r;
                g += p.g;
                b += p.b;
                a += p.a;
            };
            const n = (y1 - y0) * (x1 - x0);
            dst[y * dw + x] = .{ .r = @intCast(r / n), .g = @intCast(g / n), .b = @intCast(b / n), .a = @intCast(a / n) };
        }
    }
}

/// `data:image/png;base64,...` for the webview. Caller owns the result.
pub fn dataUri(gpa: std.mem.Allocator, png: []const u8) ![]u8 {
    const prefix = "data:image/png;base64,";
    const out = try gpa.alloc(u8, prefix.len + std.base64.standard.Encoder.calcSize(png.len));
    @memcpy(out[0..prefix.len], prefix);
    _ = std.base64.standard.Encoder.encode(out[prefix.len..], png);
    return out;
}

test "fitWithin downsizes, keeps aspect, and passes small images through" {
    const gpa = std.testing.allocator;
    var img = try zigimg.Image.create(gpa, 400, 100, .rgba32);
    defer img.deinit(gpa);
    for (img.pixels.rgba32) |*p| p.* = .{ .r = 200, .g = 10, .b = 10, .a = 255 };
    const buf = try gpa.alloc(u8, 400 * 100 * 4 + 64 * 1024);
    defer gpa.free(buf);
    const png = try img.writeToMemory(gpa, buf, .{ .png = .{} });

    const small = try fitWithin(gpa, png, 100);
    defer gpa.free(small);
    const s = pngSize(small).?;
    try std.testing.expectEqual(@as(u32, 100), s.width);
    try std.testing.expectEqual(@as(u32, 25), s.height);

    const same = try fitWithin(gpa, png, 1024);
    defer gpa.free(same);
    try std.testing.expectEqualSlices(u8, png, same);

    const uri = try dataUri(gpa, "PNG");
    defer gpa.free(uri);
    try std.testing.expectEqualStrings("data:image/png;base64,UE5H", uri);
}
