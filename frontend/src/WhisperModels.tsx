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
} from "./api";
import { Meter, noteText, sourceLabel } from "./LocalModels";

/** The speech model GhostPen suggests (large accuracy at small's size). */
export const RECOMMENDED_WHISPER = "large-v3-turbo-q5_0";

/** A readable name for a whisper model id ("large-v3-turbo-q5_0" → "Large v3 Turbo, 5-bit"). */
export function whisperName(id: string): string {
  const m = id.match(/^(tiny|base|small|medium|large-v3(?:-turbo)?)(?:\.(en))?(?:-q(\d)_0)?$/);
  if (!m) return id;
  const family = m[1].startsWith("large")
    ? m[1].replace("large-", "Large ").replace("-turbo", " Turbo")
    : m[1][0].toUpperCase() + m[1].slice(1);
  return family + (m[3] ? `, ${m[3]}-bit` : "") + (m[2] ? " (English only)" : "");
}

/** A catalog note without the part that only repeats the model's name ("large turbo, 8-bit" under "Large v3 Turbo, 8-bit"). */
function whisperNote(note: string, id: string): string {
  const name = whisperName(id).toLowerCase();
  const clauses = note
    .replace(/;?\s*recommended for dictation$/i, "")
    .split(/\s*;\s*/)
    .flatMap((c) => {
      const m = c.match(/^large[^,]*,\s*(.+)$/i);
      if (!m) return c ? [c] : [];
      return name.includes(m[1].toLowerCase()) ? [] : [m[1]];
    });
  return noteText(clauses.join("; "));
}

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

  // Up front: the recommended model, the one in use and whatever is downloaded;
  // the rest of the catalog waits behind "More models".
  const shownFirst = (m: (typeof models)[number]) =>
    m.id === RECOMMENDED_WHISPER || m.id === props.activeModel || m.path !== "" || m.partial > 0;
  const front = models
    .filter(shownFirst)
    .sort((a, b) => Number(b.id === RECOMMENDED_WHISPER) - Number(a.id === RECOMMENDED_WHISPER));
  const more = models.filter((m) => !shownFirst(m));

  /** The "Use" control: a state when it's the model in use, else a secondary button. */
  const useControl = (id: string, active: boolean) =>
    active ? (
      <span className="llm-state">✓ In use</span>
    ) : (
      <button className="btn" title="Use it for captions, meetings and dictation now" onClick={() => use(id)}>Use</button>
    );

  const deleteControl = (id: string, size: number) =>
    confirmDelete === id ? (
      <>
        <button className="btn" onClick={() => setConfirmDelete(null)}>Keep</button>
        <button className="btn danger solid llm-delete" onClick={() => remove(id)}>Delete {formatBytes(size)}?</button>
      </>
    ) : (
      <button className="btn danger llm-delete" onClick={() => setConfirmDelete(id)}>Delete…</button>
    );

  const row = (m: (typeof models)[number]) => {
    const installed = m.path !== "";
    const active = props.activeModel === m.id;
    const p = progress && progress.id === m.id ? progress : null;
    const pct = p && p.total > 0 ? Math.min(100, (p.done / p.total) * 100) : 0;
    return (
      <div key={m.id} className={`llm-row ${active ? "active" : ""}`}>
        <div className="llm-info">
          <div>
            <b title={m.id}>{whisperName(m.id)}</b> <span className="muted small">{formatBytes(m.size)}</span>
            {m.id === RECOMMENDED_WHISPER && <span className="llm-badge recommended">Recommended</span>}
          </div>
          <span className="llm-meta muted small">
            <Meter label="Speed" value={m.speed} />
            <Meter label="Accuracy" value={m.accuracy} />
            <span>{whisperNote(m.note, m.id)}</span>
          </span>
          {active && !installed && !p && (
            <span className="muted small">Not downloaded yet. Download it to use captions, meetings and Whisper dictation.</span>
          )}
          {installed && m.external && (
            <span className="muted small" title={m.path}>{sourceLabel(m.path)}, reused</span>
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
              {useControl(m.id, active)}
              {!m.external && !active && deleteControl(m.id, m.size)}
            </>
          ) : m.partial > 0 ? (
            <>
              <button className="btn download" disabled={busy} onClick={() => download(m.id)}>
                Resume ({Math.round((m.partial / m.size) * 100)}%)
              </button>
              {!active &&
                (confirmDelete === m.id ? (
                  <button className="btn danger solid llm-delete" disabled={busy} onClick={() => remove(m.id)}>Discard {formatBytes(m.partial)}?</button>
                ) : (
                  <button className="btn danger llm-delete" disabled={busy} onClick={() => setConfirmDelete(m.id)}>Clear</button>
                ))}
            </>
          ) : (
            <button className="btn download" disabled={busy} onClick={() => download(m.id)}>Download</button>
          )}
        </div>
      </div>
    );
  };

  return (
    <section className="card">
      <h2>Available speech models</h2>
      <div className="llm-list">{front.map(row)}</div>

      {more.length > 0 && (
        <details className="settings-advanced">
          <summary><span>More models ({more.length})</span><small>smaller and larger sizes, English-only versions</small></summary>
          <div className="settings-advanced-body">
            <div className="llm-list">{more.map(row)}</div>
          </div>
        </details>
      )}

      {others.length > 0 && (
        <>
          <h3>Also found on this computer</h3>
          <div className="llm-list">
            {others.map((o) => {
              const active = props.activeModel === o.id;
              return (
                <div key={o.path} className={`llm-row ${active ? "active" : ""}`} title={o.path}>
                  <div className="llm-info">
                    <div>
                      <b>{whisperName(o.id)}</b> <span className="muted small">{formatBytes(o.size)}</span>
                    </div>
                    <span className="muted small">{sourceLabel(o.path)}</span>
                  </div>
                  <div className="llm-actions">
                    {useControl(o.id, active)}
                    {!o.external && !active && deleteControl(o.id, o.size)}
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
