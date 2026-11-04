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
import { Icon } from "./icons";
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
// How long the overlay's controls stay once the pointer has left it.
const CONTROLS_FADE_MS = 3000;

// Audio level meter (ghostpen://caption-level, ~10 Hz, the same 0..1 RMS as dictation's).
// The events only set a target; a requestAnimationFrame loop eases the shown level toward it
// (fast attack, slow release, like an audio meter) and writes the bars straight to the DOM.
const METER_BARS = 7;
const METER_MIN = 2; // px, resting height: a flat dash, not a dot
const METER_MAX = 14; // px, full level
const METER_GAIN = 1.9; // speech sits low in 0..1: boost it so normal audio moves the bars
const METER_SHAPE = [0.5, 0.75, 0.92, 1, 0.92, 0.75, 0.5]; // centre bar tallest

/** A spoken-language setting as the toolbar shows it ("auto" detects). */
function languageName(code: string): string {
  if (!code || code === "auto") return "Auto-detect";
  try {
    return new Intl.DisplayNames(["en"], { type: "language" }).of(code) ?? code;
  } catch {
    return code;
  }
}

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
  // The spoken language (Settings → Captions), for the bar's status.
  const [language, setLanguage] = useState("auto");
  const nextId = useRef(0);
  // The audio level: the latest reading, the eased value, and what the meter draws on.
  const levelTarget = useRef(0);
  const levelNow = useRef(0);
  const meterBars = useRef<(HTMLSpanElement | null)[]>([]);
  const rootRef = useRef<HTMLDivElement>(null);
  // The overlay's controls (all but the status and Start / Stop) fade out a while after the
  // pointer leaves, and come back on hover or focus. Not on the page, which has no overlay look.
  const [asleep, setAsleep] = useState(false);
  const sleepTimer = useRef(0);
  const wake = () => {
    window.clearTimeout(sleepTimer.current);
    setAsleep(false);
  };
  const sleepSoon = () => {
    if (asPage) return;
    window.clearTimeout(sleepTimer.current);
    sleepTimer.current = window.setTimeout(() => setAsleep(true), CONTROLS_FADE_MS);
  };
  useEffect(() => {
    sleepSoon();
    return () => window.clearTimeout(sleepTimer.current);
  }, []);

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
        const captions = (await getSettings()).captions;
        setFontSize(captions.fontSize || 28);
        setLanguage(captions.language || "auto");
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
    const un6 = listen<number>("ghostpen://caption-level", (e) => {
      const v = Number(e.payload);
      levelTarget.current = Number.isFinite(v) ? Math.max(0, Math.min(1, v)) : 0;
    });
    const un2 = listen<string>("ghostpen://caption-error", (e) => {
      setError(String(e.payload));
    });
    // Summoned from the tray → leave ghost mode so the controls are reachable again.
    const un3 = listen("ghostpen://captions-show", () => {
      setGhost(false);
      wake();
      sleepSoon();
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
      un6.then((f) => f());
    };
  }, []);

  // The meter: while captions listen, ease the level and draw it (the bars in the toolbar). Stopped, it settles flat and the loop ends.
  const running = status?.running ?? false;
  useEffect(() => {
    if (!running) levelTarget.current = 0;
    let raf = 0;
    let t = 0;
    let prev = performance.now();
    const tick = (now: number) => {
      t += Math.min(0.05, (now - prev) / 1000);
      prev = now;
      const target = running ? levelTarget.current : 0;
      const k = target > levelNow.current ? 0.3 : 0.07;
      levelNow.current += (target - levelNow.current) * k;
      if (!running && levelNow.current < 0.002) levelNow.current = 0;
      const amp = Math.min(1, levelNow.current * METER_GAIN);
      meterBars.current.forEach((el, i) => {
        if (!el) return;
        // A little travelling ripple keeps the bars from moving in lockstep.
        const flow = 0.75 + 0.25 * Math.sin(i * 1.3 - t * 9);
        const h = METER_MIN + (METER_MAX - METER_MIN) * Math.min(1, amp * METER_SHAPE[i] * flow);
        el.style.height = `${h.toFixed(1)}px`;
        el.style.opacity = String(0.55 + 0.45 * Math.min(1, amp * 1.5));
      });
      if (running || levelNow.current > 0) raf = requestAnimationFrame(tick);
    };
    raf = requestAnimationFrame(tick);
    return () => cancelAnimationFrame(raf);
  }, [running]);

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
    if (running) return; // locked while captions run (the button says so)
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
    <div
      ref={rootRef}
      className={`captions ${ghost ? "ghost" : ""} ${asPage ? "page" : ""} ${asleep ? "controls-asleep" : ""}`}
      data-oriel-drag-region={asPage ? undefined : true}
      onMouseEnter={wake}
      onMouseLeave={sleepSoon}
    >
      {asPage && (
        <header className="page-head">
          <h1>Captions</h1>
          <p>Live subtitles of what this device plays, kept for the whole session.</p>
        </header>
      )}
      {!ghost && (
        <div className="cap-bar">
          <span className="cap-brand">
            {!asPage && (
              <span className={`cap-status ${running ? "live" : ""}`} title="GhostPen Captions · speech language (Settings → Captions)">
                <span className="cap-status-dot" aria-hidden="true" />
                <span className="cap-status-name">{running ? "Live" : "Captions"}</span>
                <span className="cap-status-meta" title="Spoken language">
                  <Icon name="translate" className="cap-status-icon" />
                  {languageName(language)}
                </span>
              </span>
            )}
            {running && (
              <span className="cap-meter" role="img" aria-label="Audio level" title="Audio level: the bars move while captions hear sound">
                {Array.from({ length: METER_BARS }, (_, i) => (
                  <span
                    key={i}
                    ref={(el) => {
                      meterBars.current[i] = el;
                    }}
                    className="cap-meter-bar"
                    style={{ height: `${METER_MIN}px` }}
                  />
                ))}
              </span>
            )}
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
                <span className="cap-stop-glyph" aria-hidden="true" />
                {recording ? "Stop & save" : "Stop"}
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
                <span className="cap-start-glyph" aria-hidden="true" />
                Start
              </button>
            )}
            <span className="cap-more">
              <span className="cap-sep" aria-hidden="true" />
              <button
                className={`cap-btn cap-toggle ${status?.translate ? "on" : ""}`}
                onClick={onToggleTranslate}
                role="switch"
                aria-checked={status?.translate ?? false}
                title={
                  status?.translate
                    ? `Translating → ${status.target_lang} (click to turn off)`
                    : `Translate captions → ${status?.target_lang || "target language"} (Settings → Captions to change)`
                }
              >
                <span className="switch-track" aria-hidden="true"><span className="switch-thumb" /></span>
                {status?.translate ? `Translate: ${status.target_lang || "on"}` : "Translate"}
              </button>
              <button
                className={`cap-btn cap-toggle ${status?.meeting ? "on" : ""} ${running ? "locked" : ""}`}
                onClick={onToggleMeeting}
                role="switch"
                aria-checked={status?.meeting ?? false}
                aria-disabled={running}
                title={
                  running
                    ? status?.meeting
                      ? "This session is being recorded. Stop captions to change it."
                      : "Locked while captions run. Stop captions to change it."
                    : status?.meeting
                      ? "Record meeting: the next start records the audio and your microphone, and saves a transcript (click to turn off)"
                      : "Record meeting: save the transcript with speakers and a proofread, starting with the next Start"
                }
              >
                <span className="switch-track" aria-hidden="true"><span className="switch-thumb" /></span>
                Record meeting
                {running && <Icon name="lock" className="cap-lock" />}
              </button>
              <span className="cap-sep" aria-hidden="true" />
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
                <button
                  className="cap-btn"
                  onClick={enterGhost}
                  title="Click-through: the mouse passes through the captions to the window underneath. Tray → Captions brings the controls back."
                >
                  <Icon name="pointer" className="cap-btn-icon" />
                  Click-through
                </button>
              )}
              <button
                className="cap-btn cap-icon cap-to-meetings"
                onClick={() => openMeetings().catch(() => {})}
                title="Open the Meetings window"
                aria-label="Open the Meetings window"
              >
                <Icon name="folder" className="cap-btn-icon" />
              </button>
              <button
                className="cap-btn cap-icon cap-to-settings"
                onClick={() => openSettings().catch((e) => console.warn("open settings:", e))}
                title="Open Captions settings"
                aria-label="Open Captions settings"
              >
                <Icon name="settings" className="cap-btn-icon" />
              </button>
              {!asPage && (
                <button
                  className="cap-btn cap-icon"
                  onClick={() => hideWindow().catch((e) => console.warn("hide captions:", e))}
                  title="Hide the captions overlay (captions keep running; Esc stops them)"
                  aria-label="Hide the captions overlay"
                >
                  <Icon name="close" className="cap-btn-icon" />
                </button>
              )}
            </span>
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
              <div className={`cap-idle ${running ? "live" : ""}`}>
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
