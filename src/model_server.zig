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
//!   `stream`, `chat_template_kwargs.enable_thinking`, and `response_format`
//!   `json_schema` (the answer matches the schema). The runner takes one
//!   system and one user turn: earlier turns are folded into the user text.
//!   The `model` field is ignored: the built-in model answers.
//! - `POST /v1/embeddings`: `input` (a string or strings), 768-dim vectors
//!   from embeddinggemma when it's on disk (GhostReel's or LM Studio's copy).
//! - `GET /props`: `modalities.vision` and `total_slots` (1); `GET /slots`:
//!   the context size.
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
const models = @import("models.zig");
const llm_models = @import("llm_models.zig");

const log = std.log.scoped(.model_server);
const gpa = std.heap.smp_allocator;

pub const Reply = struct { status: std.http.Status = .ok, body: []const u8, content_type: []const u8 = "application/json" };

fn errorReply(status: std.http.Status, message: []const u8, arena: std.mem.Allocator) Reply {
    const body = std.json.Stringify.valueAlloc(arena, .{ .@"error" = .{ .message = message, .type = "invalid_request_error" } }, .{}) catch "{}";
    return .{ .status = status, .body = body };
}

/// The built-in model's runner configuration, or null (logged) when it
/// isn't downloaded.
fn config(arena: std.mem.Allocator, why: *[]const u8) ?local_llm.Config {
    var diag: ai.Diag = .{};
    return main.builtinConfig(arena, &diag) catch {
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
    var why: []const u8 = "";
    const cfg = config(arena, &why) orelse return &.{};
    var list: std.ArrayList(ModelEntry) = .empty;
    try list.append(arena, .{ .id = modelName(cfg), .capabilities = .{ .chat = true, .vision = cfg.mmproj != null } });
    if (embedName(cfg)) |e| try list.append(arena, .{ .id = e, .capabilities = .{ .embeddings = true } });
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
    const cfg = config(arena, &why) orelse return errorReply(.service_unavailable, why, arena);
    return .{ .body = try std.json.Stringify.valueAlloc(arena, .{
        .model_path = cfg.model,
        .total_slots = 1,
        .modalities = .{ .vision = cfg.mmproj != null, .audio = false },
        .default_generation_settings = .{ .n_ctx = cfg.ctx },
    }, .{}) };
}

pub fn slotsReply(arena: std.mem.Allocator) !Reply {
    var why: []const u8 = "";
    const cfg = config(arena, &why) orelse return errorReply(.service_unavailable, why, arena);
    return .{ .body = try std.json.Stringify.valueAlloc(arena, .{.{ .id = 0, .n_ctx = cfg.ctx }}, .{}) };
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

/// A request's `keep_alive` in milliseconds (null: the runner's default).
fn keepAliveMs(obj: std.json.ObjectMap) ?u64 {
    const v = obj.get("keep_alive") orelse return null;
    return switch (v) {
        .integer => |n| if (n < 0) null else @as(u64, @intCast(n)) * 1000,
        .float => |f| if (f < 0) null else @intFromFloat(f * 1000),
        .string => |t| parseDuration(t),
        else => null,
    };
}

/// "30s", "5m", "1h", "250ms" or plain seconds; null when negative or unreadable.
fn parseDuration(text: []const u8) ?u64 {
    const t = std.mem.trim(u8, text, " ");
    if (t.len == 0 or t[0] == '-') return null;
    const units = [_]struct { suffix: []const u8, ms: u64 }{
        .{ .suffix = "ms", .ms = 1 },
        .{ .suffix = "s", .ms = 1000 },
        .{ .suffix = "m", .ms = 60_000 },
        .{ .suffix = "h", .ms = 3_600_000 },
    };
    for (units) |u| if (std.mem.endsWith(u8, t, u.suffix)) {
        const n = std.fmt.parseFloat(f64, t[0 .. t.len - u.suffix.len]) catch return null;
        return @intFromFloat(n * @as(f64, @floatFromInt(u.ms)));
    };
    const n = std.fmt.parseFloat(f64, t) catch return null;
    return @intFromFloat(n * 1000);
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

    var why: []const u8 = "";
    const cfg = config(arena, &why) orelse return errorReply(.service_unavailable, why, arena);
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
    stream: bool,
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
    const root = std.json.parseFromSliceLeaky(std.json.Value, arena, body, .{}) catch {
        err.* = "the body isn't JSON";
        return null;
    };
    const obj = switch (root) {
        .object => |o| o,
        else => {
            err.* = "expected a JSON object";
            return null;
        },
    };
    const messages = switch (obj.get("messages") orelse .null) {
        .array => |a| a.items,
        else => {
            err.* = "missing messages";
            return null;
        },
    };

    // Tools (unless tool_choice is "none").
    const tools: []const std.json.Value = if (obj.get("tools")) |t| (if (t == .array) t.array.items else &.{}) else &.{};
    var choice: ToolChoice = .auto;
    if (obj.get("tool_choice")) |tc| switch (tc) {
        .string => |c| choice = if (std.mem.eql(u8, c, "none")) .none else if (std.mem.eql(u8, c, "required")) .required else .auto,
        .object => |o| if (o.get("function")) |f| if (f == .object) if (f.object.get("name")) |n| if (n == .string) {
            choice = .{ .function = n.string };
        },
        else => {},
    };
    const use_tools = tools.len > 0 and choice != .none;

    var system: std.ArrayList(u8) = .empty;
    var image: ?[]const u8 = null;
    var last_user_index: ?usize = null;
    var simple = true; // one user turn after the system prompt: no transcript
    var n_turns: usize = 0;
    for (messages, 0..) |m, i| if (roleOf(m)) |r| {
        if (std.mem.eql(u8, r, "user")) last_user_index = i;
        if (!std.mem.eql(u8, r, "system") and !std.mem.eql(u8, r, "developer")) n_turns += 1;
    };
    simple = n_turns <= 1 and !use_tools;

    // Conversation turns in order; tool results carry the tool's name.
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
            if (m.object.get("tool_calls")) |tcs| if (tcs == .array) {
                var calls: std.ArrayList(u8) = .empty;
                for (tcs.array.items) |tc| {
                    if (tc != .object) continue;
                    const f = tc.object.get("function") orelse continue;
                    if (f != .object) continue;
                    const name = if (f.object.get("name")) |n| (if (n == .string) n.string else "") else "";
                    const args: []const u8 = if (f.object.get("arguments")) |a| (if (a == .string) a.string else try std.json.Stringify.valueAlloc(arena, a, .{})) else "{}";
                    if (tc.object.get("id")) |id| if (id == .string) try call_names.put(arena, id.string, name);
                    try calls.print(arena, "{s}{{\"name\":{f},\"arguments\":{s}}}", .{ if (calls.items.len > 0) "," else "", std.json.fmt(name, .{}), args });
                }
                try transcript.print(arena, "Assistant called tools: [{s}]\n\n", .{calls.items});
            };
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

    var chat: local_llm.Chat = .{ .system = system.items, .user = user, .image = image };
    if (obj.get("max_tokens") orelse obj.get("max_completion_tokens")) |v| switch (v) {
        .integer => |n| chat.max_tokens = @intCast(std.math.clamp(n, 1, 32768)),
        else => {},
    };
    if (obj.get("temperature")) |v| switch (v) {
        .float => |f| chat.temperature = f,
        .integer => |n| chat.temperature = @floatFromInt(n),
        else => {},
    };
    if (obj.get("chat_template_kwargs")) |k| if (k == .object) if (k.object.get("enable_thinking")) |t| if (t == .bool) {
        chat.think = t.bool;
    };
    if (obj.get("think")) |t| if (t == .bool) {
        chat.think = t.bool; // Ollama's spelling
    };
    if (use_tools) {
        chat.schema = try toolSchema(arena, tools, choice);
        const guide = try toolGuide(arena, tools, choice);
        chat.system = if (chat.system.len > 0) try std.fmt.allocPrint(arena, "{s}\n\n{s}", .{ chat.system, guide }) else guide;
    } else if (obj.get("response_format")) |rf| if (rf == .object) {
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
    const stream = if (obj.get("stream")) |s| s == .bool and s.bool else false;
    return .{ .chat = chat, .stream = stream, .tools = use_tools };
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

/// A non-streaming answer as a Reply; a streaming one written to `request`
/// (null returned: already answered).
pub fn chatReply(io: std.Io, arena: std.mem.Allocator, request: *std.http.Server.Request, body: []const u8) !?Reply {
    var err: []const u8 = "";
    const req = (try parseChat(arena, body, &err)) orelse return errorReply(.bad_request, err, arena);
    var why: []const u8 = "";
    const cfg = config(arena, &why) orelse return errorReply(.service_unavailable, why, arena);
    if (req.chat.image != null and cfg.mmproj == null) return errorReply(.bad_request, "the built-in model can't read images (no vision projector)", arena);
    const model = modelName(cfg);
    var id_buf: [32]u8 = undefined;
    const id = completionId(&id_buf);
    const created = std.Io.Clock.real.now(io).toSeconds();

    if (req.tools) return toolReply(io, arena, request, req, cfg, model, id, created);

    if (!req.stream) {
        var diag: []const u8 = "";
        const res = local_llm.chat(io, gpa, arena, cfg, req.chat, {}, struct {
            fn f(_: void, _: []const u8) void {}
        }.f, &diag) catch |e| switch (e) {
            error.OutOfMemory => return e,
            error.LocalFailed => return errorReply(.internal_server_error, diag, arena),
        };
        return .{ .body = try std.json.Stringify.valueAlloc(arena, .{
            .id = id,
            .object = "chat.completion",
            .created = created,
            .model = model,
            .choices = .{.{
                .index = 0,
                .message = .{ .role = "assistant", .content = res.text },
                .finish_reason = if (res.truncated) "length" else "stop",
            }},
            .usage = .{ .prompt_tokens = 0, .completion_tokens = 0, .total_tokens = 0 },
        }, .{}) };
    }

    // Server-sent events, one per piece of text as the runner writes it.
    var sse_buf: [16 * 1024]u8 = undefined;
    var bw = try request.respondStreaming(&sse_buf, .{ .respond_options = .{
        .keep_alive = false,
        .extra_headers = &.{
            .{ .name = "content-type", .value = "text/event-stream" },
            .{ .name = "cache-control", .value = "no-cache" },
        },
    } });
    const Sse = struct {
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
            self.w.writer.print("data: {s}\n\n", .{json}) catch {
                self.failed = true;
                return;
            };
            self.w.flush() catch {
                self.failed = true;
            };
        }
        fn chunk(self: *@This(), text: []const u8) void {
            self.event(.{ .content = text }, null);
        }
    };
    var sse: Sse = .{ .w = &bw, .arena = arena, .id = id, .model = model, .created = created };
    sse.event(.{ .role = "assistant", .content = "" }, null);
    var diag: []const u8 = "";
    const res = local_llm.chat(io, gpa, arena, cfg, req.chat, &sse, Sse.chunk, &diag) catch |e| switch (e) {
        error.OutOfMemory => return e,
        error.LocalFailed => {
            sse.event(.{ .content = "" }, "error");
            bw.writer.print("data: {{\"error\":{{\"message\":{f}}}}}\n\n", .{std.json.fmt(diag, .{})}) catch {};
            bw.writer.writeAll("data: [DONE]\n\n") catch {};
            bw.end() catch {};
            return null;
        },
    };
    // The last chunk's delta is an empty object (`.{}` would be `[]`).
    const Empty = struct {};
    sse.event(Empty{}, if (res.truncated) "length" else "stop");
    bw.writer.writeAll("data: [DONE]\n\n") catch {};
    bw.end() catch {};
    return null;
}

/// The OpenAI message for a tool-mode answer: `tool_calls` (arguments as
/// JSON text, ids made up) or content. Text that isn't the expected JSON
/// (cut off by max_tokens) is passed on as content.
const ToolMessage = struct {
    role: []const u8 = "assistant",
    content: ?[]const u8 = null,
    tool_calls: ?[]const ToolCall = null,
    const ToolCall = struct {
        id: []const u8,
        type: []const u8 = "function",
        function: struct { name: []const u8, arguments: []const u8 },
    };
};

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
    const res = local_llm.chat(io, gpa, arena, cfg, req.chat, {}, struct {
        fn f(_: void, _: []const u8) void {}
    }.f, &diag) catch |e| switch (e) {
        error.OutOfMemory => return e,
        error.LocalFailed => return errorReply(.internal_server_error, diag, arena),
    };
    const msg = try toolMessage(arena, res.text, id);
    const finish: []const u8 = if (msg.tool_calls != null) "tool_calls" else if (res.truncated) "length" else "stop";
    if (msg.tool_calls) |calls| {
        for (calls) |c| log.info("tool call: {s}", .{c.function.name});
    } else log.info("tool turn answered without a call", .{});
    if (!req.stream) return .{ .body = try std.json.Stringify.valueAlloc(arena, .{
        .id = id,
        .object = "chat.completion",
        .created = created,
        .model = model,
        .choices = .{.{ .index = 0, .message = msg, .finish_reason = finish }},
        .usage = .{ .prompt_tokens = 0, .completion_tokens = 0, .total_tokens = 0 },
    }, .{ .emit_null_optional_fields = false }) };

    var sse_buf: [16 * 1024]u8 = undefined;
    var bw = try request.respondStreaming(&sse_buf, .{ .respond_options = .{
        .keep_alive = false,
        .extra_headers = &.{
            .{ .name = "content-type", .value = "text/event-stream" },
            .{ .name = "cache-control", .value = "no-cache" },
        },
    } });
    // Streamed tool calls carry an index each.
    const Indexed = struct { index: usize, id: []const u8, type: []const u8 = "function", function: struct { name: []const u8, arguments: []const u8 } };
    var indexed: []Indexed = &.{};
    if (msg.tool_calls) |calls| {
        indexed = try arena.alloc(Indexed, calls.len);
        for (calls, indexed, 0..) |cl, *o, i| o.* = .{ .index = i, .id = cl.id, .function = .{ .name = cl.function.name, .arguments = cl.function.arguments } };
    }
    const Delta = struct { role: []const u8 = "assistant", content: ?[]const u8 = null, tool_calls: ?[]const Indexed = null };
    const chunk = try std.json.Stringify.valueAlloc(arena, .{
        .id = id,
        .object = "chat.completion.chunk",
        .created = created,
        .model = model,
        .choices = .{.{ .index = 0, .delta = Delta{ .content = msg.content, .tool_calls = if (msg.tool_calls != null) indexed else null }, .finish_reason = finish }},
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
    const cfg = config(arena, &why);
    const stt_ready = models.isDownloaded(io, gpa, stt_model);
    const body = std.json.Stringify.valueAlloc(arena, .{
        .version = 1,
        .app = "GhostPen",
        .pid = if (builtin.os.tag == .windows) @as(i64, std.os.windows.GetCurrentProcessId()) else @as(i64, std.c.getpid()),
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
    const dir = std.fs.path.dirname(path) orelse return;
    std.Io.Dir.cwd().createDirPath(io, dir) catch |err| return log.warn("discovery dir {s}: {s}", .{ dir, @errorName(err) });
    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = body }) catch |err| return log.warn("discovery file {s}: {s}", .{ path, @errorName(err) });
    log.info("model service announced in {s}", .{path});
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
    const me: i64 = if (builtin.os.tag == .windows) std.os.windows.GetCurrentProcessId() else std.c.getpid();
    if (parsed.pid == me) std.Io.Dir.cwd().deleteFile(io, path) catch {};
}

test parseDuration {
    try std.testing.expectEqual(@as(?u64, 30_000), parseDuration("30s"));
    try std.testing.expectEqual(@as(?u64, 300_000), parseDuration("5m"));
    try std.testing.expectEqual(@as(?u64, 250), parseDuration("250ms"));
    try std.testing.expectEqual(@as(?u64, 0), parseDuration("0"));
    try std.testing.expectEqual(@as(?u64, null), parseDuration("-1"));
    try std.testing.expectEqual(@as(?u64, null), parseDuration("soon"));
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
    try std.testing.expect(std.mem.indexOf(u8, req.chat.system, "search_moments: Search the footage") != null);
    try std.testing.expect(std.mem.indexOf(u8, req.chat.user, "User: Find a dog") != null);
    try std.testing.expect(std.mem.indexOf(u8, req.chat.user, "Assistant called tools: [{\"name\":\"search_moments\",\"arguments\":{\"query\":\"dog\"}}]") != null);
    try std.testing.expect(std.mem.indexOf(u8, req.chat.user, "Tool result (search_moments):\n2 moments found") != null);
    // The schema converts to a grammar.
    const g = try oriel.llama.jsonSchemaToGrammar(arena, req.chat.schema, null);
    try std.testing.expect(std.mem.indexOf(u8, g, "search_moments") != null);

    const calls = try toolMessage(arena, "{\"tool_calls\":[{\"name\":\"search_moments\",\"arguments\":{\"query\":\"cat\"}}]}", "chatcmpl-abc");
    try std.testing.expectEqualStrings("search_moments", calls.tool_calls.?[0].function.name);
    try std.testing.expectEqualStrings("{\"query\":\"cat\"}", calls.tool_calls.?[0].function.arguments);
    try std.testing.expectEqualStrings("call_abc_0", calls.tool_calls.?[0].id);
    const answer = try toolMessage(arena, "{\"answer\":\"Here it is.\"}", "chatcmpl-abc");
    try std.testing.expectEqualStrings("Here it is.", answer.content.?);
    try std.testing.expect(answer.tool_calls == null);
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
