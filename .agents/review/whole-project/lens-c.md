# Lens C: Power of 10 Review

**Target**: GhostPen (`src/`, 31 files, 18,728 lines)  
**Zig version**: 0.16.0  
**Status**: 107 tests passing (`zig build test`), 1 file needs formatting (`zig fmt --check src/*.zig`)

---

## Findings

### [medium] Extreme function complexity and length in core runners and CLI (Lens C - Rule 4)
- **Where**:
  - `src/local_llm.zig:219-469` (`chatImpl`): 251 lines, complexity 71, nesting 4, 9 parameters.
  - `src/llm_helper.zig:198-395` (`main`): 198 lines, complexity 78, nesting 3.
  - `src/cli.zig:50-218` (`main`): 169 lines, complexity 58, nesting 3.
  - `src/speakers.zig:110-234` (`findSpeakers`): 125 lines, complexity 44, nesting 3, 7 parameters.
  - `src/web_page.zig:384-493` (`extract`): 110 lines, complexity 47, nesting 3.
- **What goes wrong**: These monolithic functions combine command dispatch, state machine decoding, argument validation, child process communication, signal handling, and output stream formatting into single massive blocks. This makes auditability, regression isolation, and unit testing difficult.
- **Fix**:
  - In `src/local_llm.zig`: Extract payload preparation, line-by-line response parsing, and error diagnostics into separate helper functions.
  - In `src/cli.zig:main`: Split the command-handling switch cases into dedicated sub-command handlers (`cmdRun`, `cmdModels`, `cmdStatus`).
  - In `src/llm_helper.zig:main`: Factor IPC loop dispatch into command-specific runner functions.
  - In `src/speakers.zig:findSpeakers`: Separate audio window extraction from clustering and speaker labeling.

---

### [low] Excessive parameter lists on download and streaming functions (Lens C - Rule 4)
- **Where**:
  - `src/llm_models.zig:424-530` (`fetchFile`): 13 parameters.
  - `src/llm_models.zig:402-421` (`downloadFile`): 12 parameters.
  - `src/ai.zig:185-246` (`exchange`): 9 parameters.
  - `src/local_llm.zig:219-469` (`chatImpl`): 9 parameters.
  - `src/model_server.zig:836-912` (`streamChat`): 8 parameters.
  - `src/model_server.zig:986-1030` (`toolReply`): 8 parameters.
- **What goes wrong**: Passing 8 to 13 positional arguments increases call-site fragility, makes parameter swapping undetectable if types match (`[]const u8`), and clutters public interfaces.
- **Fix**: Bundle related parameters into dedicated options structs (e.g. `DownloadOptions`, `ChatOptions`, `HttpExchangeOptions`).

---

### [low] Formatting violation in `src/web_page.zig` (Lens C - Rule 10)
- **Where**: `src/web_page.zig:701-705`, `src/web_page.zig:725-726`
- **What goes wrong**: Running `zig fmt --check src/*.zig` fails with code 1 due to multiline string indentation in unit tests within `src/web_page.zig`.
- **Fix**: Format `src/web_page.zig` using `zig fmt src/web_page.zig`.

---

## What was checked and found sound
- **Rule 1 (Control flow)**: No recursion without static bounds; tree walks and document parsing (`pdf.zig`, `web_page.zig`) use bounded iterative loops.
- **Rule 2 (Loop bounds)**: Token generation budgets (`generated < budget`), streaming timeouts, and line limits prevent infinite loops.
- **Rule 3 (Bounded allocation)**: Input buffers from external sources (web pages, audio frames, HTTP bodies) are capped (`max_html_bytes = 2 * 1024 * 1024`, `max_samples = 3 * 60 * 60 * sample_rate`).
- **Rule 5 (Invariants at boundaries)**: Strong validation on external inputs (`meeting_store.zig:check` validates 15+ structural invariants; `chat_format.zig:neutralizeRequest` guards against prompt injection / control token smuggling).
- **Rule 6 (Data scoping)**: Local variables are tightly scoped within blocks; constants are marked `const`.
- **Rule 7 (Return values)**: Return values are checked across all modules; fallible calls are propagated with `try`.
- **Rule 8 (Comptime simplicity)**: Comptime is restricted to simple type introspection, progress reporting closures, and enum stringification.
- **Rule 9 (Pointer safety)**: Clean pointer discipline without arbitrary raw arithmetic.
- **Rule 10 (Builds & Tests)**: `zig build test` passes with 107 tests; builds clean in `ReleaseSafe`.

## What was not covered
- Performance profiling of AST parsing in `web_page.extract` under multi-megabyte HTML files.

## zigatlas false positives / misses
- **False Positive on Complexity**: `src/meeting_store.zig:604` (`check`, complexity 40). This function is purely an input validation routine checking array lengths, string sizes, float finiteness, and ID uniqueness. High complexity here is a direct consequence of implementing Power of 10 Rule 5 ("Invariants asserted at trust boundaries"). Breaking this single validator into tiny functions would obscure the validation checklist.
- **Miss**: zigatlas does not flag `zig fmt --check` failures.
