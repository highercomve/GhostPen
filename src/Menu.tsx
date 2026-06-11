import { useEffect, useState, useCallback, useMemo, useRef } from "react";
import { listen, UnlistenFn } from "@tauri-apps/api/event";
import { Icon, IconName } from "./icons";
import { wordDiff } from "./diff";
import {
  Status,
  ProcessResult,
  CustomAction,
  Level,
  getStatus,
  getSettings,
  getSelection,
  processAiAction,
  processAiCustom,
  processTextStream,
  hideWindow,
  openSettings,
  openPlayground,
  TRANSLATE_LANGUAGES,
} from "./api";

// A pending generation: which action ran, against which selection, and how to "apply" it.
type Pending = {
  action: string; // backend action id (proofread/professional/casual/concise/expand/translate or a custom-action id)
  label: string;
  targetLang: string | null;
  source: string; // the selection text this result was generated from (used for the diff)
};

type View =
  | { kind: "menu" }
  | { kind: "translate" }
  | { kind: "result"; pending: Pending };

// Tone chips live under "Rewrite". Each maps to an existing backend action id.
const TONES: { id: string; label: string; icon: IconName }[] = [
  { id: "casual", label: "Friendly", icon: "casual" },
  { id: "professional", label: "Professional", icon: "professional" },
  { id: "concise", label: "Concise", icon: "concise" },
  { id: "expand", label: "Expand", icon: "expand" },
];

const LEVELS: Level[] = ["subtle", "balanced", "strong"];

// True when a keyboard event originates from a text field — so global menu shortcuts
// (arrows, Enter) don't fire while the user is typing in the describe field.
function isTypingTarget(t: EventTarget | null): boolean {
  return t instanceof HTMLElement && (t.tagName === "INPUT" || t.tagName === "TEXTAREA");
}

export default function Menu() {
  const [status, setStatus] = useState<Status | null>(null);
  const [selection, setSelection] = useState<string>("");
  const [customActions, setCustomActions] = useState<CustomAction[]>([]);
  const [level, setLevel] = useState<Level>("balanced");
  const [view, setView] = useState<View>({ kind: "menu" });
  // Keyboard cursor across the focusable chips on the menu card.
  const [cursor, setCursor] = useState(0);
  const [langCursor, setLangCursor] = useState(0);
  // Free-text instruction typed in the "Describe your change…" field.
  const [prompt, setPrompt] = useState("");

  // ---- streaming result state (the preview, before any paste) ------------------------
  const [streamText, setStreamText] = useState("");
  const [streaming, setStreaming] = useState(false);
  const [streamErr, setStreamErr] = useState<string | null>(null);
  // Set once the user confirms Replace (mirrors the old ProcessResult handling).
  const [applied, setApplied] = useState<ProcessResult | null>(null);
  const [applying, setApplying] = useState(false);
  const [copied, setCopied] = useState(false);

  const refresh = useCallback(async () => {
    try {
      setStatus(await getStatus());
    } catch {
      /* ignore */
    }
    try {
      setCustomActions((await getSettings()).customActions ?? []);
    } catch {
      /* ignore */
    }
    try {
      setSelection((await getSelection()).trim());
    } catch {
      setSelection("");
    }
  }, []);

  const empty = selection.length === 0;

  const resetMenu = useCallback(() => {
    setView({ kind: "menu" });
    setCursor(0);
    setStreamText("");
    setStreaming(false);
    setStreamErr(null);
    setApplied(null);
    setApplying(false);
    setCopied(false);
  }, []);

  // Begin a preview: stream the result INTO the card (no clipboard side effects yet).
  // Uses the existing `process_text_stream` command against the live selection text.
  const preview = useCallback(
    async (pending: Pending) => {
      if (empty) return;
      setStreamText("");
      setStreamErr(null);
      setApplied(null);
      setApplying(false);
      setCopied(false);
      setStreaming(true);
      setView({ kind: "result", pending });

      const unlisten: UnlistenFn[] = [];
      let acc = "";
      try {
        unlisten.push(
          await listen<string>("ghostpen://chunk", (e) => {
            acc += e.payload;
            setStreamText(acc);
          }),
        );
        unlisten.push(
          await listen<string>("ghostpen://done", (e) => {
            if (e.payload) setStreamText(e.payload);
          }),
        );
        unlisten.push(
          await listen<string>("ghostpen://error", (e) => setStreamErr(e.payload)),
        );
        await processTextStream(pending.action, pending.targetLang, level, pending.source);
      } catch (e) {
        setStreamErr(String(e));
      } finally {
        unlisten.forEach((u) => u());
        setStreaming(false);
      }
    },
    [empty, level],
  );

  // Confirm: apply the result via the real clipboard+paste path. Re-runs the model (the
  // backend generate/apply split is TODO 12.1). Mirrors the old ProcessResult handling
  // (pasted vs. manual-copy).
  const applyPending = useCallback(
    async (pending: Pending) => {
      if (applying) return;
      setApplying(true);
      try {
        const result = await processAiAction(pending.action, pending.targetLang, level);
        setApplied(result);
      } catch (e) {
        setStreamErr(String(e));
      } finally {
        setApplying(false);
      }
    },
    [applying, level],
  );

  // Run the free-text instruction from the describe field over the current selection.
  // There is no streaming/generate-only command for arbitrary instructions, so this applies
  // directly via `process_ai_custom` (clipboard+paste), then shows the same result card.
  const runCustom = useCallback(async () => {
    const instruction = prompt.trim();
    if (!instruction || empty) return;
    const pending: Pending = { action: "__custom", label: instruction, targetLang: null, source: selection };
    setStreamText("");
    setStreamErr(null);
    setApplied(null);
    setCopied(false);
    setStreaming(false);
    setApplying(true);
    setView({ kind: "result", pending });
    try {
      const result = await processAiCustom(instruction);
      setStreamText(result.output);
      setApplied(result);
      setPrompt("");
    } catch (e) {
      setStreamErr(String(e));
    } finally {
      setApplying(false);
    }
  }, [prompt, empty, selection]);

  // The verb/tone/custom chips, in keyboard order: Proofread, the four tones, Translate,
  // then any user custom actions.
  const chips = useMemo(() => {
    type Chip = { id: string; label: string; icon: IconName; activate: () => void };
    const items: Chip[] = [];
    items.push({
      id: "proofread",
      label: "Proofread",
      icon: "proofread",
      activate: () =>
        preview({ action: "proofread", label: "Proofread", targetLang: null, source: selection }),
    });
    for (const t of TONES) {
      items.push({
        id: t.id,
        label: t.label,
        icon: t.icon,
        activate: () =>
          preview({ action: t.id, label: t.label, targetLang: null, source: selection }),
      });
    }
    items.push({
      id: "__translate",
      label: "Translate",
      icon: "translate",
      activate: () => setView({ kind: "translate" }),
    });
    for (const a of customActions) {
      items.push({
        id: a.id,
        label: a.label,
        icon: "custom",
        activate: () =>
          preview({ action: a.id, label: a.label, targetLang: null, source: selection }),
      });
    }
    return items;
  }, [customActions, preview, selection]);

  // Language grid + a trailing Back entry, so the keyboard can reach Back too.
  const langItems = useMemo(() => {
    const items: { label: string; back?: boolean; activate: () => void }[] =
      TRANSLATE_LANGUAGES.map((lang) => ({
        label: lang,
        activate: () =>
          preview({ action: "translate", label: `Translate → ${lang}`, targetLang: lang, source: selection }),
      }));
    items.push({ label: "← Back", back: true, activate: () => resetMenu() });
    return items;
  }, [preview, selection, resetMenu]);

  useEffect(() => {
    refresh();
  }, [refresh]);

  // A fresh trigger (hotkey / --trigger / tray) resets to the menu and re-reads the selection.
  // Driven by an explicit backend event, NOT focus — so regaining focus after the AI call
  // completes won't wipe a result the user is reviewing.
  useEffect(() => {
    const unlisten = listen("ghostpen://show", () => {
      resetMenu();
      setPrompt("");
      refresh();
    });
    return () => {
      unlisten.then((f) => f());
    };
  }, [refresh, resetMenu]);

  // Plain focus just refreshes selection/status; it must not change the current view.
  useEffect(() => {
    const onFocus = () => refresh();
    window.addEventListener("focus", onFocus);
    return () => window.removeEventListener("focus", onFocus);
  }, [refresh]);

  useEffect(() => {
    if (view.kind === "translate") setLangCursor(0);
  }, [view.kind]);

  useEffect(() => {
    setCursor((c) => Math.min(c, Math.max(0, chips.length - 1)));
  }, [chips.length]);

  // ---- keyboard control --------------------------------------------------------------
  // Escape: sub-view → menu → hide. First Esc while typing just blurs the field.
  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if (e.key !== "Escape") return;
      if (isTypingTarget(e.target)) {
        (e.target as HTMLElement).blur();
        return;
      }
      if (view.kind === "translate" || view.kind === "result") {
        resetMenu();
      } else {
        hideWindow();
      }
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [view, resetMenu]);

  // Menu view: arrows / hjkl move between chips, Enter activates, 1–9 quick-run.
  useEffect(() => {
    if (view.kind !== "menu") return;
    const n = chips.length;
    if (n === 0) return;
    const onKey = (e: KeyboardEvent) => {
      if (isTypingTarget(e.target)) return;
      switch (e.key) {
        case "ArrowRight":
        case "ArrowDown":
        case "l":
        case "j":
          e.preventDefault();
          setCursor((c) => (c + 1) % n);
          break;
        case "ArrowLeft":
        case "ArrowUp":
        case "h":
        case "k":
          e.preventDefault();
          setCursor((c) => (c - 1 + n) % n);
          break;
        case "Enter":
          e.preventDefault();
          if (!empty) chips[cursor]?.activate();
          break;
        default:
          if (/^[1-9]$/.test(e.key)) {
            const idx = Number(e.key) - 1;
            if (idx < n) {
              e.preventDefault();
              setCursor(idx);
              if (!empty) chips[idx]?.activate();
            }
          }
      }
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [view.kind, chips, cursor, empty]);

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

  // Scroll the active item into view as the cursor moves.
  const cursorRef = useRef<HTMLButtonElement>(null);
  useEffect(() => {
    cursorRef.current?.scrollIntoView({ block: "nearest" });
  }, [cursor, langCursor, view.kind]);

  const copyResult = async () => {
    try {
      await navigator.clipboard.writeText(streamText);
      setCopied(true);
      setTimeout(() => setCopied(false), 1400);
    } catch {
      /* ignore */
    }
  };

  return (
    <div className="menu card-shell">
      <header className="menu-head">
        <span className="brand">GhostPen</span>
        <span className="head-btns">
          <button className="icon-btn" title="Playground" onClick={() => openPlayground()}>
            🧪
          </button>
          <button className="icon-btn" title="Settings" onClick={() => openSettings()}>
            ⚙
          </button>
        </span>
      </header>

      {status && (
        <div className="dest" title="Active AI destination">
          → {status.active_profile} · <code>{status.active_model}</code>
          {status.manual_mode && <span className="badge">manual</span>}
        </div>
      )}

      {view.kind === "menu" && (
        <>
          <form
            className="describe-bar"
            onSubmit={(e) => {
              e.preventDefault();
              runCustom();
            }}
          >
            <Icon name="custom" className="describe-spark" />
            <input
              className="describe-input"
              value={prompt}
              disabled={empty}
              placeholder={empty ? "Select text first…" : "Describe your change…"}
              onChange={(e) => setPrompt(e.target.value)}
            />
            <button
              type="submit"
              className="describe-send"
              disabled={empty || prompt.trim().length === 0}
              title="Run instruction (Enter)"
            >
              <Icon name="send" />
            </button>
          </form>

          <div className={`selection ${empty ? "empty" : ""}`}>
            {empty ? (
              status?.manual_mode
                ? "Copy some text (Ctrl+C), then pick an action."
                : "No text selected."
            ) : (
              <span>{selection.length > 160 ? selection.slice(0, 160) + "…" : selection}</span>
            )}
          </div>

          <div className="verbs">
            <div className="verb-group-label">Proofread</div>
            <div className="chip-row">
              {chips[0] && (
                <ChipButton
                  chip={chips[0]}
                  index={0}
                  cursor={cursor}
                  empty={empty}
                  cursorRef={cursorRef}
                  onHover={setCursor}
                  primary
                />
              )}
            </div>

            <div className="verb-group-label">Rewrite</div>
            <div className="chip-row">
              {chips.slice(1).map((c, k) => (
                <ChipButton
                  key={c.id}
                  chip={c}
                  index={k + 1}
                  cursor={cursor}
                  empty={empty}
                  cursorRef={cursorRef}
                  onHover={setCursor}
                />
              ))}
            </div>
          </div>

          <div className="intensity-pill">
            <span className="intensity-label">Intensity</span>
            <div className="seg">
              {LEVELS.map((l) => (
                <button
                  key={l}
                  className={`seg-btn ${level === l ? "active" : ""}`}
                  onClick={() => setLevel(l)}
                  title="Applies to Rewrite tones"
                >
                  {l[0].toUpperCase() + l.slice(1)}
                </button>
              ))}
            </div>
          </div>
        </>
      )}

      {view.kind === "translate" && (
        <div className="lang-grid">
          {langItems.map((lang, i) => (
            <button
              key={lang.label}
              ref={i === langCursor ? cursorRef : undefined}
              className={`lang ${lang.back ? "back" : ""} ${i === langCursor ? "selected" : ""}`}
              disabled={!lang.back && empty}
              onClick={() => lang.activate()}
              onMouseEnter={() => setLangCursor(i)}
            >
              {lang.label}
            </button>
          ))}
        </div>
      )}

      {view.kind === "result" && (
        <ResultView
          pending={view.pending}
          text={streamText}
          streaming={streaming}
          error={streamErr}
          applied={applied}
          applying={applying}
          copied={copied}
          onReplace={() => applyPending(view.pending)}
          onCopy={copyResult}
          onBack={resetMenu}
          onClose={() => hideWindow()}
          onRetry={() => preview(view.pending)}
        />
      )}
    </div>
  );
}

// ---- chip button -----------------------------------------------------------------------

function ChipButton({
  chip,
  index,
  cursor,
  empty,
  cursorRef,
  onHover,
  primary,
}: {
  chip: { id: string; label: string; icon: IconName; activate: () => void };
  index: number;
  cursor: number;
  empty: boolean;
  cursorRef: React.RefObject<HTMLButtonElement | null>;
  onHover: (i: number) => void;
  primary?: boolean;
}) {
  const selected = index === cursor;
  return (
    <button
      ref={selected ? cursorRef : undefined}
      className={`chip ${primary ? "chip-primary-verb" : ""} ${selected ? "selected" : ""}`}
      disabled={empty}
      onClick={() => chip.activate()}
      onMouseEnter={() => onHover(index)}
    >
      <Icon name={chip.icon} className="chip-icon" />
      <span className="chip-label">{chip.label}</span>
    </button>
  );
}

// ---- result preview --------------------------------------------------------------------

function ResultView({
  pending,
  text,
  streaming,
  error,
  applied,
  applying,
  copied,
  onReplace,
  onCopy,
  onBack,
  onClose,
  onRetry,
}: {
  pending: Pending;
  text: string;
  streaming: boolean;
  error: string | null;
  applied: ProcessResult | null;
  applying: boolean;
  copied: boolean;
  onReplace: () => void;
  onCopy: () => void;
  onBack: () => void;
  onClose: () => void;
  onRetry: () => void;
}) {
  const isProofread = pending.action === "proofread";
  const diff = useMemo(
    () => (isProofread && text ? wordDiff(pending.source, text) : null),
    [isProofread, pending.source, text],
  );
  const isCustom = pending.action === "__custom";

  // Once applied, mirror the old ProcessResult handling (pasted vs. manual-copy).
  if (applied) {
    return (
      <div className="result">
        <div className="result-head">
          <span className="result-title">{pending.label}</span>
          <span className="result-ok">{applied.pasted ? "Replaced ✓" : "Copied ✓"}</span>
        </div>
        {!applied.pasted && (
          <div className="manual-hint">
            On the clipboard — press <kbd>Ctrl</kbd>+<kbd>V</kbd> to paste.
          </div>
        )}
        <div className="result-body">{applied.output}</div>
        <div className="result-actions">
          <button className="chip" onClick={onBack}>
            ← Back
          </button>
          <button className="chip chip-primary-verb" onClick={onClose}>
            Done
          </button>
        </div>
      </div>
    );
  }

  return (
    <div className="result">
      <div className="result-head">
        <span className="result-title">{pending.label}</span>
        {(streaming || applying) && <span className="result-status">generating…</span>}
      </div>

      {error ? (
        <div className="result-error">⚠ {error}</div>
      ) : (
        <div className={`result-body ${(streaming || applying) && !text ? "shimmer" : ""}`}>
          {(streaming || applying) && !text ? (
            <span className="shimmer-line" />
          ) : diff ? (
            diff.map((s, i) => (
              <span key={i} className={s.type === "equal" ? "" : `diff-${s.type}`}>
                {s.text}
              </span>
            ))
          ) : (
            text
          )}
        </div>
      )}

      <div className="result-actions">
        <button className="chip" onClick={onBack} title="Back to menu (Esc)">
          ← Back
        </button>
        {error ? (
          <button className="chip" onClick={onRetry} disabled={streaming}>
            Retry
          </button>
        ) : isCustom ? (
          // Custom instructions already applied (no generate-only command); offer Copy + Done.
          <>
            <button className="chip" onClick={onCopy} disabled={applying || !text}>
              {copied ? "Copied ✓" : "Copy"}
            </button>
            <button className="chip chip-primary-verb" onClick={onClose} disabled={applying}>
              Done
            </button>
          </>
        ) : (
          <>
            <button className="chip" onClick={onCopy} disabled={streaming || !text}>
              {copied ? "Copied ✓" : "Copy"}
            </button>
            <button
              className="chip chip-primary-verb"
              onClick={onReplace}
              disabled={streaming || applying || !text}
              title="Apply to your document"
            >
              {applying ? "Replacing…" : "Replace"}
            </button>
          </>
        )}
      </div>
    </div>
  );
}
