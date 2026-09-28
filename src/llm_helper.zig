//! The local LLM runner: GhostPen's own executable started as
//! `ghostpen --llm-helper --model <file.gguf> [--mmproj <file.gguf>] [--embed-model <file.gguf>]
//! [--ctx N] [--kv-type f16|q8_0|q4_0] [--flash-attn auto|on|off] [--cpu]` by
//! `local_llm.zig`. A separate process so a crash or an out-of-memory in
//! llama.cpp can't take the app down, Stop can always kill it, and the
//! model's memory is returned when it exits.
//!
//! Protocol: JSON lines. Once the model is loaded the helper prints
//!
//!     {"ready":true,"ctx":8192,"gpu":"NVIDIA GeForce RTX 4070","vision":true,"load_ms":2140}
//!
//! then reads requests from stdin, one at a time:
//!
//!     {"id":1,"cmd":"chat","system":"…","user":"…","max_tokens":2048,"temperature":0.2,"think":false}
//!     {"cmd":"cancel"}                        stop the running request
//!
//! With `--mmproj` (the model's vision projector) a chat can carry an image,
//! `"image":"<base64 PNG/JPEG>"`: llama.cpp's mtmd turns it into tokens
//! placed before the user's text.
//!
//! A chat can also carry `"schema":"<JSON Schema>"`: the answer is then JSON
//! matching it (llama.cpp's grammar sampler). With `"think":true` the grammar
//! binds only once the reasoning block is over, so the model reasons freely
//! first. Like GhostReel's runner, a token is drawn as usual and only checked
//! against the grammar; the grammar goes over the whole vocabulary only when
//! that token is rejected (checking every token of a 250k vocabulary at every
//! step is ~2.5x slower).
//!
//! and answers each with deltas and one final line:
//!
//!     {"id":1,"delta":"Hel"}  {"id":1,"delta":"lo"}
//!     {"id":1,"done":true,"prompt_tokens":52,"gen_tokens":9,"truncated":false,"cancelled":false}
//!     {"id":1,"error":"…"}
//!
//! With `--embed-model` (a small embedding model, e.g. embeddinggemma-300M,
//! with its own context: it runs while a chat is generating):
//!
//!     {"id":2,"cmd":"embed","texts":["a","b"]}
//!     {"id":2,"done":true,"embeddings":[[…],[…]],"model":"embeddinggemma-300M-Q8_0"}
//!
//! It exits when stdin closes (GhostPen quit or unloaded it). llama.cpp's
//! errors go to stderr, which GhostPen keeps for its error messages.

const std = @import("std");
const oriel = @import("oriel");
const chat_format = @import("chat_format.zig");

const c = oriel.llama.c;
const log = std.log.scoped(.llm);

const Options = struct {
    model: [:0]const u8,
    mmproj: ?[:0]const u8 = null,
    embed_model: ?[:0]const u8 = null,
    ctx: u32 = 8192,
    cpu: bool = false,
    /// KV cache precision: q4_0 holds ~4x the context of f16 in the same
    /// memory, at some quality cost; q8_0 (GhostReel's default) about 2x.
    kv_type: c.ggml_type = c.GGML_TYPE_Q8_0,
    flash_attn: c.llama_flash_attn_type = c.LLAMA_FLASH_ATTN_TYPE_AUTO,
};

const Request = struct {
    id: u64 = 0,
    cmd: []const u8,
    system: []const u8 = "",
    user: []const u8 = "",
    max_tokens: u32 = 2048,
    temperature: f32 = 0.2,
    think: bool = false,
    seed: u32 = 42,
    /// Base64 image (PNG, JPEG, ...), for models with a vision projector.
    image: []const u8 = "",
    /// A JSON Schema the answer must match ("" = free text).
    schema: []const u8 = "",
    /// `embed`: the texts to embed.
    texts: []const []const u8 = &.{},
};

fn parseKvType(s: []const u8) ?c.ggml_type {
    if (std.mem.eql(u8, s, "f16")) return c.GGML_TYPE_F16;
    if (std.mem.eql(u8, s, "q8_0")) return c.GGML_TYPE_Q8_0;
    if (std.mem.eql(u8, s, "q4_0")) return c.GGML_TYPE_Q4_0;
    return null;
}

fn parseFlashAttn(s: []const u8) ?c.llama_flash_attn_type {
    if (std.mem.eql(u8, s, "auto")) return c.LLAMA_FLASH_ATTN_TYPE_AUTO;
    if (std.mem.eql(u8, s, "on")) return c.LLAMA_FLASH_ATTN_TYPE_ENABLED;
    if (std.mem.eql(u8, s, "off")) return c.LLAMA_FLASH_ATTN_TYPE_DISABLED;
    return null;
}

/// Request lines: text, or an image in base64 (a 1024-pixel PNG is ~1-3 MB).
const max_line_bytes = 32 * 1024 * 1024;

var io: std.Io = undefined;
var out_mutex: std.Io.Mutex = .init;
var out_buf: [16 * 1024]u8 = undefined;
var out_writer: std.Io.File.Writer = undefined;
var cancel: std.atomic.Value(bool) = .init(false);
/// A request is running. Cleared just before its last line goes out, so
/// the client's next request (sent as soon as it reads that line) is never
/// refused as "busy".
var busy: std.atomic.Value(bool) = .init(false);

/// One JSON line on stdout (serialized: the reader and the worker both write).
fn send(value: anytype) void {
    out_mutex.lockUncancelable(io);
    defer out_mutex.unlock(io);
    const w = &out_writer.interface;
    std.json.Stringify.value(value, .{}, w) catch return;
    w.writeByte('\n') catch return;
    w.flush() catch return;
}

fn sendError(id: u64, message: []const u8) void {
    send(.{ .id = id, .@"error" = message });
}

/// The last line of a request (`done` or `error`).
fn sendFinal(value: anytype) void {
    busy.store(false, .release);
    send(value);
}

/// llama.cpp/ggml log lines: errors only, to stderr.
fn logCallback(level: c.ggml_log_level, text: [*c]const u8, _: ?*anyopaque) callconv(.c) void {
    if (level != c.GGML_LOG_LEVEL_ERROR) return;
    std.debug.print("{s}", .{std.mem.span(text)});
}

fn abortCallback(_: ?*anyopaque) callconv(.c) bool {
    return cancel.load(.acquire);
}

pub fn main(process_io: std.Io, gpa: std.mem.Allocator, args: []const []const u8) u8 {
    io = process_io;
    out_writer = std.Io.File.stdout().writerStreaming(io, &out_buf);

    var opts: Options = .{ .model = "" };
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        const has_value = i + 1 < args.len;
        if (std.mem.eql(u8, a, "--model") and has_value) {
            i += 1;
            opts.model = gpa.dupeZ(u8, args[i]) catch return 1;
        } else if (std.mem.eql(u8, a, "--mmproj") and has_value) {
            i += 1;
            opts.mmproj = gpa.dupeZ(u8, args[i]) catch return 1;
        } else if (std.mem.eql(u8, a, "--ctx") and has_value) {
            i += 1;
            opts.ctx = std.fmt.parseInt(u32, args[i], 10) catch 8192;
        } else if (std.mem.eql(u8, a, "--embed-model") and has_value) {
            i += 1;
            opts.embed_model = gpa.dupeZ(u8, args[i]) catch return 1;
        } else if (std.mem.eql(u8, a, "--kv-type") and has_value) {
            i += 1;
            opts.kv_type = parseKvType(args[i]) orelse {
                std.debug.print("ghostpen-llm: --kv-type must be f16, q8_0 or q4_0 (got {s})\n", .{args[i]});
                return 2;
            };
        } else if (std.mem.eql(u8, a, "--flash-attn") and has_value) {
            i += 1;
            opts.flash_attn = parseFlashAttn(args[i]) orelse {
                std.debug.print("ghostpen-llm: --flash-attn must be auto, on or off (got {s})\n", .{args[i]});
                return 2;
            };
        } else if (std.mem.eql(u8, a, "--cpu")) {
            opts.cpu = true;
        }
    }
    if (opts.model.len == 0 and opts.embed_model == null) {
        std.debug.print("ghostpen-llm: nothing to load: --model and/or --embed-model\n", .{});
        return 2;
    }

    c.llama_log_set(logCallback, null);
    c.ggml_log_set(logCallback, null);
    c.mtmd_helper_log_set(logCallback, null);
    const start = std.Io.Clock.awake.now(io);
    const gpus: usize = if (opts.cpu) 0 else oriel.ggml_gpu.load(io);
    c.llama_backend_init();
    defer c.llama_backend_free();
    const threads: i32 = @intCast(@min(std.Thread.getCpuCount() catch 4, 8));

    // The chat model, unless this runner only embeds (`--embed-model` alone:
    // a search doesn't load a chat model).
    var chat: ?ChatModel = if (opts.model.len > 0) (ChatModel.load(opts, gpus, threads) orelse return 1) else null;
    defer if (chat) |*m| m.deinit();

    var embedder: ?Embedder = if (opts.embed_model) |path| Embedder.load(path, gpus > 0, threads) catch |err| blk: {
        std.debug.print("ghostpen-llm: could not load the embedding model {s} ({s}); no embeddings\n", .{ path, @errorName(err) });
        if (chat == null) return 1; // nothing else to serve
        break :blk null;
    } else null;
    defer if (embedder) |*e| e.deinit();

    const load_ms = start.durationTo(std.Io.Clock.awake.now(io)).toMilliseconds();
    send(.{
        .ready = true,
        .chat = chat != null,
        .ctx = if (chat) |m| c.llama_n_ctx(m.ctx) else 0,
        .gpu = if (gpus > 0) (oriel.ggml_gpu.gpuName() orelse "GPU") else null,
        .gpu_layers = if (chat) |m| m.ngl else 0,
        .format = if (chat) |m| @tagName(m.format) else "",
        .vision = if (chat) |m| m.vision != null else false,
        .embed_dim = if (embedder) |e| e.dim else 0,
        .load_ms = load_ms,
    });

    var engine: ?Engine = if (chat) |m| .{ .gpa = gpa, .model = m.model, .ctx = m.ctx, .vocab = c.llama_model_get_vocab(m.model).?, .format = m.format, .template = m.template, .vision = m.vision } else null;

    // Requests: the worker generates; this thread keeps reading so a cancel
    // gets through.
    const in_buf = gpa.alloc(u8, max_line_bytes) catch return 1;
    defer gpa.free(in_buf);
    var reader = std.Io.File.stdin().readerStreaming(io, in_buf);
    var worker: ?std.Thread = null;
    defer if (worker) |t| {
        cancel.store(true, .release);
        t.join();
    };
    while (true) {
        const line = reader.interface.takeDelimiter('\n') catch |err| switch (err) {
            error.StreamTooLong => {
                // Skip the rest of that line (the reader keeps it otherwise).
                _ = reader.interface.discardDelimiterInclusive('\n') catch break;
                sendError(0, "The text is too long for the built-in model.");
                continue;
            },
            else => break,
        } orelse break;
        if (std.mem.trim(u8, line, " \t\r").len == 0) continue;
        // Copies of the strings: `line` points into the stdin buffer, which
        // this thread keeps refilling while the worker uses the request.
        const parsed = std.json.parseFromSlice(Request, gpa, line, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch {
            sendError(0, "Malformed request.");
            continue;
        };
        const req = parsed.value;
        if (std.mem.eql(u8, req.cmd, "cancel")) {
            parsed.deinit();
            cancel.store(true, .release);
            continue;
        }
        if (std.mem.eql(u8, req.cmd, "embed")) {
            // Here, not in the worker: its own model and context, so it runs
            // while a chat generates (a cancel waits for it, milliseconds).
            defer parsed.deinit();
            const e = if (embedder) |*e| e else {
                sendError(req.id, "No embedding model is loaded.");
                continue;
            };
            e.embedTexts(gpa, req.id, req.texts);
            continue;
        }
        if (!std.mem.eql(u8, req.cmd, "chat")) {
            sendError(req.id, "Unknown command.");
            parsed.deinit();
            continue;
        }
        const eng = if (engine) |*e| e else {
            sendError(req.id, "This runner has no chat model (embeddings only).");
            parsed.deinit();
            continue;
        };
        if (busy.load(.acquire)) {
            sendError(req.id, "The built-in model is busy.");
            parsed.deinit();
            continue;
        }
        if (worker) |t| t.join();
        worker = null;
        cancel.store(false, .release);
        busy.store(true, .release);
        worker = std.Thread.spawn(.{}, Engine.run, .{ eng, parsed }) catch {
            busy.store(false, .release);
            sendError(req.id, "Could not start the request.");
            parsed.deinit();
            continue;
        };
    }
    return 0;
}

/// The chat model with its context and (optional) vision projector.
const ChatModel = struct {
    model: *c.llama_model,
    ctx: *c.llama_context,
    vision: ?*c.mtmd_context,
    ngl: i32,
    template: ?[]const u8,
    format: chat_format.Format,

    /// Null (the reason on stderr) when it can't be loaded.
    fn load(opts: Options, gpus: usize, threads: i32) ?ChatModel {
        // As many layers on the GPU as its free memory holds (other apps may
        // use it too); on failure fewer, down to the CPU alone.
        var ngl: i32 = if (gpus > 0) gpuLayers(opts) else 0;
        const model = while (true) {
            var mparams = c.llama_model_default_params();
            mparams.n_gpu_layers = ngl;
            if (c.llama_model_load_from_file(opts.model.ptr, mparams)) |m| break m;
            if (ngl == 0) {
                std.debug.print("ghostpen-llm: could not load the model {s} (unsupported or damaged file)\n", .{opts.model});
                return null;
            }
            ngl = if (ngl >= 999) @max(@divTrunc(layerCount(opts) * 2, 3), 0) else @divTrunc(ngl, 2);
            std.debug.print("ghostpen-llm: not enough GPU memory, retrying with {d} layers on the GPU\n", .{ngl});
        };
        errdefer c.llama_model_free(model);

        // The context: as asked, capped at what the model was trained for; on
        // failure (out of memory) halved down to 2048.
        const trained: u32 = @intCast(@max(c.llama_model_n_ctx_train(model), 512));
        var n_ctx = @max(@min(opts.ctx, trained), 512);
        const ctx = while (true) {
            var cparams = c.llama_context_default_params();
            cparams.n_ctx = n_ctx;
            cparams.n_batch = 512;
            cparams.n_ubatch = 512;
            cparams.n_threads = threads;
            cparams.n_threads_batch = threads;
            cparams.no_perf = true;
            cparams.abort_callback = abortCallback;
            cparams.type_k = opts.kv_type;
            cparams.type_v = opts.kv_type;
            cparams.flash_attn_type = opts.flash_attn;
            if (c.llama_init_from_model(model, cparams)) |ctx| break ctx;
            if (n_ctx <= 2048) {
                std.debug.print("ghostpen-llm: could not create a {d}-token context (out of memory?)\n", .{n_ctx});
                c.llama_model_free(model);
                return null;
            }
            n_ctx = @max(n_ctx / 2, 2048);
            std.debug.print("ghostpen-llm: retrying with a {d}-token context\n", .{n_ctx});
        };

        // The vision projector: on the GPU with the model; without it the
        // model still answers text.
        const vision: ?*c.mtmd_context = if (opts.mmproj) |path| blk: {
            var mp = c.mtmd_context_params_default();
            mp.use_gpu = ngl > 0;
            mp.n_threads = threads;
            mp.print_timings = false;
            mp.warmup = false;
            const m = c.mtmd_init_from_file(path.ptr, model, mp) orelse {
                std.debug.print("ghostpen-llm: could not load the vision projector {s}; images won't be read\n", .{path});
                break :blk null;
            };
            if (!c.mtmd_support_vision(m)) {
                c.mtmd_free(m);
                std.debug.print("ghostpen-llm: {s} has no vision encoder; images won't be read\n", .{path});
                break :blk null;
            }
            break :blk m;
        } else null;

        const template: ?[]const u8 = if (c.llama_model_chat_template(model, null)) |t| std.mem.span(t) else null;
        return .{ .model = model, .ctx = ctx, .vision = vision, .ngl = ngl, .template = template, .format = chat_format.detect(template) };
    }

    fn deinit(self: *ChatModel) void {
        if (self.vision) |m| c.mtmd_free(m);
        c.llama_free(self.ctx);
        c.llama_model_free(self.model);
    }
};

/// A small embedding model (e.g. embeddinggemma-300M) with its own context.
/// Only the reading thread uses it.
const Embedder = struct {
    model: *c.llama_model,
    ctx: *c.llama_context,
    vocab: *const c.llama_vocab,
    dim: usize,
    n_ctx: usize,
    /// The file's name without `.gguf`: what /v1/embeddings reports.
    name: []const u8,
    has_encoder: bool,

    fn load(path: [:0]const u8, gpu: bool, threads: i32) !Embedder {
        var mparams = c.llama_model_default_params();
        mparams.n_gpu_layers = if (gpu) 999 else 0;
        const model = c.llama_model_load_from_file(path.ptr, mparams) orelse return error.ModelLoadFailed;
        errdefer c.llama_model_free(model);
        const n_ctx: u32 = @intCast(@min(@max(c.llama_model_n_ctx_train(model), 512), 2048));
        var cparams = c.llama_context_default_params();
        cparams.n_ctx = n_ctx;
        // Non-causal models need a whole text in one micro-batch.
        cparams.n_batch = n_ctx;
        cparams.n_ubatch = n_ctx;
        cparams.n_threads = threads;
        cparams.n_threads_batch = threads;
        cparams.embeddings = true;
        cparams.no_perf = true;
        const ctx = c.llama_init_from_model(model, cparams) orelse return error.ContextFailed;
        errdefer c.llama_free(ctx);
        if (c.llama_pooling_type(ctx) == c.LLAMA_POOLING_TYPE_NONE) return error.NotAnEmbeddingModel;
        const base = std.fs.path.basename(path);
        return .{
            .model = model,
            .ctx = ctx,
            .vocab = c.llama_model_get_vocab(model).?,
            .dim = @intCast(c.llama_model_n_embd_out(model)),
            .n_ctx = n_ctx,
            .name = if (std.mem.endsWith(u8, base, ".gguf")) base[0 .. base.len - ".gguf".len] else base,
            .has_encoder = c.llama_model_has_encoder(model),
        };
    }

    fn deinit(self: *Embedder) void {
        c.llama_free(self.ctx);
        c.llama_model_free(self.model);
    }

    /// Embed each text (L2-normalized, like llama-server and OpenAI) and send
    /// them in one line, or an error.
    fn embedTexts(self: *Embedder, gpa: std.mem.Allocator, id: u64, texts: []const []const u8) void {
        var arena_state: std.heap.ArenaAllocator = .init(gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        const out = arena.alloc([]const f32, texts.len) catch return sendError(id, "Out of memory.");
        for (texts, out) |text, *vec| {
            vec.* = self.embedOne(arena, text) catch |err| return sendError(id, switch (err) {
                error.OutOfMemory => "Out of memory.",
                else => "The embedding model failed on a text.",
            });
        }
        send(.{ .id = id, .done = true, .embeddings = out, .model = self.name });
    }

    fn embedOne(self: *Embedder, arena: std.mem.Allocator, text: []const u8) ![]const f32 {
        const n = -c.llama_tokenize(self.vocab, text.ptr, @intCast(text.len), null, 0, true, true);
        var tokens = try arena.alloc(c.llama_token, @intCast(@max(n, 1)));
        const got = c.llama_tokenize(self.vocab, text.ptr, @intCast(text.len), tokens.ptr, @intCast(tokens.len), true, true);
        if (got <= 0) return error.EmptyText;
        // Longer than the model reads: its start (what search needs most).
        const len = @min(@as(usize, @intCast(got)), self.n_ctx);
        tokens = tokens[0..len];
        c.llama_memory_clear(c.llama_get_memory(self.ctx), true);
        const batch = c.llama_batch_get_one(tokens.ptr, @intCast(tokens.len));
        const rc = if (self.has_encoder) c.llama_encode(self.ctx, batch) else c.llama_decode(self.ctx, batch);
        if (rc != 0) return error.DecodeFailed;
        const raw = c.llama_get_embeddings_seq(self.ctx, 0) orelse return error.NoEmbeddings;
        const vec = try arena.alloc(f32, self.dim);
        var norm: f64 = 0;
        for (raw[0..self.dim]) |x| norm += @as(f64, x) * @as(f64, x);
        const scale: f32 = if (norm > 0) @floatCast(1.0 / @sqrt(norm)) else 1;
        for (vec, raw[0..self.dim]) |*o, x| o.* = x * scale;
        return vec;
    }
};

/// The model's layer count (metadata only, nothing loaded).
fn layerCount(opts: Options) i32 {
    var p = c.llama_model_default_params();
    p.vocab_only = true;
    p.n_gpu_layers = 0;
    const m = c.llama_model_load_from_file(opts.model.ptr, p) orelse return 0;
    defer c.llama_model_free(m);
    // `<arch>.block_count` (n_layer isn't set by a vocab-only load).
    var arch: [64]u8 = undefined;
    const n = c.llama_model_meta_val_str(m, "general.architecture", &arch, arch.len);
    if (n <= 0) return 0;
    var key: [96]u8 = undefined;
    const k = std.fmt.bufPrintZ(&key, "{s}.block_count", .{arch[0..@intCast(n)]}) catch return 0;
    var val: [32]u8 = undefined;
    const v = c.llama_model_meta_val_str(m, k.ptr, &val, val.len);
    if (v <= 0) return 0;
    return std.fmt.parseInt(i32, val[0..@intCast(v)], 10) catch 0;
}

/// GPU layers for the free memory of the first GPU: all of them when the
/// weights plus the context fit, else the share that does.
fn gpuLayers(opts: Options) i32 {
    var free: usize = 0;
    var total: usize = 0;
    for (0..c.ggml_backend_dev_count()) |i| {
        const dev = c.ggml_backend_dev_get(i) orelse continue;
        if (c.ggml_backend_dev_type(dev) != c.GGML_BACKEND_DEVICE_TYPE_GPU) continue;
        c.ggml_backend_dev_memory(dev, &free, &total);
        break;
    }
    if (free == 0) return 999; // unknown: try, then back off
    const file = std.Io.Dir.cwd().statFile(io, opts.model, .{}) catch return 999;
    // KV cache and compute buffers: ~0.5 GB per 8k tokens, plus 0.6 GB.
    const reserve: u64 = 600 * 1024 * 1024 + @as(u64, opts.ctx) * 64 * 1024;
    if (file.size + reserve <= free) return 999;
    if (free <= reserve) return 0;
    const layers = layerCount(opts);
    const share = @as(f64, @floatFromInt(free - reserve)) / @as(f64, @floatFromInt(file.size));
    const n: i32 = @intFromFloat(@floor(@as(f64, @floatFromInt(layers)) * share));
    std.debug.print("ghostpen-llm: {d} MiB of GPU memory free: {d} of {d} layers on the GPU\n", .{ free >> 20, n, layers });
    return n;
}

const Engine = struct {
    gpa: std.mem.Allocator,
    model: *c.llama_model,
    ctx: *c.llama_context,
    vocab: *const c.llama_vocab,
    format: chat_format.Format,
    template: ?[]const u8,
    vision: ?*c.mtmd_context,

    fn run(self: *Engine, parsed: std.json.Parsed(Request)) void {
        defer parsed.deinit();
        const req = parsed.value;
        var arena: std.heap.ArenaAllocator = .init(self.gpa);
        defer arena.deinit();
        self.generate(arena.allocator(), req) catch |err| switch (err) {
            error.Reported => {},
            error.OutOfMemory => sendFinal(.{ .id = req.id, .@"error" = "Out of memory." }),
        };
    }

    const Error = error{ Reported, OutOfMemory };

    fn fail(id: u64, comptime fmt: []const u8, args: anytype) Error {
        var buf: [512]u8 = undefined;
        sendFinal(.{ .id = id, .@"error" = std.fmt.bufPrint(&buf, fmt, args) catch fmt });
        return error.Reported;
    }

    /// The whole prompt; `user` is the user's turn (with the media marker
    /// in front when there's an image).
    fn prompt(self: *Engine, arena: std.mem.Allocator, req: Request, user: []const u8) Error![]const u8 {
        if (try chat_format.render(arena, self.format, req.system, user, req.think)) |p| return p;
        // llama.cpp's built-in templates (by the model's template, else ChatML).
        const msgs = [_]c.llama_chat_message{
            .{ .role = "system", .content = (try arena.dupeZ(u8, req.system)).ptr },
            .{ .role = "user", .content = (try arena.dupeZ(u8, user)).ptr },
        };
        const tmpl: ?[*:0]const u8 = if (self.template) |t| (try arena.dupeZ(u8, t)).ptr else null;
        var cap: usize = (req.system.len + user.len) * 2 + 512;
        while (true) {
            const buf = try arena.alloc(u8, cap);
            var n = c.llama_chat_apply_template(tmpl, &msgs, msgs.len, true, buf.ptr, @intCast(cap));
            if (n < 0 and tmpl != null) n = c.llama_chat_apply_template("chatml", &msgs, msgs.len, true, buf.ptr, @intCast(cap));
            if (n < 0) return fail(req.id, "This model's chat format isn't supported.", .{});
            if (@as(usize, @intCast(n)) <= cap) return buf[0..@intCast(n)];
            cap = @intCast(n);
        }
    }

    fn tokenize(self: *Engine, arena: std.mem.Allocator, text: []const u8) ![]c.llama_token {
        const n = -c.llama_tokenize(self.vocab, text.ptr, @intCast(text.len), null, 0, true, true);
        if (n <= 0) return &.{};
        const tokens = try arena.alloc(c.llama_token, @intCast(n));
        const got = c.llama_tokenize(self.vocab, text.ptr, @intCast(text.len), tokens.ptr, n, true, true);
        return tokens[0..@intCast(@max(got, 0))];
    }

    fn generate(self: *Engine, arena: std.mem.Allocator, req: Request) Error!void {
        const n_ctx: usize = c.llama_n_ctx(self.ctx);
        c.llama_memory_clear(c.llama_get_memory(self.ctx), true);
        const n_prompt = if (req.image.len > 0)
            try self.readImagePrompt(arena, req, n_ctx)
        else
            try self.readTextPrompt(arena, req, n_ctx);
        if (n_prompt == 0) return self.finish(req.id, 0, 0, false, true); // cancelled
        const budget = @min(@as(usize, req.max_tokens), n_ctx - n_prompt);

        const chain = c.llama_sampler_chain_init(c.llama_sampler_chain_default_params()) orelse return error.OutOfMemory;
        defer c.llama_sampler_free(chain);
        if (req.temperature <= 0) {
            c.llama_sampler_chain_add(chain, c.llama_sampler_init_greedy());
        } else {
            c.llama_sampler_chain_add(chain, c.llama_sampler_init_penalties(c.llama_vocab_n_tokens(self.vocab), 64, 1.05, 0, 0));
            c.llama_sampler_chain_add(chain, c.llama_sampler_init_top_k(40));
            c.llama_sampler_chain_add(chain, c.llama_sampler_init_top_p(0.95, 1));
            c.llama_sampler_chain_add(chain, c.llama_sampler_init_min_p(0.05, 1));
            c.llama_sampler_chain_add(chain, c.llama_sampler_init_temp(req.temperature));
            c.llama_sampler_chain_add(chain, c.llama_sampler_init_dist(req.seed));
        }

        // Schema: the grammar, and a candidate list to sample with it.
        const grammar: ?*c.llama_sampler = if (req.schema.len > 0) blk: {
            var why: ?[]u8 = null;
            const gbnf = oriel.llama.jsonSchemaToGrammar(arena, req.schema, &why) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return fail(req.id, "The JSON schema isn't usable: {s}", .{why orelse "invalid"}),
            };
            break :blk c.llama_sampler_init_grammar(self.vocab, gbnf.ptr, "root") orelse
                return fail(req.id, "The JSON schema's grammar couldn't be compiled.", .{});
        } else null;
        defer if (grammar) |g| c.llama_sampler_free(g);
        const candidates: []c.llama_token_data = if (grammar != null)
            try arena.alloc(c.llama_token_data, @intCast(c.llama_vocab_n_tokens(self.vocab)))
        else
            &.{};

        // The whole output (special tokens as text, so the reasoning block's
        // markers can be found); `sent` bytes of its visible part went out.
        var out: std.ArrayList(u8) = .empty;
        var filter: chat_format.ReasoningFilter = .init(self.format, req.think);
        var sent: usize = 0;
        var generated: usize = 0;
        var cancelled = false;
        // The grammar binds to the answer: from the start, or (thinking) once
        // the reasoning block is over.
        var answering = filter.visible(out.items) != null;
        while (generated < budget) {
            if (cancel.load(.acquire)) {
                cancelled = true;
                break;
            }
            var tok = if (grammar) |g| (if (answering) self.sampleWithGrammar(chain, g, candidates) else c.llama_sampler_sample(chain, self.ctx, -1)) else c.llama_sampler_sample(chain, self.ctx, -1);
            if (c.llama_vocab_is_eog(self.vocab, tok)) break;
            generated += 1;
            var piece: [256]u8 = undefined;
            const n = c.llama_token_to_piece(self.vocab, tok, &piece, piece.len, 0, true);
            if (n > 0) {
                try out.appendSlice(arena, piece[0..@intCast(n)]);
            } else if (n < 0) { // longer than the buffer: -n bytes
                const big = try arena.alloc(u8, @intCast(-n));
                const m = c.llama_token_to_piece(self.vocab, tok, big.ptr, @intCast(big.len), 0, true);
                if (m > 0) try out.appendSlice(arena, big[0..@intCast(m)]);
            }
            if (filter.visible(out.items)) |vis| {
                answering = true;
                const upto = chat_format.completeUtf8(vis);
                if (upto > sent) {
                    send(.{ .id = req.id, .delta = try chat_format.validUtf8(arena, vis[sent..upto]) });
                    sent = upto;
                }
            }
            const rc = c.llama_decode(self.ctx, c.llama_batch_get_one(&tok, 1));
            if (rc != 0) {
                if (cancel.load(.acquire)) {
                    cancelled = true;
                    break;
                }
                return fail(req.id, "The built-in model stopped generating (llama_decode {d}).", .{rc});
            }
        }
        if (filter.visible(out.items)) |vis| if (vis.len > sent) send(.{ .id = req.id, .delta = try chat_format.validUtf8(arena, vis[sent..]) });
        return self.finish(req.id, n_prompt, generated, !cancelled and generated >= budget, cancelled);
    }

    /// The next token under `grammar`: drawn from the usual chain and only
    /// checked against the grammar; only when it's rejected does the grammar
    /// filter the whole vocabulary before drawing again. Both samplers
    /// accept the token.
    fn sampleWithGrammar(self: *Engine, chain: *c.llama_sampler, grammar: *c.llama_sampler, candidates: []c.llama_token_data) c.llama_token {
        const logits = c.llama_get_logits_ith(self.ctx, -1);
        fillCandidates(candidates, logits);
        var all: c.llama_token_data_array = .{ .data = candidates.ptr, .size = candidates.len, .selected = -1, .sorted = false };
        c.llama_sampler_apply(chain, &all);
        var tok = all.data[@intCast(all.selected)].id;

        var one = [1]c.llama_token_data{.{ .id = tok, .logit = 1, .p = 0 }};
        var single: c.llama_token_data_array = .{ .data = &one, .size = 1, .selected = -1, .sorted = false };
        c.llama_sampler_apply(grammar, &single);
        if (one[0].logit == -std.math.inf(f32)) {
            fillCandidates(candidates, logits);
            all = .{ .data = candidates.ptr, .size = candidates.len, .selected = -1, .sorted = false };
            c.llama_sampler_apply(grammar, &all);
            c.llama_sampler_apply(chain, &all);
            tok = all.data[@intCast(all.selected)].id;
        }
        c.llama_sampler_accept(grammar, tok);
        c.llama_sampler_accept(chain, tok);
        return tok;
    }

    fn fillCandidates(candidates: []c.llama_token_data, logits: [*c]const f32) void {
        for (candidates, 0..) |*cd, i| cd.* = .{ .id = @intCast(i), .logit = logits[i], .p = 0 };
    }

    /// Decode the text prompt; its token count (0: cancelled).
    fn readTextPrompt(self: *Engine, arena: std.mem.Allocator, req: Request, n_ctx: usize) Error!usize {
        const text = try self.prompt(arena, req, req.user);
        const tokens = try self.tokenize(arena, text);
        if (tokens.len == 0) return fail(req.id, "Empty prompt.", .{});
        if (tokens.len + 16 > n_ctx)
            return fail(req.id, "The text is too long for the built-in model's context ({d} tokens, the context holds {d}): raise the context size in Settings.", .{ tokens.len, n_ctx });
        var pos: usize = 0;
        while (pos < tokens.len) {
            const n = @min(tokens.len - pos, 512);
            const rc = c.llama_decode(self.ctx, c.llama_batch_get_one(tokens[pos..].ptr, @intCast(n)));
            if (cancel.load(.acquire)) return 0;
            if (rc != 0) return fail(req.id, "The built-in model failed to read the prompt (llama_decode {d}).", .{rc});
            pos += n;
        }
        return tokens.len;
    }

    /// Decode a prompt with an image (through the vision projector); its
    /// token count (0: cancelled).
    fn readImagePrompt(self: *Engine, arena: std.mem.Allocator, req: Request, n_ctx: usize) Error!usize {
        const mctx = self.vision orelse return fail(req.id, "This built-in model can't read images: download its image projector in Settings → Built-in models, or pick a model that has one.", .{});
        const decoder = std.base64.standard.Decoder;
        const size = decoder.calcSizeForSlice(req.image) catch return fail(req.id, "The image isn't valid base64.", .{});
        const bytes = try arena.alloc(u8, size);
        decoder.decode(bytes, req.image) catch return fail(req.id, "The image isn't valid base64.", .{});
        const wrapped = c.mtmd_helper_bitmap_init_from_buf(mctx, bytes.ptr, bytes.len, false, c.mtmd_helper_init_opt_default());
        // Video (MTMD_VIDEO) isn't built: only still images, no video context.
        std.debug.assert(wrapped.video_ctx == null);
        const bitmap = wrapped.bitmap orelse return fail(req.id, "The built-in model couldn't decode the image.", .{});
        defer c.mtmd_bitmap_free(bitmap);

        // The image goes where the marker is: before the user's text.
        const user = try std.fmt.allocPrint(arena, "{s}\n{s}", .{ std.mem.span(c.mtmd_default_marker()), req.user });
        const text = try self.prompt(arena, req, user);
        const text_z = try arena.dupeZ(u8, text);
        const input: c.mtmd_input_text = .{ .text = text_z.ptr, .text_len = text.len, .add_special = true, .parse_special = true };
        const chunks = c.mtmd_input_chunks_init() orelse return error.OutOfMemory;
        defer c.mtmd_input_chunks_free(chunks);
        const bitmaps = [_]?*const c.mtmd_bitmap{bitmap};
        const trc = c.mtmd_tokenize(mctx, chunks, &input, @ptrCast(&bitmaps), bitmaps.len);
        if (trc != 0) return fail(req.id, "The built-in model couldn't read the image (mtmd_tokenize {d}).", .{trc});
        const n_tokens = c.mtmd_helper_get_n_tokens(chunks);
        if (n_tokens + 16 > n_ctx)
            return fail(req.id, "The image and text need {d} tokens, the built-in model's context holds {d}: raise the context size in Settings.", .{ n_tokens, n_ctx });
        var n_past: c.llama_pos = 0;
        const rc = c.mtmd_helper_eval_chunks(mctx, self.ctx, chunks, 0, 0, 512, true, &n_past);
        if (cancel.load(.acquire)) return 0;
        if (rc != 0) return fail(req.id, "The built-in model failed to read the image ({d}).", .{rc});
        return n_tokens;
    }

    fn finish(_: *Engine, id: u64, prompt_tokens: usize, gen_tokens: usize, truncated: bool, cancelled: bool) Error!void {
        sendFinal(.{ .id = id, .done = true, .prompt_tokens = prompt_tokens, .gen_tokens = gen_tokens, .truncated = truncated, .cancelled = cancelled });
    }
};
