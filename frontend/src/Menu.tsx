import { useEffect, useState, useCallback, useMemo, useRef } from "react";
import { listen } from "./events";
import LevelBar from "./LevelBar";
import { Icon, IconName } from "./icons";
import {
  Status,
  ProcessResult,
  CustomAction,
  Level,
  LEVELS,
  SelectionInfo,
  getStatus,
  getSettings,
  getSelection,
  extractImageText,
  copyText,
  pasteResult,
  ttsSpeak,
  ttsStop,
  TtsState,
  ttsState,
  ttsWarmUp,
  listenVoice,
  processAiAction,
  processAiCustom,
  dismissMenu,
  PASTE_KEYS,
  cancelAi,
  openSettings,
  openPlayground,
  TRANSLATE_LANGUAGES,
} from "./api";

type View =
  | { kind: "menu" }
  | { kind: "translate" }
  | { kind: "loading"; label: string }
  | { kind: "result"; result: ProcessResult }
  | { kind: "reading" }
  | { kind: "error"; message: string };

const ACTIONS: { id: string; label: string; hint: string; icon: IconName }[] = [
  { id: "proofread", label: "Proofread", hint: "Fix spelling & grammar", icon: "proofread" },
  { id: "professional", label: "Professional", hint: "Rewrite polished & clear", icon: "professional" },
  { id: "casual", label: "Casual", hint: "Friendly, conversational", icon: "casual" },
  { id: "concise", label: "Concise", hint: "Condense, keep meaning", icon: "concise" },
  { id: "expand", label: "Expand", hint: "Add detail & elaborate", icon: "expand" },
  { id: "__read", label: "Read", hint: "This text, out loud", icon: "read" },
];

/** What a menu action is doing (ghostpen://ai-progress from the backend). */
interface AiProgress {
  stage: "loading" | "reading" | "writing" | "waiting";
  model: string;
  tokens: number;
  tok_s: number;
}

function progressText(p: AiProgress | null): string {
  if (!p) return "Starting…";
  switch (p.stage) {
    case "loading":
      return `Loading ${p.model} into memory…`;
    case "reading":
      return `${p.model} is reading your text…`;
    case "writing":
      return `Writing · ${p.tokens} tokens${p.tok_s > 0 ? ` · ${p.tok_s.toFixed(0)} tok/s` : ""}`;
    case "waiting":
      return `Waiting for ${p.model}…`;
  }
}

// Cycle the intensity level by `dir` (+1 / -1), clamped (no wrap).
function shiftLevel(level: Level, dir: number): Level {
  const i = LEVELS.indexOf(level);
  return LEVELS[Math.min(LEVELS.length - 1, Math.max(0, i + dir))];
}

// True when a keyboard event originates from a text field — so global menu shortcuts
// (arrows, Enter, 1–9, j/k/h/l) don't fire while the user is typing in the prompt bar.
function isTypingTarget(t: EventTarget | null): boolean {
  return t instanceof HTMLElement && (t.tagName === "INPUT" || t.tagName === "TEXTAREA");
}

function isTextSelection(s: SelectionInfo): s is { kind: "text"; text: string } {
  return s.kind === "text";
}

function isImageSelection(s: SelectionInfo): s is { kind: "image"; preview: string; width: number; height: number } {
  return s.kind === "image";
}

function isEmptySelection(s: SelectionInfo): s is { kind: "empty" } {
  return s.kind === "empty";
}

export default function Menu() {
  const [status, setStatus] = useState<Status | null>(null);
  const [selection, setSelection] = useState<SelectionInfo>({ kind: "empty" });
  const [customActions, setCustomActions] = useState<CustomAction[]>([]);
  const [level, setLevel] = useState<Level>("balanced");
  const [view, setView] = useState<View>({ kind: "menu" });
  // While an action runs: what the model is doing, and for how long.
  const [progress, setProgress] = useState<AiProgress | null>(null);
  const [elapsedMs, setElapsedMs] = useState(0);
  // Listening all along: the first event can come before the loading view's
  // effects run (it's reset when an action starts).
  useEffect(() => {
    const unlisten = listen<AiProgress>("ghostpen://ai-progress", (e) => setProgress(e.payload));
    return () => {
      unlisten.then((f) => f());
    };
  }, []);
  useEffect(() => {
    if (view.kind !== "loading") return;
    setElapsedMs(0);
    const start = performance.now();
    const timer = window.setInterval(() => setElapsedMs(performance.now() - start), 100);
    return () => window.clearInterval(timer);
  }, [view.kind]);
  // Keyboard cursor: index into `menuItems` (menu view) and into the language grid (translate view).
  const [cursor, setCursor] = useState(0);
  const [langCursor, setLangCursor] = useState(0);
  // Freeform instruction typed in the prompt bar.
  const [prompt, setPrompt] = useState("");
  // Transient "Copied ✓" feedback after copying the whole selection to the clipboard.
  const [copied, setCopied] = useState(false);

  const refresh = useCallback(async () => {
    try {
      setStatus(await getStatus());
    } catch {
      /* ignore */
    }
    try {
      const settings = await getSettings();
      setCustomActions(settings.customActions ?? []);
    } catch {
      /* ignore */
    }
    try {
      setSelection(await getSelection());
    } catch {
      setSelection({ kind: "empty" });
    }
  }, []);

  // Whether Shift is down (keys and clicks): Shift+action shows the result.
  const shiftHeld = useRef(false);
  // The language the shown result came from (looks up the read-aloud's voice).
  const resultVoiceLang = useRef<string>("");
  useEffect(() => {
    const track = (e: KeyboardEvent | MouseEvent) => {
      shiftHeld.current = e.shiftKey;
    };
    window.addEventListener("keydown", track, true);
    window.addEventListener("keyup", track, true);
    window.addEventListener("mousedown", track, true);
    return () => {
      window.removeEventListener("keydown", track, true);
      window.removeEventListener("keyup", track, true);
      window.removeEventListener("mousedown", track, true);
    };
  }, []);

  const run = useCallback(
    async (action: string, targetLang: string | null, label: string) => {
      setProgress(null);
      setView({ kind: "loading", label });
      try {
        // Shift held (key or click): show the result here instead of pasting.
        const result = await processAiAction(action, targetLang, level, shiftHeld.current);
        if (targetLang) resultVoiceLang.current = targetLang; else resultVoiceLang.current = "";
        setView({ kind: "result", result });
      } catch (e) {
        setView({ kind: "error", message: String(e) });
      }
    },
    [level],
  );

  const empty = isEmptySelection(selection) || (isTextSelection(selection) && selection.text.trim().length === 0);

  // Run the freeform instruction from the prompt bar over the current selection.
  const runCustom = useCallback(async () => {
    const instruction = prompt.trim();
    if (!instruction || empty) return;
    setProgress(null);
      setView({ kind: "loading", label: instruction });
    try {
      const result = await processAiCustom(instruction, shiftHeld.current);
      setPrompt("");
      setView({ kind: "result", result });
    } catch (e) {
      setView({ kind: "error", message: String(e) });
    }
  }, [prompt, empty]);

  const doExtractText = useCallback(async () => {
    if (!isImageSelection(selection)) return;
    setProgress(null);
      setView({ kind: "loading", label: "Extracting text" });
    try {
      const text = await extractImageText();
      setCopied(false);
      setSelection({ kind: "text", text });
      setView({ kind: "menu" });
    } catch (e) {
      setView({ kind: "error", message: String(e) });
    }
  }, [selection]);

  // Copy the entire current text selection to the clipboard, with transient feedback.
  // Bound to Ctrl/Cmd+C in the menu view — the quick way to grab freshly-extracted text.
  const copyFull = useCallback(async () => {
    if (!isTextSelection(selection) || !selection.text.trim()) return;
    try {
      await copyText(selection.text);
      setCopied(true);
      window.setTimeout(() => setCopied(false), 1600);
    } catch {
      /* ignore */
    }
  }, [selection]);

  // Paste a result that was shown (Shift+action, or the show setting): copy it to the
  // clipboard and send Ctrl+V to the app underneath — the deliver flow a normal action runs.
  const pasteShown = useCallback(async (output: string) => {
    try {
      await pasteResult(output);
      setView({ kind: "menu" });
    } catch (e) {
      setView({ kind: "error", message: String(e) });
    }
  }, []);

  // The built-in voice: its state lands here while the window is open.
  const [voiceState, setVoiceState] = useState<TtsState>({ phase: "idle", message: "", progress: 0, voice: "" });
  const voiceRevision = useRef(0);
  useEffect(() => {
    const revision = voiceRevision.current;
    ttsState().then((s) => { if (voiceRevision.current === revision) setVoiceState(s); }).catch(() => {});
    const un = listenVoice((v) => {
      voiceRevision.current += 1;
      setVoiceState(v);
    });
    return () => {
      un.then((f) => f());
    };
  }, []);
  // Read the shown result through the built-in voice; `s` toggles stop/start.
  const speakResult = useCallback(async (output: string) => {
    try {
      if (voiceState.phase === "playing" || voiceState.phase === "generating" || voiceState.phase === "downloading") {
        await ttsStop();
      } else if (voiceState.phase === "idle") {
        // A translated result reads in its language; everything else in the voice's default.
        const lang = !!resultVoiceLang.current ? resultVoiceLang.current : "";
        await ttsSpeak(output, lang, "", "");
      } else {
        await ttsStop();
      }
    } catch {
      /* ignore */
    }
  }, [voiceState.phase]);

  // A result with Speak is shown: load the voice (in its language) meanwhile.
  useEffect(() => {
    if (view.kind === "result") ttsWarmUp(resultVoiceLang.current || "").catch(() => {});
  }, [view.kind]);

  // The Read action: read the selection itself, no AI pass. The reading view
  // below follows the voice's progress and offers the Stop.
  const [readText, setReadText] = useState("");
  const [readStarting, setReadStarting] = useState(false);
  const doRead = useCallback(() => {
    if (!isTextSelection(selection) || selection.text.trim().length === 0) return;
    voiceRevision.current += 1;
    setReadText(selection.text);
    setReadStarting(true);
    setVoiceState({ phase: "generating", message: "Preparing your reading…", progress: 0, voice: "" });
    setView({ kind: "reading" });
    ttsSpeak(selection.text, "", "", "").catch((e) => {
      setVoiceState({ phase: "error", message: String(e), progress: 0, voice: "" });
    }).finally(() => setReadStarting(false));
  }, [selection]);

  // The latest speakResult for the key handler without re-binding it.
  const speakResultRef = useRef<(output: string) => void>(() => {});
  useEffect(() => {
    speakResultRef.current = speakResult;
  }, [speakResult]);

  // Copy a shown result, with a transient "Copied ✓" on the button itself.
  const [copiedResult, setCopiedResult] = useState(false);
  const copyResult = useCallback(async (output: string) => {
    try {
      await copyText(output);
      setCopiedResult(true);
      window.setTimeout(() => setCopiedResult(false), 1600);
    } catch {
      /* ignore */
    }
  }, []);

  // Flat, ordered list of selectable menu items — the single source of truth for both
  // rendering and keyboard navigation, so the cursor index always matches what's on screen.
  const menuItems = useMemo(() => {
    const items: { id: string; label: string; hint: string; icon: IconName; activate: () => void }[] =
      ACTIONS.map((a) => ({
        id: a.id,
        label: a.label,
        hint: a.hint,
        icon: a.icon,
        // The read action speaks the selection; the rest run through the AI.
        activate: a.id === "__read" ? doRead : () => run(a.id, null, a.label),
      }));
    items.push({
      id: "__translate",
      label: "Translate →",
      hint: "Into another language",
      icon: "translate",
      activate: () => setView({ kind: "translate" }),
    });
    for (const a of customActions) {
      items.push({
        id: a.id,
        label: a.label,
        hint: "Custom action",
        icon: "custom",
        activate: () => run(a.id, null, a.label),
      });
    }
    return items;
  }, [customActions, run, doRead]);

  // Language grid items + a trailing "Back" entry, so the keyboard can reach Back too.
  const langItems = useMemo(() => {
    const items: { label: string; back?: boolean; activate: () => void }[] =
      TRANSLATE_LANGUAGES.map((lang) => ({
        label: lang,
        activate: () => run("translate", lang, `Translate → ${lang}`),
      }));
    items.push({ label: "← Back", back: true, activate: () => setView({ kind: "menu" }) });
    return items;
  }, [run]);

  useEffect(() => {
    refresh();
  }, [refresh]);

  // A fresh trigger (hotkey / --trigger / tray) resets to the menu and re-reads the selection.
  // This is driven by an explicit event from the backend, NOT window focus — otherwise simply
  // regaining focus (e.g. after the AI call completes) would wipe the result the user wants.
  useEffect(() => {
    const unlisten = listen("ghostpen://show", () => {
      setView({ kind: "menu" });
      setCursor(0);
      setCopied(false);
      refresh();
    });
    return () => {
      unlisten.then((f) => f());
    };
  }, [refresh]);

  // Plain focus just refreshes the selection/status; it must not change the current view.
  useEffect(() => {
    const onFocus = () => {
      refresh();
    };
    window.addEventListener("focus", onFocus);
    return () => window.removeEventListener("focus", onFocus);
  }, [refresh]);

  // Reset the language cursor each time we enter the translate view.
  useEffect(() => {
    if (view.kind === "translate") setLangCursor(0);
  }, [view.kind]);

  // Keep the cursor in range if the item count changes (e.g. custom actions load in).
  useEffect(() => {
    setCursor((c) => Math.min(c, Math.max(0, menuItems.length - 1)));
  }, [menuItems.length]);

  // ---- keyboard control --------------------------------------------------------------
  // Escape dismisses reading/the menu; other sub-views return to the menu first.
  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if (e.key !== "Escape") return;
      // First Esc while typing just leaves the prompt field; a second Esc then hides/closes.
      if (isTypingTarget(e.target)) {
        (e.target as HTMLElement).blur();
        return;
      }
      if (view.kind === "translate" || view.kind === "result" || view.kind === "error") {
        setView({ kind: "menu" });
      } else if (view.kind === "reading") {
        // Cancel playback and dismiss, even when reading has already stopped.
        setReadStarting(false);
        ttsStop().catch(() => {});
        setVoiceState({ phase: "idle", message: "Stopped", progress: 0, voice: "" });
        setView({ kind: "menu" });
        dismissMenu();
      } else if (view.kind === "loading") {
        // Stop the built-in model's answer instead of pasting it later.
        cancelAi().catch(() => {});
        setView({ kind: "menu" });
        dismissMenu();
      } else {
        dismissMenu();
      }
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [view]);

  // Menu view: up/down and j/k traverse actions, left/right and h/l change intensity, Enter activates,
  // and 1–9 jump to and run an action directly.
  useEffect(() => {
    if (view.kind !== "menu") return;
    const n = menuItems.length;
    if (n === 0) return;
    const onKey = (e: KeyboardEvent) => {
      if (isTypingTarget(e.target)) return; // don't hijack keys while typing in the prompt bar
      // Ctrl/Cmd+C copies the whole selection (e.g. just-extracted text). Defer to a manual
      // in-page text selection if the user has one highlighted.
      if ((e.ctrlKey || e.metaKey) && (e.key === "c" || e.key === "C")) {
        const domSel = window.getSelection();
        if (isTextSelection(selection) && selection.text.trim() && (!domSel || domSel.isCollapsed)) {
          e.preventDefault();
          copyFull();
        }
        return;
      }
      switch (e.key) {
        case "ArrowDown":
          e.preventDefault();
          setCursor((c) => (c + 1) % n);
          break;
        case "j":
          e.preventDefault();
          setCursor((c) => (c + 1) % n);
          break;
        case "ArrowUp":
          e.preventDefault();
          setCursor((c) => (c - 1 + n) % n);
          break;
        case "k":
          e.preventDefault();
          setCursor((c) => (c - 1 + n) % n);
          break;
        case "ArrowLeft":
        case "h":
          e.preventDefault();
          setLevel((lv) => shiftLevel(lv, -1));
          break;
        case "ArrowRight":
        case "l":
          e.preventDefault();
          setLevel((lv) => shiftLevel(lv, 1));
          break;
        case "Enter":
          e.preventDefault();
          if (isImageSelection(selection)) {
            doExtractText();
          } else if (!empty) {
            menuItems[cursor]?.activate();
          }
          break;
        default:
          // e.code: Shift+1 gives "!" as the key.
          const digit = /^Digit([1-9])$/.exec(e.code)?.[1] ?? (/^[1-9]$/.test(e.key) ? e.key : null);
          if (digit) {
            const idx = Number(digit) - 1;
            if (idx < n) {
              e.preventDefault();
              setCursor(idx);
              if (!empty && !isImageSelection(selection)) menuItems[idx]?.activate();
            }
          }
      }
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [view.kind, menuItems, cursor, empty, selection, doExtractText, copyFull]);

  // Translate view: arrows move across the 2-column grid, Enter picks the language.
  useEffect(() => {
    if (view.kind !== "translate") return;
    const n = langItems.length;
    const COLS = 2;
    const onKey = (e: KeyboardEvent) => {
      if (isTypingTarget(e.target)) return;
      switch (e.key) {
        case "ArrowRight":
        case "l":
          e.preventDefault();
          setLangCursor((c) => Math.min(n - 1, c + 1));
          break;
        case "ArrowLeft":
        case "h":
          e.preventDefault();
          setLangCursor((c) => Math.max(0, c - 1));
          break;
        case "ArrowDown":
        case "j":
          e.preventDefault();
          setLangCursor((c) => Math.min(n - 1, c + COLS));
          break;
        case "ArrowUp":
        case "k":
          e.preventDefault();
          setLangCursor((c) => Math.max(0, c - COLS));
          break;
        case "Enter":
          e.preventDefault();
          langItems[langCursor]?.activate();
          break;
      }
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [view.kind, langItems, langCursor]);

  // Scroll the active item into view as the cursor moves through a long list.
  const cursorRef = useRef<HTMLButtonElement>(null);
  useEffect(() => {
    cursorRef.current?.scrollIntoView({ block: "nearest" });
  }, [cursor, langCursor, view.kind]);

  // Result view keyboard controls: ↑/↓ (j/k) scroll the output, Space/PgUp/PgDn page it,
  // Home/End jump, C (or Ctrl/Cmd+C) copies, Enter pastes — activating a focused button
  // instead when one has focus (Tab moves it), so native controls aren't hijacked.
  // The global handler sends Escape back to the menu.
  const outputRef = useRef<HTMLPreElement>(null);
  useEffect(() => {
    if (view.kind !== "result") return;
    const output = view.result.output;
    const canPaste = view.result.shown && !view.result.pasted;
    const scrollBy = (dy: number) => outputRef.current?.scrollBy({ top: dy, behavior: "auto" });
    const onKey = (e: KeyboardEvent) => {
      if (isTypingTarget(e.target)) return;
      const focused = document.activeElement;
      const onButton = focused instanceof HTMLElement && focused.tagName === "BUTTON";
      if ((e.ctrlKey || e.metaKey) && (e.key === "c" || e.key === "C")) {
        e.preventDefault();
        copyResult(output);
        return;
      }
      switch (e.key) {
        case "ArrowDown":
        case "j":
          e.preventDefault();
          scrollBy(30);
          return;
        case "ArrowUp":
        case "k":
          e.preventDefault();
          scrollBy(-30);
          return;
        case "PageDown":
          e.preventDefault();
          scrollBy(outputRef.current ? outputRef.current.clientHeight - 40 : 300);
          return;
        case "PageUp":
          e.preventDefault();
          scrollBy(outputRef.current ? -(outputRef.current.clientHeight - 40) : -300);
          return;
        case "Home":
          e.preventDefault();
          outputRef.current?.scrollTo({ top: 0 });
          return;
        case "End":
          e.preventDefault();
          outputRef.current?.scrollTo({ top: outputRef.current.scrollHeight });
          return;
      }
      if (e.key === "Enter" && canPaste && !onButton) {
        e.preventDefault();
        pasteShown(output);
      } else if (e.key.toLowerCase() === "c" && !(e.ctrlKey || e.metaKey || e.altKey) && !onButton) {
        e.preventDefault();
        copyResult(output);
      } else if (e.key.toLowerCase() === "s" && !(e.ctrlKey || e.metaKey || e.altKey) && !onButton) {
        e.preventDefault();
        speakResultRef.current(output);
      }
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [view.kind, view, copyResult, pasteShown, speakResult]);

  return (
    <div className="menu">
      <header className="menu-head" data-oriel-drag-region>
        <span className="brand">GhostPen</span>
        <span className="head-btns">
          <button className="icon-btn" title="Playground" onClick={() => openPlayground()}>
            🧪
          </button>
          <button className="icon-btn" title="Settings" onClick={() => openSettings()}>
            ⚙️
          </button>
        </span>
      </header>

      {status && (
        <div className="dest" title="Active AI destination">
          → {status.active_profile} · <code>{status.active_model}</code>
          {status.manual_mode && <span className="badge">manual</span>}
        </div>
      )}

      {view.kind === "menu" && isImageSelection(selection) && (
        <div className="image-mode">
          <figure className="image-capture">
            <img src={selection.preview} alt="Captured image" />
            <figcaption className="image-capture-meta">
              <Icon name="image" className="image-capture-icon" />
              Image on clipboard · {selection.width} × {selection.height}
            </figcaption>
          </figure>

          <button ref={cursorRef} className="extract-cta selected" onClick={doExtractText}>
            <Icon name="scan" className="extract-cta-icon" />
            <span className="extract-cta-text">
              <span className="extract-cta-label">Extract Text</span>
              <span className="extract-cta-hint">Read the text out of the image</span>
            </span>
          </button>

          <p className="image-mode-note">
            Proofread, translate, rewrite &amp; more unlock once the text is extracted.
          </p>
        </div>
      )}

      {view.kind === "menu" && !isImageSelection(selection) && (
        <>
          <div className={`selection ${empty ? "empty" : ""}`}>
            {isTextSelection(selection) ? (
              <>
                <span className="selection-text-wrap">
                  {selection.text.length > 140 ? selection.text.slice(0, 140) + "…" : selection.text}
                </span>
                <div className="copy-bar">
                  <span className="copy-bar-count">{selection.text.length} chars</span>
                  <button
                    className={`copy-bar-btn ${copied ? "done" : ""}`}
                    title="Copy the whole text (Ctrl+C)"
                    onClick={copyFull}
                  >
                    <Icon name="copy" className="copy-text-icon" />
                    {copied ? "Copied ✓" : "Copy all"}
                    <kbd>Ctrl+C</kbd>
                  </button>
                </div>
              </>
            ) : (
              <span>
                {status?.manual_mode
                  ? "Copy some text or an image (Ctrl+C), then pick an action."
                  : "No text or image selected."}
              </span>
            )}
          </div>

          <LevelBar level={level} setLevel={setLevel} />
          <div className="actions">
            {menuItems.map((a, i) => (
              <button
                key={a.id}
                ref={i === cursor ? cursorRef : undefined}
                className={`action ${i === cursor ? "selected" : ""}`}
                disabled={empty}
                onClick={() => a.activate()}
                title={a.id === "__read" ? "Read the selected text aloud" : "Shift+click (or Shift+number): preview the result here, paste it after reading"}
                onMouseEnter={() => setCursor(i)}
              >
                <Icon name={a.icon} className="action-icon" />
                <span className="action-text">
                  <span className="action-label">{a.label}</span>
                  <span className="action-hint">{a.hint}</span>
                </span>
              </button>
            ))}
          </div>
          <form
            className="prompt-bar"
            onSubmit={(e) => {
              e.preventDefault();
              runCustom();
            }}
          >
            <input
              className="prompt-input"
              value={prompt}
              disabled={empty}
              placeholder={empty ? "Select text first…" : "Tell GhostPen what to do…"}
              onChange={(e) => setPrompt(e.target.value)}
            />
            <button
              type="submit"
              className="prompt-send"
              disabled={empty || prompt.trim().length === 0}
              title="Run instruction (Enter)"
            >
              <Icon name="send" />
            </button>
          </form>
        </>
      )}

      {view.kind === "translate" && (
        <div className="lang-grid">
          {langItems.map((lang, i) => (
            <button
              key={lang.label}
              ref={i === langCursor ? cursorRef : undefined}
              className={`lang ${lang.back ? "back" : ""} ${i === langCursor ? "selected" : ""}`}
              onClick={() => lang.activate()}
              onMouseEnter={() => setLangCursor(i)}
            >
              {lang.label}
            </button>
          ))}
        </div>
      )}

      {view.kind === "loading" && (
        <div className="state">
          <div className="spinner" />
          <div className="state-label">{view.label}…</div>
          <div className="state-detail">{progressText(progress)}</div>
          <div className="state-time">{(elapsedMs / 1000).toFixed(1)} s</div>
        </div>
      )}

      {view.kind === "reading" && (
        <section className="state reading" aria-label="Read aloud">
          <div className="reading-heading"><Icon name="read" /><h2>Read aloud</h2></div>
          <div className="reading-status" role="status" aria-live="polite">
            {readStarting || voiceState.phase === "generating" || voiceState.phase === "downloading" ? <span className="spinner" /> : <Icon name="read" />}
            <div>
              <strong>{readStarting ? "Preparing your reading…" : voiceState.phase === "playing" ? "Reading aloud" : voiceState.phase === "idle" ? (voiceState.message === "Stopped" ? "Reading stopped" : "Reading finished") : voiceState.phase === "error" ? "Couldn't read this text" : voiceState.phase === "downloading" ? "Downloading the voice" : "Preparing the voice"}</strong>
              <p>{voiceState.phase === "idle" ? "Read again, or return to your actions." : voiceState.phase === "playing" ? "You can keep using other apps while listening." : voiceState.message || "The first sentence will play as soon as it's ready."}</p>
            </div>
          </div>
          {voiceState.phase === "downloading" && <progress className="reading-download" max={1} value={voiceState.progress} aria-label="Voice download progress" />}
          <blockquote className="reading-text">{readText}</blockquote>
          <div className="row reading-controls">
            {readStarting || ["generating", "playing", "downloading"].includes(voiceState.phase) ? (
              <button className="action small primary" onClick={async () => {
                setReadStarting(false);
                await ttsStop().catch(() => {});
                setVoiceState({ phase: "idle", message: "Stopped", progress: 0, voice: "" });
              }}>Stop reading</button>
            ) : (
              <button className="action small primary" onClick={() => {
                setReadStarting(true);
                setVoiceState({ phase: "generating", message: "Preparing your reading…", progress: 0, voice: "" });
                ttsSpeak(readText, "", "", "").catch((e) => setVoiceState({ phase: "error", message: String(e), progress: 0, voice: "" })).finally(() => setReadStarting(false));
              }}>Read again</button>
            )}
            <button className="action small" onClick={async () => { await ttsStop().catch(() => {}); setView({ kind: "menu" }); }}>Back to actions</button>
          </div>
        </section>
      )}

      {view.kind === "result" && (
        <div className="state result">
          <div className="state-label ok">
            {view.result.shown ? "✓ Result" : view.result.pasted ? "✓ Pasted" : "✓ Result copied"}
          </div>
          {!view.result.pasted && !view.result.shown && (
            <div className="hint">On the clipboard — press <kbd>{PASTE_KEYS}</kbd> to paste.</div>
          )}
          {view.result.shown && <div className="hint">Read it here; paste it into your app when you're done.</div>}
          <pre ref={outputRef} className="output">{view.result.output}</pre>
          <div className="row">
            {view.result.shown && (
              <>
                <button
                  className={`action small primary ${copiedResult ? "done" : ""}`}
                  onClick={() => copyResult(view.result.output)}
                  title="Copy to the clipboard (C)"
                >
                  {copiedResult ? "Copied ✓" : "Copy"}
                </button>
                <button
                  className="action small primary"
                  onClick={() => pasteShown(view.result.output)}
                  title="Clipboard + paste into the app underneath (Enter)"
                >
                  Paste
                </button>
                <button
                  className="action small"
                  disabled={voiceState.phase === "downloading" && !view.result.shown}
                  onClick={() => speakResult(view.result.output)}
                  title="Read it through the built-in voice (S); again to stop"
                >
                  {voiceState.phase === "downloading"
                    ? `Voice ${Math.round(voiceState.progress * 100)}%`
                    : voiceState.phase === "playing" || voiceState.phase === "generating"
                      ? "■ Stop"
                      : "🔊 Speak"}
                </button>
              </>
            )}
            <button className="action small" onClick={() => setView({ kind: "menu" })}>
              Back
            </button>
            <button className="action small" onClick={() => dismissMenu()}>
              Close
            </button>
          </div>
        </div>
      )}

      {view.kind === "error" && (
        <div className="state error">
          <div className="state-label bad">⚠ {view.message}</div>
          <button className="action small" onClick={() => setView({ kind: "menu" })}>
            Back
          </button>
        </div>
      )}
    </div>
  );
}
