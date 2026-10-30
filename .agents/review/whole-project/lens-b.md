# Lens B: Memory and Resources Review

**Target**: GhostPen (`src/`, 31 files, 18,728 lines)  
**Zig version**: 0.16.0  
**Status**: 107 tests passing (`zig build test`)

---

## Findings

### [medium] Watchdog background threads run indefinitely with no shutdown join or stop signal (Lens B)
- **Where**: `src/models.zig:230`, `src/models.zig:488`, `src/models.zig:540-554`; `src/local_llm.zig:159`, `src/local_llm.zig:771`, `src/local_llm.zig:878-891`
- **What goes wrong**: In both `models.zig` and `local_llm.zig`, a watchdog thread (`idleWatch`) is spawned on first runner startup:
  ```zig
  if (watchdog == null) watchdog = std.Thread.spawn(.{}, idleWatch, .{io}) catch null;
  ```
  Inside `idleWatch`, each thread loops indefinitely:
  ```zig
  while (true) {
      io.sleep(.fromSeconds(30), .awake) catch return;
      ...
  }
  ```
  Neither module provides a `deinit()` function or shutdown flag to signal `idleWatch` to terminate, nor is `watchdog.?.join()` ever called. When the application or service shuts down, these background threads remain alive until forced OS termination, potentially waking during memory deallocation.
- **Fix**: Add an atomic `running: std.atomic.Value(bool) = .init(true)` shutdown flag or condition variable, and an exported `pub fn deinit(io: std.Io) void` in both `models.zig` and `local_llm.zig` that sets `running` to `false`, wakes the thread, and calls `watchdog.?.join()`.

---

### [low] Missing explicit deallocation of `vad_path` on application shutdown (Lens B)
- **Where**: `src/models.zig:123`, `src/models.zig:132-137`
- **What goes wrong**:
  ```zig
  var vad_path: ?[:0]u8 = null;
  var vad_tried = false;
  ...
  vad_path = whisper.VadModel.install(io, gpa, vad_dir) catch |err| { ... };
  ```
  `vad_path` is allocated via `gpa` when installing the VAD model. While this lives for the lifetime of the process, it is not freed in any module shutdown routine, which flags leak detection under GPAs if cleanup checks are executed.
- **Fix**: Free `vad_path` in an explicit `models.deinit(gpa)` function.

---

### [low] Unbounded cache growth risk for remembered LLM plans (Lens B)
- **Where**: `src/llm_helper.zig:843-855`
- **What goes wrong**:
  ```zig
  const max_plan_entries = 64;
  ...
  const PlanEntry = struct { key: []const u8, ngl: i32, experts: usize, batch: u32, ubatch: u32 };
  const PlanFile = struct { plans: []PlanEntry = &.{} };
  ```
  The constant `max_plan_entries = 64` exists, but the file loading and saving routines do not enforce eviction when `plans.len >= max_plan_entries` if multiple different models or options are repeatedly evaluated.
- **Fix**: Enforce LRU or FIFO eviction when `plans.len >= max_plan_entries` prior to saving `PlanFile`.

---

## What was checked and found sound
- **Child process pipelines**: Every `std.process.Child` spawned in `models.zig`, `local_llm.zig`, `model_server.zig`, and `stt_server.zig` properly closes stdin/stdout/stderr pipes and calls `child.kill()` / `child.wait()` on error paths and termination.
- **Stderr drain thread synchronization**: In `models.zig:506` and `local_llm.zig:828`, `r.stderr_thread.?.join()` is consistently called before closing pipes and deallocating `Runner` structs, preventing use-after-free on pipe descriptors.
- **File handles**: All file open operations across `wav.zig`, `web_page.zig`, `meeting_store.zig`, and `pdf.zig` feature immediate `defer file.close(io)` or `errdefer file.close(io)`.
- **Large line buffers**: Model runners allocate 8MB–16MB reply buffers on heap (`stdout_buf`), and these are explicitly freed in `stop()` via `runner_gpa.free(r.stdout_buf)`.
- **Arena management**: Heavy allocations in requests (PDF generation, web extraction, audio window slicing) are anchored to scoped `ArenaAllocator` instances that release memory completely upon completion.

## What was not covered
- Long-duration audio capture stability under hardware device disconnects (ALSA/PulseAudio/PipeWire backends).
- GPU VRAM fragmentation across repeated model loads/unloads in upstream `llama.cpp`.

## zigatlas notes
- zigatlas does not currently track thread join lifecycles or background loop termination conditions, which is an expected limitation for an AST-based analyzer.
