import { useEffect, useRef, useState } from "react";
import { listen } from "./events";
import {
  Caption,
  CaptionsStatus,
  getSettings,
  captionsStatus,
  captionsStart,
  captionsStop,
  captionsSetClickThrough,
  captionsSetTranslate,
  captionsSetMeeting,
  openMeetings,
  MeetingProgress,
  openSettings,
  hideWindow,
  copyText,
} from "./api";
import { singleWindow } from "./mode";

interface Line {
  id: number;
  text: string;
  translated: boolean;
  speaker: string;
  /** The speaker's label ("" = none). */
  name: string;
  /** When it came (ms since the epoch). */
  at: number;
}

/** Consecutive captions by one speaker: one line in the overlay. */
interface Turn {
  speaker: string;
  name: string;
  lines: Line[];
}

function turnsOf(lines: Line[]): Turn[] {
  // System audio is unlabelled unless someone else (the mic, a recognised
  // speaker) is talking too: then it's "Others".
  const labelled = lines.some((l) => l.speaker);
  const out: Turn[] = [];
  for (const l of lines) {
    const name = l.name || (labelled ? "Others" : "");
    const last = out[out.length - 1];
    if (last && last.speaker === l.speaker) last.lines.push(l);
    else out.push({ speaker: l.speaker, name, lines: [l] });
  }
  return out;
}

const STEP: Record<string, string> = {
  saving: "Saving the meeting…",
  transcribing: "Transcribing the meeting…",
  diarizing: "Finding the speakers…",
  proofreading: "Proofreading…",
};

function clock(seconds: number): string {
  const t = Math.max(0, Math.floor(seconds));
  const h = Math.floor(t / 3600);
  const mm = String(Math.floor(t / 60) % 60).padStart(2, "0");
  const ss = String(t % 60).padStart(2, "0");
  return h > 0 ? `${h}:${mm}:${ss}` : `${mm}:${ss}`;
}

// Recent captions flow together as one paragraph, newest at the bottom, so a sentence
// split across chunks reads on. The bar keeps a fixed height (wlroots' transparent webview
// doesn't clear old frames, so a bar that resizes ghosts): it shows as many lines as fit
// and clips the oldest at the top. Enough captions to fill it at the smallest font size.
const KEEP_CAPTIONS = 8;
// As a page of the app window (single-window mode, captions not floating) there's room:
// the whole session, as a transcript that scrolls.
const KEEP_HISTORY = 5000;
const asPage = singleWindow;

function timeOf(ms: number): string {
  return new Date(ms).toLocaleTimeString([], { hour: "2-digit", minute: "2-digit", second: "2-digit" });
}

/** The transcript as plain text: a line per speaker turn. */
function transcriptText(lines: Line[]): string {
  return turnsOf(lines)
    .map((t) => `[${timeOf(t.lines[0].at)}] ${t.name ? t.name + ": " : ""}${t.lines.map((l) => l.text.trim()).join(" ")}`)
    .join("\n");
}

export default function Captions() {
  const [lines, setLines] = useState<Line[]>([]);
  const [status, setStatus] = useState<CaptionsStatus | null>(null);
  const [fontSize, setFontSize] = useState(28);
  // "Ghost" = click-through: the mouse passes through to the video/meeting underneath.
  const [ghost, setGhost] = useState(false);
  const [error, setError] = useState<string | null>(null);
  // The last meeting's save pipeline, for the bar's note.
  const [saving, setSaving] = useState<MeetingProgress | null>(null);
  // Recording time: the status's, counted on locally.
  const [recSeconds, setRecSeconds] = useState(0);
  const nextId = useRef(0);

  const refreshStatus = async () => {
    try {
      setStatus(await captionsStatus());
    } catch {
      /* ignore */
    }
  };

  // Initial load: font size from settings + current status.
  useEffect(() => {
    (async () => {
      try {
        setFontSize((await getSettings()).captions.fontSize || 28);
      } catch {
        /* ignore */
      }
      refreshStatus();
    })();
  }, []);

  // Stream captions in.
  useEffect(() => {
    const un1 = listen<Caption>("ghostpen://caption", (e) => {
      const { text, translated, speaker = "", name } = e.payload;
      if (!text.trim()) return;
      setError(null);
      setLines((prev) => {
        const label = name || (speaker === "me" ? "Me" : "");
        const next = [...prev, { id: nextId.current++, text, translated, speaker, name: label, at: Date.now() }];
        return next.slice(-(asPage ? KEEP_HISTORY : KEEP_CAPTIONS));
      });
    });
    const un2 = listen<string>("ghostpen://caption-error", (e) => {
      setError(String(e.payload));
    });
    // Summoned from the tray → leave ghost mode so the controls are reachable again.
    const un3 = listen("ghostpen://captions-show", () => {
      setGhost(false);
      refreshStatus();
    });
    // Every start, recorded or not, begins with a clean overlay.
    const un5 = listen("ghostpen://captions-started", () => {
      setLines([]);
      setError(null);
      setSaving(null);
      refreshStatus();
    });
    const un4 = listen<MeetingProgress>("ghostpen://meeting", (e) => {
      setSaving(e.payload);
      // A stop from elsewhere (hotkey, tray): the REC clock goes too.
      if (e.payload.state === "saving") refreshStatus();
    });
    return () => {
      un1.then((f) => f());
      un2.then((f) => f());
      un3.then((f) => f());
      un4.then((f) => f());
      un5.then((f) => f());
    };
  }, []);

  // The recording clock.
  const recording = status?.recording ?? null;
  useEffect(() => {
    if (!recording) return;
    const began = Date.now() - recording.seconds * 1000;
    setRecSeconds(recording.seconds);
    const t = window.setInterval(() => setRecSeconds((Date.now() - began) / 1000), 1000);
    return () => window.clearInterval(t);
  }, [recording?.id]);

  // Esc dismisses the overlay like every other GhostPen window — and stops capture, so
  // captions never keep transcribing invisibly behind a hidden window.
  useEffect(() => {
    const onKey = (ev: KeyboardEvent) => {
      // A page of the app window: Esc isn't "close the overlay".
      if (asPage) return;
      if (ev.key === "Escape") {
        ev.preventDefault();
        captionsStop().catch(() => {});
        hideWindow().catch(() => {});
        setLines([]);
        refreshStatus();
      }
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, []);

  const onStart = async () => {
    setError(null);
    setLines([]);
    setSaving(null);
    try {
      await captionsStart();
      await refreshStatus();
    } catch (e) {
      setError(String(e));
    }
  };

  const onStop = async () => {
    // A meeting: "Saving…" right away (its events follow).
    if (status?.recording) setSaving({ id: status.recording.id, state: "saving", progress: 0, message: "" });
    try {
      await captionsStop();
      await refreshStatus();
    } catch (e) {
      setError(String(e));
    }
  };

  const onToggleTranslate = async () => {
    const enable = !(status?.translate ?? false);
    try {
      await captionsSetTranslate(enable);
      await refreshStatus();
    } catch (e) {
      setError(String(e));
    }
  };

  const onToggleMeeting = async () => {
    try {
      await captionsSetMeeting(!(status?.meeting ?? false));
      await refreshStatus();
    } catch (e) {
      setError(String(e));
    }
  };

  const enterGhost = async () => {
    try {
      await captionsSetClickThrough(true);
      setGhost(true);
    } catch (e) {
      setError(String(e));
    }
  };

  const running = status?.running ?? false;

  // The page's transcript follows the newest caption unless scrolled up to read.
  const historyRef = useRef<HTMLDivElement>(null);
  const following = useRef(true);
  useEffect(() => {
    const el = historyRef.current;
    if (el && following.current) el.scrollTop = el.scrollHeight;
  }, [lines]);
  const [copied, setCopied] = useState(false);
  const onCopy = async () => {
    try {
      await copyText(transcriptText(lines));
      setCopied(true);
      window.setTimeout(() => setCopied(false), 1500);
    } catch (e) {
      setError(String(e));
    }
  };

  return (
    // Pressed anywhere but a button, the overlay moves (Oriel drag region).
    <div className={`captions ${ghost ? "ghost" : ""} ${asPage ? "page" : ""}`} data-oriel-drag-region={asPage ? undefined : true}>
      {asPage && (
        <header className="page-head">
          <h1>Captions</h1>
          <p>Live subtitles of what this device plays, kept for the whole session.</p>
        </header>
      )}
      {!ghost && (
        <div className="cap-bar">
          <span className="cap-brand">
            {!asPage && "GhostPen Captions"}
            {recording && (
              <span className="cap-rec" title="Recording this meeting: Stop saves it">
                ● REC {clock(recSeconds)}
              </span>
            )}
            {!recording && saving && saving.state !== "recording" && (
              <button
                className={`cap-saving ${saving.state}`}
                onClick={() => openMeetings().catch(() => {})}
                title="Open the Meetings window"
              >
                {saving.state === "ready"
                  ? "✓ Meeting saved · Open"
                  : saving.state === "error"
                    ? "⚠ Meeting not fully saved · Open"
                    : `${STEP[saving.state] ?? "Saving…"}${saving.progress > 0 ? ` ${Math.round(saving.progress * 100)}%` : ""}`}
              </button>
            )}
          </span>
          <span className="cap-controls">
            {running ? (
              <button className="cap-btn stop" onClick={onStop} title={recording ? "Stop and save the meeting" : "Stop captions"}>
                {recording ? "■ Stop & save" : "■ Stop"}
              </button>
            ) : (
              <button
                className="cap-btn cap-start"
                onClick={onStart}
                disabled={status ? !status.available : true}
                title={
                  status && !status.available
                    ? "This build lacks captions support (rebuild with --features captions)"
                    : "Start captions"
                }
              >
                ● Start
              </button>
            )}
            <button
              className={`cap-btn ${status?.translate ? "active" : ""}`}
              onClick={onToggleTranslate}
              title={
                status?.translate
                  ? `Translating → ${status.target_lang} (click to turn off)`
                  : `Translate captions → ${status?.target_lang || "target language"} (Settings → Captions to change)`
              }
            >
              🌐 {status?.translate ? status.target_lang || "On" : "Translate"}
            </button>
            <button
              className={`cap-btn ${status?.meeting ? "active" : ""}`}
              onClick={onToggleMeeting}
              disabled={running}
              title={
                running
                  ? "Meeting mode changes on the next start"
                  : status?.meeting
                    ? "Meeting mode: the next start records the audio and your microphone, and saves a transcript (click to turn off)"
                    : "Meeting mode: record and save the transcript, with speakers and a proofread"
              }
            >
              🎙 Meeting
            </button>
            <button className="cap-btn cap-to-meetings" onClick={() => openMeetings().catch(() => {})} title="Saved meetings">
              🗂
            </button>
            {asPage ? (
              <>
                <button className="cap-btn" onClick={onCopy} disabled={lines.length === 0} title="Copy the transcript">
                  {copied ? "✓ Copied" : "Copy"}
                </button>
                <button className="cap-btn" onClick={() => setLines([])} disabled={lines.length === 0 || running} title="Clear the transcript">
                  Clear
                </button>
              </>
            ) : (
              <button className="cap-btn" onClick={enterGhost} title="Click-through (mouse passes through)">
                👻 Ghost
              </button>
            )}
            <button className="cap-btn cap-to-settings" onClick={() => openSettings().catch((e) => console.warn("open settings:", e))} title="Captions settings">
              ⚙
            </button>
            {!asPage && (
              <button className="cap-btn" onClick={() => hideWindow().catch((e) => console.warn("hide captions:", e))} title="Hide overlay">
                ✕
              </button>
            )}
          </span>
        </div>
      )}

      {asPage ? (
        <div
          className="cap-history"
          ref={historyRef}
          onScroll={(e) => {
            const el = e.currentTarget;
            following.current = el.scrollHeight - el.scrollTop - el.clientHeight < 40;
          }}
        >
          {error && <div className="cap-error">⚠ {error}</div>}
          {lines.length === 0 ? (
            <div className="cap-idle">
              {status && !status.available
                ? "Captions support isn’t compiled into this build."
                : running
                  ? "Listening… play some audio."
                  : status && !status.model_ready
                    ? `Model “${status.model}” not downloaded — open Settings → Speech.`
                    : "Press Start to caption your system audio. The whole session stays here."}
            </div>
          ) : (
            turnsOf(lines).map((t) => (
              <p key={t.lines[0].id} className={`cap-history-turn ${t.speaker === "me" ? "me" : ""}`}>
                <span className="cap-history-time">{timeOf(t.lines[0].at)}</span>
                {t.name && <span className="cap-speaker">{t.name}:</span>}
                {t.lines.map((l) => (
                  <span key={l.id}>
                    {l.text}
                    {l.translated && <span className="cap-tag">translated</span>}{" "}
                  </span>
                ))}
              </p>
            ))
          )}
        </div>
      ) : (
      <div className="cap-stage" style={{ fontSize }}>
        {/* Idle, error, and caption text all share the ONE fixed-size bar (.cap-lines):
            swapping between differently-sized boxes ghosts on wlroots (see styles.css). */}
        {(!ghost || error || lines.length > 0) && (
          // Remounted per caption: the whole bar is repainted, so the text that just scrolled
          // up can't leave its old pixels behind (the same wlroots no-clear ghosting).
          <div
            key={error ? "error" : lines.length ? `c${lines[lines.length - 1].id}` : "idle"}
            className={`cap-lines ${error || lines.length === 0 ? "centered" : ""}`}
          >
            {error ? (
              <div className="cap-error">⚠ {error}</div>
            ) : lines.length === 0 ? (
              <div className="cap-idle">
                {status && !status.available
                  ? "Captions support isn’t compiled into this build."
                  : running
                    ? recording
                      ? "Recording the meeting… captions show here."
                      : "Listening… play some audio."
                    : status && !status.model_ready
                      ? `Model “${status.model}” not downloaded — open Settings → Captions.`
                      : "Press Start to caption your system audio."}
              </div>
            ) : (
              <div className="cap-roll">
                {/* A line per speaker turn, labelled; one speaker flows as a paragraph. */}
                {turnsOf(lines).map((t) => (
                  <div key={t.lines[0].id} className={`cap-turn ${t.speaker === "me" ? "me" : ""}`}>
                    {t.name && <span className="cap-speaker">{t.name}:</span>}
                    {t.lines.map((l) => (
                      <span key={l.id} className={`cap-line ${l.id === lines[lines.length - 1].id ? "current" : "past"}`}>
                        {l.text}
                        {l.translated && <span className="cap-tag">translated</span>}{" "}
                      </span>
                    ))}
                  </div>
                ))}
              </div>
            )}
          </div>
        )}
      </div>

      )}

      {ghost && <div className="cap-ghost-hint">Tray → Captions to show controls</div>}
    </div>
  );
}
