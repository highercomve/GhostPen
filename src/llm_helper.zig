//! The local LLM runner: GhostPen's own executable started as
//! `ghostpen --llm-helper --model <file.gguf> [--ctx N] [--cpu]` by
//! `local_llm.zig`. A separate process so a crash or an out-of-memory in
//! llama.cpp can't take the app down, Stop can always kill it, and the
//! model's memory is returned when it exits.
//!
//! Protocol: JSON lines. Once the model is loaded the helper prints
//!
//!     {"ready":true,"ctx":8192,"gpu":"NVIDIA GeForce RTX 4070","load_ms":2140}
//!
//! then reads requests from stdin, one at a time:
//!
//!     {"id":1,"cmd":"chat","system":"…","user":"…","max_tokens":2048,"temperature":0.2,"think":false}
//!     {"cmd":"cancel"}                        stop the running request
//!
//! and answers each with deltas and one final line:
//!
//!     {"id":1,"delta":"Hel"}  {"id":1,"delta":"lo"}
//!     {"id":1,"done":true,"prompt_tokens":52,"gen_tokens":9,"truncated":false,"cancelled":false}
//!     {"id":1,"error":"…"}
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
    ctx: u32 = 8192,
    cpu: bool = false,
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
};

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
        } else if (std.mem.eql(u8, a, "--ctx") and has_value) {
            i += 1;
            opts.ctx = std.fmt.parseInt(u32, args[i], 10) catch 8192;
        } else if (std.mem.eql(u8, a, "--cpu")) {
            opts.cpu = true;
        }
    }
    if (opts.model.len == 0) {
        std.debug.print("ghostpen-llm: --model is required\n", .{});
        return 2;
    }

    c.llama_log_set(logCallback, null);
    c.ggml_log_set(logCallback, null);
    const start = std.Io.Clock.awake.now(io);
    const gpus: usize = if (opts.cpu) 0 else oriel.ggml_gpu.load(io);
    c.llama_backend_init();
    defer c.llama_backend_free();

    // As many layers on the GPU as its free memory holds (other apps may use
    // it too); on failure fewer, down to the CPU alone.
    var ngl: i32 = if (gpus > 0) gpuLayers(opts) else 0;
    const model = while (true) {
        var mparams = c.llama_model_default_params();
        mparams.n_gpu_layers = ngl;
        if (c.llama_model_load_from_file(opts.model.ptr, mparams)) |m| break m;
        if (ngl == 0) {
            std.debug.print("ghostpen-llm: could not load the model {s} (unsupported or damaged file)\n", .{opts.model});
            return 1;
        }
        ngl = if (ngl >= 999) @max(@divTrunc(layerCount(opts) * 2, 3), 0) else @divTrunc(ngl, 2);
        std.debug.print("ghostpen-llm: not enough GPU memory, retrying with {d} layers on the GPU\n", .{ngl});
    };
    defer c.llama_model_free(model);

    // The context: as asked, capped at what the model was trained for; on
    // failure (out of memory) halved down to 2048.
    const trained: u32 = @intCast(@max(c.llama_model_n_ctx_train(model), 512));
    var n_ctx = @max(@min(opts.ctx, trained), 512);
    const threads: i32 = @intCast(@min(std.Thread.getCpuCount() catch 4, 8));
    const ctx = while (true) {
        var cparams = c.llama_context_default_params();
        cparams.n_ctx = n_ctx;
        cparams.n_batch = 512;
        cparams.n_ubatch = 512;
        cparams.n_threads = threads;
        cparams.n_threads_batch = threads;
        cparams.no_perf = true;
        cparams.abort_callback = abortCallback;
        if (c.llama_init_from_model(model, cparams)) |ctx| break ctx;
        if (n_ctx <= 2048) {
            std.debug.print("ghostpen-llm: could not create a {d}-token context (out of memory?)\n", .{n_ctx});
            return 1;
        }
        n_ctx = @max(n_ctx / 2, 2048);
        std.debug.print("ghostpen-llm: retrying with a {d}-token context\n", .{n_ctx});
    };
    defer c.llama_free(ctx);

    const template: ?[]const u8 = if (c.llama_model_chat_template(model, null)) |t| std.mem.span(t) else null;
    const format = chat_format.detect(template);

    const load_ms = start.durationTo(std.Io.Clock.awake.now(io)).toMilliseconds();
    send(.{
        .ready = true,
        .ctx = c.llama_n_ctx(ctx),
        .gpu = if (ngl > 0) (oriel.ggml_gpu.gpuName() orelse "GPU") else null,
        .gpu_layers = ngl,
        .format = @tagName(format),
        .load_ms = load_ms,
    });

    var engine: Engine = .{ .gpa = gpa, .model = model, .ctx = ctx, .vocab = c.llama_model_get_vocab(model).?, .format = format, .template = template };

    // Requests: the worker generates; this thread keeps reading so a cancel
    // gets through.
    var in_buf: [256 * 1024]u8 = undefined;
    var reader = std.Io.File.stdin().readerStreaming(io, &in_buf);
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
        const parsed = std.json.parseFromSlice(Request, gpa, line, .{ .ignore_unknown_fields = true }) catch {
            sendError(0, "Malformed request.");
            continue;
        };
        const req = parsed.value;
        if (std.mem.eql(u8, req.cmd, "cancel")) {
            parsed.deinit();
            cancel.store(true, .release);
            continue;
        }
        if (!std.mem.eql(u8, req.cmd, "chat")) {
            sendError(req.id, "Unknown command.");
            parsed.deinit();
            continue;
        }
        if (busy.load(.acquire)) {
            sendError(req.id, "The built-in model is busy.");
            parsed.deinit();
            continue;
        }
        if (worker) |t| t.join();
        worker = null;
        cancel.store(false, .release);
        busy.store(true, .release);
        worker = std.Thread.spawn(.{}, Engine.run, .{ &engine, parsed }) catch {
            busy.store(false, .release);
            sendError(req.id, "Could not start the request.");
            parsed.deinit();
            continue;
        };
    }
    return 0;
}

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

    fn prompt(self: *Engine, arena: std.mem.Allocator, req: Request) Error![]const u8 {
        if (try chat_format.render(arena, self.format, req.system, req.user, req.think)) |p| return p;
        // llama.cpp's built-in templates (by the model's template, else ChatML).
        const msgs = [_]c.llama_chat_message{
            .{ .role = "system", .content = (try arena.dupeZ(u8, req.system)).ptr },
            .{ .role = "user", .content = (try arena.dupeZ(u8, req.user)).ptr },
        };
        const tmpl: ?[*:0]const u8 = if (self.template) |t| (try arena.dupeZ(u8, t)).ptr else null;
        var cap: usize = (req.system.len + req.user.len) * 2 + 512;
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
        const text = try self.prompt(arena, req);
        const tokens = try self.tokenize(arena, text);
        const n_ctx: usize = c.llama_n_ctx(self.ctx);
        if (tokens.len == 0) return fail(req.id, "Empty prompt.", .{});
        if (tokens.len + 16 > n_ctx)
            return fail(req.id, "The text is too long for the built-in model's context ({d} tokens, the context holds {d}): raise the context size in Settings.", .{ tokens.len, n_ctx });
        const budget = @min(@as(usize, req.max_tokens), n_ctx - tokens.len);

        c.llama_memory_clear(c.llama_get_memory(self.ctx), true);
        var pos: usize = 0;
        while (pos < tokens.len) {
            const n = @min(tokens.len - pos, 512);
            const rc = c.llama_decode(self.ctx, c.llama_batch_get_one(tokens[pos..].ptr, @intCast(n)));
            if (cancel.load(.acquire)) return self.finish(req.id, tokens.len, 0, false, true);
            if (rc != 0) return fail(req.id, "The built-in model failed to read the prompt (llama_decode {d}).", .{rc});
            pos += n;
        }

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

        // The whole output (special tokens as text, so the reasoning block's
        // markers can be found); `sent` bytes of its visible part went out.
        var out: std.ArrayList(u8) = .empty;
        var filter: chat_format.ReasoningFilter = .init(self.format, req.think);
        var sent: usize = 0;
        var generated: usize = 0;
        var cancelled = false;
        while (generated < budget) {
            if (cancel.load(.acquire)) {
                cancelled = true;
                break;
            }
            var tok = c.llama_sampler_sample(chain, self.ctx, -1);
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
        return self.finish(req.id, tokens.len, generated, !cancelled and generated >= budget, cancelled);
    }

    fn finish(_: *Engine, id: u64, prompt_tokens: usize, gen_tokens: usize, truncated: bool, cancelled: bool) Error!void {
        sendFinal(.{ .id = id, .done = true, .prompt_tokens = prompt_tokens, .gen_tokens = gen_tokens, .truncated = truncated, .cancelled = cancelled });
    }
};
