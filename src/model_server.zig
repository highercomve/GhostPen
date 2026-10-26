//! The model service: GhostPen's built-in models for other local apps
//! (GhostReel first), on the transcription server's port, so two apps don't
//! each load a model into GPU memory. It uses the very runners GhostPen's
//! own features use (`local_llm.zig`, `models.zig`), so a request from
//! another app never loads a second copy.
//!
//! The OpenAI-compatible routes, shaped like llama-server's where clients
//! probe them (GhostReel's `probe.rs`):
//!
//! - `POST /v1/chat/completions`: messages (text, and `image_url` data URLs
//!   when the model has a vision projector), `max_tokens`, `temperature`,
//!   `stream`, `top_p`, `top_k`, `min_p`, `presence_penalty`,
//!   `frequency_penalty`, `repeat_penalty` (unset: Qwen's agent settings,
//!   `agent_sampling`), thinking, and `response_format` `json_schema` (the answer
//!   matches the schema). Thinking is on unless the request turns it off
//!   (`reasoning_effort: "none"`, `chat_template_kwargs.enable_thinking` or
//!   `think` false); the reasoning comes back as `reasoning_content`.
//!   GhostPen's own features don't go through here and keep theirs off.
//!   The runner takes one system and one user turn: earlier turns are folded
//!   into the user text. An agent that keeps making the same tool call and
//!   getting the same result is told so after the second time and gets no
//!   tools after the third (`repeatedTurns`), so it answers instead of looping.
//!   The `model` field selects any installed built-in model; an omitted model
//!   uses the configured default. The runner loads on demand and switches models.
//! - `POST /v1/embeddings`: `input` (a string or strings), 768-dim vectors
//!   from embeddinggemma when it's on disk (GhostReel's or LM Studio's copy).
//! - `GET /v1/models`: all installed chat models (configured model first),
//!   plus transcription and embeddings. Chat models load on first request.
//! - `GET /props`: `modalities.vision` and `total_slots` (1); `GET /slots`:
//!   the context size.
//! - `GET /metrics`: the built-in model's performance counters (src/metrics.zig):
//!   requests, tokens and wall-clock of prompt and generation, tokens/s of
//!   the totals, the last request and the one running now.
//! - `POST /unload` (`{"models":["chat","embeddings","stt"]}`, or no body
//!   for all): stop those runners now, freeing their (GPU) memory, e.g. when
//!   a job is over.
//!
//! Models load when a request needs them (chat, embeddings and whisper each
//! in its own runner) and stop after a while unused. A request's
//! `keep_alive` (Ollama's: seconds, or "30s", "5m", "1h"; 0 = unload right
//! after the answer; negative = the default) sets how long its runner stays.
//!
//! Other apps find it through a discovery file (`discoveryPath`), written
//! when the server listens: its URL, this process's pid and what it serves.

const std = @import("std");
const builtin = @import("builtin");
const oriel = @import("oriel");
const main = @import("main.zig");
const ai = @import("ai.zig");
const local_llm = @import("local_llm.zig");
const ai_stream = @import("ai_stream.zig");
const metrics = @import("metrics.zig");
const models = @import("models.zig");
const llm_models = @import("llm_models.zig");

const log = std.log.scoped(.model_server);
const gpa = std.heap.smp_allocator;

pub const Reply = struct { status: std.http.Status = .ok, body: []const u8, content_type: []const u8 = "application/json" };

pub fn errorReply(status: std.http.Status, message: []const u8, arena: std.mem.Allocator) Reply {
    const body = std.json.Stringify.valueAlloc(arena, .{ .@"error" = .{ .message = message, .type = "invalid_request_error" } }, .{}) catch "{}";
    return .{ .status = status, .body = body };
}

/// The built-in model's runner configuration, or null (logged) when it
/// isn't downloaded.
fn config(arena: std.mem.Allocator, selected: ?[]const u8, why: *[]const u8) ?local_llm.Config {
    var diag: ai.Diag = .{};
    return (if (selected) |model| main.builtinConfigForModel(arena, model, &diag) else main.builtinConfig(arena, &diag)) catch {
        why.* = if (diag.message.len > 0) diag.message else "the built-in model isn't available";
        return null;
    };
}

fn modelName(cfg: local_llm.Config) []const u8 {
    const base = std.fs.path.basename(cfg.model);
    return if (std.ascii.endsWithIgnoreCase(base, ".gguf")) base[0 .. base.len - ".gguf".len] else base;
}

fn embedName(cfg: local_llm.Config) ?[]const u8 {
    const p = cfg.embed_model orelse return null;
    const base = std.fs.path.basename(p);
    return if (std.ascii.endsWithIgnoreCase(base, ".gguf")) base[0 .. base.len - ".gguf".len] else base;
}

/// The chat and embedding entries for `/v1/models` (after the whisper one).
pub fn modelEntries(arena: std.mem.Allocator) ![]const ModelEntry {
    const dirs = try main.llmDirs(arena);
    const status = try llm_models.status(main.io, arena, dirs);
    var why: []const u8 = "";
    const cfg = config(arena, null, &why);
    var list: std.ArrayList(ModelEntry) = .empty;
    // The configured model comes first, so clients using the default alias
    // retain GhostPen's selected model.
    if (cfg) |active| {
        for (status.models) |m| if (m.path.len > 0 and std.mem.eql(u8, m.path, active.model)) {
            try list.append(arena, .{ .id = m.id, .capabilities = .{ .chat = true, .vision = m.vision } });
        };
        for (status.others) |m| if (std.mem.eql(u8, m.path, active.model)) {
            try list.append(arena, .{ .id = m.id, .capabilities = .{ .chat = true, .vision = m.vision } });
        };
    }
    for (status.models) |m| {
        if (m.path.len == 0 or (cfg != null and std.mem.eql(u8, m.path, cfg.?.model))) continue;
        try list.append(arena, .{ .id = m.id, .capabilities = .{ .chat = true, .vision = m.vision } });
    }
    for (status.others) |m| {
        if (cfg != null and std.mem.eql(u8, m.path, cfg.?.model)) continue;
        try list.append(arena, .{ .id = m.id, .capabilities = .{ .chat = true, .vision = m.vision } });
    }
    if (cfg) |active| if (embedName(active)) |e| try list.append(arena, .{ .id = e, .capabilities = .{ .embeddings = true } });
    return list.items;
}

pub const ModelEntry = struct {
    id: []const u8,
    object: []const u8 = "model",
    owned_by: []const u8 = "ghostpen",
    capabilities: struct { chat: bool = false, vision: bool = false, embeddings: bool = false },
};

pub fn propsReply(arena: std.mem.Allocator) !Reply {
    var why: []const u8 = "";
    const cfg = config(arena, null, &why) orelse return errorReply(.service_unavailable, why, arena);
    return .{ .body = try std.json.Stringify.valueAlloc(arena, .{
        .model_path = cfg.model,
        .total_slots = 1,
        .modalities = .{ .vision = cfg.mmproj != null, .audio = false },
        .default_generation_settings = .{ .n_ctx = cfg.ctx },
    }, .{}) };
}

pub fn slotsReply(arena: std.mem.Allocator) !Reply {
    var why: []const u8 = "";
    const cfg = config(arena, null, &why) orelse return errorReply(.service_unavailable, why, arena);
    return .{ .body = try std.json.Stringify.valueAlloc(arena, .{.{ .id = 0, .n_ctx = cfg.ctx }}, .{}) };
}

/// `GET /metrics`: the built-in model's counters (src/metrics.zig), what it
/// runs on, and the speed of the last request and the one running now.
pub fn metricsReply(io: std.Io, arena: std.mem.Allocator) !Reply {
    var why: []const u8 = "";
    const cfg = config(arena, null, &why);
    return .{ .body = try metricsBody(arena, metrics.snapshot(io, arena), cfg) };
}

fn metricsBody(arena: std.mem.Allocator, snap: metrics.Snapshot, cfg: ?local_llm.Config) ![]const u8 {
    const info: ?metrics.Info = snap.loaded;
    return std.json.Stringify.valueAlloc(arena, .{
        // The loaded model, else what a request would use.
        .model = if (info) |i| i.model else if (cfg) |c| std.fs.path.basename(c.model) else "",
        .loaded = local_llm.loaded(),
        .gpu = if (info) |i| i.gpu else "",
        .ctx = if (info) |i| i.ctx else if (cfg) |c| c.ctx else 0,
        .load_ms = if (info) |i| i.load_ms else 0,
        .requests = snap.requests,
        .failed_requests = snap.failed_requests,
        .prompt_tokens = snap.prompt_tokens,
        .prompt_ms = snap.prompt_ms,
        .prompt_tokens_second = perSecond(snap.prompt_tokens, snap.prompt_ms),
        .gen_tokens = snap.gen_tokens,
        .gen_ms = snap.gen_ms,
        .gen_tokens_second = perSecond(snap.gen_tokens, snap.gen_ms),
        .last = if (snap.last) |l| .{
            .prompt_tokens = l.usage.prompt_tokens,
            .prompt_ms = l.usage.prompt_ms,
            .prompt_tokens_second = perSecond(l.usage.prompt_tokens, l.usage.prompt_ms),
            .gen_tokens = l.usage.gen_tokens,
            .gen_ms = l.usage.gen_ms,
            .gen_tokens_second = perSecond(l.usage.gen_tokens, l.usage.gen_ms),
            .finished = l.finished,
        } else null,
        .in_flight = if (snap.in_flight) |f| .{
            .model = f.info.model,
            .gpu = f.info.gpu,
            .ctx = f.info.ctx,
            .elapsed_ms = f.usage.prompt_ms + f.usage.gen_ms,
            .prompt_tokens = f.usage.prompt_tokens,
            .prompt_ms = f.usage.prompt_ms,
            .prompt_tokens_second = perSecond(f.usage.prompt_tokens, f.usage.prompt_ms),
            .gen_tokens = f.usage.gen_tokens,
            .gen_ms = f.usage.gen_ms,
            .gen_tokens_second = perSecond(f.usage.gen_tokens, f.usage.gen_ms),
        } else null,
    }, .{ .emit_null_optional_fields = false });
}

/// The context a request asks for: Ollama's `options.num_ctx`, or `n_ctx`
/// (null: GhostPen's setting). At most 256k tokens.
fn requestedCtx(obj: std.json.ObjectMap) ?u32 {
    const v = blk: {
        if (obj.get("options")) |o| if (o == .object) if (o.object.get("num_ctx")) |n| break :blk n;
        break :blk obj.get("n_ctx") orelse return null;
    };
    return switch (v) {
        .integer => |n| if (n <= 0) null else @intCast(@min(n, 262144)),
        else => null,
    };
}

/// The longest `keep_alive` honored: a day keeps a runner as good as
/// forever, and the client's number can't overflow the arithmetic.
const max_keep_alive_ms: u64 = 24 * 60 * 60 * 1000;

/// A request's `keep_alive` in milliseconds (null: the runner's default).
fn keepAliveMs(obj: std.json.ObjectMap) ?u64 {
    const v = obj.get("keep_alive") orelse return null;
    return switch (v) {
        .integer => |n| if (n < 0) null else @min(std.math.mul(u64, @intCast(n), 1000) catch max_keep_alive_ms, max_keep_alive_ms),
        .float => |f| scaledMs(f, 1000),
        .string => |t| parseDuration(t),
        else => null,
    };
}

/// `n` units of `unit_ms` as milliseconds, at most a day; null when
/// negative, NaN or infinite.
fn scaledMs(n: f64, unit_ms: f64) ?u64 {
    if (!std.math.isFinite(n) or n < 0) return null;
    const ms = n * unit_ms;
    if (ms >= @as(f64, @floatFromInt(max_keep_alive_ms))) return max_keep_alive_ms;
    return @intFromFloat(ms);
}

/// "30s", "5m", "1h", "250ms" or plain seconds; null when negative or unreadable.
fn parseDuration(text: []const u8) ?u64 {
    const t = std.mem.trim(u8, text, " ");
    if (t.len == 0 or t[0] == '-') return null;
    const units = [_]struct { suffix: []const u8, ms: f64 }{
        .{ .suffix = "ms", .ms = 1 },
        .{ .suffix = "s", .ms = 1000 },
        .{ .suffix = "m", .ms = 60_000 },
        .{ .suffix = "h", .ms = 3_600_000 },
    };
    for (units) |u| if (std.mem.endsWith(u8, t, u.suffix)) {
        return scaledMs(std.fmt.parseFloat(f64, t[0 .. t.len - u.suffix.len]) catch return null, u.ms);
    };
    return scaledMs(std.fmt.parseFloat(f64, t) catch return null, 1000);
}

// ---- /unload --------------------------------------------------------------------------

pub fn unloadReply(io: std.Io, arena: std.mem.Allocator, body: []const u8) !Reply {
    var chat = true;
    var embeddings = true;
    var stt = true;
    if (std.mem.trim(u8, body, " \t\r\n").len > 0) {
        const root = std.json.parseFromSliceLeaky(std.json.Value, arena, body, .{}) catch return errorReply(.bad_request, "the body isn't JSON", arena);
        if (root == .object) if (root.object.get("models")) |m| if (m == .array) {
            chat = false;
            embeddings = false;
            stt = false;
            for (m.array.items) |item| if (item == .string) {
                if (std.mem.eql(u8, item.string, "chat")) chat = true;
                if (std.mem.eql(u8, item.string, "embeddings")) embeddings = true;
                if (std.mem.eql(u8, item.string, "stt")) stt = true;
            };
        };
    }
    if (chat) local_llm.unloadChat(io);
    if (embeddings) local_llm.unloadEmbeddings(io);
    if (stt) models.unload(io);
    log.info("unloaded on request:{s}{s}{s}", .{ if (chat) " chat" else "", if (embeddings) " embeddings" else "", if (stt) " stt" else "" });
    return .{ .body = try std.json.Stringify.valueAlloc(arena, .{ .unloaded = .{ .chat = chat, .embeddings = embeddings, .stt = stt } }, .{}) };
}

// ---- /v1/embeddings -----------------------------------------------------------------

/// Texts and bytes one embeddings request may carry: the runner embeds them
/// one by one, holding the embedding model the whole time.
const max_embed_inputs = 256;
const max_embed_bytes = 4 * 1024 * 1024;

pub fn embeddingsReply(io: std.Io, arena: std.mem.Allocator, body: []const u8) !Reply {
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, body, .{}) catch return errorReply(.bad_request, "the body isn't JSON", arena);
    const obj = switch (parsed) {
        .object => |o| o,
        else => return errorReply(.bad_request, "expected a JSON object", arena),
    };
    const input = obj.get("input") orelse return errorReply(.bad_request, "missing input", arena);
    var texts: std.ArrayList([]const u8) = .empty;
    switch (input) {
        .string => |t| try texts.append(arena, t),
        .array => |a| for (a.items) |item| switch (item) {
            .string => |t| try texts.append(arena, t),
            else => return errorReply(.bad_request, "input must be strings", arena),
        },
        else => return errorReply(.bad_request, "input must be a string or strings", arena),
    }
    if (texts.items.len == 0) return errorReply(.bad_request, "input is empty", arena);
    if (texts.items.len > max_embed_inputs) return errorReply(.bad_request, std.fmt.comptimePrint("too many inputs ({d} at most)", .{max_embed_inputs}), arena);
    var total: usize = 0;
    for (texts.items) |t| total += t.len;
    if (total > max_embed_bytes) return errorReply(.payload_too_large, "the inputs are too large (4 MB at most)", arena);

    var why: []const u8 = "";
    const cfg = config(arena, null, &why) orelse return errorReply(.service_unavailable, why, arena);
    if (cfg.embed_model == null) return errorReply(.service_unavailable, "no embedding model (embeddinggemma-300M-Q8_0.gguf) found in the model folders", arena);
    var model: []const u8 = "";
    var diag: []const u8 = "";
    const vectors = local_llm.embed(io, gpa, arena, cfg, texts.items, &model, keepAliveMs(obj), &diag) catch |err| switch (err) {
        error.OutOfMemory => return err,
        error.LocalFailed => return errorReply(.internal_server_error, diag, arena),
    };
    const Item = struct { object: []const u8 = "embedding", index: usize, embedding: []const f32 };
    const data = try arena.alloc(Item, vectors.len);
    for (data, vectors, 0..) |*d, v, i| d.* = .{ .index = i, .embedding = v };
    return .{ .body = try std.json.Stringify.valueAlloc(arena, .{
        .object = "list",
        .model = model,
        .data = data,
        .usage = .{ .prompt_tokens = 0, .total_tokens = 0 },
    }, .{}) };
}

// ---- /v1/chat/completions -----------------------------------------------------------

const ChatRequest = struct {
    chat: local_llm.Chat,
    model: ?[]const u8 = null,
    stream: bool,
    /// `stream_options.include_usage`: a final chunk with `usage` (and empty
    /// `choices`) before `[DONE]`.
    include_usage: bool = false,
    /// Tools were offered: the answer is JSON (`ToolAnswer`), turned into
    /// OpenAI `tool_calls` or content.
    tools: bool = false,
};

/// The JSON the model answers with when tools are offered (the grammar
/// `toolSchema` builds allows exactly this).
const ToolAnswer = struct {
    tool_calls: ?[]const struct { name: []const u8, arguments: std.json.Value } = null,
    answer: ?[]const u8 = null,
};

/// The runner's request from an OpenAI chat body; null (with `err` set) when
/// it can't be served.
fn parseChat(arena: std.mem.Allocator, body: []const u8, err: *[]const u8) !?ChatRequest {
    var root = std.json.parseFromSliceLeaky(std.json.Value, arena, body, .{}) catch {
        err.* = "the body isn't JSON";
        return null;
    };
    if (root != .object) {
        err.* = "expected a JSON object";
        return null;
    }
    const messages = switch (root.object.get("messages") orelse .null) {
        .array => |a| a.items,
        else => {
            err.* = "missing messages";
            return null;
        },
    };

    // A small model in an agent loop calls the same tool with the same
    // arguments, gets the same result, and calls it again: a note on that
    // result, then a turn without tools so it answers.
    const repeats = try repeatedTurns(arena, messages);
    if (repeats >= repeat_note_at) {
        try noteRepeat(arena, messages, repeats);
        if (repeats >= repeat_answer_at) _ = root.object.orderedRemove("tools");
    }
    const request_body = if (repeats >= repeat_note_at) try std.json.Stringify.valueAlloc(arena, root, .{}) else body;
    const obj = root.object;

    // Tools (unless tool_choice is "none").
    const tools: []const std.json.Value = if (obj.get("tools")) |t| (if (t == .array) t.array.items else &.{}) else &.{};
    const choice = toolChoice(obj);
    const use_tools = tools.len > 0 and choice != .none;

    const folded = try foldMessages(arena, messages, err) orelse return null;
    // Other apps' agents get the model's reasoning by default (it picks
    // tools far better with it); GhostPen's own features run without.
    var chat: local_llm.Chat = .{ .system = folded.system, .user = folded.user, .image = folded.image, .think = true, .temperature = agent_temperature, .sampling = agent_sampling };
    try applyOptions(arena, obj, &chat);
    // Without an image the model's own chat template takes the request as it
    // is, as llama-server does: the messages with their tool calls and
    // results, and the tools, in the format the model was trained on. An
    // image goes the runner's vision way: one system and one user turn.
    if (folded.image == null) chat.request = request_body;
    if (use_tools and chat.request.len == 0) {
        chat.schema = try toolSchema(arena, tools, choice);
        const guide = try toolGuide(arena, tools, choice);
        chat.system = if (chat.system.len > 0) try std.fmt.allocPrint(arena, "{s}\n\n{s}", .{ chat.system, guide }) else guide;
    }
    const stream = if (obj.get("stream")) |s| s == .bool and s.bool else false;
    var include_usage = false;
    if (obj.get("stream_options")) |so| if (so == .object) if (so.object.get("include_usage")) |iu| {
        include_usage = iu == .bool and iu.bool;
    };
    const requested = if (obj.get("model")) |m| (if (m == .string and m.string.len > 0) m.string else null) else null;
    return .{ .chat = chat, .model = requested, .stream = stream, .include_usage = include_usage, .tools = use_tools };
}

/// The same tool calls with the same results this many turns in a row: a
/// note on the last result; then the tools are left out.
const repeat_note_at = 2;
const repeat_answer_at = 3;

/// How many assistant turns in a row, up to the end, made the very same tool
/// calls (names and arguments, not ids) and got the very same results; 0
/// unless the request ends with tool results. A poll whose answer changes
/// isn't a repeat.
fn repeatedTurns(arena: std.mem.Allocator, messages: []const std.json.Value) !usize {
    var n: usize = 0;
    var latest: ?[]const u8 = null;
    var end = messages.len;
    var i = messages.len;
    while (i > 0) {
        i -= 1;
        const role = roleOf(messages[i]) orelse continue;
        if (std.mem.eql(u8, role, "tool")) continue;
        if (!std.mem.eql(u8, role, "assistant") or i + 1 == end) break;
        const key = try turnKey(arena, messages[i..end]) orelse break;
        if (latest) |l| {
            if (!std.mem.eql(u8, l, key)) break;
        } else latest = key;
        n += 1;
        end = i;
    }
    return n;
}

/// An assistant turn's tool calls (their functions) and the results after
/// it, as JSON text to compare; null when it called no tool.
fn turnKey(arena: std.mem.Allocator, turn: []const std.json.Value) !?[]const u8 {
    const calls = turn[0].object.get("tool_calls") orelse return null;
    if (calls != .array or calls.array.items.len == 0) return null;
    var w: std.Io.Writer.Allocating = .init(arena);
    for (calls.array.items) |call| {
        const f = if (call == .object) call.object.get("function") orelse .null else .null;
        try std.json.Stringify.value(f, .{}, &w.writer);
    }
    for (turn[1..]) |result| if (result == .object) {
        try std.json.Stringify.value(result.object.get("content") orelse .null, .{}, &w.writer);
    };
    return w.written();
}

/// Tells the model, after the last tool result, that it keeps making the
/// same call (and, from `repeat_answer_at`, that it has no tools now).
fn noteRepeat(arena: std.mem.Allocator, messages: []std.json.Value, repeats: usize) !void {
    var i = messages.len;
    const last = while (i > 0) {
        i -= 1;
        const role = roleOf(messages[i]) orelse continue;
        if (std.mem.eql(u8, role, "tool")) break &messages[i];
    } else return;
    const note = try std.fmt.allocPrint(arena, "\n\n[Note: you have made this same tool call with the same arguments {d} times in a row, and it returned the same result each time. {s}]", .{
        repeats,
        if (repeats >= repeat_answer_at) "Tools are off for this turn: answer the user now with what you have." else "Do not call it again: use the result above, or answer the user.",
    });
    const content = last.object.getPtr("content") orelse return;
    switch (content.*) {
        .string => |t| content.* = .{ .string = try std.mem.concat(arena, u8, &.{ t, note }) },
        .array => |*parts| {
            var part: std.json.ObjectMap = .empty;
            try part.put(arena, "type", .{ .string = "text" });
            try part.put(arena, "text", .{ .string = note });
            try parts.append(.{ .object = part });
        },
        else => content.* = .{ .string = note },
    }
}

fn toolChoice(obj: std.json.ObjectMap) ToolChoice {
    const tc = obj.get("tool_choice") orelse return .auto;
    return switch (tc) {
        .string => |c| if (std.mem.eql(u8, c, "none")) .none else if (std.mem.eql(u8, c, "required")) .required else .auto,
        .object => |o| blk: {
            const f = o.get("function") orelse break :blk .auto;
            if (f != .object) break :blk .auto;
            const n = f.object.get("name") orelse break :blk .auto;
            break :blk if (n == .string) .{ .function = n.string } else .auto;
        },
        else => .auto,
    };
}

const Folded = struct { system: []const u8, user: []const u8, image: ?[]const u8 };

/// The messages as the runner's one system and one user turn: system and
/// developer messages joined; one user turn after them as it is, else the
/// conversation as a transcript (tool results carry the tool's name). The
/// last user turn's image. Null (with `err` set) on an image it can't take.
fn foldMessages(arena: std.mem.Allocator, messages: []const std.json.Value, err: *[]const u8) !?Folded {
    var system: std.ArrayList(u8) = .empty;
    var image: ?[]const u8 = null;
    var last_user_index: ?usize = null;
    var n_turns: usize = 0;
    for (messages, 0..) |m, i| if (roleOf(m)) |r| {
        if (std.mem.eql(u8, r, "user")) last_user_index = i;
        if (!std.mem.eql(u8, r, "system") and !std.mem.eql(u8, r, "developer")) n_turns += 1;
    };
    // One user turn after the system prompt: no transcript, tools or not (a
    // "Continue as the assistant" wrapper makes models narrate instead of
    // calling the tool).
    const simple = n_turns <= 1;

    var transcript: std.ArrayList(u8) = .empty;
    var last_user: []const u8 = "";
    var call_names: std.StringHashMapUnmanaged([]const u8) = .empty;
    for (messages, 0..) |m, i| {
        const role = roleOf(m) orelse continue;
        const text = try messageText(arena, m, if (i == last_user_index) &image else null, err) orelse return null;
        if (std.mem.eql(u8, role, "system") or std.mem.eql(u8, role, "developer")) {
            if (system.items.len > 0) try system.appendSlice(arena, "\n\n");
            try system.appendSlice(arena, text);
        } else if (std.mem.eql(u8, role, "assistant")) {
            if (text.len > 0) try transcript.print(arena, "Assistant: {s}\n\n", .{text});
            if (m.object.get("tool_calls")) |tcs| if (tcs == .array) try foldToolCalls(arena, &transcript, &call_names, tcs.array.items);
        } else if (std.mem.eql(u8, role, "tool")) {
            const id = if (m.object.get("tool_call_id")) |t| (if (t == .string) t.string else "") else "";
            const name = call_names.get(id) orelse (if (m.object.get("name")) |n| (if (n == .string) n.string else "tool") else "tool");
            try transcript.print(arena, "Tool result ({s}):\n{s}\n\n", .{ name, text });
        } else {
            if (i == last_user_index) last_user = text;
            try transcript.print(arena, "User: {s}\n\n", .{text});
        }
    }
    const user = if (simple) last_user else try std.fmt.allocPrint(arena, "The conversation so far:\n\n{s}Continue as the assistant.", .{transcript.items});
    return .{ .system = system.items, .user = user, .image = image };
}

/// An assistant turn's tool calls into the transcript; their ids' names
/// into `call_names` (the tool results name the tool).
fn foldToolCalls(arena: std.mem.Allocator, transcript: *std.ArrayList(u8), call_names: *std.StringHashMapUnmanaged([]const u8), tcs: []const std.json.Value) !void {
    var calls: std.ArrayList(u8) = .empty;
    for (tcs) |tc| {
        if (tc != .object) continue;
        const f = tc.object.get("function") orelse continue;
        if (f != .object) continue;
        const name = if (f.object.get("name")) |n| (if (n == .string) n.string else "") else "";
        const args: []const u8 = if (f.object.get("arguments")) |a| (if (a == .string) a.string else try std.json.Stringify.valueAlloc(arena, a, .{})) else "{}";
        if (tc.object.get("id")) |id| if (id == .string) try call_names.put(arena, id.string, name);
        try calls.print(arena, "{s}{{\"name\":{f},\"arguments\":{s}}}", .{ if (calls.items.len > 0) "," else "", std.json.fmt(name, .{}), args });
    }
    try transcript.print(arena, "Assistant called tools: [{s}]\n\n", .{calls.items});
}

/// How other apps' agents sample unless the request says otherwise: Qwen's
/// recommendation for thinking and tool use, with a mild presence penalty.
/// Near-greedy sampling (GhostPen's own 0.2) makes a thinking model repeat
/// itself, and an agent then calls the same tool over and over.
const agent_temperature = 0.6;
const agent_sampling: local_llm.Sampling = .{ .top_p = 0.95, .top_k = 20, .min_p = 0, .presence_penalty = 1.0 };

/// The request's generation options: max_tokens, sampling (OpenAI's and
/// llama-server's names), thinking, response_format (overridden by tools),
/// keep_alive, context.
fn applyOptions(arena: std.mem.Allocator, obj: std.json.ObjectMap, chat: *local_llm.Chat) !void {
    if (obj.get("max_tokens") orelse obj.get("max_completion_tokens")) |v| switch (v) {
        .integer => |n| chat.max_tokens = @intCast(std.math.clamp(n, 1, 32768)),
        else => {},
    };
    if (number(obj, "temperature", 0, 2)) |f| chat.temperature = f;
    const sp = &chat.sampling;
    if (number(obj, "top_p", 0, 1)) |f| sp.top_p = @floatCast(f);
    if (number(obj, "top_k", 0, 1000)) |f| sp.top_k = @intFromFloat(f);
    if (number(obj, "min_p", 0, 1)) |f| sp.min_p = @floatCast(f);
    if (number(obj, "presence_penalty", -2, 2)) |f| sp.presence_penalty = @floatCast(f);
    if (number(obj, "frequency_penalty", -2, 2)) |f| sp.frequency_penalty = @floatCast(f);
    if (number(obj, "repeat_penalty", 0, 2) orelse number(obj, "repetition_penalty", 0, 2)) |f| sp.repeat_penalty = @floatCast(f);
    // OpenAI's spelling (pi, Codex): "none" is off, any effort is on.
    if (obj.get("reasoning_effort")) |e| if (e == .string) {
        chat.think = !std.mem.eql(u8, e.string, "none");
    };
    if (obj.get("chat_template_kwargs")) |k| if (k == .object) if (k.object.get("enable_thinking")) |t| if (t == .bool) {
        chat.think = t.bool;
    };
    if (obj.get("think")) |t| if (t == .bool) {
        chat.think = t.bool; // Ollama's spelling
    };
    if (obj.get("response_format")) |rf| if (rf == .object) {
        const kind = if (rf.object.get("type")) |t| (if (t == .string) t.string else "") else "";
        if (std.mem.eql(u8, kind, "json_schema")) {
            const js = rf.object.get("json_schema") orelse .null;
            const schema = if (js == .object) (js.object.get("schema") orelse .null) else .null;
            if (schema != .null) chat.schema = try std.json.Stringify.valueAlloc(arena, schema, .{});
        } else if (std.mem.eql(u8, kind, "json_object")) {
            chat.schema = "{\"type\":\"object\"}";
        }
    };
    chat.keep_alive_ms = keepAliveMs(obj);
    chat.ctx = requestedCtx(obj);
}

/// A numeric field clamped to `lo`..`hi`; null when absent or not a finite number.
fn number(obj: std.json.ObjectMap, field: []const u8, lo: f64, hi: f64) ?f64 {
    const f: f64 = switch (obj.get(field) orelse return null) {
        .float => |f| f,
        .integer => |n| @floatFromInt(n),
        else => return null,
    };
    return if (std.math.isFinite(f)) std.math.clamp(f, lo, hi) else null;
}

const ToolChoice = union(enum) { auto, none, required, function: []const u8 };

/// A message's text (text parts joined); its first data-URL image into
/// `image` when given. Null (with `err` set) on an image it can't take.
fn messageText(arena: std.mem.Allocator, m: std.json.Value, image: ?*?[]const u8, err: *[]const u8) !?[]const u8 {
    const content = m.object.get("content") orelse return "";
    var text: std.ArrayList(u8) = .empty;
    switch (content) {
        .string => |t| try text.appendSlice(arena, t),
        .array => |parts| for (parts.items) |part| {
            const p = switch (part) {
                .object => |o| o,
                else => continue,
            };
            const kind = if (p.get("type")) |t| (if (t == .string) t.string else "") else "";
            if (std.mem.eql(u8, kind, "text")) {
                if (p.get("text")) |t| if (t == .string) {
                    if (text.items.len > 0) try text.append(arena, '\n');
                    try text.appendSlice(arena, t.string);
                };
            } else if (std.mem.eql(u8, kind, "image_url")) {
                const slot = image orelse continue; // earlier turns: text only
                if (slot.* != null) continue; // the runner takes one image
                slot.* = try imageFromPart(arena, p) orelse {
                    err.* = "only data: image URLs (base64) are supported";
                    return null;
                };
            }
        },
        else => {},
    }
    return text.items;
}

fn toolName(t: std.json.Value) ?[]const u8 {
    if (t != .object) return null;
    const f = t.object.get("function") orelse return null;
    if (f != .object) return null;
    const n = f.object.get("name") orelse return null;
    return if (n == .string) n.string else null;
}

fn toolField(t: std.json.Value, field: []const u8) ?std.json.Value {
    const f = t.object.get("function") orelse return null;
    return if (f == .object) f.object.get(field) else null;
}

/// The grammar's JSON Schema for a tool answer: tool calls (each with one of
/// the offered tools' names and arguments matching its parameters) or, when
/// the choice allows, a final text answer.
fn toolSchema(arena: std.mem.Allocator, tools: []const std.json.Value, choice: ToolChoice) ![]const u8 {
    var w: std.Io.Writer.Allocating = .init(arena);
    const o = &w.writer;
    try o.writeAll("{\"oneOf\":[{\"type\":\"object\",\"properties\":{\"tool_calls\":{\"type\":\"array\",\"minItems\":1,\"maxItems\":8,\"items\":{\"oneOf\":[");
    var n: usize = 0;
    for (tools) |t| {
        const name = toolName(t) orelse continue;
        if (choice == .function and !std.mem.eql(u8, choice.function, name)) continue;
        const params = toolField(t, "parameters") orelse std.json.Value{ .null = {} };
        try o.print("{s}{{\"type\":\"object\",\"properties\":{{\"name\":{{\"const\":{f}}},\"arguments\":", .{ if (n > 0) "," else "", std.json.fmt(name, .{}) });
        if (params == .object) try std.json.Stringify.value(params, .{}, o) else try o.writeAll("{\"type\":\"object\"}");
        try o.writeAll("},\"required\":[\"name\",\"arguments\"],\"additionalProperties\":false}");
        n += 1;
    }
    try o.writeAll("]}}},\"required\":[\"tool_calls\"],\"additionalProperties\":false}");
    if (choice == .auto) try o.writeAll(",{\"type\":\"object\",\"properties\":{\"answer\":{\"type\":\"string\"}},\"required\":[\"answer\"],\"additionalProperties\":false}");
    try o.writeAll("]}");
    return w.written();
}

/// The system prompt's part about the tools and the answer's shape.
fn toolGuide(arena: std.mem.Allocator, tools: []const std.json.Value, choice: ToolChoice) ![]const u8 {
    var w: std.Io.Writer.Allocating = .init(arena);
    const o = &w.writer;
    try o.writeAll("# Tools\n\nYou can call these tools:\n\n");
    for (tools) |t| {
        const name = toolName(t) orelse continue;
        if (choice == .function and !std.mem.eql(u8, choice.function, name)) continue;
        const desc = if (toolField(t, "description")) |d| (if (d == .string) d.string else "") else "";
        try o.print("- {s}: {s}\n  Parameters (JSON Schema): ", .{ name, desc });
        if (toolField(t, "parameters")) |p| try std.json.Stringify.value(p, .{}, o) else try o.writeAll("{}");
        try o.writeAll("\n");
    }
    try o.writeAll("\nAnswer with JSON only. To call tools: {\"tool_calls\":[{\"name\":\"<tool>\",\"arguments\":{...}}]} (their results come back in the next message).");
    if (choice == .auto) try o.writeAll(" When you have what you need, answer the user: {\"answer\":\"<your reply>\"}.");
    return w.written();
}

fn roleOf(m: std.json.Value) ?[]const u8 {
    if (m != .object) return null;
    const r = m.object.get("role") orelse return null;
    return if (r == .string) r.string else null;
}

/// The bytes of a `data:image/...;base64,...` URL part.
fn imageFromPart(arena: std.mem.Allocator, part: std.json.ObjectMap) !?[]const u8 {
    const iu = part.get("image_url") orelse return null;
    const url = switch (iu) {
        .string => |s| s,
        .object => |o| if (o.get("url")) |u| (if (u == .string) u.string else return null) else return null,
        else => return null,
    };
    if (!std.mem.startsWith(u8, url, "data:")) return null;
    const comma = std.mem.indexOfScalar(u8, url, ',') orelse return null;
    if (std.mem.indexOf(u8, url[0..comma], ";base64") == null) return null;
    const b64 = url[comma + 1 ..];
    const dec = std.base64.standard.Decoder;
    const size = dec.calcSizeForSlice(b64) catch return null;
    const bytes = try arena.alloc(u8, size);
    dec.decode(bytes, b64) catch return null;
    return bytes;
}

fn completionId(buf: []u8) []const u8 {
    var r: [8]u8 = undefined;
    main.io.random(&r);
    return std.fmt.bufPrint(buf, "chatcmpl-{x}", .{std.mem.readInt(u64, &r, .little)}) catch "chatcmpl";
}

/// Tokens per second (the runner's wall-clock); 0 without a measurement.
fn perSecond(tokens: u64, ms: u64) f64 {
    if (tokens == 0 or ms == 0) return 0;
    return @as(f64, @floatFromInt(tokens)) * 1000.0 / @as(f64, @floatFromInt(ms));
}

/// OpenAI's `usage` and llama-server's `timings` from a finished request.
fn usageFields(res: local_llm.Result) struct {
    usage: struct { prompt_tokens: u64, completion_tokens: u64, total_tokens: u64 },
    timings: struct {
        prompt_n: u64,
        prompt_ms: u64,
        prompt_per_second: f64,
        predicted_n: u64,
        predicted_ms: u64,
        predicted_per_second: f64,
    },
} {
    const u: metrics.Usage = .{
        .prompt_tokens = res.prompt_tokens,
        .gen_tokens = res.gen_tokens,
        .prompt_ms = res.prompt_ms,
        .gen_ms = res.gen_ms,
    };
    return .{
        .usage = .{
            .prompt_tokens = u.prompt_tokens,
            .completion_tokens = u.gen_tokens,
            .total_tokens = u.prompt_tokens + u.gen_tokens,
        },
        .timings = .{
            .prompt_n = u.prompt_tokens,
            .prompt_ms = u.prompt_ms,
            .prompt_per_second = perSecond(u.prompt_tokens, u.prompt_ms),
            .predicted_n = u.gen_tokens,
            .predicted_ms = u.gen_ms,
            .predicted_per_second = perSecond(u.gen_tokens, u.gen_ms),
        },
    };
}

/// A non-streaming answer as a Reply; a streaming one written to `request`
/// (null returned: already answered).
pub fn chatReply(io: std.Io, arena: std.mem.Allocator, request: *std.http.Server.Request, body: []const u8) !?Reply {
    var err: []const u8 = "";
    const req = (try parseChat(arena, body, &err)) orelse return errorReply(.bad_request, err, arena);
    var why: []const u8 = "";
    const cfg = config(arena, req.model, &why) orelse return errorReply(.service_unavailable, why, arena);
    if (req.chat.image != null and cfg.mmproj == null) return errorReply(.bad_request, "the built-in model can't read images (no vision projector)", arena);
    const model = req.model orelse modelName(cfg);
    var id_buf: [32]u8 = undefined;
    const id = completionId(&id_buf);
    const created = std.Io.Clock.real.now(io).toSeconds();

    if (req.tools and req.chat.request.len == 0) return toolReply(io, arena, request, req, cfg, model, id, created);
    if (!req.stream) return try completeChat(io, arena, req, cfg, model, id, created);
    try streamChat(io, arena, request, req, cfg, model, id, created);
    return null;
}

/// The model's reasoning, kept apart from the answer (`res.text`) as
/// `chatChannels` delivers it; null when it didn't reason.
const Reasoning = struct {
    arena: std.mem.Allocator,
    text: std.ArrayList(u8) = .empty,
    fn collect(self: *Reasoning, d: ai_stream.Delta) void {
        if (d.channel == .thinking) self.text.appendSlice(self.arena, d.text) catch {};
    }
    fn content(self: *const Reasoning) ?[]const u8 {
        return if (self.text.items.len > 0) self.text.items else null;
    }
};

/// The whole answer as one reply.
fn completeChat(io: std.Io, arena: std.mem.Allocator, req: ChatRequest, cfg: local_llm.Config, model: []const u8, id: []const u8, created: i64) !Reply {
    var diag: []const u8 = "";
    var reasoning: Reasoning = .{ .arena = arena };
    const res = local_llm.chatChannels(io, gpa, arena, cfg, req.chat, &reasoning, Reasoning.collect, &diag) catch |e| switch (e) {
        error.OutOfMemory => return e,
        error.LocalFailed => return errorReply(.internal_server_error, diag, arena),
    };
    const counted = usageFields(res);
    const msg: ToolMessage = if (res.message) |m| try templateMessage(arena, m, id) else .{ .content = res.text, .reasoning_content = reasoning.content() };
    return .{ .body = try std.json.Stringify.valueAlloc(arena, .{
        .id = id,
        .object = "chat.completion",
        .created = created,
        .model = model,
        .choices = .{.{
            .index = 0,
            .message = msg,
            .finish_reason = finishReason(msg, res),
        }},
        .usage = counted.usage,
        .timings = counted.timings,
    }, .{ .emit_null_optional_fields = false }) };
}

/// Server-sent events, one per piece of text as the runner writes it,
/// written to `request`.
fn streamChat(io: std.Io, arena: std.mem.Allocator, request: *std.http.Server.Request, req: ChatRequest, cfg: local_llm.Config, model: []const u8, id: []const u8, created: i64) !void {
    var sse_buf: [16 * 1024]u8 = undefined;
    var bw = try request.respondStreaming(&sse_buf, .{ .respond_options = .{
        .keep_alive = false,
        .extra_headers = &.{
            .{ .name = "content-type", .value = "text/event-stream" },
            .{ .name = "cache-control", .value = "no-cache" },
        },
    } });
    const Sse = struct {
        io: std.Io,
        w: *std.http.BodyWriter,
        arena: std.mem.Allocator,
        id: []const u8,
        model: []const u8,
        created: i64,
        failed: bool = false,
        fn event(self: *@This(), delta: anytype, finish: ?[]const u8) void {
            if (self.failed) return;
            const json = std.json.Stringify.valueAlloc(self.arena, .{
                .id = self.id,
                .object = "chat.completion.chunk",
                .created = self.created,
                .model = self.model,
                .choices = .{.{ .index = 0, .delta = delta, .finish_reason = finish }},
            }, .{}) catch return;
            self.w.writer.print("data: {s}\n\n", .{json}) catch return self.fail();
            self.w.flush() catch return self.fail();
        }
        /// The client is gone: stop generating for nobody.
        fn fail(self: *@This()) void {
            self.failed = true;
            local_llm.cancel(self.io);
        }
        fn chunk(self: *@This(), d: ai_stream.Delta) void {
            switch (d.channel) {
                .answer => self.event(.{ .content = d.text }, null),
                .thinking => self.event(.{ .reasoning_content = d.text }, null),
            }
        }
    };
    var sse: Sse = .{ .io = io, .w = &bw, .arena = arena, .id = id, .model = model, .created = created };
    sse.event(.{ .role = "assistant", .content = "" }, null);
    if (sse.failed) return; // gone already: don't generate at all
    var diag: []const u8 = "";
    const res = local_llm.chatChannels(io, gpa, arena, cfg, req.chat, &sse, Sse.chunk, &diag) catch |e| switch (e) {
        error.OutOfMemory => return e,
        error.LocalFailed => {
            sse.event(.{ .content = "" }, "error");
            bw.writer.print("data: {{\"error\":{{\"message\":{f}}}}}\n\n", .{std.json.fmt(diag, .{})}) catch {};
            bw.writer.writeAll("data: [DONE]\n\n") catch {};
            bw.end() catch {};
            return;
        },
    };
    // Tool calls go out whole, after the text (they can't be shown before
    // they're complete).
    const msg: ToolMessage = if (res.message) |m| try templateMessage(arena, m, id) else .{};
    if (msg.tool_calls) |calls| sse.event(.{ .tool_calls = try indexedCalls(arena, calls) }, null);
    // The last chunk's delta is an empty object (`.{}` would be `[]`).
    const Empty = struct {};
    sse.event(Empty{}, finishReason(msg, res));
    if (req.include_usage) {
        // OpenAI's shape: a chunk with no choices, only the usage.
        const chunk = std.json.Stringify.valueAlloc(arena, .{
            .id = id,
            .object = "chat.completion.chunk",
            .created = created,
            .model = model,
            .choices = @as([]const Empty, &.{}),
            .usage = usageFields(res).usage,
        }, .{}) catch "";
        if (chunk.len > 0) bw.writer.print("data: {s}\n\n", .{chunk}) catch {};
    }
    bw.writer.writeAll("data: [DONE]\n\n") catch {};
    bw.end() catch {};
}

/// The OpenAI message for a tool-mode answer: `tool_calls` (arguments as
/// JSON text, ids made up) or content. Text that isn't the expected JSON
/// (cut off by max_tokens) is passed on as content.
const ToolMessage = struct {
    role: []const u8 = "assistant",
    content: ?[]const u8 = null,
    reasoning_content: ?[]const u8 = null,
    tool_calls: ?[]const ToolCall = null,
    const ToolCall = struct {
        id: []const u8,
        type: []const u8 = "function",
        function: struct { name: []const u8, arguments: []const u8 },
    };
};

/// A `Chat.request`'s answer (`Result.message`, parsed by the model's chat
/// template) as the OpenAI message, its tool calls with ids. A message it
/// can't read is passed on as content.
fn templateMessage(arena: std.mem.Allocator, message: []const u8, id: []const u8) !ToolMessage {
    const Parsed = struct {
        content: []const u8 = "",
        reasoning_content: []const u8 = "",
        tool_calls: []const struct { name: []const u8, arguments: []const u8 } = &.{},
    };
    const p = std.json.parseFromSliceLeaky(Parsed, arena, message, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch
        return .{ .content = message };
    var calls: ?[]ToolMessage.ToolCall = null;
    if (p.tool_calls.len > 0) {
        const out = try arena.alloc(ToolMessage.ToolCall, p.tool_calls.len);
        for (p.tool_calls, out, 0..) |call, *o, i| o.* = .{
            .id = try std.fmt.allocPrint(arena, "call_{s}_{d}", .{ id["chatcmpl-".len..], i }),
            .function = .{ .name = call.name, .arguments = call.arguments },
        };
        for (out) |c| log.info("tool call: {s}", .{c.function.name});
        calls = out;
    }
    return .{
        .content = if (p.content.len > 0 or calls == null) p.content else null,
        .reasoning_content = if (p.reasoning_content.len > 0) p.reasoning_content else null,
        .tool_calls = calls,
    };
}

fn finishReason(msg: ToolMessage, res: local_llm.Result) []const u8 {
    return if (msg.tool_calls != null) "tool_calls" else if (res.truncated) "length" else "stop";
}

/// Streamed tool calls carry an index each.
const IndexedCall = struct { index: usize, id: []const u8, type: []const u8 = "function", function: struct { name: []const u8, arguments: []const u8 } };

fn indexedCalls(arena: std.mem.Allocator, calls: []const ToolMessage.ToolCall) ![]IndexedCall {
    const out = try arena.alloc(IndexedCall, calls.len);
    for (calls, out, 0..) |cl, *o, i| o.* = .{ .index = i, .id = cl.id, .function = .{ .name = cl.function.name, .arguments = cl.function.arguments } };
    return out;
}

fn toolMessage(arena: std.mem.Allocator, text: []const u8, id: []const u8) !ToolMessage {
    const parsed = std.json.parseFromSliceLeaky(ToolAnswer, arena, text, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch
        return .{ .content = text };
    if (parsed.tool_calls) |calls| if (calls.len > 0) {
        const out = try arena.alloc(ToolMessage.ToolCall, calls.len);
        for (calls, out, 0..) |call, *o, i| o.* = .{
            .id = try std.fmt.allocPrint(arena, "call_{s}_{d}", .{ id["chatcmpl-".len..], i }),
            .function = .{ .name = call.name, .arguments = try std.json.Stringify.valueAlloc(arena, call.arguments, .{}) },
        };
        return .{ .tool_calls = out };
    };
    return .{ .content = parsed.answer orelse "" };
}

/// Tools: the whole answer, then one reply (a stream gets it as one chunk:
/// tool calls can't be shown before they're complete).
fn toolReply(io: std.Io, arena: std.mem.Allocator, request: *std.http.Server.Request, req: ChatRequest, cfg: local_llm.Config, model: []const u8, id: []const u8, created: i64) !?Reply {
    var diag: []const u8 = "";
    var reasoning: Reasoning = .{ .arena = arena };
    const res = local_llm.chatChannels(io, gpa, arena, cfg, req.chat, &reasoning, Reasoning.collect, &diag) catch |e| switch (e) {
        error.OutOfMemory => return e,
        error.LocalFailed => return errorReply(.internal_server_error, diag, arena),
    };
    var msg = try toolMessage(arena, res.text, id);
    msg.reasoning_content = reasoning.content();
    const finish: []const u8 = if (msg.tool_calls != null) "tool_calls" else if (res.truncated) "length" else "stop";
    if (msg.tool_calls) |calls| {
        for (calls) |c| log.info("tool call: {s}", .{c.function.name});
    } else log.info("tool turn answered without a call", .{});
    const counted = usageFields(res);
    if (!req.stream) return .{ .body = try std.json.Stringify.valueAlloc(arena, .{
        .id = id,
        .object = "chat.completion",
        .created = created,
        .model = model,
        .choices = .{.{ .index = 0, .message = msg, .finish_reason = finish }},
        .usage = counted.usage,
        .timings = counted.timings,
    }, .{ .emit_null_optional_fields = false }) };

    var sse_buf: [16 * 1024]u8 = undefined;
    var bw = try request.respondStreaming(&sse_buf, .{ .respond_options = .{
        .keep_alive = false,
        .extra_headers = &.{
            .{ .name = "content-type", .value = "text/event-stream" },
            .{ .name = "cache-control", .value = "no-cache" },
        },
    } });
    const indexed: []const IndexedCall = if (msg.tool_calls) |calls| try indexedCalls(arena, calls) else &.{};
    const Delta = struct { role: []const u8 = "assistant", content: ?[]const u8 = null, reasoning_content: ?[]const u8 = null, tool_calls: ?[]const IndexedCall = null };
    const chunk = try std.json.Stringify.valueAlloc(arena, .{
        .id = id,
        .object = "chat.completion.chunk",
        .created = created,
        .model = model,
        .choices = .{.{ .index = 0, .delta = Delta{ .content = msg.content, .reasoning_content = msg.reasoning_content, .tool_calls = if (msg.tool_calls != null) indexed else null }, .finish_reason = finish }},
    }, .{ .emit_null_optional_fields = false });
    bw.writer.print("data: {s}\n\ndata: [DONE]\n\n", .{chunk}) catch {};
    bw.end() catch {};
    return null;
}

// ---- discovery ------------------------------------------------------------------------

/// Where other apps look for a running model service (one per user, whatever
/// app writes it): Linux `$XDG_RUNTIME_DIR/ghost/models.json` (else
/// `~/.cache/ghost/`), macOS `~/Library/Application Support/Ghost/`,
/// Windows `%LOCALAPPDATA%\Ghost\`.
pub fn discoveryPath(arena: std.mem.Allocator, env: *const std.process.Environ.Map) ?[]const u8 {
    const dir: []const u8 = switch (builtin.os.tag) {
        .windows => std.fs.path.join(arena, &.{ env.get("LOCALAPPDATA") orelse return null, "Ghost" }) catch return null,
        .macos => std.fs.path.join(arena, &.{ env.get("HOME") orelse return null, "Library", "Application Support", "Ghost" }) catch return null,
        else => if (env.get("XDG_RUNTIME_DIR")) |r| (if (r.len > 0) std.fs.path.join(arena, &.{ r, "ghost" }) catch return null else return null) else std.fs.path.join(arena, &.{ env.get("HOME") orelse return null, ".cache", "ghost" }) catch return null,
    };
    return std.fs.path.join(arena, &.{ dir, "models.json" }) catch null;
}

/// Write the discovery file for the server at `url` (atomically). Never
/// fails: problems are logged.
pub fn writeDiscovery(io: std.Io, env: *const std.process.Environ.Map, url: []const u8, stt_model: []const u8) void {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const path = discoveryPath(arena, env) orelse return log.warn("no place for the discovery file", .{});
    var why: []const u8 = "";
    const cfg = config(arena, null, &why);
    const stt_ready = models.isDownloaded(io, gpa, stt_model);
    const body = std.json.Stringify.valueAlloc(arena, .{
        .version = 1,
        .app = "GhostPen",
        .pid = currentPid(),
        .url = url,
        .capabilities = .{
            .chat = cfg != null,
            .vision = if (cfg) |c| c.mmproj != null else false,
            .embeddings = if (cfg) |c| c.embed_model != null else false,
            .stt = stt_ready,
        },
        .models = .{
            .chat = if (cfg) |c| modelName(c) else "",
            .embeddings = if (cfg) |c| (embedName(c) orelse "") else "",
            .stt = stt_model,
        },
        .updated = std.Io.Clock.real.now(io).toSeconds(),
    }, .{ .whitespace = .indent_2 }) catch return;
    const dir_path = std.fs.path.dirname(path) orelse return;
    std.Io.Dir.cwd().createDirPath(io, dir_path) catch |err| return log.warn("discovery dir {s}: {s}", .{ dir_path, @errorName(err) });
    // A temporary file renamed over it: a reader never sees half a file. Its
    // name is this process's, should another app write at the same time.
    var dir = std.Io.Dir.cwd().openDir(io, dir_path, .{}) catch |err| return log.warn("discovery dir {s}: {s}", .{ dir_path, @errorName(err) });
    defer dir.close(io);
    const tmp = std.fmt.allocPrint(arena, "{s}.{d}.tmp", .{ std.fs.path.basename(path), currentPid() }) catch return;
    dir.writeFile(io, .{ .sub_path = tmp, .data = body }) catch |err| return log.warn("discovery file {s}: {s}", .{ path, @errorName(err) });
    dir.rename(tmp, dir, std.fs.path.basename(path), io) catch |err| {
        dir.deleteFile(io, tmp) catch {};
        return log.warn("discovery file {s}: {s}", .{ path, @errorName(err) });
    };
    log.info("model service announced in {s}", .{path});
}

fn currentPid() i64 {
    return if (builtin.os.tag == .windows) std.os.windows.GetCurrentProcessId() else std.c.getpid();
}

/// Remove the discovery file if it's ours (at exit).
pub fn removeDiscovery(io: std.Io, env: *const std.process.Environ.Map) void {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const path = discoveryPath(arena, env) orelse return;
    const data = std.Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(64 * 1024)) catch return;
    const Pid = struct { pid: i64 = 0 };
    const parsed = std.json.parseFromSliceLeaky(Pid, arena, data, .{ .ignore_unknown_fields = true }) catch return;
    if (parsed.pid == currentPid()) std.Io.Dir.cwd().deleteFile(io, path) catch {};
}

test "metrics: totals, rates, the last request" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const snap: metrics.Snapshot = .{
        .requests = 3,
        .failed_requests = 1,
        .prompt_tokens = 300,
        .prompt_ms = 600,
        .gen_tokens = 450,
        .gen_ms = 3000,
        .last = .{ .usage = .{ .prompt_tokens = 100, .prompt_ms = 200, .gen_tokens = 150, .gen_ms = 1000 }, .finished = 1759620000 },
    };
    const body = try metricsBody(arena_state.allocator(), snap, null);
    const v = try std.json.parseFromSliceLeaky(std.json.Value, arena_state.allocator(), body, .{});
    const o = v.object;
    // A whole-number rate serializes as an integer ("500", not "5e2"): read
    // either number form.
    const asNum = struct {
        fn f(x: std.json.Value) f64 {
            return switch (x) {
                .integer => |n| @floatFromInt(n),
                .float => |fl| fl,
                else => unreachable,
            };
        }
    }.f;
    try std.testing.expectEqual(@as(i64, 3), o.get("requests").?.integer);
    try std.testing.expectEqual(@as(i64, 1), o.get("failed_requests").?.integer);
    try std.testing.expectEqual(@as(f64, 500), asNum(o.get("prompt_tokens_second").?));
    try std.testing.expectEqual(@as(f64, 150), asNum(o.get("gen_tokens_second").?));
    try std.testing.expect(!o.get("loaded").?.bool); // the runner isn't up in a test
    const last = o.get("last").?.object;
    try std.testing.expectEqual(@as(i64, 1759620000), last.get("finished").?.integer);
    try std.testing.expectEqual(@as(f64, 150), asNum(last.get("gen_tokens_second").?));
    try std.testing.expect(o.get("in_flight") == null); // nothing running: omitted
}

test parseDuration {
    try std.testing.expectEqual(@as(?u64, 30_000), parseDuration("30s"));
    try std.testing.expectEqual(@as(?u64, 300_000), parseDuration("5m"));
    try std.testing.expectEqual(@as(?u64, 250), parseDuration("250ms"));
    try std.testing.expectEqual(@as(?u64, 0), parseDuration("0"));
    try std.testing.expectEqual(@as(?u64, null), parseDuration("-1"));
    try std.testing.expectEqual(@as(?u64, null), parseDuration("soon"));
    // Out of range or not a number: clamped to a day, or the default.
    try std.testing.expectEqual(@as(?u64, max_keep_alive_ms), parseDuration("1e300h"));
    try std.testing.expectEqual(@as(?u64, max_keep_alive_ms), parseDuration("48h"));
    try std.testing.expectEqual(@as(?u64, null), parseDuration("nan"));
    try std.testing.expectEqual(@as(?u64, null), parseDuration("infs"));
    try std.testing.expectEqual(@as(?u64, null), parseDuration("inf"));
}

test keepAliveMs {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const cases = [_]struct { json: []const u8, want: ?u64 }{
        .{ .json = "{\"keep_alive\":30}", .want = 30_000 },
        .{ .json = "{\"keep_alive\":0}", .want = 0 },
        .{ .json = "{\"keep_alive\":-1}", .want = null },
        .{ .json = "{\"keep_alive\":9223372036854775807}", .want = max_keep_alive_ms },
        .{ .json = "{\"keep_alive\":1.5}", .want = 1500 },
        .{ .json = "{\"keep_alive\":1e300}", .want = max_keep_alive_ms },
        .{ .json = "{\"keep_alive\":-0.5}", .want = null },
        .{ .json = "{\"keep_alive\":\"5m\"}", .want = 300_000 },
        .{ .json = "{\"keep_alive\":true}", .want = null },
        .{ .json = "{}", .want = null },
    };
    for (cases) |case| {
        const v = try std.json.parseFromSliceLeaky(std.json.Value, arena, case.json, .{});
        try std.testing.expectEqual(case.want, keepAliveMs(v.object));
    }
}

test "chat request keeps the selected model" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    var err: []const u8 = "";
    const req = (try parseChat(arena_state.allocator(), "{\"model\":\"qwen3.5-4b\",\"messages\":[{\"role\":\"user\",\"content\":\"hello\"}]}", &err)).?;
    try std.testing.expectEqualStrings("qwen3.5-4b", req.model.?);
}

test "tools: schema, guide, transcript and the answer as tool_calls" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var err: []const u8 = "";
    const req = (try parseChat(arena,
        \\{"tools":[{"type":"function","function":{"name":"search_moments","description":"Search the footage",
        \\  "parameters":{"type":"object","properties":{"query":{"type":"string"}},"required":["query"]}}}],
        \\ "messages":[{"role":"system","content":"You write scripts."},
        \\  {"role":"user","content":"Find a dog"},
        \\  {"role":"assistant","content":null,"tool_calls":[{"id":"c1","type":"function","function":{"name":"search_moments","arguments":"{\"query\":\"dog\"}"}}]},
        \\  {"role":"tool","tool_call_id":"c1","content":"2 moments found"}]}
    , &err)).?;
    try std.testing.expect(req.tools);
    // No image: the model's own template takes the request as it is.
    try std.testing.expect(std.mem.indexOf(u8, req.chat.request, "\"search_moments\"") != null);
    try std.testing.expectEqualStrings("", req.chat.schema);
    try std.testing.expectEqualStrings("You write scripts.", req.chat.system);
    try std.testing.expect(std.mem.indexOf(u8, req.chat.user, "User: Find a dog") != null);
    try std.testing.expect(std.mem.indexOf(u8, req.chat.user, "Assistant called tools: [{\"name\":\"search_moments\",\"arguments\":{\"query\":\"dog\"}}]") != null);
    try std.testing.expect(std.mem.indexOf(u8, req.chat.user, "Tool result (search_moments):\n2 moments found") != null);
    // The image path's guide and grammar (the schema converts).
    const tools = (try std.json.parseFromSliceLeaky(std.json.Value, arena, req.chat.request, .{})).object.get("tools").?.array.items;
    try std.testing.expect(std.mem.indexOf(u8, try toolGuide(arena, tools, .auto), "search_moments: Search the footage") != null);
    const g = try oriel.llama.jsonSchemaToGrammar(arena, try toolSchema(arena, tools, .auto), null);
    try std.testing.expect(std.mem.indexOf(u8, g, "search_moments") != null);

    const calls = try toolMessage(arena, "{\"tool_calls\":[{\"name\":\"search_moments\",\"arguments\":{\"query\":\"cat\"}}]}", "chatcmpl-abc");
    try std.testing.expectEqualStrings("search_moments", calls.tool_calls.?[0].function.name);
    try std.testing.expectEqualStrings("{\"query\":\"cat\"}", calls.tool_calls.?[0].function.arguments);
    try std.testing.expectEqualStrings("call_abc_0", calls.tool_calls.?[0].id);
    const answer = try toolMessage(arena, "{\"answer\":\"Here it is.\"}", "chatcmpl-abc");
    try std.testing.expectEqualStrings("Here it is.", answer.content.?);
    try std.testing.expect(answer.tool_calls == null);
}

test "parseChat: thinking on unless the request turns it off; one turn with tools isn't wrapped" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var err: []const u8 = "";
    const msgs = "\"messages\":[{\"role\":\"developer\",\"content\":\"Be brief.\"},{\"role\":\"user\",\"content\":\"Read a.md\"}]";
    const tools = "\"tools\":[{\"type\":\"function\",\"function\":{\"name\":\"read\",\"parameters\":{\"type\":\"object\"}}}]";

    const plain = (try parseChat(arena, "{" ++ msgs ++ "}", &err)).?;
    try std.testing.expect(plain.chat.think);
    const high = (try parseChat(arena, "{\"reasoning_effort\":\"high\"," ++ msgs ++ "}", &err)).?;
    try std.testing.expect(high.chat.think);
    const none = (try parseChat(arena, "{\"reasoning_effort\":\"none\"," ++ msgs ++ "}", &err)).?;
    try std.testing.expect(!none.chat.think);
    const ollama = (try parseChat(arena, "{\"think\":false," ++ msgs ++ "}", &err)).?;
    try std.testing.expect(!ollama.chat.think);
    // An explicit switch wins over the effort.
    const kwarg = (try parseChat(arena, "{\"reasoning_effort\":\"high\",\"chat_template_kwargs\":{\"enable_thinking\":false}," ++ msgs ++ "}", &err)).?;
    try std.testing.expect(!kwarg.chat.think);

    const tooled = (try parseChat(arena, "{" ++ tools ++ "," ++ msgs ++ "}", &err)).?;
    try std.testing.expect(tooled.tools);
    try std.testing.expectEqualStrings("Read a.md", tooled.chat.user);
    try std.testing.expect(tooled.chat.request.len > 0);

    // An image: the vision path (one system and one user turn), tools in the guide.
    const pic = (try parseChat(arena, "{" ++ tools ++ ",\"messages\":[{\"role\":\"user\",\"content\":[{\"type\":\"text\",\"text\":\"What is it?\"},{\"type\":\"image_url\",\"image_url\":{\"url\":\"data:image/png;base64,aGVsbG8=\"}}]}]}", &err)).?;
    try std.testing.expectEqualStrings("", pic.chat.request);
    try std.testing.expect(std.mem.indexOf(u8, pic.chat.system, "# Tools") != null);
}

test "parseChat: system, history folded, image, thinking and schema" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var err: []const u8 = "";
    const req = (try parseChat(arena,
        \\{"model":"x","stream":true,"max_tokens":300,"temperature":0,
        \\ "chat_template_kwargs":{"enable_thinking":false},
        \\ "response_format":{"type":"json_schema","json_schema":{"name":"f","schema":{"type":"object"}}},
        \\ "messages":[{"role":"system","content":"Be brief."},
        \\  {"role":"user","content":"Hi"},{"role":"assistant","content":"Hello!"},
        \\  {"role":"user","content":[{"type":"text","text":"What is this?"},
        \\   {"type":"image_url","image_url":{"url":"data:image/png;base64,aGVsbG8="}}]}]}
    , &err)).?;
    try std.testing.expect(req.stream);
    try std.testing.expectEqualStrings("Be brief.", req.chat.system);
    try std.testing.expect(std.mem.indexOf(u8, req.chat.user, "User: Hi") != null);
    try std.testing.expect(std.mem.indexOf(u8, req.chat.user, "Assistant: Hello!") != null);
    try std.testing.expect(std.mem.indexOf(u8, req.chat.user, "User: What is this?\n\nContinue as the assistant.") != null);
    try std.testing.expectEqualStrings("hello", req.chat.image.?);
    try std.testing.expect(!req.chat.think);
    try std.testing.expectEqual(@as(u32, 300), req.chat.max_tokens);
    try std.testing.expectEqualStrings("{\"type\":\"object\"}", req.chat.schema);
    try std.testing.expect(req.chat.ctx == null);

    const big = (try parseChat(arena, "{\"options\":{\"num_ctx\":65536},\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}]}", &err)).?;
    try std.testing.expectEqual(@as(?u32, 65536), big.chat.ctx);

    try std.testing.expect((try parseChat(arena, "{\"messages\":[{\"role\":\"user\",\"content\":[{\"type\":\"image_url\",\"image_url\":{\"url\":\"https://x/y.png\"}}]}]}", &err)) == null);
}

test "parseChat: agents sample as Qwen recommends unless the request says otherwise" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var err: []const u8 = "";
    const plain = (try parseChat(arena, "{\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}]}", &err)).?;
    try std.testing.expectEqual(@as(f64, 0.6), plain.chat.temperature);
    try std.testing.expectEqual(@as(i32, 20), plain.chat.sampling.top_k);
    try std.testing.expectEqual(@as(f32, 0), plain.chat.sampling.min_p);
    try std.testing.expectEqual(@as(f32, 1.0), plain.chat.sampling.presence_penalty);

    const own = (try parseChat(arena,
        \\{"temperature":0.1,"top_p":0.8,"top_k":5000,"min_p":0.1,"presence_penalty":0,
        \\ "frequency_penalty":"high","repeat_penalty":1.1,"messages":[{"role":"user","content":"hi"}]}
    , &err)).?;
    try std.testing.expectEqual(@as(f64, 0.1), own.chat.temperature);
    try std.testing.expectEqual(@as(f32, 0.8), own.chat.sampling.top_p);
    try std.testing.expectEqual(@as(i32, 1000), own.chat.sampling.top_k);
    try std.testing.expectEqual(@as(f32, 0.1), own.chat.sampling.min_p);
    try std.testing.expectEqual(@as(f32, 0), own.chat.sampling.presence_penalty);
    try std.testing.expectEqual(@as(f32, 0), own.chat.sampling.frequency_penalty);
    try std.testing.expectEqual(@as(f32, 1.1), own.chat.sampling.repeat_penalty);
}

test "parseChat: the same tool call with the same result again and again" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var err: []const u8 = "";
    const Body = struct {
        /// A request whose agent ran `bash ls` once per result, then (`asked`) a user turn.
        fn of(a: std.mem.Allocator, results: []const []const u8, asked: bool) ![]const u8 {
            var b: std.ArrayList(u8) = .empty;
            try b.appendSlice(a, "{\"tools\":[{\"type\":\"function\",\"function\":{\"name\":\"bash\",\"parameters\":{\"type\":\"object\"}}}],\"messages\":[{\"role\":\"user\",\"content\":\"list\"}");
            for (results, 0..) |r, i| {
                try b.print(a, ",{{\"role\":\"assistant\",\"content\":\"Let me look.\",\"tool_calls\":[{{\"id\":\"c{d}\",\"type\":\"function\",\"function\":{{\"name\":\"bash\",\"arguments\":\"{{\\\"cmd\\\":\\\"ls\\\"}}\"}}}}]}}", .{i});
                try b.print(a, ",{{\"role\":\"tool\",\"tool_call_id\":\"c{d}\",\"content\":\"{s}\"}}", .{ i, r });
            }
            if (asked) try b.appendSlice(a, ",{\"role\":\"user\",\"content\":\"again\"}");
            try b.appendSlice(a, "]}");
            return b.items;
        }
    };

    // Once: as it is.
    const once = try Body.of(arena, &.{"a.md"}, false);
    try std.testing.expectEqualStrings(once, (try parseChat(arena, once, &err)).?.chat.request);

    // Twice with the same result: a note on the last result, tools still on.
    const r2 = (try parseChat(arena, try Body.of(arena, &.{ "a.md", "a.md" }, false), &err)).?;
    try std.testing.expect(std.mem.indexOf(u8, r2.chat.request, "2 times in a row") != null);
    try std.testing.expect(std.mem.indexOf(u8, r2.chat.request, "\"tools\"") != null);
    try std.testing.expect(r2.tools);

    // A poll whose result changes isn't a repeat.
    const poll = try Body.of(arena, &.{ "pending", "done" }, false);
    try std.testing.expectEqualStrings(poll, (try parseChat(arena, poll, &err)).?.chat.request);

    // Three times: no tools, answer now.
    const r3 = (try parseChat(arena, try Body.of(arena, &.{ "a.md", "a.md", "a.md" }, false), &err)).?;
    try std.testing.expect(std.mem.indexOf(u8, r3.chat.request, "Tools are off for this turn") != null);
    try std.testing.expect(std.mem.indexOf(u8, r3.chat.request, "\"tools\"") == null);
    try std.testing.expect(!r3.tools);

    // A new user message starts over.
    const asked = try Body.of(arena, &.{ "a.md", "a.md" }, true);
    try std.testing.expectEqualStrings(asked, (try parseChat(arena, asked, &err)).?.chat.request);
}
