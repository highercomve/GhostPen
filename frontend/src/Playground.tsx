import { useEffect, useMemo, useState } from "react";
import { listen, type UnlistenFn } from "./events";
import LevelBar from "./LevelBar";
import { Icon } from "./icons";
import PageHeader from "./PageHeader";
import { wordDiff } from "./wordDiff";
import {
  Status,
  CustomAction,
  Level,
  getStatus,
  getSettings,
  processTextStream,
  TRANSLATE_LANGUAGES,
} from "./api";

const ACTIONS = [
  { id: "proofread", label: "Proofread" },
  { id: "professional", label: "Professional" },
  { id: "casual", label: "Casual" },
  { id: "concise", label: "Concise" },
  { id: "expand", label: "Expand" },
];

export default function Playground() {
  const [status, setStatus] = useState<Status | null>(null);
  const [customActions, setCustomActions] = useState<CustomAction[]>([]);
  const [input, setInput] = useState("");
  const [output, setOutput] = useState("");
  const [lang, setLang] = useState("Spanish");
  const [level, setLevel] = useState<Level>("balanced");
  const [busy, setBusy] = useState<string | null>(null);
  const [error, setError] = useState("");
  const [copied, setCopied] = useState(false);
  const [hotkey, setHotkey] = useState("Ctrl+Shift+A");
  // The action that produced the result, and whether it shows against the input.
  const [resultLabel, setResultLabel] = useState("");
  const [showChanges, setShowChanges] = useState(false);
  // The input the result was made from (the box may be edited afterwards).
  const [source, setSource] = useState("");

  // On load and whenever the window comes back (the profile or its custom
  // actions may have changed in Settings meanwhile).
  useEffect(() => {
    const load = () => {
      getStatus().then(setStatus).catch(() => {});
      getSettings()
        .then((s) => {
          setCustomActions(s.customActions ?? []);
          if (s.hotkey) setHotkey(s.hotkey);
        })
        .catch(() => {});
    };
    load();
    window.addEventListener("focus", load);
    return () => window.removeEventListener("focus", load);
  }, []);

  const [prompt, setPrompt] = useState("");

  const run = async (action: string, targetLang: string | null, label: string, instruction?: string) => {
    if (!input.trim() || busy) return;
    setBusy(label);
    setError("");
    setOutput("");
    setResultLabel(label);
    setSource(input);
    const unlisten: UnlistenFn[] = [];
    let acc = "";
    try {
      unlisten.push(
        await listen<string>("ghostpen://chunk", (e) => {
          acc += e.payload;
          setOutput(acc);
        }),
      );
      unlisten.push(await listen<string>("ghostpen://done", (e) => setOutput(e.payload)));
      unlisten.push(await listen<string>("ghostpen://error", (e) => setError(e.payload)));
      await processTextStream(action, targetLang, level, input, instruction);
    } catch (e) {
      setError(String(e));
    } finally {
      unlisten.forEach((u) => u());
      setBusy(null);
    }
  };

  const copyOut = async () => {
    try {
      await navigator.clipboard.writeText(output);
      setCopied(true);
      setTimeout(() => setCopied(false), 1200);
    } catch {
      /* ignore */
    }
  };

  const hasInput = input.trim().length > 0;
  const diff = useMemo(() => (showChanges && output ? wordDiff(source, output) : []), [showChanges, output, source]);
  const blocked = !!busy || !hasInput;
  const android = document.documentElement.classList.contains("platform-android");

  return (
    <div className="playground">
      <div className="pg-wrap">
        <PageHeader
          title="Playground"
          subtitle="Try an action on any text here before you use it in another app."
          status={status}
        />

        <div className="pg-controls">
          <div className="pg-actions">
            {ACTIONS.map((a) => (
              <button
                key={a.id}
                className="btn pg-action"
                disabled={blocked}
                onClick={() => run(a.id, null, a.label)}
              >
                {busy === a.label ? "…" : a.label}
              </button>
            ))}
            {/* One control: the main part translates into the chosen language, the chevron picks it. */}
            <span className={`pg-split ${blocked ? "blocked" : ""}`}>
              <button
                className="btn pg-action"
                disabled={blocked}
                onClick={() => run("translate", lang, `Translate → ${lang}`)}
              >
                {busy?.startsWith("Translate") ? "…" : `Translate → ${lang}`}
              </button>
              <select value={lang} onChange={(e) => setLang(e.target.value)} aria-label="Translate into" title="Choose the language">
                {TRANSLATE_LANGUAGES.map((l) => (
                  <option key={l} value={l}>{l}</option>
                ))}
              </select>
            </span>
            <LevelBar level={level} setLevel={setLevel} />
          </div>

          {customActions.length > 0 && (
            <div className="pg-actions">
              <span className="pg-actions-label">Your actions</span>
              {customActions.map((a) => (
                <button
                  key={a.id}
                  className="btn pg-action"
                  disabled={blocked}
                  onClick={() => run(a.id, null, a.label)}
                >
                  {busy === a.label ? "…" : a.label}
                </button>
              ))}
            </div>
          )}
          {/* Freeform instruction, like the menu's prompt bar. */}
          <form
            className="prompt-bar pg-prompt"
            onSubmit={(e) => {
              e.preventDefault();
              if (prompt.trim()) run("custom", null, "Instruction", prompt.trim());
            }}
          >
            <input
              className="prompt-input"
              value={prompt}
              placeholder="Or tell GhostPen what to do… (e.g. “turn this into a bulleted list”)"
              onChange={(e) => setPrompt(e.target.value)}
              aria-label="Instruction"
            />
            <button
              type="submit"
              className="prompt-send"
              disabled={blocked || !prompt.trim()}
              title="Run instruction (Enter)"
              aria-label="Run instruction"
            >
              {busy === "Instruction" ? "…" : <Icon name="send" />}
            </button>
          </form>
        </div>

        {error && <div className="pg-error">⚠ {error}</div>}

        <div className="pg-panes">
          <div className="pg-label">
            <span className="pg-pane-head">
              <span>Input</span>
              <button
                type="button"
                className="btn pg-mini"
                disabled={!input && !output && !error}
                title="Empty the input and the result"
                onClick={() => { setInput(""); setOutput(""); setError(""); setResultLabel(""); setSource(""); }}
              >
                Clear all
              </button>
            </span>
            <textarea
              className="pg-area"
              value={input}
              placeholder="Type or paste text here to start, then pick an action above…"
              aria-label="Input"
              onChange={(e) => setInput(e.target.value)}
            />
          </div>
          <div className={`pg-label pg-result-pane${output ? " has-output" : ""}`}>
            <div className="pg-pane-head">
              <span>
                Result
                {resultLabel && output ? <> · <strong>{resultLabel}</strong></> : null}
                {busy && <span className="pg-working"> · working…</span>}
              </span>
              <span className="pg-pane-tools">
                {output && !busy && (
                  <label className="pg-switch" title="Highlight the words the result added and removed">
                    <input type="checkbox" role="switch" checked={showChanges} onChange={(e) => setShowChanges(e.target.checked)} />
                    <span className="switch-track" aria-hidden="true"><span className="switch-thumb" /></span>
                    <span>Show changes</span>
                  </label>
                )}
                <button
                  type="button"
                  className="btn pg-mini"
                  disabled={!output || !!busy}
                  onClick={() => setInput(output)}
                  title={output ? "Put the result in the Input box" : "Run an action first"}
                >
                  Use as input
                </button>
                <button
                  type="button"
                  className="btn pg-mini"
                  disabled={!output || !!busy}
                  onClick={copyOut}
                  title={output ? "Copy the result" : "Run an action first"}
                >
                  {copied ? "Copied ✓" : "Copy"}
                </button>
              </span>
            </div>
            {showChanges && output && !busy ? (
              <div className="pg-area result pg-diff" tabIndex={0} aria-label="Result with changes marked">
                {diff.map((d, i) =>
                  d.type === "ins" ? <ins key={i}>{d.text}</ins> : d.type === "del" ? <del key={i}>{d.text}</del> : <span key={i}>{d.text}</span>,
                )}
              </div>
            ) : !hasInput && !output && !busy ? (
              <div className="pg-area result pg-start" aria-label="Getting started">
                <h2>Getting started</h2>
                {android ? (
                  <ol>
                    <li>Paste or type text on the left.</li>
                    <li>Pick an action, or type an instruction.</li>
                    <li>Copy the result, or use it as the next input.</li>
                  </ol>
                ) : (
                  <ol>
                    <li>Select text in any app.</li>
                    <li>
                      {status?.hotkeys_unavailable ? (
                        <>Run <code>ghostpen --trigger</code> (bind it to a key in your desktop)</>
                      ) : (
                        <>Press <kbd>{hotkey}</kbd></>
                      )}
                    </li>
                    <li>Pick an action, or type an instruction. In the other app, the result replaces your selection.</li>
                  </ol>
                )}
                <p className="pg-start-hint">
                  Captions, dictation and meetings live in the tray menu and in Settings → Speech.
                </p>
              </div>
            ) : (
              <textarea
                className="pg-area result"
                value={output}
                readOnly
                aria-label="Result"
                placeholder={busy ? "Working…" : "The result appears here."}
              />
            )}
          </div>
        </div>
      </div>
    </div>
  );
}
