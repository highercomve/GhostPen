//! Speakers by voice (MEETINGS.md phase 3), over `oriel.speakers`: the
//! speaker model (downloaded on first use), the meeting's speakers on save
//! (whisper's segments embedded in windows, clustered, matched to the
//! known voices) and the live labels of the captions overlay.
//!
//! The encoder isn't thread-safe: `mutex` serializes the save pipeline and
//! the captions worker. It runs on the CPU, in this process.

const std = @import("std");
const oriel = @import("oriel");
const main = @import("main.zig");
const store = @import("meeting_store.zig");
const voices = @import("voices.zig");
const wav = @import("wav.zig");
const llm_models = @import("llm_models.zig");

const sp = oriel.speakers;
const log = std.log.scoped(.speakers);
const gpa = std.heap.smp_allocator;
// Speaker labels aren't built for every platform (oriel.speakers.available:
// not Android yet): there, every entry point says no.
const rate = if (sp.available) sp.sample_rate else 16000;

pub const available = sp.available;
/// The catalog's first: WeSpeaker ResNet34 (Oriel's docs/speakers.md has
/// the measurements; the ECAPA GGUF tells people apart much less well).
pub const default_model = if (available) sp.catalog[0].id else "";

var mutex: std.Io.Mutex = .init;
var encoder: if (available) ?*sp.Encoder else ?*anyopaque = null;
var encoder_model: []u8 = &.{};
var family_buf: [128]u8 = undefined;
var family_len: usize = 0;

pub fn find(id: []const u8) ?sp.Model {
    for (sp.catalog) |m| if (std.mem.eql(u8, m.id, id)) return m;
    return null;
}

fn modelDir(arena: std.mem.Allocator) ![]const u8 {
    const base = try oriel.paths.appData(arena, .{ .name = "GhostPen" });
    return std.fs.path.join(arena, &.{ base, "models", "speakers" });
}

pub fn isDownloaded(arena: std.mem.Allocator, id: []const u8) bool {
    if (!available) return false;
    const m = find(id) orelse return false;
    const dir = modelDir(arena) catch return false;
    const p = std.fs.path.join(arena, &.{ dir, m.file }) catch return false;
    const st = std.Io.Dir.cwd().statFile(main.io, p, .{}) catch return false;
    return st.size == m.size;
}

/// The model's file, downloaded first when missing (resumed and verified
/// like the other models; `progress(ctx, 0..1)`). Blocks: a worker only.
pub fn ensureModel(arena: std.mem.Allocator, id: []const u8, ctx: anytype, comptime progress: fn (@TypeOf(ctx), f64) void) ![:0]const u8 {
    if (!available) return error.Unsupported;
    const m = find(id) orelse return error.UnknownModel;
    const dir = try modelDir(arena);
    if (!isDownloaded(arena, id)) {
        log.info("downloading the speaker model {s} ({d} MB)", .{ m.id, m.size / 1_000_000 });
        const Report = struct {
            fn on(c: @TypeOf(ctx), p: llm_models.Progress) void {
                if (p.total > 0) progress(c, @as(f64, @floatFromInt(p.done)) / @as(f64, @floatFromInt(p.total)));
            }
        };
        var status: std.http.Status = .ok;
        _ = try llm_models.downloadFile(main.io, gpa, arena, dir, m.id, m.file, m.url, m.size, m.sha256, ctx, Report.on, &status);
    }
    return std.fs.path.joinZ(arena, &.{ dir, m.file });
}

/// The loaded encoder for `id` (loading or switching it). With `mutex` held.
fn encoderLocked(path: [:0]const u8, id: []const u8) !*sp.Encoder {
    if (encoder) |e| {
        if (std.mem.eql(u8, encoder_model, id)) return e;
        e.deinit();
        encoder = null;
        gpa.free(encoder_model);
        encoder_model = &.{};
    }
    const began = std.Io.Clock.awake.now(main.io);
    const e = sp.Encoder.load(path) catch |err| {
        log.err("speaker model {s}: {s} ({s})", .{ id, @errorName(err), sp.lastLoadError() });
        return err;
    };
    encoder = e;
    encoder_model = try gpa.dupe(u8, id);
    const fam = e.family();
    family_len = @min(fam.len, family_buf.len);
    @memcpy(family_buf[0..family_len], fam[0..family_len]);
    log.info("speaker model {s} loaded in {d} ms ({d}-d, {s})", .{ id, began.durationTo(std.Io.Clock.awake.now(main.io)).toMilliseconds(), e.dim(), fam });
    return e;
}

// ---- the meeting's speakers ----------------------------------------------------------------

/// 3 s windows: at 1.5 s one man's halves were only 0.54 alike (0.80 at 3 s).
const window_s = 3.0;
const step_s = 1.5;
const min_s = 1.0;
/// Windows per segment at most (a long segment is sampled, not swept).
const max_windows = 12;

const Win = struct { seg: usize, emb: []f32 };

/// Label the others' segments by voice: speakers "s1", "s2", … named by
/// the known voices they match ("Speaker N" otherwise); "me" keeps its id
/// and gets its voice too. `progress(0..1)`.
pub fn findSpeakers(
    arena: std.mem.Allocator,
    m: *store.Meeting,
    audio_path: []const u8,
    model_id: []const u8,
    expected: u32,
    ctx: anytype,
    comptime progress: fn (@TypeOf(ctx), f64) void,
) !void {
    if (!available) return error.Unsupported;
    const Dl = struct {
        fn report(c: @TypeOf(ctx), p: f64) void {
            progress(c, p * 0.2);
        }
    };
    const model_path = try ensureModel(arena, model_id, ctx, Dl.report);

    const f = try std.Io.Dir.cwd().openFile(main.io, audio_path, .{});
    defer f.close(main.io);
    const info = try wav.info(main.io, f);
    if (info.rate != rate) return error.UnsupportedFormat;

    const family = blk: {
        mutex.lockUncancelable(main.io);
        defer mutex.unlock(main.io);
        _ = try encoderLocked(model_path, model_id);
        break :blk try arena.dupe(u8, family_buf[0..family_len]);
    };

    // Embed windows of every segment, track by track.
    var wins: std.ArrayList(Win) = .empty;
    var me_wins: std.ArrayList([]f32) = .empty;
    for (m.segments, 0..) |seg, i| {
        const is_me = std.mem.eql(u8, seg.speaker, store.me_id);
        if (is_me and me_wins.items.len >= 40) continue;
        const channel: u16 = if (is_me and info.channels > 1) 1 else 0;
        const len = seg.end - seg.start;
        if (len < min_s) continue;
        const n_win: usize = if (len <= window_s) 1 else @min(max_windows, @as(usize, @intFromFloat((len - window_s) / step_s)) + 1);
        const stride = if (n_win > 1) (len - window_s) / @as(f64, @floatFromInt(n_win - 1)) else 0;
        for (0..n_win) |k| {
            const start = seg.start + stride * @as(f64, @floatFromInt(k));
            const dur = @min(window_s, len);
            const from: u64 = @intFromFloat(start * rate);
            const samples = try wav.readChannel(main.io, gpa, f, info, channel, from, @intFromFloat(dur * rate));
            defer gpa.free(samples);
            if (store.silent(samples)) continue;
            const e = blk: {
                mutex.lockUncancelable(main.io);
                defer mutex.unlock(main.io);
                const enc = try encoderLocked(model_path, model_id);
                break :blk enc.embed(gpa, samples) catch |err| {
                    log.warn("embedding a window at {d:.1} s: {s}", .{ start, @errorName(err) });
                    continue;
                };
            };
            defer gpa.free(e);
            const owned = try arena.dupe(f32, e);
            if (is_me) try me_wins.append(arena, owned) else try wins.append(arena, .{ .seg = i, .emb = owned });
        }
        if (i % 8 == 0) progress(ctx, 0.2 + 0.7 * @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(m.segments.len)));
    }

    if (main.environ_map.get("GHOSTPEN_SPEAKERS_DUMP")) |dump| dumpWindows(arena, dump, m.segments, wins.items) catch {};
    // Cluster the others' windows; a segment takes its windows' majority.
    const embs = try arena.alloc([]const f32, wins.items.len);
    for (embs, wins.items) |*e, w| e.* = w.emb;
    const labels = if (embs.len > 0) try sp.cluster(arena, embs, .{ .speakers = expected }) else &[_]u32{};
    var k: usize = 0;
    for (labels) |l| k = @max(k, l + 1);

    const known = (voices.load(main.io, arena, try @import("meetings.zig").voicesPath(arena)) catch voices.File{}).voices;
    var speakers: std.ArrayList(store.Speaker) = .empty;
    if (me_wins.items.len > 0 or hasSpeaker(m.*, store.me_id)) {
        const c = try centroid(arena, me_wins.items);
        const match = if (c.len > 0) voices.bestMatch(known, family, c) else null;
        try speakers.append(arena, .{
            .id = store.me_id,
            .name = m.keptName(store.me_id) orelse "Me",
            .voice = if (match) |j| known[j].name else "",
            .embedding = c,
        });
    }
    const ids = try arena.alloc([]const u8, k);
    for (0..k) |c_i| {
        var members: std.ArrayList([]f32) = .empty;
        for (wins.items, labels) |w, l| if (l == c_i) try members.append(arena, w.emb);
        const c = try centroid(arena, members.items);
        const match = voices.bestMatch(known, family, c);
        ids[c_i] = try std.fmt.allocPrint(arena, "s{d}", .{c_i + 1});
        try speakers.append(arena, .{
            .id = ids[c_i],
            .name = if (match) |j| known[j].name else try std.fmt.allocPrint(arena, "Speaker {d}", .{c_i + 1}),
            .voice = if (match) |j| known[j].name else "",
            .embedding = c,
        });
    }

    // Votes per segment.
    const segs = try arena.dupe(store.Segment, m.segments);
    const votes = try arena.alloc(u32, k * segs.len);
    @memset(votes, 0);
    for (wins.items, labels) |w, l| votes[w.seg * k + l] += 1;
    var last: ?usize = null;
    for (segs, 0..) |*s, i| {
        if (std.mem.eql(u8, s.speaker, store.me_id)) continue;
        var best: ?usize = null;
        var best_n: u32 = 0;
        for (0..k) |c_i| if (votes[i * k + c_i] > best_n) {
            best_n = votes[i * k + c_i];
            best = c_i;
        };
        // Too short to embed: the previous others' speaker, else the first.
        const pick = best orelse last orelse (if (k > 0) @as(?usize, 0) else null);
        if (pick) |p| {
            s.speaker = ids[p];
            last = p;
        } else {
            s.speaker = "s1";
        }
    }
    try pruneAndNumber(arena, &speakers, segs);
    // Others with no voice at all (all too short): one plain speaker.
    if (k == 0 and hasOthers(segs)) try speakers.append(arena, .{ .id = "s1", .name = m.keptName("s1") orelse "Speaker 1" });

    m.segments = segs;
    m.speakers = speakers.items;
    m.voiceFamily = family;
    m.final = try relabel(arena, m.final, segs);
    progress(ctx, 1);
    log.info("{d} speakers from {d} windows ({d} known)", .{ k, wins.items.len, countKnown(speakers.items) });
}

/// Speakers who won no line (outvoted inside a segment) go; the others are
/// numbered s1, s2, … by first line ("Speaker N" unless a known voice).
fn pruneAndNumber(arena: std.mem.Allocator, list: *std.ArrayList(store.Speaker), segs: []store.Segment) !void {
    var out: std.ArrayList(store.Speaker) = .empty;
    for (list.items) |x| if (std.mem.eql(u8, x.id, store.me_id)) try out.append(arena, x);
    // Old id → new id, in order of first line.
    var old_ids: std.ArrayList([]const u8) = .empty;
    var new_ids: std.ArrayList([]const u8) = .empty;
    for (segs) |seg| {
        if (std.mem.eql(u8, seg.speaker, store.me_id)) continue;
        if (indexOf(old_ids.items, seg.speaker) != null) continue;
        for (list.items) |x| if (std.mem.eql(u8, x.id, seg.speaker)) {
            const n = old_ids.items.len + 1;
            var renamed = x;
            renamed.id = try std.fmt.allocPrint(arena, "s{d}", .{n});
            if (x.voice.len == 0) renamed.name = try std.fmt.allocPrint(arena, "Speaker {d}", .{n});
            try old_ids.append(arena, x.id);
            try new_ids.append(arena, renamed.id);
            try out.append(arena, renamed);
            break;
        };
    }
    for (segs) |*seg| if (indexOf(old_ids.items, seg.speaker)) |i| {
        seg.speaker = new_ids.items[i];
    };
    list.* = out;
}

fn indexOf(ids: []const []const u8, id: []const u8) ?usize {
    for (ids, 0..) |x, i| if (std.mem.eql(u8, x, id)) return i;
    return null;
}

fn hasSpeaker(m: store.Meeting, id: []const u8) bool {
    for (m.segments) |s| if (std.mem.eql(u8, s.speaker, id)) return true;
    return false;
}

fn hasOthers(segs: []const store.Segment) bool {
    for (segs) |s| if (!std.mem.eql(u8, s.speaker, store.me_id)) return true;
    return false;
}

fn countKnown(list: []const store.Speaker) usize {
    var n: usize = 0;
    for (list) |s| n += @intFromBool(s.voice.len > 0);
    return n;
}

/// Mean of L2-normalized embeddings, normalized ("" for none).
fn centroid(arena: std.mem.Allocator, members: []const []f32) ![]f32 {
    if (members.len == 0) return &.{};
    const c = try arena.alloc(f32, members[0].len);
    @memset(c, 0);
    for (members) |e| for (c, e) |*x, y| {
        x.* += y;
    };
    voices.normalize(c);
    return c;
}

/// The clean text's turns follow the new labels: each takes the speaker of
/// the segment that starts nearest to it.
fn relabel(arena: std.mem.Allocator, final: []const store.Segment, segs: []const store.Segment) ![]const store.Segment {
    if (final.len == 0 or segs.len == 0) return final;
    const out = try arena.dupe(store.Segment, final);
    for (out) |*t| {
        var best: usize = 0;
        var best_d: f64 = std.math.inf(f64);
        for (segs, 0..) |s, i| {
            const d = @abs(s.start - t.start);
            if (d < best_d) {
                best_d = d;
                best = i;
            }
        }
        t.speaker = segs[best].speaker;
    }
    return out;
}

// ---- live labels ---------------------------------------------------------------------------

/// The live speaker of a caption chunk: its index in `tracker`, and the name
/// to show. null when the model isn't downloaded (live labels never wait
/// for a download) or the chunk can't be embedded.
pub fn liveLabel(arena: std.mem.Allocator, tracker: *voices.Tracker, model_id: []const u8, samples: []const f32, known: []const voices.Voice) ?struct { index: usize, name: []const u8 } {
    if (!available) return null;
    if (!isDownloaded(arena, model_id)) return null;
    const m = find(model_id) orelse return null;
    const dir = modelDir(arena) catch return null;
    const path = std.fs.path.joinZ(arena, &.{ dir, m.file }) catch return null;
    // A meeting being saved holds the model for its whole recording: the
    // live caption goes out unlabelled rather than waiting (and holding up Stop).
    if (!mutex.tryLock()) return null;
    defer mutex.unlock(main.io);
    const enc = encoderLocked(path, model_id) catch return null;
    const e = enc.embed(gpa, samples) catch return null;
    defer gpa.free(e);
    const i = tracker.assign(e, known, family_buf[0..family_len]) catch return null;
    const name = if (tracker.known.items[i]) |j| known[j].name else std.fmt.allocPrint(arena, "Speaker {d}", .{i + 1}) catch return null;
    return .{ .index = i, .name = name };
}

/// Tuning aid (GHOSTPEN_SPEAKERS_DUMP=file): every window's segment start and embedding, as JSON.
fn dumpWindows(arena: std.mem.Allocator, path: []const u8, segs: []const store.Segment, wins: []const Win) !void {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(arena, "[");
    for (wins, 0..) |w, i| {
        if (i > 0) try out.appendSlice(arena, ",");
        try out.print(arena, "{{\"start\":{d},\"emb\":", .{segs[w.seg].start});
        try out.appendSlice(arena, try std.json.Stringify.valueAlloc(arena, w.emb, .{}));
        try out.appendSlice(arena, "}");
    }
    try out.appendSlice(arena, "]");
    try std.Io.Dir.cwd().writeFile(main.io, .{ .sub_path = path, .data = out.items });
}
