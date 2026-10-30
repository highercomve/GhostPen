# Lens D: Architecture, Layers and Reuse Review

**Target**: GhostPen (`src/`, 31 files, 18,728 lines)  
**Zig version**: 0.16.0  
**Status**: 107 tests passing (`zig build test`)

---

## 1. Layers and Dependency Direction

### Proposed Layers
| Layer | Files | Lines | Role |
|---|---:|---:|---|
| **app** | `src/main.zig` | 1,836 | Desktop GUI entrypoint, window orchestration, tray menu |
| **cli** (thin) | `src/cli.zig` | 306 | CLI interface (flag parsing, stdout formatting) |
| **features** | `captions.zig`, `dictation.zig`, `meetings.zig`, `speakers.zig`, `model_server.zig`, `stt_server.zig`, `updates.zig`, `tts.zig`, `pdf.zig`, `web_page.zig`, `image.zig`, `logs.zig`, `store.zig` | 8,419 | Feature workflows and server endpoints |
| **helpers** | `llm_helper.zig`, `whisper_helper.zig` | 1,848 | Out-of-process C library runners (`llama.cpp`, `whisper.cpp`) |
| **core** | `ai.zig`, `ai_stream.zig`, `ai_observer.zig`, `chat_format.zig`, `local_llm.zig`, `llm_models.zig`, `models.zig`, `settings.zig`, `meeting_store.zig`, `metrics.zig`, `gguf_context.zig`, `voices.zig`, `wav.zig` | 6,296 | Shared models, types, storage, and utility libraries |
| **tests** | `src/tests.zig` | 23 | Test runner |

### [high] 8-file import loop around `main.zig` via global access (Lens D)
- **Where**:
  - `src/captions.zig:8`
  - `src/dictation.zig:14`
  - `src/meetings.zig:14`
  - `src/model_server.zig:49`
  - `src/speakers.zig:11`
  - `src/stt_server.zig:32`
  - `src/updates.zig:22`
  - All importing `src/main.zig`, which in turn imports all of them.
- **What goes wrong**: Feature modules import `main.zig` to access globals (`main.io`, `main.shared`, `main.events`, `main.showWindow`, `main.windowFor`). Because `main.zig` imports each feature module, this creates a bidirectional circular dependency graph across 8 files. No feature module can be tested, imported, or reasoned about in isolation.
- **Fix**: Move shared application primitives (`io`, `settingsHolder`, `events`) down to `core` (e.g. `src/app_context.zig` or pass them into feature `init()` / command handlers), and decouple GUI window commands through a callback interface or event bus.

---

### [high] Inverted dependency: `core` importing `helpers` entrypoint (Lens D)
- **Where**: `src/models.zig:11`, `src/models.zig:289`
- **What goes wrong**:
  `src/models.zig` (layer `core`) imports `src/whisper_helper.zig` (layer `helpers`):
  ```zig
  const whisper_helper = @import("whisper_helper.zig");
  ...
  if (samples.len > whisper_helper.max_samples) return error.AudioTooLong;
  ```
  `whisper_helper.zig` is the entry module for a child process executable, not a library. Core importing a child process runner inverts the architectural boundary.
- **Fix**: Move `max_samples` (and the shared wire types `Word`, `Segment`, `Request`) into `models.zig` or a shared `core` types file. `whisper_helper.zig` should import `models.zig`, not the other way around.

---

### [medium] `thick_frontend`: CLI duplicates core model resolution and execution logic (Lens D)
- **Where**: `src/cli.zig:50-218`, `src/cli.zig:226-243`, `src/main.zig:227-251`
- **What goes wrong**: `cli.zig:main` (complexity 58) directly drives `local_llm` and `llm_models`. Furthermore, `resolveLocal` is duplicated almost verbatim between `src/cli.zig:226` and `src/main.zig:227` (resolving directories, locating model files, validating executables, configuring context tokens). Any fix or enhancement to local model resolution must be manually duplicated across both front-ends.
- **Fix**: Extract `resolveLocal` and model status inspection into a shared service function in `llm_models.zig` (e.g. `pub fn resolveRunnerConfig(...)`), making `cli.zig` a thin wrapper that only parses flags and prints outputs.

---

## 2. Duplication and Reuse

### [medium] Triplicate `containsIgnoreCase` implementation (Lens D)
- **Where**:
  - `src/ai.zig:714-721`
  - `src/captions.zig:386-393`
  - `src/llm_models.zig:326-333`
- **What goes wrong**: All three modules implement the exact same 8-line helper:
  ```zig
  fn containsIgnoreCase(haystack: []const u8, lower_needle: []const u8) bool {
      if (lower_needle.len > haystack.len) return false;
      var i: usize = 0;
      while (i + lower_needle.len <= haystack.len) : (i += 1) {
          if (std.ascii.eqlIgnoreCase(haystack[i..][0..lower_needle.len], lower_needle)) return true;
      }
      return false;
  }
  ```
  The Zig standard library in 0.16 already provides `std.ascii.indexOfIgnoreCase(haystack, needle) != null` (`lib/std/ascii.zig:382`), rendering all three custom implementations completely redundant.
- **Fix**: Replace all three implementations with `std.ascii.indexOfIgnoreCase(haystack, needle) != null`.

---

### [medium] Duplicated model download failure handling and progress emission (Lens D)
- **Where**: `src/captions.zig:772-789`, `src/main.zig:1220-1238`
- **What goes wrong**: 18 lines of identical error-mapping and UI progress reporting are duplicated between `Commands.whisper_download_model` and `Commands.llm_download_model`:
  ```zig
  const message: []const u8 = switch (err) {
      error.Cancelled => "",
      error.UnknownModel => "Unknown model.",
      error.ChecksumMismatch => "The download was damaged (checksum mismatch) and was deleted: try again.",
      error.RangeIgnored => "The server can't resume this download: try again to start over.",
      error.Incomplete => "The download stopped early: try again to resume it.",
      error.Stalled => "The download stalled (no data for a minute): check the connection, then resume it.",
      error.HttpError => try std.fmt.allocPrint(arena, "Download failed: HTTP {d} {s}.", .{ @intFromEnum(status), status.phrase() orelse "" }),
      else => try std.fmt.allocPrint(arena, "Download failed ({s}).", .{@errorName(err)}),
  };
  ```
- **Fix**: Extract this error-to-message mapping into a shared helper in `llm_models.zig` or `models.zig` (e.g. `pub fn downloadErrorMessage(arena, err, status)`).

---

### [medium] Triplicate wire types: `Word` and `Segment` (Lens D)
- **Where**:
  - `src/meeting_store.zig:31-35`
  - `src/models.zig:162-170`
  - `src/whisper_helper.zig:49-51`
- **What goes wrong**: `Word` (`start`, `end`, `text`) and `Segment` (`start`, `end`, `text`, `words`) are independently defined across three files. Changes to timestamp precision or word fields require editing multiple files.
- **Fix**: Retain the canonical definitions in `models.zig` (or `meeting_store.zig`) and import them in `whisper_helper.zig` and other consumers.

---

### [medium] Duplicated child process stderr tail ring-buffers (Lens D)
- **Where**: `src/local_llm.zig:847-874`, `src/models.zig:513-537`
- **What goes wrong**: 25 lines of ring-buffered stderr line streaming (`tail_buf: [2048]u8`, `tail_len`, `tail_mutex`, `std.mem.copyForwards`) are copy-pasted between the LLM runner and Whisper runner.
- **Fix**: Extract a reusable `TailBuffer` or `drainStderr` utility in `core`.

---

### [low] Duplicated `keptName` lookup (Lens D)
- **Where**: `src/meetings.zig:794-797`, `src/speakers.zig:279-282`
- **What goes wrong**: Identical helper searching a `Meeting` struct for a speaker name by ID:
  ```zig
  fn keptName(m: Meeting, id: []const u8) ?[]const u8 {
      for (m.speakers) |sp| if (std.mem.eql(u8, sp.id, id)) return sp.name;
      return null;
  }
  ```
- **Fix**: Move `keptName` to `src/meeting_store.zig` as `pub fn speakerName(self: Meeting, id: []const u8) ?[]const u8`.

---

### [low] Dead public function `embeddingsLoaded` (Lens D)
- **Where**: `src/local_llm.zig:579-581`
- **What goes wrong**: `pub fn embeddingsLoaded() bool` is exported, but is unreferenced anywhere across the entire project and tests.
- **Fix**: Remove the function or make it private if only needed internally.

---

## 3. Cohesion and File Size
5 files exceed 1,000 lines:
1. `src/main.zig` (1,836 lines): Mixes application startup, command line dispatch, window routing, tray icon management, hotkey binding, and UI commands. Should split window routing and IPC commands into `app_commands.zig`.
2. `src/llm_helper.zig` (1,561 lines): Mixes llama.cpp C-API initialization, memory planning ladder, prompt template rendering, sampling loop, and JSON IPC.
3. `src/meetings.zig` (1,514 lines): Mixes audio capture coordination, UI IPC commands, markdown export, and meeting Q&A generation.
4. `src/model_server.zig` (1,353 lines): Mixes HTTP request routing, OpenAI chat format transformation, streaming SSE chunk generation, and tool call handling.
5. `src/pdf.zig` (1,097 lines): Self-contained PDF generator; cohesion is high despite line count.

---

## 4. Proposed `addAtlasStep` Configuration for `build.zig`

```zig
atlas.addAtlasStep(b, .{
    .name = "ghostpen",
    .roots = &.{"src"},
    .layers = &.{
        .{ .name = "app", .paths = &.{"src/main.zig"} },
        .{ .name = "cli", .paths = &.{"src/cli.zig"}, .thin = true },
        .{ .name = "features", .paths = &.{
            "src/captions.zig",
            "src/dictation.zig",
            "src/meetings.zig",
            "src/speakers.zig",
            "src/model_server.zig",
            "src/stt_server.zig",
            "src/updates.zig",
            "src/tts.zig",
            "src/pdf.zig",
            "src/web_page.zig",
            "src/image.zig",
            "src/logs.zig",
            "src/store.zig",
        } },
        .{ .name = "helpers", .paths = &.{"src/llm_helper.zig", "src/whisper_helper.zig"} },
        .{ .name = "core", .paths = &.{
            "src/ai.zig",
            "src/ai_stream.zig",
            "src/ai_observer.zig",
            "src/chat_format.zig",
            "src/local_llm.zig",
            "src/llm_models.zig",
            "src/models.zig",
            "src/settings.zig",
            "src/meeting_store.zig",
            "src/metrics.zig",
            "src/gguf_context.zig",
            "src/voices.zig",
            "src/wav.zig",
        } },
        .{ .name = "tests", .paths = &.{"src/tests.zig"} },
    },
    .forbid = &.{
        .{ .from = "features", .to = "app", .reason = "feature modules must not reach into the app's globals (main.io, main.shared); pass them in" },
        .{ .from = "core", .to = "helpers", .reason = "core must not import a helper process's entry module" },
        .{ .from = "helpers", .to = "features", .reason = "helper processes stay independent of the GUI features" },
        .{ .from = "cli", .to = "features", .reason = "the CLI has no GUI" },
    },
});
```

---

## 5. zigatlas False Positives / Misses

- **False Positive on Parallel Implementations**:
  - `find()` across `src/llm_models.zig:49`, `src/models.zig:55`, `src/speakers.zig:35`. Each function searches a slice of distinct struct types (`llm_models.Entry`, `models.Entry`, `speakers.Entry`). They cannot share a single function without generic comptime abstraction, which would reduce clarity.
  - `path()` in `src/meeting_store.zig:189` and `src/models.zig:79`. Completely unrelated functions that format completely different paths.
  - `load()` in `src/meeting_store.zig:194` and `src/voices.zig:67`. Unrelated loaders.
  - `status()` in `src/llm_models.zig:269` and `src/models.zig:578`. Distinct scans for GGUF vs Whisper models.
- **Miss**:
  - Inconsistency between `main.zig:1525` (`onTrayMenu` calls `captions.open()`) and `main.zig:1549` (`handleArgs` calls `captions.toggle()`).
