import { useEffect, useRef, useState } from "react";
import { listen } from "@tauri-apps/api/event";
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
const MIN_FONT = 16;
const MAX_FONT = 48;

export default function Captions() {
  const [lines, setLines] = useState<Line[]>([]);
  const [status, setStatus] = useState<CaptionsStatus | null>(null);
  const [fontSize, setFontSize] = useState(28);
  // "Ghost" = click-through: the mouse passes through to the video/meeting underneath.
  const [ghost, setGhost] = useState(false);
  const [error, setError] = useState<string | null>(null);
  // Hover-reveal (macOS Live Captions): idle = text only, hover fades the controls in.
  const [hover, setHover] = useState(false);
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
      const { text, translated } = e.payload;
      if (!text.trim()) return;
      setError(null);
      setLines((prev) => {
        const next = [...prev, { id: nextId.current++, text, translated }];
        return next.slice(-MAX_LINES);
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
    return () => {
      un1.then((f) => f());
      un2.then((f) => f());
      un3.then((f) => f());
    };
  }, []);

  const onStart = async () => {
    setError(null);
    try {
      await captionsStart();
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

  const bumpFont = (d: number) =>
    setFontSize((f) => Math.min(MAX_FONT, Math.max(MIN_FONT, f + d)));

  const running = status?.running ?? false;
  // Controls reveal on hover (never in ghost mode — hover can't work while click-through).
  const showControls = !ghost && hover;

  return (
    <div
      className={`captions ${ghost ? "ghost" : ""} ${showControls ? "hovering" : ""}`}
      onMouseEnter={() => setHover(true)}
      onMouseLeave={() => setHover(false)}
    >
      {!ghost && (
        <div className="cap-bar">
          <span className="cap-brand">GhostPen Captions</span>
          <span className="cap-controls">
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
              🌐 {status?.translate ? status.target_lang || "On" : "Translate"}
            </button>
            <span className="cap-font" title="Caption font size">
              <button
                className="cap-btn"
                onClick={() => bumpFont(-2)}
                disabled={fontSize <= MIN_FONT}
                title="Smaller text"
              >
                A−
              </button>
              <button
                className="cap-btn"
                onClick={() => bumpFont(2)}
                disabled={fontSize >= MAX_FONT}
                title="Larger text"
              >
                A+
              </button>
            </span>
            <button className="cap-btn" onClick={enterGhost} title="Click-through (mouse passes through)">
              👻 Ghost
            </button>
            <button className="cap-btn" onClick={() => openSettings()} title="Captions settings">
              ⚙
            </button>
            <button className="cap-btn" onClick={() => hideWindow()} title="Hide overlay">
              ✕
            </button>
          </span>
        </div>
      )}

      <div className="cap-stage" style={{ fontSize }}>
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
          <div className="cap-lines">
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
