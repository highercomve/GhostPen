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
  ttsSpeak,
  ttsStop,
} from "./api";

/** A sentence to hear a voice with, in its language (espeak codes). */
const SAMPLES: Record<string, string> = {
  en: "Hello! This is how I sound when GhostPen reads your text aloud.",
  es: "¡Hola! Así sueno cuando GhostPen lee tu texto en voz alta.",
  fr: "Bonjour ! Voici ma voix quand GhostPen lit votre texte à voix haute.",
  pt: "Olá! É assim que eu soo quando o GhostPen lê o seu texto em voz alta.",
  it: "Ciao! Ecco come suono quando GhostPen legge il tuo testo ad alta voce.",
  ja: "こんにちは。GhostPenがあなたの文章を読み上げるときの声です。",
  zh: "你好！这是GhostPen为你朗读文字时的声音。",
  hi: "नमस्ते! जब GhostPen आपका पाठ पढ़ता है, तो मेरी आवाज़ ऐसी होती है।",
};
export const sampleFor = (lang: string) => SAMPLES[lang.split("-")[0]] ?? SAMPLES.en;

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
  const busySample = inUse || state?.phase === "downloading";
  const modelReady = (catalog?.models ?? []).some((m) => m.downloaded);
  const modelSize = catalog?.models?.[0]?.size ?? 0;
  /** Play a voice's sample (downloading what it needs first), or stop the one playing. */
  const play = (voice: string, lang: string) => {
    if (busySample && state?.voice === voice) return void ttsStop().catch(() => {});
    ttsSpeak(sampleFor(lang), lang, voice).catch((e) => setMessage(String(e)));
  };

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
        <button className="btn" onClick={() => setConfirmDelete(null)}>Keep</button>
        <button className="btn danger solid llm-delete" onClick={() => remove(id)}>Delete {formatBytes(size)}?</button>
      </>
    ) : (
      <button className="btn danger llm-delete" onClick={() => setConfirmDelete(id)}>Delete…</button>
    );

  const models = catalog?.models ?? [];
  const voices = catalog?.voices ?? [];
  const pct = progress && progress.total > 0 ? Math.min(100, (progress.done / progress.total) * 100) : 0;

  // "English (US) · Heart" → the language and the voice's name.
  const splitLabel = (label: string): [string, string] => {
    const at = label.indexOf(" · ");
    return at < 0 ? ["Other", label] : [label.slice(0, at), label.slice(at + 3)];
  };
  // Grouped by language (catalog order), the groups with a downloaded voice first.
  const groups: { language: string; voices: typeof voices }[] = [];
  for (const v of voices) {
    const language = splitLabel(v.label)[0];
    const g = groups.find((x) => x.language === language);
    if (g) g.voices.push(v);
    else groups.push({ language, voices: [v] });
  }
  // A voice name used by more than one language ("Dora") says which one it is.
  const nameCount = new Map<string, number>();
  for (const v of voices) {
    const n = splitLabel(v.label)[1];
    nameCount.set(n, (nameCount.get(n) ?? 0) + 1);
  }
  const languageName = (v: (typeof voices)[number]): string => {
    try {
      const n = v.lang ? new Intl.DisplayNames(["en"], { type: "language" }).of(v.lang) : undefined;
      if (n && n !== v.lang) return n;
    } catch { /* An unknown code: use the group's own name. */ }
    return splitLabel(v.label)[0];
  };
  const voiceName = (v: (typeof voices)[number]): string => {
    const n = splitLabel(v.label)[1];
    return (nameCount.get(n) ?? 0) > 1 ? `${n} · ${languageName(v)}` : n;
  };
  const hasDownloaded = (g: (typeof groups)[number]) => g.voices.some((v) => v.downloaded);
  groups.sort((a, b) => Number(hasDownloaded(b)) - Number(hasDownloaded(a)));
  const downloadedCount = voices.filter((v) => v.downloaded).length;

  const voiceRow = (v: (typeof voices)[number]) => {
    const p = progress && progress.id === v.id ? progress : null;
    const showPct = p && p.total > 0 ? Math.min(100, (p.done / p.total) * 100) : 0;
    const speaking = inUse && state?.voice === v.id;
    return (
      <div key={v.id} className={`llm-row voice-row ${v.downloaded ? "downloaded" : ""} ${speaking ? "active" : ""}`}>
        <div className="llm-info">
          <div>
            <b>{voiceName(v)}</b>{" "}
            <span className="muted small">{formatBytes(v.size)}</span>
            {v.downloaded && <span className="llm-badge downloaded">✓ Downloaded</span>}
            {speaking && <span className="llm-badge">Playing</span>}
          </div>
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
          {!p && (
            <button
              className="btn"
              onClick={() => play(v.id, v.lang ?? "en-us")}
              title={v.downloaded && modelReady ? "Hear a sample of this voice" : `Hear a sample of this voice. Downloads ${formatBytes((v.downloaded ? 0 : v.size) + (modelReady ? 0 : modelSize))} first.`}
            >
              {busySample && state?.voice === v.id ? "■ Stop" : "▶ Preview"}
            </button>
          )}
          {p ? null : v.downloaded ? (
            deleteButtons(v.id, v.size)
          ) : (
            <button className="btn download" disabled={busy} onClick={() => download(v.id, v.size)}>Download</button>
          )}
        </div>
      </div>
    );
  };

  return (
    <section className="card">
      <h2>
        Voice model <span className="muted small">what reads your text aloud</span>
      </h2>
      {catalog && (
        <p className="muted small">Runs on <b>{catalog.backend}</b>{catalog.gpu ? ` (${catalog.gpu})` : ""}.</p>
      )}

      <div className="llm-list">
        {models.map((m) => {
          const p = progress && progress.id === m.id ? progress : null;
          const showPct = p && p.total > 0 ? Math.min(100, (p.done / p.total) * 100) : 0;
          return (
            <div key={m.id} className={`llm-row ${m.downloaded ? "downloaded" : ""}`}>
              <div className="llm-info">
                <div>
                  <b>{m.label}</b> <span className="muted small">{formatBytes(m.size)}</span>
                  {m.downloaded && <span className="llm-badge downloaded">✓ Downloaded</span>}
                  {inUse && m.downloaded && <span className="llm-badge">In use</span>}
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
                  <button className="btn download" disabled={busy} onClick={() => download(m.id, m.size)}>Download</button>
                )}
              </div>
            </div>
          );
        })}
      </div>

      <h3>Voice packs{downloadedCount > 0 && ` · ${downloadedCount} downloaded`}</h3>
      {groups.map((g) => (
        <div key={g.language} className="voice-group">
          <div className="voice-group-title">
            {g.language}
            <span className="muted small">
              {hasDownloaded(g) ? `${g.voices.filter((v) => v.downloaded).length} of ${g.voices.length} downloaded` : `${g.voices.length} to download`}
            </span>
          </div>
          <div className="llm-list">
            {[...g.voices].sort((a, b) => Number(b.downloaded) - Number(a.downloaded)).map(voiceRow)}
          </div>
        </div>
      ))}

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
