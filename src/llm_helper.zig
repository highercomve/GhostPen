//! The local LLM runner: GhostPen's own executable started as
//! `ghostpen --llm-helper --model <file.gguf> [--mmproj <file.gguf>] [--embed-model <file.gguf>]
//! [--ctx N] [--kv-type f16|q8_0|q4_0] [--flash-attn auto|on|off] [--moe-pct N] [--cpu]` by
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
//!     {"id":1,"done":true,"prompt_tokens":52,"gen_tokens":9,"prompt_ms":8,"gen_ms":92,"truncated":false,"cancelled":false}
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
    /// MoE models: the percentage of blocks whose expert weights load into
    /// system RAM (0: all on the GPU; 100: every expert); attention stays on
    /// the GPU.
    moe_pct: u8 = 0,
};

/// Prompt batch and micro-batch (llama.cpp's -b / -ub 2048, as highllama):
/// the batch also sizes the logits buffer; the micro-batch drives prompt
/// eval speed (2048 is ~3x faster than 512) and the compute buffer's size.
const n_batch = 2048;
const n_ubatch = 2048;
/// The expert tensors of one MoE block (`std::regex_search`ed against the
/// tensor name; llama.cpp's LLM_FFN_EXPS_REGEX).
const ffn_exps_regex = "\\.ffn_(up|down|gate|gate_up)_(ch|)exps";

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
        } else if (std.mem.eql(u8, a, "--moe-pct") and has_value) {
            i += 1;
            const pct = std.fmt.parseInt(u8, args[i], 10) catch 0;
            if (pct > 100) {
                std.debug.print("ghostpen-llm: --moe-pct must be 0-100 (got {s})\n", .{args[i]});
                return 2;
            }
            opts.moe_pct = pct;
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
    // Physical cores: generation is memory-bound, and the SMT siblings only
    // add contention (highllama's -t 8 on an 8-core/16-thread machine).
    const logical = std.Thread.getCpuCount() catch 4;
    const threads: i32 = @intCast(if (logical >= 16) logical / 2 else logical);

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
        // MoE experts in system RAM: tensor-name patterns (matched with a
        // regex search) whose weights load on the CPU while the rest goes to
        // the GPU (llama.cpp's --n-cpu-moe). They must live through the load.
        const max_moe_blocks = 128;
        var moe_patterns: [max_moe_blocks][96]u8 = undefined;
        var moe_overrides: [max_moe_blocks + 1]c.llama_model_tensor_buft_override = undefined;
        const blocks: usize = @intCast(@max(layerCount(opts), 0));
        // The plan: GPU layers and experts held back, from the free memory
        // right now. Recomputed on the first failure: a restart races the
        // previous runner's VRAM release (the kill returns before the driver
        // frees), so the first measurement can be far too pessimistic.
        const plan = planSplit(opts, gpus, blocks, &moe_patterns, &moe_overrides);
        var ngl = plan.ngl;
        var n_overrides = plan.n_overrides;
        var attempts: usize = 0;
        const model = while (true) {
            attempts += 1;
            var mparams = c.llama_model_default_params();
            mparams.n_gpu_layers = ngl;
            // With experts in RAM, read the weights into memory instead of
            // mmap: mmap'd weights are clean file pages that memory pressure
            // evicts — a model bigger than the RAM that's left refaults from
            // disk on every token; malloc'd memory is only swapped under real
            // pressure.
            if (n_overrides > 0) mparams.load_mode = c.LLAMA_LOAD_MODE_NONE;
            if (n_overrides > 0) mparams.tensor_buft_overrides = &moe_overrides;
            if (c.llama_model_load_from_file(opts.model.ptr, mparams)) |m| break m;
            if (ngl == 0) {
                std.debug.print("ghostpen-llm: could not load the model {s} (unsupported or damaged file)\n", .{opts.model});
                return null;
            }
            // First failure: the previous runner's VRAM may still be freeing.
            // Wait, measure again, and retry the freshly planned split before
            // giving anything up.
            if (attempts == 1 and gpus > 0) {
                std.debug.print("ghostpen-llm: load failed; the previous runner's GPU memory may still be freeing — retrying\n", .{});
                std.Io.sleep(io, .fromSeconds(2), .awake) catch {};
                const fresh = planSplit(opts, gpus, blocks, &moe_patterns, &moe_overrides);
                if (fresh.ngl != ngl or fresh.n_overrides != n_overrides) {
                    ngl = fresh.ngl;
                    n_overrides = fresh.n_overrides;
                    continue;
                }
            }
            // Out of GPU memory with the experts held back: shift more expert
            // weights into system RAM (the whole blocks stay on the GPU —
            // their attention is cheap); halve the GPU layers only once every
            // expert is already out.
            if (n_overrides > 0 and ngl >= 999 and n_overrides < blocks) {
                const more = @min(n_overrides + @max(blocks / 8, 1), blocks);
                std.debug.print("ghostpen-llm: not enough GPU memory: {d} of {d} blocks' experts in system RAM\n", .{ more, blocks });
                n_overrides = writeMoeOverrides(&moe_patterns, &moe_overrides, more);
                continue;
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
            // llama.cpp's defaults (-b 2048 -ub 512): the whole prompt in a
            // few large batches, without the huge compute buffers (a
            // batch-sized logits buffer alone is 2 GB at 250k vocabulary)
            // that would push an -ngl 99 split out of the GPU's memory.
            cparams.n_batch = n_batch;
            cparams.n_ubatch = n_ubatch;
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

        // A resident threadpool (what llama-server does): without one, ggml
        // builds a disposable pool — spawns and joins all the threads — for
        // every graph compute, and in split mode (experts in system RAM)
        // there is one per CPU/GPU boundary, dozens per generated token.
        var tpp = c.ggml_threadpool_params_default(threads);
        const tp = c.ggml_threadpool_new(&tpp);
        c.llama_attach_threadpool(ctx, tp, tp);

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
    return modelMeta(opts).layers;
}

const ModelMeta = struct {
    layers: i32 = 0,
    /// KV-cache bytes per context token (K and V, this model's geometry and
    /// the configured KV precision).
    kv_per_token: u64 = 0,
    /// Vocabulary size: the logits buffer is n_batch entries of it.
    vocab: u32 = 0,
};

/// Layer count and KV size from the file's metadata (a vocab-only load).
fn modelMeta(opts: Options) ModelMeta {
    var p = c.llama_model_default_params();
    p.vocab_only = true;
    p.n_gpu_layers = 0;
    const m = c.llama_model_load_from_file(opts.model.ptr, p) orelse return .{};
    defer c.llama_model_free(m);
    var out: ModelMeta = .{};
    var arch: [64]u8 = undefined;
    const n = c.llama_model_meta_val_str(m, "general.architecture", &arch, arch.len);
    if (n <= 0) return out;
    out.layers = metaInt(m, "{s}.block_count", arch[0..@intCast(n)]);
    // Not a GGUF key on every model: the vocab-only load still has it.
    if (c.llama_model_get_vocab(m)) |v| {
        out.vocab = @intCast(@max(c.llama_vocab_n_tokens(v), 0));
    }
    const heads = metaInt(m, "{s}.attention.head_count_kv", arch[0..@intCast(n)]);
    if (heads <= 0) return out;
    var head_dim = metaInt(m, "{s}.attention.key_length", arch[0..@intCast(n)]);
    if (head_dim <= 0) {
        const n_embd = metaInt(m, "{s}.embedding_length", arch[0..@intCast(n)]);
        const n_heads = metaInt(m, "{s}.attention.head_count", arch[0..@intCast(n)]);
        if (n_embd <= 0 or n_heads <= 0) return out;
        head_dim = @divTrunc(n_embd, n_heads);
    }
    const elem = @divTrunc(c.ggml_type_size(opts.kv_type), @as(usize, @intCast(c.ggml_blck_size(opts.kv_type))));
    out.kv_per_token = 2 * @as(u64, @intCast(heads)) * @as(u64, @intCast(head_dim)) * @as(u64, @intCast(elem));
    return out;
}

/// One `<arch>.<key>` integer from the model's metadata (0 when absent).
fn metaInt(m: *c.llama_model, comptime fmt: []const u8, arch: []const u8) i32 {
    var key: [96]u8 = undefined;
    const k = std.fmt.bufPrintZ(&key, fmt, .{arch}) catch return 0;
    var val: [32]u8 = undefined;
    const v = c.llama_model_meta_val_str(m, k.ptr, &val, val.len);
    if (v <= 0) return 0;
    return std.fmt.parseInt(i32, val[0..@intCast(v)], 10) catch 0;
}

/// The context length the model was trained for (metadata only, nothing
/// loaded; 0 when the file can't be read): what the UI may offer as the
/// context window's maximum.
pub fn trainedCtx(arena: std.mem.Allocator, path: []const u8) u32 {
    var p = c.llama_model_default_params();
    p.vocab_only = true;
    p.n_gpu_layers = 0;
    const z = arena.dupeZ(u8, path) catch return 0;
    const m = c.llama_model_load_from_file(z.ptr, p) orelse return 0;
    defer c.llama_model_free(m);
    const n = c.llama_model_n_ctx_train(m);
    return if (n > 0) @intCast(n) else 0;
}

/// The split plan for the free memory right now: how many layers on the GPU
/// (all of them when experts are held back) and how many blocks' expert
/// weights in system RAM. Written into `patterns`/`overrides`.
fn planSplit(opts: Options, gpus: usize, blocks: usize, patterns: *[128][96]u8, overrides: *[129]c.llama_model_tensor_buft_override) struct { ngl: i32, n_overrides: usize } {
    if (gpus == 0) return .{ .ngl = 0, .n_overrides = 0 };
    var ngl: i32 = gpuLayers(opts);
    var n_overrides: usize = 0;
    if (opts.moe_pct > 0) {
        // The user's share of the blocks whose experts go to RAM (rounded up,
        // so even a small percentage does something) — but never less than
        // what the GPU's free memory forces: with every block on the GPU, the
        // experts left on the GPU still have to fit (highllama's estimator).
        var n: usize = @min(@max(blocks * @as(usize, opts.moe_pct) / 100 + 1, 1), blocks);
        const by_vram = moeCpuForVram(opts, blocks);
        if (by_vram > n) {
            n = by_vram;
            std.debug.print("ghostpen-llm: the GPU's memory needs more: {d} of {d} blocks' experts in system RAM\n", .{ n, blocks });
        }
        n_overrides = writeMoeOverrides(patterns, overrides, n);
        std.debug.print("ghostpen-llm: MoE experts of {d} of {d} blocks in system RAM\n", .{ n_overrides, blocks });
        // With experts held back, every block goes on the GPU: the expert
        // tensors are the bulk of the weights, so the rest fits easily
        // (highllama's `-ngl 99 --n-cpu-moe N`).
        ngl = 999;
    }
    return .{ .ngl = ngl, .n_overrides = n_overrides };
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
    // The KV cache at this model's geometry and the configured precision
    // (assuming f16 at 64 KB/token here used to reserve gigabytes that the
    // model never needs and park it all in system RAM), the logits buffer
    // (n_batch entries of the vocabulary — 2 GB at 250k), and the rest of the
    // compute buffers.
    const meta = modelMeta(opts);
    const kv: u64 = @as(u64, opts.ctx) * meta.kv_per_token;
    const logits: u64 = @as(u64, n_batch) * @as(u64, meta.vocab) * 4;
    const compute: u64 = 650 * 1024 * 1024 + @as(u64, n_ubatch / 512) * 750 * 1024 * 1024;
    const reserve: u64 = compute + kv + logits;
    if (file.size + reserve <= free) return 999;
    if (free <= reserve) return 0;
    const layers = layerCount(opts);
    const share = @as(f64, @floatFromInt(free - reserve)) / @as(f64, @floatFromInt(file.size));
    const n: i32 = @intFromFloat(@floor(@as(f64, @floatFromInt(layers)) * share));
    std.debug.print("ghostpen-llm: {d} MiB of GPU memory free: {d} of {d} layers on the GPU\n", .{ free >> 20, n, layers });
    return n;
}

/// Blocks whose expert weights must go to system RAM so the rest fits the
/// first GPU's free memory (highllama's estimator): the attention and dense
/// weights of every block go to the GPU (`-ngl 99`), the experts left there
/// are the ones to fit. 0 when it all fits.
fn moeCpuForVram(opts: Options, blocks: usize) usize {
    if (blocks == 0) return 0;
    var free: usize = 0;
    var total: usize = 0;
    for (0..c.ggml_backend_dev_count()) |i| {
        const dev = c.ggml_backend_dev_get(i) orelse continue;
        if (c.ggml_backend_dev_type(dev) != c.GGML_BACKEND_DEVICE_TYPE_GPU) continue;
        c.ggml_backend_dev_memory(dev, &free, &total);
        break;
    }
    if (free == 0) return 0;
    const file = std.Io.Dir.cwd().statFile(io, opts.model, .{}) catch return 0;
    const weights_mib = file.size >> 20;
    // The KV cache (this model's geometry and precision), the logits buffer
    // (n_batch entries of the vocabulary), the CUDA + compute buffers, with a
    // safety margin.
    const meta = modelMeta(opts);
    const kv_mib = @as(u64, opts.ctx) * meta.kv_per_token >> 20;
    const logits_mib = @as(u64, n_batch) * @as(u64, meta.vocab) * 4 >> 20;
    // Compute buffers: base + the activations, which scale with the
    // micro-batch size.
    const overhead_mib = 650 + ((@as(u64, opts.ctx) * 8) >> 10) + (n_ubatch / 512) * 750 + logits_mib;
    if (weights_mib + kv_mib + overhead_mib <= free >> 20) return 0; // all fits
    const budget_mib = (free >> 20) -| (kv_mib + overhead_mib);
    if (budget_mib == 0) return blocks;
    // The experts are ~95% of a MoE model's weights, and the compute
    // buffers need headroom: too thin a margin costs more than a few extra
    // blocks in RAM (each failed load re-reads the whole file).
    const per_block_mib = 95 * weights_mib / (100 * blocks);
    const need_mib = weights_mib - budget_mib;
    return @min(need_mib / per_block_mib + 1, blocks);
}

/// The first `n` blocks' expert-tensor patterns as CPU-buffer overrides
/// (NUL-terminated: llama.cpp reads them as C strings); their count.
fn writeMoeOverrides(patterns: *[128][96]u8, overrides: *[129]c.llama_model_tensor_buft_override, n: usize) usize {
    var written: usize = 0;
    for (0..n) |bi| {
        const p = std.fmt.bufPrint(&patterns[written], "blk\\.{d}{s}", .{ bi, ffn_exps_regex }) catch continue;
        patterns[written][p.len] = 0;
        overrides[written] = .{ .pattern = &patterns[written], .buft = c.ggml_backend_cpu_buffer_type() };
        written += 1;
    }
    overrides[written] = .{ .pattern = null, .buft = null };
    return written;
}

const Engine = struct {
    gpa: std.mem.Allocator,
    model: *c.llama_model,
    ctx: *c.llama_context,
    vocab: *const c.llama_vocab,
    format: chat_format.Format,
    template: ?[]const u8,
    vision: ?*c.mtmd_context,
    /// The last text prompt's tokens: the KV cache still holds their shared
    /// prefix, so the next request only evaluates its new tail (what makes an
    /// agent's repeated 100k-token context cheap).
    cached: std.ArrayList(c.llama_token) = .empty,

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
        const req_start = std.Io.Clock.awake.now(io);
        var n_prompt: usize = 0;
        if (req.image.len > 0) {
            // The vision path places its tokens itself: no prefix to reuse.
            self.cached.clearRetainingCapacity();
            c.llama_memory_clear(c.llama_get_memory(self.ctx), true);
            n_prompt = try self.readImagePrompt(arena, req, n_ctx);
        } else {
            n_prompt = try self.readTextPrompt(arena, req, n_ctx);
        }
        if (n_prompt == 0) return self.finish(req.id, 0, 0, 0, 0, false, true); // cancelled
        const prompt_ms: u64 = @intCast(@max(req_start.durationTo(std.Io.Clock.awake.now(io)).toMilliseconds(), 0));
        const gen_start = std.Io.Clock.awake.now(io);
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

        // Schema: the grammar, and a candidate list to sample with it. A
        // schema the converter can't handle (an agent may send one with
        // $refs, nullable types, ...) isn't fatal: the answer goes out
        // unconstrained instead of failing the request.
        const grammar: ?*c.llama_sampler = if (req.schema.len > 0) blk: {
            var why: ?[]u8 = null;
            const gbnf = oriel.llama.jsonSchemaToGrammar(arena, req.schema, &why) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.InvalidSchema => {
                    std.debug.print("ghostpen-llm: unconstrained answer: the JSON schema isn't usable: {s}\n", .{why orelse "invalid"});
                    break :blk null;
                },
                else => |x| return x,
            };
            const g = c.llama_sampler_init_grammar(self.vocab, gbnf.ptr, "root") orelse {
                std.debug.print("ghostpen-llm: unconstrained answer: the schema's grammar couldn't be compiled\n", .{});
                break :blk null;
            };
            break :blk g;
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
        const gen_ms: u64 = @intCast(@max(gen_start.durationTo(std.Io.Clock.awake.now(io)).toMilliseconds(), 0));
        return self.finish(req.id, n_prompt, generated, prompt_ms, gen_ms, !cancelled and generated >= budget, cancelled);
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

    /// Decode the text prompt, reusing the KV cache of the prefix it shares
    /// with the previous request: only the new tail is evaluated. Returns its
    /// token count (0: cancelled).
    fn readTextPrompt(self: *Engine, arena: std.mem.Allocator, req: Request, n_ctx: usize) Error!usize {
        const text = try self.prompt(arena, req, req.user);
        const tokens = try self.tokenize(arena, text);
        if (tokens.len == 0) return fail(req.id, "Empty prompt.", .{});
        if (tokens.len + 16 > n_ctx)
            return fail(req.id, "The text is too long for the built-in model's context ({d} tokens, the context holds {d}): raise the context size in Settings.", .{ tokens.len, n_ctx });

        // The longest prefix the last request already has in the cache; at
        // least one token is always decoded (so the cache never "covers" a
        // request whole).
        var common: usize = 0;
        const limit = @min(tokens.len, self.cached.items.len);
        while (common < limit and self.cached.items[common] == tokens[common]) common += 1;
        if (common >= tokens.len) common = tokens.len - 1;
        // Recurrent and hybrid models (Qwen3.5, Mamba-style layers) can't
        // drop the tail of their state: seq_rm refuses, and decoding on top
        // would answer with the previous request still in the model's state
        // (a "casual" rewrite that remembered the translation before it).
        // Then start over from an empty memory.
        const mem = c.llama_get_memory(self.ctx);
        if (!c.llama_memory_seq_rm(mem, 0, @intCast(common), -1)) {
            c.llama_memory_clear(mem, true);
            common = 0;
        }
        var pos: usize = common;
        while (pos < tokens.len) {
            const n = @min(tokens.len - pos, n_ubatch);
            const rc = c.llama_decode(self.ctx, c.llama_batch_get_one(tokens[pos..].ptr, @intCast(n)));
            if (cancel.load(.acquire)) return 0;
            if (rc != 0) return fail(req.id, "The built-in model failed to read the prompt (llama_decode {d}).", .{rc});
            pos += n;
        }
        if (common > 0) log.info("prompt cache: {d} of {d} prompt tokens reused", .{ common, tokens.len });
        // Remember it for the next request (outlives this arena).
        self.cached.clearRetainingCapacity();
        self.cached.appendSlice(self.gpa, tokens) catch {};
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

    fn finish(_: *Engine, id: u64, prompt_tokens: usize, gen_tokens: usize, prompt_ms: u64, gen_ms: u64, truncated: bool, cancelled: bool) Error!void {
        sendFinal(.{ .id = id, .done = true, .prompt_tokens = prompt_tokens, .gen_tokens = gen_tokens, .prompt_ms = prompt_ms, .gen_ms = gen_ms, .truncated = truncated, .cancelled = cancelled });
    }
};
