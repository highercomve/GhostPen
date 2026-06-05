import { useEffect, useState, useCallback, useMemo, useRef } from "react";
import { listen } from "@tauri-apps/api/event";
import LevelBar from "./LevelBar";
import { Icon, IconName } from "./icons";
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
  hideWindow,
  openSettings,
  openPlayground,
  TRANSLATE_LANGUAGES,
} from "./api";

type View =
  | { kind: "menu" }
  | { kind: "translate" }
  | { kind: "loading"; label: string }
  | { kind: "result"; result: ProcessResult }
  | { kind: "error"; message: string };

const ACTIONS: { id: string; label: string; hint: string; icon: IconName }[] = [
  { id: "proofread", label: "Proofread", hint: "Fix spelling & grammar", icon: "proofread" },
  { id: "professional", label: "Professional", hint: "Rewrite polished & clear", icon: "professional" },
  { id: "casual", label: "Casual", hint: "Friendly, conversational", icon: "casual" },
  { id: "concise", label: "Concise", hint: "Condense, keep meaning", icon: "concise" },
  { id: "expand", label: "Expand", hint: "Add detail & elaborate", icon: "expand" },
];

const LEVELS: Level[] = ["subtle", "balanced", "strong"];

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

export default function Menu() {
  const [status, setStatus] = useState<Status | null>(null);
  const [selection, setSelection] = useState<string>("");
  const [customActions, setCustomActions] = useState<CustomAction[]>([]);
  const [level, setLevel] = useState<Level>("balanced");
  const [view, setView] = useState<View>({ kind: "menu" });
  // Keyboard cursor: index into `menuItems` (menu view) and into the language grid (translate view).
  const [cursor, setCursor] = useState(0);
  const [langCursor, setLangCursor] = useState(0);
  // Freeform instruction typed in the prompt bar.
  const [prompt, setPrompt] = useState("");

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

  const run = useCallback(
    async (action: string, targetLang: string | null, label: string) => {
      setView({ kind: "loading", label });
      try {
        const result = await processAiAction(action, targetLang, level);
        setView({ kind: "result", result });
      } catch (e) {
        setView({ kind: "error", message: String(e) });
      }
    },
    [level],
  );

  const empty = selection.length === 0;

  // Run the freeform instruction from the prompt bar over the current selection.
  const runCustom = useCallback(async () => {
    const instruction = prompt.trim();
    if (!instruction || empty) return;
    setView({ kind: "loading", label: instruction });
    try {
      const result = await processAiCustom(instruction);
      setPrompt("");
      setView({ kind: "result", result });
    } catch (e) {
      setView({ kind: "error", message: String(e) });
    }
  }, [prompt, empty]);

  // Flat, ordered list of selectable menu items — the single source of truth for both
  // rendering and keyboard navigation, so the cursor index always matches what's on screen.
  const menuItems = useMemo(() => {
    const items: { id: string; label: string; hint: string; icon: IconName; activate: () => void }[] =
      ACTIONS.map((a) => ({
        id: a.id,
        label: a.label,
        hint: a.hint,
        icon: a.icon,
        activate: () => run(a.id, null, a.label),
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
  }, [customActions, run]);

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
  // Escape closes the menu; from a sub-view it goes back to the menu first.
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
      } else {
        hideWindow();
      }
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [view]);

  // Menu view: ↑/↓ (or j/k) move the cursor, ←/→ (or h/l) change intensity, Enter activates,
  // and 1–9 jump to and run an action directly.
  useEffect(() => {
    if (view.kind !== "menu") return;
    const n = menuItems.length;
    if (n === 0) return;
    const onKey = (e: KeyboardEvent) => {
      if (isTypingTarget(e.target)) return; // don't hijack keys while typing in the prompt bar
      switch (e.key) {
        case "ArrowDown":
        case "j":
          e.preventDefault();
          setCursor((c) => (c + 1) % n);
          break;
        case "ArrowUp":
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
          if (!empty) menuItems[cursor]?.activate();
          break;
        default:
          if (/^[1-9]$/.test(e.key)) {
            const idx = Number(e.key) - 1;
            if (idx < n) {
              e.preventDefault();
              setCursor(idx);
              if (!empty) menuItems[idx]?.activate();
            }
          }
      }
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [view.kind, menuItems, cursor, empty]);

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

  return (
    <div className="menu">
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
          <div className={`selection ${empty ? "empty" : ""}`}>
            {empty ? (
              status?.manual_mode ? (
                "Copy some text (Ctrl+C), then pick an action."
              ) : (
                "No text selected."
              )
            ) : (
              <span>{selection.length > 140 ? selection.slice(0, 140) + "…" : selection}</span>
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
        </div>
      )}

      {view.kind === "result" && (
        <div className="state result">
          <div className="state-label ok">
            {view.result.pasted ? "✓ Pasted" : "✓ Result copied"}
          </div>
          {!view.result.pasted && (
            <div className="hint">On the clipboard — press <kbd>Ctrl</kbd>+<kbd>V</kbd> to paste.</div>
          )}
          <pre className="output">{view.result.output}</pre>
          <div className="row">
            <button className="action small" onClick={() => setView({ kind: "menu" })}>
              Back
            </button>
            <button className="action small" onClick={() => hideWindow()}>
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
