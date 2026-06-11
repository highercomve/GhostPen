import { useEffect, useRef, useState } from "react";
import { listen } from "@tauri-apps/api/event";
import { Icon } from "./icons";
import {
  Caption,
  CaptionsStatus,
  getSettings,
  captionsStatus,
  captionsStart,
  captionsStop,
  captionsSetClickThrough,
  captionsSetTranslate,
  openSettings,
  hideWindow,
} from "./api";

interface Line {
  id: number;
  text: string;
  translated: boolean;
}

// How many recent caption lines to keep on screen (subtitle convention: 1–2 lines).
const MAX_LINES = 2;
// Fade the pill out after this long without a new caption (macOS/Android auto-hide).
const SILENCE_MS = 6000;

export default function Captions() {
  const [lines, setLines] = useState<Line[]>([]);
  const [status, setStatus] = useState<CaptionsStatus | null>(null);
  const [fontSize, setFontSize] = useState(28);
  // "Ghost" = click-through: the mouse passes through to the video/meeting underneath.
  const [ghost, setGhost] = useState(false);
  const [error, setError] = useState<string | null>(null);
  // Auto-hide on silence: the pill fades out after SILENCE_MS, back in on the next caption.
  // The window stays mapped throughout — this is a pure CSS opacity transition, no show/hide.
  const [silent, setSilent] = useState(false);
  // "Keep onscreen" pin disables the silence auto-hide (macOS "Keep Onscreen").
  const [pinned, setPinned] = useState(false);
  const nextId = useRef(0);
  const silenceTimer = useRef<ReturnType<typeof setTimeout> | null>(null);

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

  // (Re)arm the silence timer whenever a caption arrives.
  const bumpSilence = () => {
    setSilent(false);
    if (silenceTimer.current) clearTimeout(silenceTimer.current);
    silenceTimer.current = setTimeout(() => setSilent(true), SILENCE_MS);
  };

  // Stream captions in.
  useEffect(() => {
    const un1 = listen<Caption>("ghostpen://caption", (e) => {
      const { text, translated } = e.payload;
      if (!text.trim()) return;
      setError(null);
      bumpSilence();
      setLines((prev) => {
        const next = [...prev, { id: nextId.current++, text, translated }];
        return next.slice(-MAX_LINES);
      });
    });
    const un2 = listen<string>("ghostpen://caption-error", (e) => {
      setError(String(e.payload));
      bumpSilence();
    });
    // Summoned from the tray → leave ghost mode so the controls are reachable again.
    const un3 = listen("ghostpen://captions-show", () => {
      setGhost(false);
      bumpSilence();
      refreshStatus();
    });
    return () => {
      un1.then((f) => f());
      un2.then((f) => f());
      un3.then((f) => f());
      if (silenceTimer.current) clearTimeout(silenceTimer.current);
    };
  }, []);

  const onStart = async () => {
    setError(null);
    try {
      await captionsStart();
      bumpSilence();
      await refreshStatus();
    } catch (e) {
      setError(String(e));
    }
  };

  const onStop = async () => {
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

  const enterGhost = async () => {
    try {
      await captionsSetClickThrough(true);
      setGhost(true);
    } catch (e) {
      setError(String(e));
    }
  };

  const running = status?.running ?? false;
  // Fade out only when idle, pinned-off, not in an error, and not showing the placeholder.
  const faded = silent && !pinned && !error && lines.length > 0;

  return (
    <div className={`captions ${ghost ? "ghost" : ""}`}>
      {!ghost && (
        <div className="cap-bar" role="toolbar">
          {running ? (
            <button className="cap-btn stop" onClick={onStop} title="Stop captions">
              ■ Stop
            </button>
          ) : (
            <button
              className="cap-btn"
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
            🌐
          </button>
          <button
            className={`cap-btn ${pinned ? "active" : ""}`}
            onClick={() => setPinned((p) => !p)}
            title={pinned ? "Keep onscreen: on (auto-hide disabled)" : "Keep onscreen (disable auto-hide on silence)"}
          >
            <Icon name="pin" />
          </button>
          <button className="cap-btn" onClick={enterGhost} title="Click-through (mouse passes through)">
            👻
          </button>
          <button className="cap-btn" onClick={() => openSettings()} title="Captions settings">
            ⚙
          </button>
          <button className="cap-btn" onClick={() => hideWindow()} title="Hide overlay">
            ✕
          </button>
        </div>
      )}

      <div
        className={`cap-stage ${faded ? "faded" : ""}`}
        style={{ fontSize }}
        data-tauri-drag-region
      >
        {error ? (
          <div className="cap-error">⚠ {error}</div>
        ) : lines.length === 0 ? (
          !ghost && (
            <div className="cap-idle">
              {status && !status.available
                ? "Captions support isn’t compiled into this build."
                : running
                  ? "Listening… play some audio."
                  : status && !status.model_ready
                    ? `Model “${status.model}” not downloaded — open Settings → Captions.`
                    : "Press Start to caption your system audio."}
            </div>
          )
        ) : (
          <div className="cap-lines" data-tauri-drag-region>
            {lines.map((l, i) => (
              <div
                key={l.id}
                className={`cap-line ${i === lines.length - 1 ? "current" : "past"}`}
              >
                {l.text}
                {l.translated && <span className="cap-tag">translated</span>}
              </div>
            ))}
          </div>
        )}
      </div>

      {ghost && <div className="cap-ghost-hint">Tray → Captions to show controls</div>}
    </div>
  );
}
