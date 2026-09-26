//! Models for the local runner: a small catalog of chat models that suit
//! GhostPen's short editing tasks, resumable downloads from Hugging Face
//! (checked against the SHA-256 Hugging Face publishes), and discovery of
//! GGUF files already on disk (LM Studio, GhostReel), so nothing is
//! downloaded twice. Plain std: the CLI resolves models too.
//!
//! Files keep their upstream names in `<data dir>/GhostPen/models` (next to
//! the whisper models), where GhostReel looks for them as well.

const std = @import("std");
const builtin = @import("builtin");

const log = std.log.scoped(.llm_models);

pub const Entry = struct {
    id: []const u8,
    name: []const u8,
    repo: []const u8,
    file: []const u8,
    size: u64,
    sha256: []const u8,
    /// Relative 1-5 scores for the UI.
    speed: u8,
    quality: u8,
    note: []const u8,
};

/// Smallest first. Sizes and hashes from Hugging Face's API (2026-09).
pub const catalog = [_]Entry{
    .{ .id = "qwen3.5-2b", .name = "Qwen3.5 2B", .repo = "unsloth/Qwen3.5-2B-GGUF", .file = "Qwen3.5-2B-Q4_K_M.gguf", .size = 1280835840, .sha256 = "aaf42c8b7c3cab2bf3d69c355048d4a0ee9973d48f16c731c0520ee914699223", .speed = 5, .quality = 2, .note = "fastest; fine for proofreading" },
    .{ .id = "gemma-3-4b-it", .name = "Gemma 3 4B", .repo = "ggml-org/gemma-3-4b-it-GGUF", .file = "gemma-3-4b-it-Q4_K_M.gguf", .size = 2489757856, .sha256 = "882e8d2db44dc554fb0ea5077cb7e4bc49e7342a1f0da57901c0802ea21a0863", .speed = 4, .quality = 3, .note = "good all-rounder, many languages" },
    .{ .id = "qwen3.5-4b", .name = "Qwen3.5 4B", .repo = "unsloth/Qwen3.5-4B-GGUF", .file = "Qwen3.5-4B-Q4_K_M.gguf", .size = 2740937888, .sha256 = "00fe7986ff5f6b463e62455821146049db6f9313603938a70800d1fb69ef11a4", .speed = 4, .quality = 3, .note = "balanced" },
    .{ .id = "gemma-4-e4b-it", .name = "Gemma 4 E4B", .repo = "unsloth/gemma-4-E4B-it-GGUF", .file = "gemma-4-E4B-it-Q4_K_M.gguf", .size = 4977171584, .sha256 = "85a896a047553e842f25297ee5b031d64ff30147d9c4af17b1e4b394cd1fab87", .speed = 3, .quality = 4, .note = "recommended; the model GhostPen's Ollama preset uses" },
    .{ .id = "qwen3.5-9b", .name = "Qwen3.5 9B", .repo = "unsloth/Qwen3.5-9B-GGUF", .file = "Qwen3.5-9B-UD-Q4_K_XL.gguf", .size = 5966095584, .sha256 = "6f5d30666c2d8ae16a306e616d95341dcf3cc46810df84d7e6f5a7d1e4c1b293", .speed = 2, .quality = 5, .note = "best quality; needs ~8 GB of GPU memory" },
};

pub const default_id = "gemma-4-e4b-it";

pub fn find(id: []const u8) ?Entry {
    for (catalog) |e| if (std.mem.eql(u8, e.id, id)) return e;
    return null;
}

pub fn url(arena: std.mem.Allocator, e: Entry) ![]const u8 {
    return std.fmt.allocPrint(arena, "https://huggingface.co/{s}/resolve/main/{s}", .{ e.repo, e.file });
}

/// Where the models live and where else to look.
pub const Dirs = struct {
    /// `<data dir>/GhostPen/models`: downloads go here.
    own: []const u8,
    /// Other apps' model folders, searched (never written).
    others: []const []const u8,
};

/// The directories for this user; `own` is `<data dir>/GhostPen/models`
/// (`ownDir`). Paths point into `arena`.
pub fn dirs(arena: std.mem.Allocator, own: []const u8, env: *const std.process.Environ.Map) !Dirs {
    var others: std.ArrayList([]const u8) = .empty;
    const home = env.get(if (builtin.os.tag == .windows) "USERPROFILE" else "HOME");
    if (home) |h| try others.append(arena, try std.fs.path.join(arena, &.{ h, ".lmstudio", "models" }));
    if (env.get("GHOSTREEL_HOME")) |g| {
        try others.append(arena, try std.fs.path.join(arena, &.{ g, "models" }));
    } else if (home) |h| try others.append(arena, try std.fs.path.join(arena, &.{ h, ".ghostreel", "models" }));
    return .{ .own = own, .others = others.items };
}

/// `<data dir>/GhostPen/models` without Oriel (for the CLI): the place
/// `oriel.store.dataDir` gives the app.
pub fn ownDir(arena: std.mem.Allocator, env: *const std.process.Environ.Map) ?[]const u8 {
    const base = platformDataDir(arena, env) orelse return null;
    return std.fs.path.join(arena, &.{ base, "GhostPen", "models" }) catch null;
}

fn platformDataDir(arena: std.mem.Allocator, env: *const std.process.Environ.Map) ?[]const u8 {
    return switch (builtin.os.tag) {
        .windows => env.get("LOCALAPPDATA"),
        .macos => if (env.get("HOME")) |h| std.fs.path.join(arena, &.{ h, "Library", "Application Support" }) catch null else null,
        else => blk: {
            if (env.get("XDG_DATA_HOME")) |d| if (d.len > 0) break :blk d;
            const h = env.get("HOME") orelse break :blk null;
            break :blk std.fs.path.join(arena, &.{ h, ".local", "share" }) catch null;
        },
    };
}

/// `name` (case-insensitive) under `root`, at most 4 levels deep; non-empty files only.
fn findFile(io: std.Io, arena: std.mem.Allocator, root: []const u8, name: []const u8) ?[]const u8 {
    var dir = std.Io.Dir.cwd().openDir(io, root, .{ .iterate = true }) catch return null;
    defer dir.close(io);
    var walker = dir.walk(arena) catch return null;
    defer walker.deinit();
    while (walker.next(io) catch null) |entry| {
        if (entry.depth() > 4) continue;
        if (entry.kind != .file and entry.kind != .sym_link) continue;
        if (!std.ascii.eqlIgnoreCase(entry.basename, name)) continue;
        const st = entry.dir.statFile(io, entry.basename, .{}) catch continue;
        if (st.size == 0) continue;
        return std.fs.path.join(arena, &.{ root, entry.path }) catch null;
    }
    return null;
}

/// The model file for a setting: a catalog id (in our folder, else found in
/// another app's), or `file:<path>` (a GGUF found on disk). Null when absent.
pub fn resolve(io: std.Io, arena: std.mem.Allocator, d: Dirs, model: []const u8) ?[]const u8 {
    if (std.mem.startsWith(u8, model, "file:")) {
        // Only a GGUF in one of the model folders (the setting comes from the page).
        const p = model["file:".len..];
        if (!std.ascii.endsWithIgnoreCase(p, ".gguf") or std.mem.indexOf(u8, p, "..") != null) return null;
        var inside = std.mem.startsWith(u8, p, d.own);
        for (d.others) |root| inside = inside or std.mem.startsWith(u8, p, root);
        if (!inside) return null;
        std.Io.Dir.cwd().access(io, p, .{}) catch return null;
        return p;
    }
    const e = find(model) orelse return null;
    const own = std.fs.path.join(arena, &.{ d.own, e.file }) catch return null;
    if (std.Io.Dir.cwd().access(io, own, .{})) |_| return own else |_| {}
    for (d.others) |root| if (findFile(io, arena, root, e.file)) |p| return p;
    return null;
}

pub const ModelState = struct {
    id: []const u8,
    name: []const u8,
    file: []const u8,
    size: u64,
    speed: u8,
    quality: u8,
    note: []const u8,
    /// Where it is ("" = not downloaded).
    path: []const u8 = "",
    /// Found in another app's folder (reused; not removable here).
    external: bool = false,
    /// Bytes of an interrupted download (resumable).
    partial: u64 = 0,
};

/// A GGUF found in another app's folder that isn't in the catalog.
pub const LocalFile = struct { id: []const u8, name: []const u8, path: []const u8, size: u64 };

pub const Status = struct {
    dir: []const u8,
    models: []const ModelState,
    others: []const LocalFile,
};

pub fn status(io: std.Io, arena: std.mem.Allocator, d: Dirs) !Status {
    var models: std.ArrayList(ModelState) = .empty;
    for (catalog) |e| {
        var s: ModelState = .{ .id = e.id, .name = e.name, .file = e.file, .size = e.size, .speed = e.speed, .quality = e.quality, .note = e.note };
        if (resolve(io, arena, d, e.id)) |p| {
            s.path = p;
            s.external = !std.mem.startsWith(u8, p, d.own);
        } else {
            const part = try std.fmt.allocPrint(arena, "{s}{c}{s}.part", .{ d.own, std.fs.path.sep, e.file });
            if (std.Io.Dir.cwd().statFile(io, part, .{})) |st| s.partial = st.size else |_| {}
        }
        try models.append(arena, s);
    }
    return .{ .dir = d.own, .models = models.items, .others = try scanOthers(io, arena, d) };
}

/// Chat-model GGUFs in the other apps' folders that aren't catalog files
/// (no projectors, speculative-decoding heads or embedding models).
fn scanOthers(io: std.Io, arena: std.mem.Allocator, d: Dirs) ![]const LocalFile {
    var out: std.ArrayList(LocalFile) = .empty;
    for (d.others) |root| {
        var dir = std.Io.Dir.cwd().openDir(io, root, .{ .iterate = true }) catch continue;
        defer dir.close(io);
        var walker = dir.walk(arena) catch continue;
        defer walker.deinit();
        while (walker.next(io) catch null) |entry| {
            if (entry.depth() > 4 or (entry.kind != .file and entry.kind != .sym_link)) continue;
            const base = entry.basename;
            if (!std.ascii.endsWithIgnoreCase(base, ".gguf")) continue;
            if (containsIgnoreCase(base, "mmproj") or std.ascii.startsWithIgnoreCase(base, "mtp-") or containsIgnoreCase(base, "embed")) continue;
            // A split model loads from its first part.
            if (containsIgnoreCase(base, "-of-") and !containsIgnoreCase(base, "-00001-of-")) continue;
            var in_catalog = false;
            for (catalog) |e| {
                if (std.ascii.eqlIgnoreCase(e.file, base)) in_catalog = true;
            }
            if (in_catalog) continue;
            const st = entry.dir.statFile(io, base, .{}) catch continue;
            if (st.size < 100 * 1024 * 1024) continue;
            const path = try std.fs.path.join(arena, &.{ root, entry.path });
            try out.append(arena, .{
                .id = try std.fmt.allocPrint(arena, "file:{s}", .{path}),
                .name = try arena.dupe(u8, base[0 .. base.len - ".gguf".len]),
                .path = path,
                .size = st.size,
            });
        }
    }
    return out.items;
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len > haystack.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[i..][0..needle.len], needle)) return true;
    }
    return false;
}

// ---- downloads ----------------------------------------------------------------------------

pub const Progress = struct {
    id: []const u8,
    /// downloading | verifying | done | cancelled | error
    state: []const u8,
    done: u64 = 0,
    total: u64 = 0,
    message: []const u8 = "",
};

/// One download at a time; `cancel_download` stops it (the .part is kept).
var downloading: std.atomic.Value(bool) = .init(false);
var cancel_flag: std.atomic.Value(bool) = .init(false);

pub fn cancelDownload() void {
    cancel_flag.store(true, .release);
}

pub fn isDownloading() bool {
    return downloading.load(.acquire);
}

/// Download catalog model `id` into `d.own`, resuming a `.part`, verifying
/// the SHA-256, then renaming. `on_progress(ctx, p)` at most every 200 ms.
pub fn download(
    io: std.Io,
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    d: Dirs,
    id: []const u8,
    ctx: anytype,
    comptime on_progress: fn (@TypeOf(ctx), Progress) void,
    status_out: *std.http.Status,
) ![]const u8 {
    const e = find(id) orelse return error.UnknownModel;
    if (downloading.swap(true, .acq_rel)) return error.Busy;
    defer downloading.store(false, .release);
    cancel_flag.store(false, .release);

    try std.Io.Dir.cwd().createDirPath(io, d.own);
    const final = try std.fs.path.join(arena, &.{ d.own, e.file });
    const part = try std.fmt.allocPrint(arena, "{s}.part", .{final});

    // Resume: hash what's there, then ask for the rest.
    var hasher: std.crypto.hash.sha2.Sha256 = .init(.{});
    var have: u64 = 0;
    if (std.Io.Dir.cwd().openFile(io, part, .{})) |f| {
        defer f.close(io);
        var rbuf: [256 * 1024]u8 = undefined;
        var r = f.reader(io, &rbuf);
        on_progress(ctx, .{ .id = id, .state = "verifying", .done = 0, .total = e.size, .message = "Checking the partial download…" });
        while (true) {
            if (cancel_flag.load(.acquire)) return error.Cancelled;
            const chunk = r.interface.peekGreedy(1) catch break;
            hasher.update(chunk);
            have += chunk.len;
            r.interface.toss(chunk.len);
        }
        if (have > e.size) {
            std.Io.Dir.cwd().deleteFile(io, part) catch {};
            hasher = .init(.{});
            have = 0;
        }
    } else |_| {}

    var file = if (have > 0)
        try std.Io.Dir.cwd().openFile(io, part, .{ .mode = .write_only })
    else
        try std.Io.Dir.cwd().createFile(io, part, .{});
    var closed = false;
    defer if (!closed) file.close(io);

    var sink: Sink(@TypeOf(ctx), on_progress) = .{
        .io = io,
        .file = file,
        .pos = have,
        .hasher = &hasher,
        .id = id,
        .total = e.size,
        .ctx = ctx,
        .last = .now(io, .awake),
        .progress = .init(have),
    };
    sink.init();

    if (have < e.size) {
        const target = try url(arena, e);
        const Outcome = union(enum) { fetched: anyerror!void, watched: error{ Cancelled, Stalled } };
        var buf: [2]Outcome = undefined;
        var sel = std.Io.Select(Outcome).init(io, &buf);
        sel.concurrent(.fetched, fetchInto, .{ io, gpa, target, have, &sink.writer, status_out }) catch return error.DownloadFailed;
        // The fetch points into this frame: never return while it may still run.
        sel.concurrent(.watched, watch, .{ io, &sink.progress }) catch {
            sel.cancelDiscard();
            return error.DownloadFailed;
        };
        const first = sel.await() catch {
            sel.cancelDiscard();
            return error.Cancelled;
        };
        sel.cancelDiscard();
        switch (first) {
            .watched => |w| return w,
            .fetched => |r| r catch |err| {
                if (sink.cancelled) return error.Cancelled;
                if (sink.failed) return error.WriteFailed;
                if (err == error.RangeIgnored) {
                    // The server won't resume this file: start over next time.
                    file.close(io);
                    closed = true;
                    std.Io.Dir.cwd().deleteFile(io, part) catch {};
                }
                return err;
            },
        }
    }
    file.close(io);
    closed = true;

    if (sink.pos != e.size) return error.Incomplete;
    var digest: [32]u8 = undefined;
    hasher.final(&digest);
    const hex = std.fmt.bytesToHex(digest, .lower);
    if (!std.mem.eql(u8, &hex, e.sha256)) {
        std.Io.Dir.cwd().deleteFile(io, part) catch {};
        return error.ChecksumMismatch;
    }
    try std.Io.Dir.cwd().rename(part, std.Io.Dir.cwd(), final, io);
    log.info("downloaded {s}", .{e.file});
    return final;
}

/// GET `target` from byte `have` on into `w`. The status (and, resuming, the
/// Content-Range start) is checked before any byte is written.
fn fetchInto(io: std.Io, gpa: std.mem.Allocator, target: []const u8, have: u64, w: *std.Io.Writer, status_out: *std.http.Status) anyerror!void {
    const uri = try std.Uri.parse(target);
    var client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer client.deinit();
    var range_buf: [64]u8 = undefined;
    const range = try std.fmt.bufPrint(&range_buf, "bytes={d}-", .{have});
    var req = try client.request(.GET, uri, .{
        .redirect_behavior = @enumFromInt(5),
        // Byte ranges of the file itself, never of a compressed body.
        .headers = .{ .accept_encoding = .{ .override = "identity" } },
        .extra_headers = if (have > 0) &.{.{ .name = "Range", .value = range }} else &.{},
    });
    defer req.deinit();
    try req.sendBodiless();
    var redirect_buf: [8 * 1024]u8 = undefined;
    var response = try req.receiveHead(&redirect_buf);
    status_out.* = response.head.status;
    if (have > 0) {
        if (response.head.status == .ok) return error.RangeIgnored;
        if (response.head.status != .partial_content) return error.HttpError;
        var start: ?u64 = null;
        var it = response.head.iterateHeaders();
        while (it.next()) |h| {
            if (std.ascii.eqlIgnoreCase(h.name, "content-range")) start = rangeStart(h.value);
        }
        if (start != have) return error.RangeIgnored;
    } else if (response.head.status != .ok) return error.HttpError;
    var transfer_buf: [64]u8 = undefined;
    const reader = response.reader(&transfer_buf);
    _ = reader.streamRemaining(w) catch |err| switch (err) {
        error.ReadFailed => return response.bodyErr() orelse error.ReadFailed,
        error.WriteFailed => return error.WriteFailed,
    };
    try w.flush();
}

/// `bytes 100-199/200` → 100.
fn rangeStart(value: []const u8) ?u64 {
    const v = std.mem.trim(u8, value, " ");
    if (!std.mem.startsWith(u8, v, "bytes ")) return null;
    const rest = v["bytes ".len..];
    const dash = std.mem.indexOfScalar(u8, rest, '-') orelse return null;
    return std.fmt.parseInt(u64, rest[0..dash], 10) catch null;
}

/// Ends the download on Pause, or when no byte arrived for a minute.
fn watch(io: std.Io, progress: *std.atomic.Value(u64)) error{ Cancelled, Stalled } {
    var last = progress.load(.acquire);
    var quiet_ms: u64 = 0;
    while (true) {
        io.sleep(.fromMilliseconds(250), .awake) catch return error.Cancelled;
        if (cancel_flag.load(.acquire)) return error.Cancelled;
        const now = progress.load(.acquire);
        if (now != last) {
            last = now;
            quiet_ms = 0;
        } else {
            quiet_ms += 250;
            if (quiet_ms >= 60_000) return error.Stalled;
        }
    }
}

/// Writes the body to the file, hashing it and reporting progress.
fn Sink(comptime Ctx: type, comptime on_progress: fn (Ctx, Progress) void) type {
    return struct {
        const Self = @This();
        io: std.Io,
        file: std.Io.File,
        pos: u64,
        hasher: *std.crypto.hash.sha2.Sha256,
        id: []const u8,
        total: u64,
        ctx: Ctx,
        last: std.Io.Clock.Timestamp,
        cancelled: bool = false,
        failed: bool = false,
        /// `pos`, for the watcher.
        progress: std.atomic.Value(u64) = .init(0),
        buf: [256 * 1024]u8 = undefined,
        writer: std.Io.Writer = undefined,

        fn init(self: *Self) void {
            self.writer = .{ .buffer = &self.buf, .vtable = &.{ .drain = drain, .flush = flush } };
        }

        fn flush(w: *std.Io.Writer) std.Io.Writer.Error!void {
            const self: *Self = @alignCast(@fieldParentPtr("writer", w));
            try self.put(w.buffered());
            w.end = 0;
        }

        fn drain(w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
            const self: *Self = @alignCast(@fieldParentPtr("writer", w));
            try self.put(w.buffered());
            w.end = 0;
            var n: usize = 0;
            for (data[0 .. data.len - 1]) |d| {
                try self.put(d);
                n += d.len;
            }
            for (0..splat) |_| {
                try self.put(data[data.len - 1]);
                n += data[data.len - 1].len;
            }
            return n;
        }

        fn put(self: *Self, bytes: []const u8) std.Io.Writer.Error!void {
            if (cancel_flag.load(.acquire)) {
                self.cancelled = true;
                return error.WriteFailed;
            }
            if (bytes.len == 0) return;
            self.file.writePositionalAll(self.io, bytes, self.pos) catch {
                self.failed = true;
                return error.WriteFailed;
            };
            self.hasher.update(bytes);
            self.pos += bytes.len;
            self.progress.store(self.pos, .release);
            const now: std.Io.Clock.Timestamp = .now(self.io, .awake);
            if (self.last.durationTo(now).raw.toMilliseconds() >= 200) {
                self.last = now;
                on_progress(self.ctx, .{ .id = self.id, .state = "downloading", .done = self.pos, .total = self.total });
            }
        }
    };
}

/// Delete a downloaded model (and its partial download) from our folder.
pub fn remove(io: std.Io, arena: std.mem.Allocator, d: Dirs, id: []const u8) !void {
    const e = find(id) orelse return error.UnknownModel;
    if (isDownloading()) return error.Busy;
    const final = try std.fs.path.join(arena, &.{ d.own, e.file });
    std.Io.Dir.cwd().deleteFile(io, final) catch {};
    std.Io.Dir.cwd().deleteFile(io, try std.fmt.allocPrint(arena, "{s}.part", .{final})) catch {};
}

test "catalog ids and hashes" {
    for (catalog) |e| {
        try std.testing.expectEqual(@as(usize, 64), e.sha256.len);
        try std.testing.expect(std.ascii.endsWithIgnoreCase(e.file, ".gguf"));
        try std.testing.expect(find(e.id) != null);
    }
    try std.testing.expect(find(default_id) != null);
}

test rangeStart {
    try std.testing.expectEqual(@as(?u64, 100), rangeStart("bytes 100-199/200"));
    try std.testing.expectEqual(@as(?u64, null), rangeStart("items 1-2/3"));
}

test resolve {
    const io = std.testing.io;
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "own");
    try tmp.dir.createDirPath(io, "lms/unsloth/Qwen3.5-2B-GGUF");
    try tmp.dir.writeFile(io, .{ .sub_path = "lms/unsloth/Qwen3.5-2B-GGUF/qwen3.5-2b-q4_k_m.gguf", .data = "GGUF" });
    const base = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    const d: Dirs = .{ .own = try std.fs.path.join(a, &.{ base, "own" }), .others = &.{try std.fs.path.join(a, &.{ base, "lms" })} };
    const found = resolve(io, a, d, "qwen3.5-2b").?;
    try std.testing.expect(std.mem.endsWith(u8, found, "qwen3.5-2b-q4_k_m.gguf"));
    try std.testing.expect(resolve(io, a, d, "gemma-3-4b-it") == null);
    try std.testing.expect(resolve(io, a, d, "nope") == null);
    // file: only for GGUFs inside the model folders.
    try std.testing.expect(resolve(io, a, d, try std.fmt.allocPrint(a, "file:{s}", .{found})) != null);
    try std.testing.expect(resolve(io, a, d, "file:/etc/passwd") == null);
}
