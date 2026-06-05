import { useEffect, useState, useCallback } from "react";
import { listen } from "@tauri-apps/api/event";
import LevelBar from "./LevelBar";
import {
  Status,
  ProcessResult,
  CustomAction,
  Level,
  getStatus,
  getSettings,
  getSelection,
  processAiAction,
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

const ACTIONS = [
  { id: "proofread", label: "Proofread", hint: "Fix spelling & grammar" },
  { id: "professional", label: "Professional", hint: "Rewrite polished & clear" },
  { id: "casual", label: "Casual", hint: "Friendly, conversational" },
  { id: "concise", label: "Concise", hint: "Condense, keep meaning" },
  { id: "expand", label: "Expand", hint: "Add detail & elaborate" },
];

export default function Menu() {
  const [status, setStatus] = useState<Status | null>(null);
  const [selection, setSelection] = useState<string>("");
  const [customActions, setCustomActions] = useState<CustomAction[]>([]);
  const [level, setLevel] = useState<Level>("balanced");
  const [view, setView] = useState<View>({ kind: "menu" });

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

  useEffect(() => {
    refresh();
  }, [refresh]);

  // A fresh trigger (hotkey / --trigger / tray) resets to the menu and re-reads the selection.
  // This is driven by an explicit event from the backend, NOT window focus — otherwise simply
  // regaining focus (e.g. after the AI call completes) would wipe the result the user wants.
  useEffect(() => {
    const unlisten = listen("ghostpen://show", () => {
      setView({ kind: "menu" });
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

  // Escape closes the menu; if in a sub-view, go back to the menu first.
  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if (e.key !== "Escape") return;
      if (view.kind === "translate" || view.kind === "result" || view.kind === "error") {
        setView({ kind: "menu" });
      } else {
        hideWindow();
      }
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [view]);

  const run = async (action: string, targetLang: string | null, label: string) => {
    setView({ kind: "loading", label });
    try {
      const result = await processAiAction(action, targetLang, level);
      setView({ kind: "result", result });
    } catch (e) {
      setView({ kind: "error", message: String(e) });
    }
  };

  const empty = selection.length === 0;

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
            {ACTIONS.map((a) => (
              <button
                key={a.id}
                className="action"
                disabled={empty}
                onClick={() => run(a.id, null, a.label)}
              >
                <span className="action-label">{a.label}</span>
                <span className="action-hint">{a.hint}</span>
              </button>
            ))}
            <button
              className="action"
              disabled={empty}
              onClick={() => setView({ kind: "translate" })}
            >
              <span className="action-label">Translate →</span>
              <span className="action-hint">Into another language</span>
            </button>
            {customActions.map((a) => (
              <button
                key={a.id}
                className="action"
                disabled={empty}
                onClick={() => run(a.id, null, a.label)}
              >
                <span className="action-label">{a.label}</span>
                <span className="action-hint">Custom action</span>
              </button>
            ))}
          </div>
        </>
      )}

      {view.kind === "translate" && (
        <div className="lang-grid">
          {TRANSLATE_LANGUAGES.map((lang) => (
            <button key={lang} className="lang" onClick={() => run("translate", lang, `Translate → ${lang}`)}>
              {lang}
            </button>
          ))}
          <button className="lang back" onClick={() => setView({ kind: "menu" })}>
            ← Back
          </button>
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
