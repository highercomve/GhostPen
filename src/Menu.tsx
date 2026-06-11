import { useEffect, useState, useCallback, useMemo, useRef } from "react";
import { listen, UnlistenFn } from "@tauri-apps/api/event";
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
  processTextStream,
  hideWindow,
  openSettings,
  openPlayground,
  TRANSLATE_LANGUAGES,
} from "./api";

// A run target the palette can execute: a built-in/custom action (streamable preview) or a
// freeform instruction typed into the search bar (no streaming command exists for it).
type RunTarget =
  | { kind: "action"; id: string; targetLang: string | null; label: string; level: Level }
  | { kind: "custom"; instruction: string; label: string };

type View =
  | { kind: "menu" }
  | { kind: "translate" }
  // The result-preview view: stream the output, then let the user confirm the paste/replace.
  | { kind: "preview"; target: RunTarget }
  | { kind: "applying"; label: string }
  | { kind: "done"; result: ProcessResult }
  | { kind: "error"; message: string };

const ACTIONS: { id: string; label: string; hint: string; icon: IconName }[] = [
  { id: "proofread", label: "Proofread", hint: "Fix spelling & grammar", icon: "proofread" },
  { id: "professional", label: "Professional", hint: "Rewrite polished & clear", icon: "professional" },
  { id: "casual", label: "Casual", hint: "Friendly, conversational", icon: "casual" },
  { id: "concise", label: "Concise", hint: "Condense, keep meaning", icon: "concise" },
  { id: "expand", label: "Expand", hint: "Add detail & elaborate", icon: "expand" },
];

const LEVELS: Level[] = ["subtle", "balanced", "strong"];

// Case-insensitive substring match over a row's label + hint.
function matches(query: string, label: string, hint: string): boolean {
  const q = query.trim().toLowerCase();
  if (!q) return true;
  return (label + " " + hint).toLowerCase().includes(q);
}

export default function Menu() {
  const [status, setStatus] = useState<Status | null>(null);
  const [selection, setSelection] = useState<string>("");
  const [customActions, setCustomActions] = useState<CustomAction[]>([]);
  const [level, setLevel] = useState<Level>("balanced");
  const [view, setView] = useState<View>({ kind: "menu" });
  // Keyboard cursor: index into the *filtered* `menuItems`, and into the language grid.
  const [cursor, setCursor] = useState(0);
  const [langCursor, setLangCursor] = useState(0);
  // The search/prompt query: fuzzy-filters the list, or runs as a custom instruction on Enter.
  const [query, setQuery] = useState("");

  const searchRef = useRef<HTMLInputElement>(null);

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

  // Enter the result-preview view for a target (no clipboard side-effects yet).
  const preview = useCallback((target: RunTarget) => {
    setView({ kind: "preview", target });
  }, []);

  // Full, unfiltered list of rows — source of truth for badges + activation.
  const allItems = useMemo(() => {
    const items: { id: string; label: string; hint: string; icon: IconName; activate: () => void }[] =
      ACTIONS.map((a) => ({
        id: a.id,
        label: a.label,
        hint: a.hint,
        icon: a.icon,
        activate: () =>
          preview({ kind: "action", id: a.id, targetLang: null, label: a.label, level }),
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
        activate: () =>
          preview({ kind: "action", id: a.id, targetLang: null, label: a.label, level }),
      });
    }
    return items;
  }, [customActions, level, preview]);

  // Filtered view driven by the search query. These indices are what the cursor uses.
  const menuItems = useMemo(
    () => allItems.filter((it) => matches(query, it.label, it.hint)),
    [allItems, query],
  );

  // Run the search query as a freeform instruction over the selection (preview flow).
  const runQueryAsInstruction = useCallback(() => {
    const instruction = query.trim();
    if (!instruction || empty) return;
    preview({ kind: "custom", instruction, label: instruction });
  }, [query, empty, preview]);

  // Language grid items + a trailing "Back" entry, so the keyboard can reach Back too.
  const langItems = useMemo(() => {
    const items: { label: string; back?: boolean; activate: () => void }[] =
      TRANSLATE_LANGUAGES.map((lang) => ({
        label: lang,
        activate: () =>
          preview({ kind: "action", id: "translate", targetLang: lang, label: `Translate → ${lang}`, level }),
      }));
    items.push({ label: "← Back", back: true, activate: () => setView({ kind: "menu" }) });
    return items;
  }, [level, preview]);

  useEffect(() => {
    refresh();
  }, [refresh]);

  // A fresh trigger (hotkey / --trigger / tray) resets to the menu and re-reads the selection.
  // Driven by an explicit backend event, NOT focus — regaining focus must not wipe a result.
  useEffect(() => {
    const unlisten = listen("ghostpen://show", () => {
      setView({ kind: "menu" });
      setCursor(0);
      setQuery("");
      refresh();
      requestAnimationFrame(() => searchRef.current?.focus());
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

  // Autofocus the search input on initial mount.
  useEffect(() => {
    searchRef.current?.focus();
  }, []);

  // Reset the language cursor each time we enter the translate view.
  useEffect(() => {
    if (view.kind === "translate") setLangCursor(0);
  }, [view.kind]);

  // Keep the cursor in range when the filtered item count changes.
  useEffect(() => {
    setCursor((c) => Math.min(c, Math.max(0, menuItems.length - 1)));
  }, [menuItems.length]);

  // ---- keyboard control --------------------------------------------------------------
  // Escape: from a sub-view → back to menu; in the menu, clear a query first, then hide.
  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if (e.key !== "Escape") return;
      if (
        view.kind === "translate" ||
        view.kind === "preview" ||
        view.kind === "done" ||
        view.kind === "error"
      ) {
        e.preventDefault();
        setView({ kind: "menu" });
        requestAnimationFrame(() => searchRef.current?.focus());
        return;
      }
      if (query.length > 0) {
        e.preventDefault();
        setQuery("");
        return;
      }
      hideWindow();
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [view.kind, query]);

  // Menu view: ↑/↓ move the cursor, Enter runs the highlighted row (or the query as an
  // instruction when nothing matches), Ctrl/Alt+1–9 quick-run a numbered row. The search
  // input stays focused, so digits/letters type into it; navigation is arrows + modifiers.
  useEffect(() => {
    if (view.kind !== "menu") return;
    const n = menuItems.length;
    const onKey = (e: KeyboardEvent) => {
      switch (e.key) {
        case "ArrowDown":
          e.preventDefault();
          if (n > 0) setCursor((c) => (c + 1) % n);
          break;
        case "ArrowUp":
          e.preventDefault();
          if (n > 0) setCursor((c) => (c - 1 + n) % n);
          break;
        case "Enter":
          e.preventDefault();
          if (empty) break;
          if (n > 0) menuItems[cursor]?.activate();
          else runQueryAsInstruction(); // no match → treat the query as an instruction
          break;
        default:
          if ((e.ctrlKey || e.altKey) && /^[1-9]$/.test(e.key)) {
            const idx = Number(e.key) - 1;
            if (idx < n && !empty) {
              e.preventDefault();
              setCursor(idx);
              menuItems[idx]?.activate();
            }
          }
      }
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [view.kind, menuItems, cursor, empty, runQueryAsInstruction]);

  // Translate view: arrows move across the 2-column grid, Enter picks the language.
  useEffect(() => {
    if (view.kind !== "translate") return;
    const n = langItems.length;
    const COLS = 2;
    const onKey = (e: KeyboardEvent) => {
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
          setLangCursor((c) => Math.min(n - 1, c + COLS));
          break;
        case "ArrowUp":
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

  const dest = status ? (
    <span className="strip-dest" title="Active AI destination">
      → {status.active_profile} · <code>{status.active_model}</code>
      {status.manual_mode && <span className="badge">manual</span>}
    </span>
  ) : null;

  return (
    <div className="palette">
      {view.kind === "menu" && (
        <>
          {/* Top search/prompt input — autofocused, dual-purpose (filter + instruction). */}
          <div className="search-row">
            <Icon name="custom" className="search-glyph" />
            <input
              ref={searchRef}
              className="search-input"
              value={query}
              disabled={empty}
              placeholder={
                empty
                  ? status?.manual_mode
                    ? "Copy text first (Ctrl+C)…"
                    : "Select text first…"
                  : "Search actions or describe a change…"
              }
              onChange={(e) => {
                setQuery(e.target.value);
                setCursor(0);
              }}
              autoFocus
            />
            <button className="icon-btn" title="Playground" tabIndex={-1} onClick={() => openPlayground()}>
              🧪
            </button>
            <button className="icon-btn" title="Settings" tabIndex={-1} onClick={() => openSettings()}>
              ⚙
            </button>
          </div>

          <div className="palette-body">
            {empty ? (
              <div className="palette-empty">
                {status?.manual_mode
                  ? "Copy some text (Ctrl+C), then summon GhostPen again."
                  : "No text selected. Highlight something and re-trigger."}
              </div>
            ) : menuItems.length === 0 ? (
              <div className="palette-empty run-hint">
                Press <kbd>↵</kbd> to run “{query.trim()}” as a custom instruction.
              </div>
            ) : (
              <div className="list" role="listbox">
                {menuItems.map((a, i) => (
                  <button
                    key={a.id}
                    ref={i === cursor ? cursorRef : undefined}
                    className={`row ${i === cursor ? "selected" : ""}`}
                    onClick={() => a.activate()}
                    onMouseEnter={() => setCursor(i)}
                  >
                    <Icon name={a.icon} className="row-icon" />
                    <span className="row-text">
                      <span className="row-label">{a.label}</span>
                      <span className="row-hint">{a.hint}</span>
                    </span>
                    {i < 9 && <span className="row-badge">{i + 1}</span>}
                  </button>
                ))}
              </div>
            )}
          </div>

          {/* Footer: compact intensity control + Raycast-style keybinding hint strip. */}
          <div className="kbd-strip">
            <div className="seg compact" title="Applies to Professional / Casual / Concise / Expand">
              {LEVELS.map((l) => (
                <button
                  key={l}
                  className={`seg-btn ${level === l ? "active" : ""}`}
                  tabIndex={-1}
                  onClick={() => setLevel(l)}
                >
                  {l[0].toUpperCase() + l.slice(1)}
                </button>
              ))}
            </div>
            <span className="strip-keys">
              <kbd>↑↓</kbd> navigate · <kbd>↵</kbd> run · <kbd>esc</kbd> close
            </span>
            {dest}
          </div>
        </>
      )}

      {view.kind === "translate" && (
        <>
          <div className="view-head">
            <button className="back-btn" onClick={() => setView({ kind: "menu" })}>
              ← Back
            </button>
            <span className="view-title">Translate into…</span>
          </div>
          <div className="palette-body">
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
          </div>
          <div className="kbd-strip">
            <span className="strip-keys">
              <kbd>↑↓←→</kbd> move · <kbd>↵</kbd> pick · <kbd>esc</kbd> back
            </span>
            {dest}
          </div>
        </>
      )}

      {view.kind === "preview" && (
        <PreviewView
          target={view.target}
          selection={selection}
          status={status}
          onBack={() => {
            setView({ kind: "menu" });
            requestAnimationFrame(() => searchRef.current?.focus());
          }}
          onApplying={(label) => setView({ kind: "applying", label })}
          onDone={(result) => setView({ kind: "done", result })}
          onError={(message) => setView({ kind: "error", message })}
          dest={dest}
        />
      )}

      {view.kind === "applying" && (
        <div className="state">
          <div className="spinner" />
          <div className="state-label">{view.label}…</div>
        </div>
      )}

      {view.kind === "done" && (
        <div className="state result">
          <div className="state-label ok">
            {view.result.pasted ? "✓ Pasted" : "✓ Copied to clipboard"}
          </div>
          {!view.result.pasted && (
            <div className="hint">
              On the clipboard — press <kbd>Ctrl</kbd>+<kbd>V</kbd> to paste.
            </div>
          )}
          <pre className="output">{view.result.output}</pre>
          <div className="kbd-strip">
            <button className="back-btn" onClick={() => setView({ kind: "menu" })}>
              ← Back
            </button>
            <span className="strip-keys">
              <kbd>esc</kbd> close
            </span>
          </div>
        </div>
      )}

      {view.kind === "error" && (
        <div className="state error">
          <div className="state-label bad">⚠ {view.message}</div>
          <div className="kbd-strip">
            <button className="back-btn" onClick={() => setView({ kind: "menu" })}>
              ← Back
            </button>
          </div>
        </div>
      )}
    </div>
  );
}

// ---- Result-preview view -------------------------------------------------------------
// Streams the model output over the current selection (no clipboard side-effects), then
// offers Paste/Replace · Copy · Retry · Edit · Back. Paste/Replace re-runs the model via
// processAiAction/processAiCustom (which owns the clipboard snapshot + paste + restore).
function PreviewView({
  target,
  selection,
  status,
  onBack,
  onApplying,
  onDone,
  onError,
  dest,
}: {
  target: RunTarget;
  selection: string;
  status: Status | null;
  onBack: () => void;
  onApplying: (label: string) => void;
  onDone: (result: ProcessResult) => void;
  onError: (message: string) => void;
  dest: React.ReactNode;
}) {
  const [text, setText] = useState("");
  const [streaming, setStreaming] = useState(true);
  const [streamErr, setStreamErr] = useState("");
  const [copied, setCopied] = useState(false);
  const [nonce, setNonce] = useState(0); // bump to re-stream (Retry)
  const manual = status?.manual_mode ?? false;
  // Custom instructions have no streaming command, so we can't live-preview them.
  const customNoPreview = target.kind === "custom";

  const header =
    target.kind === "action"
      ? target.label
      : `“${target.label.length > 40 ? target.label.slice(0, 40) + "…" : target.label}”`;

  // Stream a fresh preview for action targets. `nonce` lets Retry re-run.
  useEffect(() => {
    if (target.kind !== "action") {
      setStreaming(false);
      return;
    }
    let cancelled = false;
    const unlisten: UnlistenFn[] = [];
    let acc = "";
    setText("");
    setStreamErr("");
    setStreaming(true);
    (async () => {
      try {
        unlisten.push(
          await listen<string>("ghostpen://chunk", (e) => {
            if (cancelled) return;
            acc += e.payload;
            setText(acc);
          }),
        );
        unlisten.push(
          await listen<string>("ghostpen://done", (e) => {
            if (cancelled) return;
            setText(e.payload);
            setStreaming(false);
          }),
        );
        unlisten.push(
          await listen<string>("ghostpen://error", (e) => {
            if (cancelled) return;
            setStreamErr(e.payload);
            setStreaming(false);
          }),
        );
        await processTextStream(target.id, target.targetLang, target.level, selection);
      } catch (e) {
        if (!cancelled) {
          setStreamErr(String(e));
          setStreaming(false);
        }
      }
    })();
    return () => {
      cancelled = true;
      unlisten.forEach((u) => u());
    };
  }, [target, selection, nonce]);

  // Apply: re-run through the clipboard-owning command to actually paste/replace.
  const apply = useCallback(async () => {
    onApplying(target.kind === "action" ? target.label : "Applying");
    try {
      const result =
        target.kind === "action"
          ? await processAiAction(target.id, target.targetLang, target.level)
          : await processAiCustom(target.instruction);
      onDone(result);
    } catch (e) {
      onError(String(e));
    }
  }, [target, onApplying, onDone, onError]);

  const copy = useCallback(async () => {
    try {
      await navigator.clipboard.writeText(text);
      setCopied(true);
      setTimeout(() => setCopied(false), 1200);
    } catch {
      /* ignore */
    }
  }, [text]);

  // Keyboard: Enter = paste/replace, c = copy, r = retry, e = edit (back).
  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if (e.key === "Enter") {
        e.preventDefault();
        if (!streaming) apply();
      } else if (e.key === "c" || e.key === "C") {
        if (customNoPreview) return;
        e.preventDefault();
        copy();
      } else if (e.key === "r" || e.key === "R") {
        if (customNoPreview) return;
        e.preventDefault();
        setNonce((nn) => nn + 1);
      } else if (e.key === "e" || e.key === "E") {
        e.preventDefault();
        onBack();
      }
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [streaming, apply, copy, onBack, customNoPreview]);

  return (
    <>
      <div className="view-head">
        <button className="back-btn" onClick={onBack}>
          ← Back
        </button>
        <span className="view-title">
          {header}
          {status && <span className="view-dest"> → {status.active_profile}</span>}
        </span>
      </div>

      <div className="palette-body preview-body">
        {streamErr ? (
          <div className="state error">
            <div className="state-label bad">⚠ {streamErr}</div>
          </div>
        ) : customNoPreview ? (
          <div className="preview-note">
            Live preview isn’t available for freeform instructions yet. Press <kbd>↵</kbd> to
            run “{target.label}” and apply it.
          </div>
        ) : (
          <pre className="output preview-output">
            {text}
            {streaming && <span className="caret">▍</span>}
          </pre>
        )}
      </div>

      <div className="kbd-strip preview-strip">
        <span className="strip-keys">
          <kbd>↵</kbd> {manual ? "copy" : "paste/replace"}
          {!customNoPreview && (
            <>
              {" "}· <kbd>c</kbd> {copied ? "copied ✓" : "copy"} · <kbd>r</kbd> retry
            </>
          )}{" "}
          · <kbd>e</kbd> edit · <kbd>esc</kbd> back
        </span>
        {dest}
      </div>
    </>
  );
}
