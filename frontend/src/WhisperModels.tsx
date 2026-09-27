import { useEffect, useState } from "react";
import { listen } from "./events";
import {
  LlmProgress,
  WhisperStatus,
  whisperModelsStatus,
  whisperDownloadModel,
  whisperCancelDownload,
  whisperDeleteModel,
  formatBytes,
  scoreMeter,
} from "./api";

/**
 * Settings → Speech models: the whisper models captions and dictation share.
 * Download (resumable, verified), pick one, delete; models GhostReel already
 * downloaded are reused.
 */
export default function WhisperModels(props: {
  /** settings.captions.model */
  activeModel: string;
  /** Use this model for captions and dictation (saves the settings). */
  onUse: (id: string) => Promise<void>;
}) {
  const [status, setStatus] = useState<WhisperStatus | null>(null);
  const [progress, setProgress] = useState<LlmProgress | null>(null);
  const [message, setMessage] = useState("");
  const [confirmDelete, setConfirmDelete] = useState<string | null>(null);

  const refresh = () =>
    whisperModelsStatus().then(setStatus).catch((e) => setMessage(String(e)));

  useEffect(() => {
    refresh();
    const un = listen<LlmProgress>("ghostpen://whisper-download", (e) => {
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
    window.addEventListener("focus", refresh);
    return () => {
      window.removeEventListener("focus", refresh);
      un.then((f) => f());
    };
  }, []);

  const download = async (id: string) => {
    setMessage("");
    setProgress({ id, state: "downloading", done: 0, total: 0, message: "" });
    try {
      await whisperDownloadModel(id);
    } catch (e) {
      // The progress event already said why, unless it never started.
      setMessage((m) => m || String(e));
    } finally {
      setProgress(null);
      refresh();
    }
  };

  const remove = async (id: string) => {
    setConfirmDelete(null);
    try {
      await whisperDeleteModel(id);
    } catch (e) {
      setMessage(String(e));
    }
    refresh();
  };

  const use = (id: string) => {
    setMessage("");
    props.onUse(id).then(refresh).catch((e) => setMessage(String(e)));
  };

  const models = status?.status.models ?? [];
  const others = status?.status.others ?? [];
  const busy = progress !== null || (status?.downloading ?? false);

  return (
    <section className="card">
      <h2>Speech models <span className="muted small">Whisper, for captions and dictation</span></h2>
      <p className="muted small">
        Live Captions and Dictation transcribe on this computer with the model you pick here.
        Larger models hear accents and uncommon words better, at the cost of speed and memory.
        Models GhostReel already downloaded are found and reused.
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
                  <b>{m.id}</b> <span className="muted small">{formatBytes(m.size)}</span>
                  {active && <span className="llm-badge">in use</span>}
                </div>
                <span className="muted small">
                  Speed {scoreMeter(m.speed)} · Accuracy {scoreMeter(m.accuracy)} · {m.note}
                </span>
                {active && !installed && !p && (
                  <span className="muted small">Not downloaded yet: captions and dictation need it.</span>
                )}
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
                  <button className="btn" onClick={() => whisperCancelDownload()}>Pause</button>
                ) : installed ? (
                  <>
                    <button className="btn primary" disabled={active} onClick={() => use(m.id)}>
                      {active ? "Using" : "Use"}
                    </button>
                    {!m.external && !active &&
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
                    {!active &&
                      (confirmDelete === m.id ? (
                        <button className="btn danger" disabled={busy} onClick={() => remove(m.id)}>Discard {formatBytes(m.partial)}?</button>
                      ) : (
                        <button className="btn" disabled={busy} onClick={() => setConfirmDelete(m.id)}>Clear</button>
                      ))}
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
                <div key={o.path} className={`llm-row ${active ? "active" : ""}`}>
                  <div className="llm-info">
                    <div>
                      <b>{o.id}</b> <span className="muted small">{formatBytes(o.size)}</span>
                      {active && <span className="llm-badge">in use</span>}
                    </div>
                    <span className="muted small llm-path" title={o.path}>{o.path}</span>
                  </div>
                  <div className="llm-actions">
                    <button className="btn primary" disabled={active} onClick={() => use(o.id)}>
                      {active ? "Using" : "Use"}
                    </button>
                    {!o.external && !active &&
                      (confirmDelete === o.id ? (
                        <>
                          <button className="btn danger" onClick={() => remove(o.id)}>Delete {formatBytes(o.size)}?</button>
                          <button className="btn" onClick={() => setConfirmDelete(null)}>Keep</button>
                        </>
                      ) : (
                        <button className="btn" onClick={() => setConfirmDelete(o.id)}>Delete</button>
                      ))}
                  </div>
                </div>
              );
            })}
          </div>
        </>
      )}

      {message && <p className="muted small llm-message">{message}</p>}
    </section>
  );
}
