import { useEffect, useState } from "react";
import { listen } from "./events";
import {
  LlmProgress,
  TtsCatalog,
  TtsState,
  ttsCatalog,
  ttsDownloadModel,
  ttsDownloadVoice,
  ttsCancelDownload,
  ttsDeleteModel,
  formatBytes,
} from "./api";

/**
 * Settings → Voices: the built-in Kokoro text-to-speech. Download the voice
 * model and as many voice packs as you like (each 511 KB, one per language),
 * delete them again. The phoneme data comes from the system package or
 * GhostPeers own folder; a missing one shows as a note (Linux desktops ship
 * it; the first Speak downloads nothing there).
 */
export default function Voices() {
  const [catalog, setCatalog] = useState<TtsCatalog | null>(null);
  const [progress, setProgress] = useState<LlmProgress | null>(null);
  const [message, setMessage] = useState("");
  const [state, setState] = useState<TtsState | null>(null);
  const [confirmDelete, setConfirmDelete] = useState<string | null>(null);

  const refresh = () => ttsCatalog().then(setCatalog).catch((e) => setMessage(String(e)));

  useEffect(() => {
    refresh();
    const un = listen<LlmProgress>("ghostpen://tts-download", (e) => {
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
    const unState = listen<TtsState>("ghostpen://tts-state", (e) => setState(e.payload));
    window.addEventListener("focus", refresh);
    return () => {
      window.removeEventListener("focus", refresh);
      un.then((f) => f());
      unState.then((f) => f());
    };
  }, []);

  const busy = progress !== null;

  const download = async (kind: "model" | "voice", id: string, size: number) => {
    setMessage("");
    setProgress({ id, state: "downloading", done: 0, total: size, message: "" });
    try {
      await (kind === "model" ? ttsDownloadModel(id) : ttsDownloadVoice(id));
    } catch (e) {
      setMessage((m) => m || String(e));
    } finally {
      setProgress(null);
      refresh();
    }
  };

  const remove = async (id: string) => {
    setConfirmDelete(null);
    try {
      await ttsDeleteModel(id);
    } catch (e) {
      setMessage(String(e));
    }
    refresh();
  };

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
        window (read the summary or the whole page). The first Speak happens
        after the model downloads here or at once from a download button below.
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
                  {state?.phase === "generating" && <span className="llm-badge muted">in use</span>}
                </div>
                <span className="muted small">{m.note}</span>
                {p && (
                  <div className="llm-progress">
                    <div className="llm-bar"><div style={{ width: `${showPct}%` }} /></div>
                    <span className="muted small">
                      {p.state === "verifying" ? p.message || "Checking…" : `${formatBytes(p.done)} of ${formatBytes(p.total || m.size)}`}
                    </span>
                  </div>
                )}
              </div>
              <div className="llm-actions">
                {p ? (
                  <button className="btn" onClick={() => ttsCancelDownload()}>Pause</button>
                ) : m.downloaded ? (
                  confirmDelete === m.id ? (
                    <>
                      <button className="btn danger" onClick={() => remove(m.id)}>Delete {formatBytes(m.size)}?</button>
                      <button className="btn" onClick={() => setConfirmDelete(null)}>Keep</button>
                    </>
                  ) : (
                    <button className="btn" onClick={() => setConfirmDelete(m.id)}>Delete</button>
                  )
                ) : (m.partial ?? 0) > 0 ? (
                  <button className="btn" disabled={busy} onClick={() => download("model", m.id, m.size)}>
                    Resume ({Math.round(((m.partial ?? 0) / m.size) * 100)}%)
                  </button>
                ) : (
                  <button className="btn" disabled={busy} onClick={() => download("model", m.id, m.size)}>Download</button>
                )}
              </div>
            </div>
          );
        })}
      </div>

      <h3>Voice packs</h3>
      <p className="muted small">
        One voice per language at a time while playing; the menu picks the matching one automatically when you translate.
      </p>
      <div className="llm-list">
        {voices.map((v) => {
          const p = progress && progress.id === v.id ? progress : null;
          const showPct = p && p.total > 0 ? Math.min(100, (p.done / p.total) * 100) : 0;
          return (
            <div key={v.id} className={`llm-row ${state?.voice === v.id ? "active" : ""}`}>
              <div className="llm-info">
                <div>
                  <b>{v.label}</b> <span className="muted small">{formatBytes(v.size)}</span>
                  {v.downloaded && <span className="llm-badge">downloaded</span>}
                  {state?.voice === v.id && <span className="llm-badge">playing</span>}
                </div>
                <span className="muted small">{v.lang}</span>
                {p && (
                  <div className="llm-progress">
                    <div className="llm-bar"><div style={{ width: `${showPct}%` }} /></div>
                    <span className="muted small">
                      {p.state === "verifying" ? p.message || "Checking…" : `${formatBytes(p.done)} of ${formatBytes(p.total || v.size)}`}
                    </span>
                  </div>
                )}
              </div>
              <div className="llm-actions">
                {p ? (
                  <button className="btn" onClick={() => ttsCancelDownload()}>Pause</button>
                ) : v.downloaded ? null : (
                  <button className="btn" disabled={busy} onClick={() => download("voice", v.id, v.size)}>Download</button>
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
          : "Not found yet: on Linux it usually comes with the espeak-ng package (`sudo pacman -S espeak-ng` on Arch, `apt install espeak-ng` on Debian); on macOS `brew install espeak-ng`."}
      </p>

      {message && <p className="settings-error">{message}</p>}
    </section>
  );
}
