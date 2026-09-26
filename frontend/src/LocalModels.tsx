import { useEffect, useState } from "react";
import { listen } from "./events";
import {
  LlmStatus,
  LlmProgress,
  LocalLlmSettings,
  llmModelsStatus,
  llmDownloadModel,
  llmCancelDownload,
  llmDeleteModel,
  llmUnload,
  formatBytes,
  scoreMeter,
} from "./api";

export const DEFAULT_LOCAL: LocalLlmSettings = { ctxTokens: 8192, gpu: true, idleMinutes: 10 };

const CONTEXT_SIZES = [2048, 4096, 8192, 16384, 32768];

/**
 * Settings → Built-in models: download the catalog models (resumable, verified),
 * pick one for the "Built-in" profile, and tune the runner.
 */
export default function LocalModels(props: {
  local: LocalLlmSettings;
  onLocalChange: (patch: Partial<LocalLlmSettings>) => void;
  /** The model the local profile uses (catalog id or "file:<path>"), if any. */
  activeModel: string | null;
  /** Use this model for the "Built-in" profile (and make it active). */
  onUse: (id: string, name: string) => void;
  /** A model was downloaded or deleted. */
  onChanged?: () => void;
}) {
  const [status, setStatus] = useState<LlmStatus | null>(null);
  const [progress, setProgress] = useState<LlmProgress | null>(null);
  const [message, setMessage] = useState("");
  const [confirmDelete, setConfirmDelete] = useState<string | null>(null);

  const refresh = () =>
    llmModelsStatus()
      .then((st) => {
        setStatus(st);
        props.onChanged?.();
      })
      .catch((e) => setMessage(String(e)));

  useEffect(() => {
    refresh();
    const un = listen<LlmProgress>("ghostpen://llm-download", (e) => {
      const p = e.payload;
      if (p.state === "done" || p.state === "cancelled" || p.state === "error") {
        setProgress(null);
        if (p.state === "error") setMessage(p.message);
        if (p.state === "cancelled") setMessage("Download paused: resume it any time.");
        refresh();
      } else {
        setProgress(p);
      }
    });
    return () => {
      un.then((f) => f());
    };
  }, []);

  const download = async (id: string) => {
    setMessage("");
    setProgress({ id, state: "downloading", done: 0, total: 0, message: "" });
    try {
      await llmDownloadModel(id);
    } catch (e) {
      setMessage(String(e));
    } finally {
      setProgress(null);
      refresh();
    }
  };

  const remove = async (id: string) => {
    setConfirmDelete(null);
    try {
      await llmDeleteModel(id);
    } catch (e) {
      setMessage(String(e));
    }
    refresh();
  };

  const local = props.local;
  const models = status?.status.models ?? [];
  const others = status?.status.others ?? [];
  const busy = progress !== null || (status?.downloading ?? false);

  return (
    <section className="card">
      <h2>Built-in models <span className="muted small">run by GhostPen itself</span></h2>
      <p className="muted small">
        GhostPen runs these models itself, with its embedded llama.cpp: no server, no
        Ollama or LM Studio needed, nothing sent over the network. Use one with a profile set to
        {" "}<b>Built-in</b> (the <b>Use</b> button creates one).
        Models LM Studio or GhostReel already downloaded are found and reused.
        Image text extraction still needs a vision endpoint.
      </p>

      <div className="llm-list">
        {models.map((m) => {
          const installed = m.path !== "";
          const active = props.activeModel === m.id;
          const p = progress && progress.id === m.id ? progress : null;
          const pct = p && p.total > 0 ? Math.min(100, (p.done / p.total) * 100) : 0;
          return (
            <div key={m.id} className={`llm-row ${active ? "active" : ""}`}>
              <div className="llm-info">
                <div>
                  <b>{m.name}</b> <span className="muted small">{formatBytes(m.size)}</span>
                  {active && <span className="llm-badge">in use</span>}
                </div>
                <span className="muted small">
                  Speed {scoreMeter(m.speed)} · Quality {scoreMeter(m.quality)} · {m.note}
                </span>
                {installed && m.external && (
                  <span className="muted small" title={m.path}>Found in another app's folder: reused</span>
                )}
                {p && (
                  <div className="llm-progress">
                    <div className="llm-bar"><div style={{ width: `${pct}%` }} /></div>
                    <span className="muted small">
                      {p.state === "verifying"
                        ? p.message || "Checking…"
                        : `${formatBytes(p.done)} of ${formatBytes(p.total || m.size)}`}
                    </span>
                  </div>
                )}
              </div>
              <div className="llm-actions">
                {p ? (
                  <button className="btn" onClick={() => llmCancelDownload()}>Pause</button>
                ) : installed ? (
                  <>
                    <button className="btn primary" disabled={active} onClick={() => props.onUse(m.id, m.name)}>
                      {active ? "Using" : "Use"}
                    </button>
                    {!m.external &&
                      (confirmDelete === m.id ? (
                        <>
                          <button className="btn danger" onClick={() => remove(m.id)}>Delete {formatBytes(m.size)}?</button>
                          <button className="btn" onClick={() => setConfirmDelete(null)}>Keep</button>
                        </>
                      ) : (
                        <button className="btn" onClick={() => setConfirmDelete(m.id)}>Delete</button>
                      ))}
                  </>
                ) : m.partial > 0 ? (
                  <>
                    <button className="btn" disabled={busy} onClick={() => download(m.id)}>
                      Resume ({Math.round((m.partial / m.size) * 100)}%)
                    </button>
                    <button className="btn" disabled={busy} onClick={() => remove(m.id)}>Clear</button>
                  </>
                ) : (
                  <button className="btn" disabled={busy} onClick={() => download(m.id)}>Download</button>
                )}
              </div>
            </div>
          );
        })}
      </div>

      {others.length > 0 && (
        <>
          <h3>Also found on this computer</h3>
          <div className="llm-list">
            {others.map((o) => {
              const active = props.activeModel === o.id;
              return (
                <div key={o.id} className={`llm-row ${active ? "active" : ""}`}>
                  <div className="llm-info">
                    <div>
                      <b>{o.name}</b> <span className="muted small">{formatBytes(o.size)}</span>
                      {active && <span className="llm-badge">in use</span>}
                    </div>
                    <span className="muted small llm-path" title={o.path}>{o.path}</span>
                  </div>
                  <div className="llm-actions">
                    <button className="btn primary" disabled={active} onClick={() => props.onUse(o.id, o.name)}>
                      {active ? "Using" : "Use"}
                    </button>
                  </div>
                </div>
              );
            })}
          </div>
        </>
      )}

      {message && <p className="muted small llm-message">{message}</p>}

      <h3>Runner</h3>
      <label>
        Context window
        <select value={local.ctxTokens} onChange={(e) => props.onLocalChange({ ctxTokens: parseInt(e.target.value, 10) })}>
          {CONTEXT_SIZES.map((n) => (
            <option key={n} value={n}>{`${n / 1024}k tokens${n === 8192 ? " (recommended)" : ""}`}</option>
          ))}
        </select>
        <span className="muted small">Room for the text and the answer. Larger uses more memory.</span>
      </label>
      <label className="checkbox">
        <input type="checkbox" checked={local.gpu} onChange={(e) => props.onLocalChange({ gpu: e.target.checked })} />
        Use the GPU <span className="muted">(as much of the model as its free memory holds; off = CPU only)</span>
      </label>
      <label>
        Unload after {local.idleMinutes === 0 ? "never" : `${local.idleMinutes} min`} idle
        <input type="range" min={0} max={60} step={5} value={local.idleMinutes}
          onChange={(e) => props.onLocalChange({ idleMinutes: parseInt(e.target.value, 10) })} />
        <span className="muted small">The model stays loaded between actions for speed, then frees its memory.</span>
      </label>
      <div className="row">
        <span className="muted small">
          {status?.loaded ? "A model is loaded now." : "No model loaded."} Models folder: <code>{status?.status.dir}</code>
        </span>
        {status?.loaded && (
          <button className="btn" onClick={() => llmUnload().then(refresh)}>Unload now</button>
        )}
      </div>
    </section>
  );
}
