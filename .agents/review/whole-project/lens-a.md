# Lens A: Zig Idioms and Correctness Review

**Target**: GhostPen (`src/`, 31 files, 18,728 lines)  
**Zig version**: 0.16.0  
**Status**: 107 tests passing (`zig build test`)

---

## Findings

### [high] Heading text slicing bug with indented markdown headings (Lens A)
- **Where**: `src/pdf.zig:190-195`, `src/pdf.zig:288-296`
- **What goes wrong**: `headingOf(raw)` permits leading indentation:
  ```zig
  var i: usize = 0;
  while (i < raw.len and (raw[i] == ' ' or raw[i] == '\t')) : (i += 1) {}
  if (i >= raw.len or raw[i] != '#') return null;
  var level: usize = 0;
  while (i < raw.len and raw[i] == '#') : (i += 1) level += 1;
  ```
  However, in `blocks()`:
  ```zig
  if (headingOf(raw)) |level| {
      try drop.both(&out, arena, &para, &quote);
      try out.append(arena, .{
          .kind = .heading,
          .level = @min(level, 3),
          .text = try plain(arena, raw[1 + level ..]),
      });
      continue;
  }
  ```
  `raw[1 + level ..]` assumes `#` starts at index 0. If `raw` has leading whitespace (e.g. `"  # Title"` with `i = 2, level = 1`), `1 + level` is 2, producing `raw[2..]` = `" # Title"` (retaining the `#` character as part of the heading text), or if indentation exceeds `1 + level`, it slices inside the leading whitespace or panics with an out-of-bounds slice on short indented lines.
- **Fix**: Return both `level` and the content slice or offset from `headingOf`, or trim leading whitespace / compute `level_end` so that `text = try plain(arena, std.mem.trimStart(u8, raw[i + level ..], " \t"))`.

---

### [medium] Heavy disk I/O and embedding under global mutex blocks live speaker detection (Lens A)
- **Where**: `src/speakers.zig:132-155`, `src/speakers.zig:335-336`
- **What goes wrong**: In `src/speakers.zig:findSpeakers`, `mutex.lockUncancelable(main.io)` is held continuously across the entire loop over all segments of a recorded meeting:
  ```zig
  mutex.lockUncancelable(main.io);
  defer mutex.unlock(main.io);
  const enc = try encoderLocked(model_path, model_id);
  ...
  for (m.segments, 0..) |seg, i| {
      ...
      const samples = try wav.readChannel(main.io, gpa, f, info, channel, from, ...);
      ...
      const e = enc.embed(gpa, samples) catch ...;
      ...
      if (i % 8 == 0) progress(ctx, ...);
  }
  ```
  Meanwhile, `identifyLive()` (called for real-time speech during live captions) attempts a non-blocking lock:
  ```zig
  if (!mutex.tryLock()) return null;
  defer mutex.unlock(main.io);
  ```
  Because `findSpeakers` holds `mutex` during long-running file reading (`wav.readChannel`), feature embedding, and progress callbacks, `identifyLive` fails continuously whenever a meeting is saving, causing live captions to drop all speaker attribution.
- **Fix**: Only hold `mutex` during calls to `encoderLocked` and `enc.embed()`. Perform `wav.readChannel` and progress reporting outside the critical section.

---

### [medium] Detached background threads spawned without lifecycle tracking or join on shutdown (Lens A)
- **Where**: `src/captions.zig:614-620`, `src/dictation.zig:495-497`
- **What goes wrong**: In `captions.toggle()`:
  ```zig
  const t = std.Thread.spawn(.{}, stopAndHide, .{}) catch return;
  t.detach();
  ...
  const t = std.Thread.spawn(.{}, startFromToggle, .{}) catch return;
  t.detach();
  ```
  And in `dictation.toggle()`:
  ```zig
  const t = std.Thread.spawn(.{}, startFromToggle, .{}) catch return;
  t.detach();
  ```
  Spawning detached threads without recording a thread handle or an atomic shutdown token means these threads can continue running during application exit or window destruction, attempting to access freed global state or GUI windows.
- **Fix**: Track the background thread handle in a module-level variable (e.g. `var toggle_thread: ?std.Thread = null`), join any prior thread before spawning a new one or at application shutdown, or coordinate through a message queue/channel.

---

### [low] Potential integer overflow in WAV header frame computation (Lens A)
- **Where**: `src/wav.zig:12-15`
- **What goes wrong**: In `fn header`:
  ```zig
  const block: u32 = @as(u32, channels) * 2;
  const data: u32 = @intCast(@min(frames * block, std.math.maxInt(u32) - 36));
  ```
  If `frames` is large (e.g. from an unvalidated or corrupted file where `frames` is near `maxInt(u64)`), `frames * block` can overflow `u64` before `@min` is applied, causing an arithmetic overflow panic in `Debug` or `ReleaseSafe`.
- **Fix**: Use saturating/checked multiplication:
  ```zig
  const total = std.math.mul(u64, frames, block) catch std.math.maxInt(u64);
  const data: u32 = @intCast(@min(total, std.math.maxInt(u32) - 36));
  ```

---

### [low] Fixed stack buffer with `catch unreachable` in HTML skip tag close matching (Lens A)
- **Where**: `src/web_page.zig:430-432`
- **What goes wrong**:
  ```zig
  var close_buf: [16]u8 = undefined;
  const close = std.fmt.bufPrint(&close_buf, "</{s}", .{name}) catch unreachable;
  ```
  While the current `skip_tags` array members fit in 16 bytes (`</noscript` is 11 bytes), if any tag name >= 14 bytes is added to `skip_tags` or matched from untrusted HTML, `bufPrint` will hit `catch unreachable` and panic in Safe modes.
- **Fix**: Expand buffer size to `[32]u8` and handle errors cleanly instead of `catch unreachable`.

---

## What was checked and found sound
- **Error handling**: Fallible allocations and file I/O operations throughout `ai.zig`, `meeting_store.zig`, `models.zig`, `pdf.zig`, `wav.zig` consistently use `try` or explicit `catch` blocks with error reporting.
- **Ownership & Arenas**: Request-scoped work correctly uses arena allocators with clear lifetime boundaries (`defer arena.deinit()`).
- **Memory safety**: No stack references escaping their scope; `@ptrCast` and `@alignCast` are only used where backed by valid types.
- **Integer conversions**: `@intCast` and `@truncate` are guarded by range checks or `@min`/`@max` clamps in almost all audio and buffer calculations.
- **Parsing robustness**: `chat_format.zig` and `meeting_store.zig` rigorously validate message depths, structure types, and bounds.

## What was not covered
- Platform-specific behavior under Windows/macOS native GUI hooks and audio drivers (testing was conducted on Linux x86_64).
- Internal C logic of `llama.cpp` and `whisper.cpp` upstream libraries.

## zigatlas notes
- zigatlas correctly flagged the `import_cycle` between feature modules and `main.zig`.
- No false positives in Lens A rules.
