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
  openSettings,
  hideWindow,
} from "./api";

interface Line {
  id: number;
  text: string;
  translated: boolean;
}

// Recent captions flow together as one paragraph, newest at the bottom, so a sentence
// split across chunks reads on. The bar keeps a fixed height (wlroots' transparent webview
// doesn't clear old frames, so a bar that resizes ghosts): it shows as many lines as fit
// and clips the oldest at the top. Enough captions to fill it at the smallest font size.
const KEEP_CAPTIONS = 8;

export default function Captions() {
  const [lines, setLines] = useState<Line[]>([]);
  const [status, setStatus] = useState<CaptionsStatus | null>(null);
  const [fontSize, setFontSize] = useState(28);
  // "Ghost" = click-through: the mouse passes through to the video/meeting underneath.
  const [ghost, setGhost] = useState(false);
  const [error, setError] = useState<string | null>(null);
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
        return next.slice(-KEEP_CAPTIONS);
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

  // Esc dismisses the overlay like every other GhostPen window — and stops capture, so
  // captions never keep transcribing invisibly behind a hidden window.
  useEffect(() => {
    const onKey = (ev: KeyboardEvent) => {
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

  const running = status?.running ?? false;

  return (
    // Pressed anywhere but a button, the overlay moves (Oriel drag region).
    <div className={`captions ${ghost ? "ghost" : ""}`} data-oriel-drag-region>
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
                    ? "Listening… play some audio."
                    : status && !status.model_ready
                      ? `Model “${status.model}” not downloaded — open Settings → Captions.`
                      : "Press Start to caption your system audio."}
              </div>
            ) : (
              <div className="cap-roll">
                {lines.map((l, i) => (
                  <span key={l.id} className={`cap-line ${i === lines.length - 1 ? "current" : "past"}`}>
                    {l.text}
                    {l.translated && <span className="cap-tag">translated</span>}{" "}
                  </span>
                ))}
              </div>
            )}
          </div>
        )}
      </div>

      {ghost && <div className="cap-ghost-hint">Tray → Captions to show controls</div>}
    </div>
  );
}
