import { useEffect, useState } from "react";
import { listen, UnlistenFn } from "@tauri-apps/api/event";
import LevelBar from "./LevelBar";
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

  useEffect(() => {
    getStatus().then(setStatus).catch(() => {});
    getSettings()
      .then((s) => setCustomActions(s.customActions ?? []))
      .catch(() => {});
  }, []);

  const run = async (action: string, targetLang: string | null, label: string) => {
    if (!input.trim() || busy) return;
    setBusy(label);
    setError("");
    setOutput("");
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
      await processTextStream(action, targetLang, level, input);
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

  return (
    <div className="playground">
      <header className="pg-head">
        <h1>Playground</h1>
        {status && (
          <span className="dest">
            → {status.active_profile} · <code>{status.active_model}</code>
          </span>
        )}
      </header>

      <label className="pg-label">
        Input
        <textarea
          className="pg-area"
          value={input}
          placeholder="Type or paste text here, then run an action…"
          onChange={(e) => setInput(e.target.value)}
        />
      </label>

      <LevelBar level={level} setLevel={setLevel} />

      <div className="pg-actions">
        {ACTIONS.map((a) => (
          <button
            key={a.id}
            className="btn"
            disabled={!!busy || !input.trim()}
            onClick={() => run(a.id, null, a.label)}
          >
            {busy === a.label ? "…" : a.label}
          </button>
        ))}
        <span className="pg-translate">
          <select value={lang} onChange={(e) => setLang(e.target.value)}>
            {TRANSLATE_LANGUAGES.map((l) => (
              <option key={l} value={l}>{l}</option>
            ))}
          </select>
          <button
            className="btn"
            disabled={!!busy || !input.trim()}
            onClick={() => run("translate", lang, `Translate → ${lang}`)}
          >
            {busy?.startsWith("Translate") ? "…" : "Translate"}
          </button>
        </span>
      </div>

      {customActions.length > 0 && (
        <div className="pg-actions">
          {customActions.map((a) => (
            <button
              key={a.id}
              className="btn"
              disabled={!!busy || !input.trim()}
              onClick={() => run(a.id, null, a.label)}
            >
              {busy === a.label ? "…" : a.label}
            </button>
          ))}
        </div>
      )}

      {error && <div className="pg-error">⚠ {error}</div>}

      <label className="pg-label">
        Result
        <textarea className="pg-area result" value={output} readOnly placeholder="Result appears here…" />
      </label>

      <div className="pg-footer">
        <button className="btn" disabled={!output} onClick={() => setInput(output)}>
          Use as input
        </button>
        <button className="btn" disabled={!output} onClick={copyOut}>
          {copied ? "Copied ✓" : "Copy result"}
        </button>
        <button className="btn" onClick={() => { setInput(""); setOutput(""); setError(""); }}>
          Clear
        </button>
      </div>
    </div>
  );
}
