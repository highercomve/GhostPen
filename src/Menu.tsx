import { useEffect, useState, useCallback, useMemo, useRef } from "react";
import { listen } from "@tauri-apps/api/event";
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

const ACTIONS: { id: string; label: string; icon: IconName }[] = [
  { id: "proofread", label: "Proofread", icon: "proofread" },
  { id: "professional", label: "Pro", icon: "professional" },
  { id: "casual", label: "Casual", icon: "casual" },
  { id: "concise", label: "Concise", icon: "concise" },
  { id: "expand", label: "Expand", icon: "expand" },
];

const LEVELS: Level[] = ["subtle", "balanced", "strong"];
// Number of tile columns in the action grid; load-bearing for grid keyboard navigation.
const COLS = 3;

// True when a keyboard event originates from a text field — so global menu shortcuts
// (arrows, Enter, 1–9) don't fire while the user is typing in the prompt bar.
function isTypingTarget(t: EventTarget | null): boolean {
  return t instanceof HTMLElement && (t.tagName === "INPUT" || t.tagName === "TEXTAREA");
}

export default function Menu() {
  const [status, setStatus] = useState<Status | null>(null);
  const [selection, setSelection] = useState<string>("");
  const [customActions, setCustomActions] = useState<CustomAction[]>([]);
  const [level, setLevel] = useState<Level>("balanced");
  const [view, setView] = useState<View>({ kind: "menu" });
  // Keyboard cursor: index into `menuItems` (menu grid) and into the language grid (translate view).
  const [cursor, setCursor] = useState(0);
  const [langCursor, setLangCursor] = useState(0);
  // Freeform instruction typed in the compact prompt bar.
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

  // Instant apply (Glass HUD differentiator): run the action and show the existing
  // loading → result/copied states. No preview-before-paste — speed over ceremony.
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

  // Flat, ordered list of selectable tiles — the single source of truth for both
  // rendering and keyboard navigation, so the cursor index always matches what's on screen.
  const menuItems = useMemo(() => {
    const items: { id: string; label: string; icon: IconName; activate: () => void }[] =
      ACTIONS.map((a) => ({
        id: a.id,
        label: a.label,
        icon: a.icon,
        activate: () => run(a.id, null, a.label),
      }));
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

  // Menu grid: ←/→ move across columns, ↑/↓ move across rows (grid navigation), Enter
  // activates the focused tile, and 1–9 jump to and run a tile directly. Intensity is
  // adjusted with the inline control / mouse in this compact layout.
  useEffect(() => {
    if (view.kind !== "menu") return;
    const n = menuItems.length;
    if (n === 0) return;
    const onKey = (e: KeyboardEvent) => {
      if (isTypingTarget(e.target)) return; // don't hijack keys while typing in the prompt bar
      switch (e.key) {
        case "ArrowRight":
          e.preventDefault();
          setCursor((c) => Math.min(n - 1, c + 1));
          break;
        case "ArrowLeft":
          e.preventDefault();
          setCursor((c) => Math.max(0, c - 1));
          break;
        case "ArrowDown":
          e.preventDefault();
          setCursor((c) => (c + COLS < n ? c + COLS : c));
          break;
        case "ArrowUp":
          e.preventDefault();
          setCursor((c) => (c - COLS >= 0 ? c - COLS : c));
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
    const LCOLS = 2;
    const onKey = (e: KeyboardEvent) => {
      if (isTypingTarget(e.target)) return;
      switch (e.key) {
        case "ArrowRight":
          e.preventDefault();
          setLangCursor((c) => Math.min(n - 1, c + 1));
          break;
        case "ArrowLeft":
          e.preventDefault();
          setLangCursor((c) => Math.max(0, c - 1));
          break;
        case "ArrowDown":
          e.preventDefault();
          setLangCursor((c) => Math.min(n - 1, c + LCOLS));
          break;
        case "ArrowUp":
          e.preventDefault();
          setLangCursor((c) => Math.max(0, c - LCOLS));
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

  return (
    <div className="hud">
      <header className="hud-head" data-tauri-drag-region>
        <span className="brand">GhostPen</span>
        <span className="head-btns">
          {status && (
            <span className="dest-chip" title="Active AI destination">
              <code>{status.active_model}</code>
              {status.manual_mode && <span className="badge">manual</span>}
            </span>
          )}
          <button className="icon-btn" title="Playground" onClick={() => openPlayground()}>
            🧪
          </button>
          <button className="icon-btn" title="Settings" onClick={() => openSettings()}>
            ⚙
          </button>
        </span>
      </header>

      {view.kind === "menu" && (
        <>
          {empty && (
            <div className="hud-hint">
              {status?.manual_mode
                ? "Copy some text (Ctrl+C), then pick an action."
                : "No text selected."}
            </div>
          )}
          <div className="tile-grid" role="menu">
            {menuItems.map((a, i) => (
              <button
                key={a.id}
                ref={i === cursor ? cursorRef : undefined}
                className={`tile ${i === cursor ? "selected" : ""}`}
                disabled={empty}
                onClick={() => a.activate()}
                onMouseEnter={() => setCursor(i)}
                title={a.label}
              >
                {i < 9 && <span className="tile-num">{i + 1}</span>}
                <Icon name={a.icon} className="tile-icon" />
                <span className="tile-label">{a.label}</span>
              </button>
            ))}
          </div>

          <div className="hud-foot">
            <div className="intensity" title="Intensity">
              {LEVELS.map((l) => (
                <button
                  key={l}
                  className={`int-dot ${level === l ? "active" : ""}`}
                  onClick={() => setLevel(l)}
                  title={l[0].toUpperCase() + l.slice(1)}
                  aria-label={`Intensity: ${l}`}
                />
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
                placeholder={empty ? "Select text first…" : "Tell GhostPen…"}
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
        <div className="state confirm">
          <div className="confirm-mark">
            {view.result.pasted ? "✓ Pasted" : "✓ Copied"}
          </div>
          {!view.result.pasted && (
            <div className="hint">
              On the clipboard — press <kbd>Ctrl</kbd>+<kbd>V</kbd>.
            </div>
          )}
          <pre className="output">{view.result.output}</pre>
          <div className="row">
            <button className="ghost-btn" onClick={() => setView({ kind: "menu" })}>
              Back
            </button>
            <button className="ghost-btn" onClick={() => hideWindow()}>
              Close
            </button>
          </div>
        </div>
      )}

      {view.kind === "error" && (
        <div className="state error">
          <div className="state-label bad">⚠ {view.message}</div>
          <button className="ghost-btn" onClick={() => setView({ kind: "menu" })}>
            Back
          </button>
        </div>
      )}
    </div>
  );
}
