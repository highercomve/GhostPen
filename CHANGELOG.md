# Changelog

This changelog follows the repository's release tags. There is no v0.2.1 tag.

## [0.4.2] - 2026-10-26

### Fixed

- Agents on the built-in model (pi, Codex, …) no longer get stuck calling
  the same tool over and over. Their requests sampled almost greedily
  (temperature 0.2, no penalty), which makes a thinking model repeat
  itself; they now sample as Qwen recommends for agents (temperature 0.6,
  top_p 0.95, top_k 20, min_p 0, presence penalty 1.0) unless the request
  sets its own. When an agent still makes the same call and gets the same
  result twice in a row, the model is told so; a third time, it answers
  without tools. A poll whose result changes isn't a repeat.
- A tool result or message carrying the model's control tokens
  (`<|im_end|>`, `<|im_start|>`, …) can no longer close its turn and write
  a fake one (a system prompt, say) for the model: agents' requests are
  neutralized like GhostPen's own prompts.

### Added

- The model service takes `top_p`, `top_k`, `min_p`, `presence_penalty`,
  `frequency_penalty` and `repeat_penalty` on `/v1/chat/completions`.

## [0.4.1] - 2026-10-26

### Fixed

- GhostPen no longer runs out of open files after a few hours of serving
  models. Finding a model in another app's folder (LM Studio, …) left
  directories open on every `/v1/models` call and model lookup, until the
  model runner couldn't start (`ProcessFdQuotaExceeded`) and the app quit
  with "Too many open files".

## [0.4.0] - 2026-10-23

### Added

- **One app window** (Settings → Actions → Window layout): every tool in a
  sidebar instead of a window each, with the hotkey and the tray opening the
  right page there. A window per tool stays the default; captions and
  dictation can still float. Changing it offers **Restart now**.
- **Android** (preview, built with `oriel android build`): the single app
  window, with a top app bar and navigation drawer on phones and a sidebar on
  Chromebooks; Android's back navigation; menus as bottom sheets.
  - The phone's own engines: **Gemini Nano** as an AI profile ("On this
    device"), Android's **speech recognition** for dictation, and its
    **voices** for Read aloud, nothing to download.
  - Meetings record other apps' audio (with the screen-capture consent) or
    the microphone, and play back with seeking.
- Captions as a page keep the whole session as a transcript with times, Copy
  and Clear; Dictation as a page lists this session's dictations.
- Settings → About shows **This build** (versions, system, architecture,
  memory, GPU backend, on-device engines) with **Copy details**; the copy
  and paste diagnostics moved there from Connections.
- Settings → Voices: **Play** a sample of each voice (and the device's).

### Changed

- Saving a meeting downloads the speech model first when it's missing,
  instead of leaving it untranscribed.
- Captions, meetings and dictation ask for the microphone permission before
  they start.
- "Read summary" is now "Read".
- Built on Oriel 0.19.3.

### Fixed

- A desktop without the GlobalShortcuts portal (e.g. ChromeOS's Linux) no
  longer reports every hotkey as failed on each save: Settings explains how
  to bind the commands there instead.

## [0.3.9] - 2026-10-22

### Added

- Record a meeting straight from the Meetings window (**Record meeting** /
  **Stop and save**), without the live captions overlay. Earlier meetings stay
  browsable while one records.
- A **Notes** tab per meeting: your own notebook with Markdown preview,
  saved automatically to `notes.md` and kept when the meeting is reprocessed.
- Meeting **Chat** asks across the transcript, clean text, personal notes,
  summary and earlier questions, shows its progress, and has a "stats for
  nerds" panel (tokens, prefill and generation speed, load and queue time).
- The tray icon shows a red dot while a meeting is recording.
- Summarize files on this machine as well as links: `~/notes.md`, absolute
  and relative paths and `file://` URLs.

### Changed

- The meeting notebook uses the reader's paper-and-ink design.
- The built-in model reuses the meeting it has already read for follow-up
  questions, including recurrent/hybrid models (one bounded snapshot), so
  later answers start sooner.

### Fixed

- When the GPU fails, its error is kept for the message and the CPU fallback
  instead of being buried under later warnings.

## [0.3.8] - 2026-10-20

### Added

- Export link summaries as PDF or Markdown from the reader toolbar.
- Render Mermaid diagrams in the reader and embed them in PDF exports.

### Fixed

- Large PDF diagrams retain readable labels across overlapping panels instead
  of shrinking to fit a single page. Short horizontal panels share a page.
- Keep headings with their diagrams, including nearly page-high drawings.
- Invalid Mermaid keeps readable source without leaving error graphics behind.
- Recognize tilde fences, repeated diagrams, and Windows line endings during
  export; clean up temporary rendering elements after failures.

## [0.3.7] - 2026-10-20

### Changed

- Model service: chat requests go through the model's own chat template, as
  llama-server serves them: the messages with their tool calls and results,
  and the tools, in the format the model was trained on, sampled with the
  template's tool-call grammar and parsed back into content, reasoning and
  tool calls. Agents (pi, Codex, OpenCode) call tools instead of announcing
  them, and long agent sessions are no longer folded into one turn or capped
  at 240 KB. Requests with an image keep the vision path.
- Model service: other apps' chat requests think by default, and the reasoning
  comes back as `reasoning_content` (streamed too). `reasoning_effort: "none"`,
  `enable_thinking: false` or `think: false` turn it off. GhostPen's own
  features are unchanged.

## [0.3.6] - 2026-10-20

### Fixed

- Link summaries keep exposed model thinking separate from the answer while
  streaming, after reopening, and when cancelled. Copy and Read summary use
  only the answer.
- Corrected the Gemma 4 E4B prompt to prevent unwanted thinking when it is
  disabled, and clarified the summary format so section headings stay outside
  bullet lists.
- Summary text updates during continuous generation instead of waiting for
  the model to pause.

### Changed

- Added a Show thinking switch matching the reader design. It reveals received
  thinking and requests it for the next summary; the choice is remembered.
- Thinking channels are normalized in the backend from provider fields,
  explicit markers, and local template metadata, with bounded processing.

## [0.3.5] - 2026-10-19

### Changed

- The macOS tray icon is the GhostPen mark as a monochrome template image:
  the menu bar recolours it for light and dark mode itself, instead of a
  coloured icon that reads as a blob (Oriel 0.18.1's `.template_png`).

## [0.3.4] - 2026-10-16

### Fixed

- Malformed WAV chunk sizes and unsupported channel counts no longer overflow
  or stall the meeting reader; invalid channel selections are rejected.
- Meeting jobs release partial allocations and roll back if a worker cannot
  start. Failed saves show an error and can be retried with Transcribe again;
  questions and reprocessing report queue failures.
- The local model helper releases its saved-plan parsing allocations,
  threadpool, control-text list, token cache and command-line strings.
- Transcription server startup releases its bind address on failure; audio
  monitor selection stops at the first matching source.

### Changed

- Meeting playback updates the interface when the displayed position, clock,
  line or word changes, and keeps a stable keyboard listener.
- The dictation waveform stops requesting animation frames once it is flat,
  and resumes when its phase changes.

## [0.3.3] - 2026-10-15

### Changed

- Meeting question suggestions now cover action items, decisions, key
  takeaways, unresolved questions and follow-up messages for every meeting,
  with a generic question placeholder instead of speaker-specific examples.

### Fixed

- Deleting a saved meeting answer now removes it from the meeting.
- The local installer opens Settings after restarting GhostPen, accepts
  window arguments such as `--meetings`, and checks that the launched
  process stays running before reporting success.

## [0.3.2] - 2026-10-15

### Added

- **Meeting summaries.** The Meetings window's **Summary** tab writes an
  overview, key points, decisions, action items and open questions with
  your AI profile, saved with the meeting and as `summary.md`. A long
  meeting (an hour or more) is read in parts and then summarized as a
  whole, sized to the model's context. Settings → Speech → Meetings can
  summarize every meeting when it's saved.
- **Questions about a meeting.** Ask anything ("What did Alex say about
  me?") under the summary: the answer cites the times it comes from, is
  saved with the meeting (and in `summary.md`), and can be copied, edited
  and asked again, or deleted. "Me" means your own speaker; suggestions
  come from the speakers' names.
- **Read aloud** for the summary and every answer, through the built-in
  voice (as the link summary).

## [0.3.1] - 2026-10-15

The first release with meetings (0.3.0 was tagged but never published).

### Added

- **Meetings.** Turn on **🎙 Meeting** in the captions bar and Start: the
  captions also record what your computer plays and your microphone
  ("Me"). Stop saves the meeting in `Documents/GhostPen/Meetings/` (the
  localized Documents folder on Linux): the whole audio is transcribed
  again with word timings, the speakers are told apart by voice, your AI
  profile proofreads it into a clean text and gives it a title, and a
  notification says it's saved. Each meeting folder holds `audio.wav`,
  `meeting.json`, `transcript.md` and `final.md`.
- **The Meetings window** (tray → Meetings): search the meetings, play one
  with the word being said highlighted, click a line to play from it,
  rename and merge speakers, move a line to another speaker, edit lines,
  copy as text, Markdown or subtitles, proofread or find the speakers
  again, open the folder, delete (also from a right-click on the list).
- **Speakers by voice** (Oriel's `oriel.speakers`, the WeSpeaker ResNet34
  model, 26 MB, downloaded the first time): live labels in the captions,
  one line per speaker, and on save the whole meeting. Name a speaker and
  pick **Remember this voice**: later meetings name them by themselves.
- Settings → Speech → Meetings: meeting mode by default, the microphone,
  the proofread, speakers by voice, live labels, how many people there
  are, the speaker model and the folder.

### Fixed

- Through speakers instead of a headset the microphone hears the call:
  those lines are recognized as the others' (the same words at the same
  moment) and dropped, live and in the saved transcript.
- The Windows build compiles again: 0.2.25's didn't, and that release was
  never published, so its live-captions fix ("Auto" follows the current
  output) reaches every platform with this one.
- Non-streamed answers from an OpenAI-compatible endpoint shorter than
  4 KiB came back as "Parse error" (dictation's proofread through Ollama,
  among others): the response was never flushed out of its buffer.

### Changed

- Built on Oriel 0.17.0.
- Every captions Start begins with an empty overlay.

## [0.2.25] - 2026-10-14

### Fixed

- Live captions on "Auto" follow the system's *current* output, so they keep
  working the moment a Bluetooth headset pairs and the machine starts playing
  through it. On Linux the capture opens the monitor of the default sink
  (`pactl get-default-sink`, as the Rust GhostPen resolved it); on Windows the
  default output's WASAPI loopback. The first-monitor pick before it stayed on
  whatever monitor was listed first — often a silent virtual loopback — while
  the audio moved to another sink. An explicit Capture device picks a monitor
  of the same device you chose, so "OpenFit 2+ by Shokz" doesn't grab the
  headset's microphone before its playback monitor when you pick it by name.

## [0.2.24] - 2026-10-13

### Changed

- Built on Oriel 0.12.1, which keeps one API per feature (GhostPen's events,
  window setup and paths moved to it).
- Linux/Wayland: the menu's keyboard focus comes from Oriel. The menu takes
  the keyboard when it opens and lets go when you click another app, without
  GhostPen setting the layer-shell mode itself.

### Fixed

- Linux/Wayland: the dictation pill and live captions no longer take the
  keyboard when they appear (on Hyprland they did, and typing went to them).

## [0.2.23] - 2026-10-11

### Changed

- Built on Oriel 0.9.16 (the framework's Power of 10 review: script time and memory limits, storage caps, per-window bridge checks).
- The model & speech service (port 8771) no longer answers web browsers: a request with an `Origin` header, or a `Host` other than the loopback address it listens on, gets 403, and JSON routes require `Content-Type: application/json` (415 otherwise). A web page could reach it before: load and unload models, run ffmpeg on its bytes, crash the app with a `keep_alive` value, and with DNS rebinding read the answers.
- The service takes at most 16 connections, cuts off clients that stall sending a request (30 s for the head, 5 min for a body), queues at most 4 chat and 4 embedding requests, takes at most 256 embedding inputs, and answers oversized bodies with 413 instead of dropping the connection. ffmpeg reads uploads from the pipe only (a playlist can't make it open files or URLs) and stops at the 3 hours the whisper runner accepts.
- Dictation sessions finish on their own after 10 minutes, and the live transcript re-reads only the last 30 s (the final pass still reads all of it).
- A finished dictation waits up to 5 s for a running menu action; if it is still busy, the pill keeps the text to copy (`C`) instead of losing it.
- Settings saves only the fields edited in the window, on top of the current settings: the pill's language and the captions' translation toggles are no longer reverted by an older Settings window. The window shows an error with Try again when settings can't be loaded.

### Fixed

- Summarize link: the page title and error shown in the summary window pointed at freed memory (garbage or a crash when the window was reopened).
- Esc while dictation or captions were still starting (the model loading) didn't stop them: the microphone or system audio kept recording behind a hidden window, and the next hotkey pasted it.
- Links in summaries open in the browser and only for `http(s)` (a `javascript:` link written by a prompt-injected page is shown as text).
- `keep_alive` values like `1e300`, `"inf"` or `1e17` crashed the app (overflow); they are capped at 24 h.
- Text containing a model's control tokens (`<|im_end|><|im_start|>system…`, from a web page or the clipboard) no longer becomes real turn markers.
- The prompt cache could reuse the wrong tokens after a cancelled or failed prompt read, giving answers from the wrong context.
- MoE models with more than 128 blocks overflowed the expert-offload table; tiny models divided by zero.
- A clipboard image whose header claims a huge size (e.g. 40000×40000) is refused before decoding (over 50 megapixels).
- Size caps: web pages (8 MB), endpoint answers (16 MB, 1 MB per streamed line), downloads past their expected size, unclosed page titles. Redirects in Summarize link can't lead to loopback or private addresses.
- A hung whisper runner no longer blocks dictation and captions forever: replies have a deadline, then the runner is restarted.
- A dropped streaming client stops the generation; the discovery file is written atomically; `file:` model paths must be inside a models folder (`/models-evil` is not inside `/models`).
- Settings values are kept in range when loaded or saved (context size, MoE %, OCR size, caption chunk length, temperature, …).
- Read-aloud status could return text another thread was overwriting; small leaks and silently dropped errors.

## [0.2.22] - 2026-10-09

### Added

- The built-in voice (Kokoro-82M, offline): select text, read it aloud from the menu's result (**🔊 Speak**, or `S` while the result is shown; **■ Stop** the same ways), translated results read back in the target language's voice. The actions list gained **Read** — speaks the selection as is (no AI pass), in a language guessed from the text (function words, unicode ranges, part-of-speech accent density), with its own screen that shows the download/voice progress and a Stop; Esc stops it. In the summary window, **Read summary** and **Read page**. Where supported it runs on the GPU like the chat models (`-Dvulkan`/`-Dcuda` builds); snd: sound output comes with it in-process. First use downloads the voice model (~135 MB, SHA-256 verified) and a 511 KB voice pack for the text's language (14 curated, one label each; the model catalog has two quantizations). `ghostpen --say "text" [--lang es] [--voice ef_dora]` speaks from a terminal.
- Settings → Voices: download and delete the voice model and voice packs, with progress bars, where the voice runs (CPU or GPU), and the phoneme-data row telling where its pronunciation rules came from.
- Oriel 0.9.5 carries the engine: `-Dkokoro` compiles [kokoro.cpp](https://github.com/simonfxr/kokoro.cpp) (vanilla ggml), espeak-ng for phonemization, Highway SIMD and an in-app miniaudio playback into the app, exposed as `oriel.kokoro` and `oriel.audio_play`; `AppOptions.include_paths` forwards C include dirs to an app's own root module.

### Changed

- Built on Oriel 0.9.11. Text to speech now uses `oriel.tts`: synthesis on the GPU where available (`-Dvulkan`/`-Dcuda` builds), the espeak-ng phoneme data bundled with GhostPen so read-aloud works without a system espeak-ng, and faster first audio (the text streams in chunks sized to the device, `warmUp` loads the voice when the summary window or a result with Speak opens). Voices downloaded by earlier builds are kept.
- Oriel 0.9.8: the framework's memory-safety release (use-after-free, out-of-bounds, overflow and leak fixes across the platform layers, modules and native UI; size-checked update-manifest signatures and keys).
- The Linux, Windows and macOS binaries that read text aloud link espeak-ng, which is **GPL-3.0-or-later**: the GhostPen application code stays MIT, and where the operating system's espeak-ng data is reused the model files stay as they are (Apache-2.0 Kokoro voices, GPL-3 espeak-ng data). The GPL applies to the shipped binary that links espeak-ng; every other part of GhostPen keeps the MIT notice.

- Shown results (Shift+action, or Settings → show) can now be pasted after reading: a Paste button (or Enter) sends the result to the clipboard and the app underneath; Copy keeps it on the clipboard only. Enter no longer needs Shift at run time — run an action with Shift to preview, decide later.
- The result view reads better on long texts: the output fills the menu height with its own scrolling (the buttons stay visible), larger text and line height, selectable and with a thin scrollbar.

## [0.2.21] - 2026-10-06

### Changed

- Redesigned Summary as a reader with warm paper and dark green themes, clearer typography, and a link form that collapses once the summary is ready.
- Added saved reading preferences: 14–24px font sizes, serif or sans-serif text, relaxed or compact line spacing, and a reset control.
- Refined the empty, loading, and error states and added a Stop button while summarizing.

### Fixed

- The menu, Settings, Playground, and Summary headers can be dragged to move their windows.
- Wayland menu and dictation overlays use on-demand keyboard focus so other applications remain usable while the overlays are open.
- Restored the Windows installer upload and updater payload in the release workflow.

## [0.2.20] - 2026-10-05

### Added

- The link summarizer: paste a URL in the summary window and GhostPen fetches the page, extracts the readable text (no headless browser) and streams the summary as Markdown with the active AI profile.
- Three summary depths in the summary window's picker: Brief (a TL;DR paragraph plus a few key points), Standard, and Detailed (fuller sections, more quotes, the document's numbers kept).
- The model service's `GET /metrics`: the built-in model's requests, tokens and wall-clock of prompt and generation, tokens/s of the totals, and the last request and the one running now. Chat completions honor `stream_options.include_usage`.
- The built-in runner remembers the split that loaded (`~/.config/ghostpen/llm-plans.json`) and reuses it across restarts; forgotten when the machine's memory changed underneath (the load fails).
- `-Dnative_ui` (experimental, Linux): the windows drawn with native GTK widgets instead of a WebView, through Oriel's native renderer; `NATIVE_UI=1 scripts/install-local.sh` builds it. Needs an Oriel with the native renderer's fixes (main after v0.7.0).

### Fixed

- The built-in model loaded, then the runner died: saving the remembered plan crashed it on every successful GPU load ("integer does not fit in destination type"). Flash attention's "auto" is the enum's -1, which `@intCast` to an unsigned type refuses.
- The summary's text column is centered in the window instead of hugging the left edge.
- Settings → Built-in models reads the models' trained context from the GGUF header directly, without loading a model.
- The menu window is transparent: only its rounded panel is drawn, so the corners show what's behind it.

### Build

- Oriel v0.9.2.

## [0.2.19] - 2026-10-01

### Added

- Settings → Model & speech service: a context window for other apps' chat requests, or the same as the built-in models (the default). Apps can still ask for more per request, up to the model's maximum.
- The log records which action each menu request ran.

### Fixed

- Built-in models no longer answer a request with the previous one in mind. With hybrid models such as Qwen3.5, the state of the last request carried over: Casual after Translate rewrote the text in the translation's language and added a note about translating it.
- Translate no longer adds notes of its own ("Nota: …"); notes that are part of the text are translated with the rest.

### Build

- Oriel v0.7.0.

## [0.2.18] - 2026-09-30

### Changed

- Reorganized Settings into focused AI profile, built-in models, actions, speech, connections, and about sections.
- Made the active AI profile and provider choice clearer, with built-in model downloads in their own section.
- Clarified which model choices apply immediately and which settings need to be saved.
- Improved narrow-window navigation and simplified the model descriptions.

### Fixed

- Settings now show unsaved changes and explicitly discard them when closing without saving.
- Optional image text extraction settings stay collapsed until needed.

### Build

- Added `NO_VULKAN=1` to `scripts/install-local.sh` for local CUDA installs when the Vulkan shader build stalls. The default install still includes Vulkan.

## [0.2.17] - 2026-09-29

- Rebuilt the website homepage with larger text and clearer download choices.
- Made the website's download picker read a cached release manifest.
- Updated the Oriel dependency to v0.6.22.

## [0.2.16] - 2026-09-29

- Sped up the built-in model runner with Oriel v0.6.21 and its updated llama.cpp.

## [0.2.15] - 2026-09-29

- Made the model service answer POST requests without a body promptly.
- Removed the model-service discovery file when Windows logs off.
- Updated the Oriel dependency to v0.6.20.

## [0.2.14] - 2026-09-28

- Added a local model service so other applications can use GhostPen's built-in models.
- Added JSON-schema responses, embeddings, OpenAI tool calls, per-request context sizes, KV cache types, and flash attention to the model runner.
- Loaded service models only when needed and allowed them to be unloaded on request.
- Updated the Oriel dependency to v0.6.19.

## [0.2.13] - 2026-09-28

- Updated to Oriel v0.6.18 so the process keeps its GhostPen name on Wayland.

## [0.2.12] - 2026-09-28

- Updated to Oriel v0.6.17 so GhostPen can run on Linux systems without gtk4-layer-shell.
- Documented Linux's minimum GTK and WebKitGTK versions.

## [0.2.11] - 2026-09-28

- Unloaded a built-in model immediately when switching to an external endpoint.
- Made Whisper fall back to the CPU when GPU memory is full.
- Added `scripts/install-local.sh` to build and install a CUDA AppImage, with a CUDA library cache per Oriel version.
- Updated the Oriel dependency to v0.6.16.

## [0.2.10] - 2026-09-28

- Created secondary windows only when opened and split their frontend pages into separate bundles.
- Moved Whisper into a helper process started on first use.
- Generated TypeScript command bindings from Zig declarations and warmed up Metal after an update.
- Updated the Oriel dependency to v0.6.14.

## [0.2.9] - 2026-09-27

- Displayed readable audio-device names instead of Windows endpoint IDs.
- Added voice activity detection so Whisper processes speech rather than silence.
- Made recent captions roll into a multiline paragraph.
- Made captions and dictation overlays draggable and kept their positions when shown again.
- Updated the Oriel dependency to v0.6.13.

## [0.2.8] - 2026-09-27

- Added a choice to show action results instead of pasting them, including a Shift shortcut.
- Added paste-at-cursor after dictation, with an option to copy only.
- Added speech-model download, pause/resume, selection, and deletion in Settings, including models already installed by GhostReel.
- Added larger Whisper models and CPU fallback when a GPU buffer cannot be allocated.
- Fixed memory-safety and lifecycle issues in updates, transcription, built-in models, and image projectors.
- Updated the Oriel dependency to v0.6.11.

## [0.2.7] - 2026-09-26

- Let built-in vision models extract text from images using their image projectors.
- Stopped treating binary clipboard data offered as text as a text selection.
- Updated the Oriel dependency to v0.6.10.

## [0.2.6] - 2026-09-26

- Enabled Vulkan GPU acceleration for the Windows release.
- Signed macOS builds with GhostPen's certificate so app permissions survive updates.
- Added an MIT license, WinGet package metadata, and a workflow to submit Windows releases.
- Cached the CUDA library in CI when its build inputs are unchanged.
- Updated the Oriel dependency to v0.6.7.

## [0.2.5] - 2026-09-26

- Added Linux CUDA packages for NVIDIA GPUs, with Vulkan as a fallback.
- Updated the download guide to explain GPU support for each Linux package.

## [0.2.4] - 2026-09-26

- Enabled Vulkan GPU acceleration for Whisper and built-in models in Linux releases.

## [0.2.3] - 2026-09-26

- Added an OpenAI-compatible speech-to-text server for other local tools.
- Added version information, update checks, and signed automatic in-app updates to Settings.

## [0.2.2] - 2026-09-26

- Renamed the executable to `ghostpen` and made the packages replace the earlier Tauri package.
- Made release builds portable with Oriel v0.6.2.
- Documented how to open the unnotarized macOS app.

## [0.2.0] - 2026-09-26

- Introduced the GhostPen port to Oriel, including migration of settings from the Tauri app.
- Added the action menu, global shortcuts, tray, AI text actions, streaming Playground, image text extraction, and clipboard restoration.
- Added live captions and dictation using local Whisper models, plus audio and end-to-end tests.
- Added built-in GGUF models with CPU fallback and the `ghostpen-cli` command-line tool.
- Added Linux layer-shell overlays, platform permissions, the website, and release packages on Oriel v0.6.0.

[0.2.22]: https://github.com/highercomve/GhostPen/compare/v0.2.21...v0.2.22
[0.2.21]: https://github.com/highercomve/GhostPen/compare/v0.2.20...v0.2.21
[0.2.20]: https://github.com/highercomve/GhostPen/compare/v0.2.19...v0.2.20
[0.2.19]: https://github.com/highercomve/GhostPen/compare/v0.2.18...v0.2.19
[0.2.18]: https://github.com/highercomve/GhostPen/compare/v0.2.17...v0.2.18
[0.2.17]: https://github.com/highercomve/GhostPen/compare/v0.2.16...v0.2.17
[0.2.16]: https://github.com/highercomve/GhostPen/compare/v0.2.15...v0.2.16
[0.2.15]: https://github.com/highercomve/GhostPen/compare/v0.2.14...v0.2.15
[0.2.14]: https://github.com/highercomve/GhostPen/compare/v0.2.13...v0.2.14
[0.2.13]: https://github.com/highercomve/GhostPen/compare/v0.2.12...v0.2.13
[0.2.12]: https://github.com/highercomve/GhostPen/compare/v0.2.11...v0.2.12
[0.2.11]: https://github.com/highercomve/GhostPen/compare/v0.2.10...v0.2.11
[0.2.10]: https://github.com/highercomve/GhostPen/compare/v0.2.9...v0.2.10
[0.2.9]: https://github.com/highercomve/GhostPen/compare/v0.2.8...v0.2.9
[0.2.8]: https://github.com/highercomve/GhostPen/compare/v0.2.7...v0.2.8
[0.2.7]: https://github.com/highercomve/GhostPen/compare/v0.2.6...v0.2.7
[0.2.6]: https://github.com/highercomve/GhostPen/compare/v0.2.5...v0.2.6
[0.2.5]: https://github.com/highercomve/GhostPen/compare/v0.2.4...v0.2.5
[0.2.4]: https://github.com/highercomve/GhostPen/compare/v0.2.3...v0.2.4
[0.2.3]: https://github.com/highercomve/GhostPen/compare/v0.2.2...v0.2.3
[0.2.2]: https://github.com/highercomve/GhostPen/compare/v0.2.0...v0.2.2
[0.2.0]: https://github.com/highercomve/GhostPen/releases/tag/v0.2.0
