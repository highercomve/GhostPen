import { useEffect, useState } from "react";
import { listen } from "./events";
import {
  TtsCatalog,
  TtsDownload,
  TtsState,
  ttsCatalog,
  ttsDownload,
  ttsDelete,
  listenVoice,
  formatBytes,
} from "./api";

/**
 * Settings → Voices: the built-in Kokoro text-to-speech (oriel.tts). Download
 * the voice model and as many voice packs as you like (each 511 KB, one per
 * language), delete them again. The phoneme data ships with GhostPen (the
 * system's espeak-ng data is used when the bundled copy is missing).
 */
export default function Voices() {
  const [catalog, setCatalog] = useState<TtsCatalog | null>(null);
  const [progress, setProgress] = useState<{ id: string; done: number; total: number } | null>(null);
  const [message, setMessage] = useState("");
  const [state, setState] = useState<TtsState | null>(null);
  const [confirmDelete, setConfirmDelete] = useState<string | null>(null);

  const refresh = () => ttsCatalog().then(setCatalog).catch((e) => setMessage(String(e)));

  useEffect(() => {
    refresh();
    const un = listen<TtsDownload>("tts:download", (e) => {
      const p = e.payload;
      const total = p.total_mb * 1048576;
      if (p.done_mb >= p.total_mb) {
        setProgress(null);
        refresh();
      } else {
        setProgress({ id: p.id, done: p.done_mb * 1048576, total });
      }
    });
    const unState = listenVoice(setState);
    window.addEventListener("focus", refresh);
    return () => {
      window.removeEventListener("focus", refresh);
      un.then((f) => f());
      unState.then((f) => f());
    };
  }, []);

  const busy = progress !== null || !!catalog?.downloading;
  const inUse = state?.phase === "generating" || state?.phase === "playing";

  const download = async (id: string, size: number) => {
    setMessage("");
    setProgress({ id, done: 0, total: size });
    try {
      await ttsDownload(id);
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
      await ttsDelete(id);
    } catch (e) {
      setMessage(String(e));
    }
    refresh();
  };

  const deleteButtons = (id: string, size: number) =>
    confirmDelete === id ? (
      <>
        <button className="btn danger" onClick={() => remove(id)}>Delete {formatBytes(size)}?</button>
        <button className="btn" onClick={() => setConfirmDelete(null)}>Keep</button>
      </>
    ) : (
      <button className="btn" onClick={() => setConfirmDelete(id)}>Delete</button>
    );

  const models = catalog?.models ?? [];
  const voices = catalog?.voices ?? [];
  const pct = progress && progress.total > 0 ? Math.min(100, (progress.done / progress.total) * 100) : 0;

  return (
    <section className="card">
      <h2>
        Voice model <span className="muted small">what reads your text aloud</span>
      </h2>
      <p className="muted small">
        The built-in voice runs on this computer. Speak it from the menu's
        result (<b>🔊 Speak</b>, or press <kbd>S</kbd>) and from the summary
        window (read the summary or the whole page). The first Speak downloads
        the model and the voice for its language, or fetch them below.
        {catalog && <> Runs on <b>{catalog.backend}</b>{catalog.gpu ? ` (${catalog.gpu})` : ""}.</>}
      </p>

      <div className="llm-list">
        {models.map((m) => {
          const p = progress && progress.id === m.id ? progress : null;
          const showPct = p && p.total > 0 ? Math.min(100, (p.done / p.total) * 100) : 0;
          return (
            <div key={m.id} className="llm-row">
              <div className="llm-info">
                <div>
                  <b>{m.label}</b> <span className="muted small">{formatBytes(m.size)}</span>
                  {m.downloaded && <span className="llm-badge">downloaded</span>}
                  {inUse && m.downloaded && <span className="llm-badge muted">in use</span>}
                </div>
                <span className="muted small">{m.note}</span>
                {p && (
                  <div className="llm-progress">
                    <div className="llm-bar"><div style={{ width: `${showPct}%` }} /></div>
                    <span className="muted small">
                      {`${formatBytes(p.done)} of ${formatBytes(p.total || m.size)}`}
                    </span>
                  </div>
                )}
              </div>
              <div className="llm-actions">
                {p ? null : m.downloaded ? (
                  deleteButtons(m.id, m.size)
                ) : (
                  <button className="btn" disabled={busy} onClick={() => download(m.id, m.size)}>Download</button>
                )}
              </div>
            </div>
          );
        })}
      </div>

      <h3>Voice packs</h3>
      <p className="muted small">
        Read and Speak pick a voice of the text's language (guessed, or the translation's) that is on this computer.
      </p>
      <div className="llm-list">
        {voices.map((v) => {
          const p = progress && progress.id === v.id ? progress : null;
          const showPct = p && p.total > 0 ? Math.min(100, (p.done / p.total) * 100) : 0;
          return (
            <div key={v.id} className={`llm-row ${inUse && state?.voice === v.id ? "active" : ""}`}>
              <div className="llm-info">
                <div>
                  <b>{v.label}</b> <span className="muted small">{formatBytes(v.size)}</span>
                  {v.downloaded && <span className="llm-badge">downloaded</span>}
                  {inUse && state?.voice === v.id && <span className="llm-badge">playing</span>}
                </div>
                <span className="muted small">{v.lang}</span>
                {p && (
                  <div className="llm-progress">
                    <div className="llm-bar"><div style={{ width: `${showPct}%` }} /></div>
                    <span className="muted small">
                      {`${formatBytes(p.done)} of ${formatBytes(p.total || v.size)}`}
                    </span>
                  </div>
                )}
              </div>
              <div className="llm-actions">
                {p ? null : v.downloaded ? (
                  deleteButtons(v.id, v.size)
                ) : (
                  <button className="btn" disabled={busy} onClick={() => download(v.id, v.size)}>Download</button>
                )}
              </div>
            </div>
          );
        })}
      </div>

      <h3>Phoneme data</h3>
      <p className="muted small">
        {catalog?.espeak_ready
          ? <>Found: <code>{catalog!.espeak_source}</code> — the engine reads its pronunciation rules from here.</>
          : "Not found: GhostPen ships it in espeak-ng-data next to the program; reinstall GhostPen, or install your system's espeak-ng package."}
      </p>

      {message && <p className="settings-error">{message}</p>}
    </section>
  );
}
