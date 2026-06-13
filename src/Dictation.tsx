import { useEffect, useRef, useState } from "react";
import { listen } from "@tauri-apps/api/event";
import {
  DictationStatus,
  DictationUpdate,
  dictationStatus,
  dictationStart,
  dictationStop,
  dictationCancel,
  dictationSetLanguage,
  dictationSetProofread,
  openSettings,
  CAPTION_LANGUAGES,
} from "./api";

// Waveform bars (Apple-dictation style): driven by ~10 Hz RMS level events from the mic.
const BAR_COUNT = 36;
const BAR_MIN = 4; // px — resting height
const BAR_MAX = 34; // px — full-loudness center bar

type Phase =
  | "idle"
  | "listening"
  | "transcribing"
  | "proofreading"
  | "done"
  | "error";

/** Bell envelope so the wave swells in the middle like Siri's, not a flat equalizer. */
function envelope(i: number): number {
  const c = (i - (BAR_COUNT - 1) / 2) / (BAR_COUNT / 2);
  return Math.exp(-c * c * 2.2);
}

const restingBars = () => Array<number>(BAR_COUNT).fill(BAR_MIN);

export default function Dictation() {
  const [phase, setPhase] = useState<Phase>("idle");
  const [text, setText] = useState("");
  const [status, setStatus] = useState<DictationStatus | null>(null);
  const [bars, setBars] = useState<number[]>(restingBars);
  // Phase inside event handlers without re-subscribing.
  const phaseRef = useRef<Phase>("idle");
  phaseRef.current = phase;

  const [lang, setLang] = useState("auto");
  const [proofread, setProofread] = useState(true);

  const refreshStatus = async () => {
    try {
      const s = await dictationStatus();
      setStatus(s);
      setLang(s.language || "auto");
      setProofread(s.proofread);
    } catch {
      /* ignore */
    }
  };

  // Applies live: a running session uses the new language on its next transcription pass.
  const changeLang = (l: string) => {
    setLang(l);
    dictationSetLanguage(l).catch(() => {});
  };

  // Applies live: a running session reads the flag at the proofread decision point, so the
  // toggle even takes effect between clicking Finish and the AI call kicking off.
  const toggleProofread = () => {
    const next = !proofread;
    setProofread(next);
    dictationSetProofread(next).catch(() => {
      // Revert on failure so the switch never lies about what's persisted.
      setProofread(!next);
    });
  };

  // A fresh trigger (hotkey/tray) resets the overlay for the new session.
  useEffect(() => {
    const un = listen("ghostpen://dictation-show", () => {
      setPhase("listening");
      setText("");
      setBars(restingBars());
      refreshStatus();
    });
    refreshStatus();
    return () => {
      un.then((f) => f());
    };
  }, []);

  // Mic level → waveform. Each tick eases every bar toward a jittered, enveloped target.
  useEffect(() => {
    const un = listen<number>("ghostpen://dictation-level", (e) => {
      if (phaseRef.current !== "listening") return;
      const level = Math.max(0, Math.min(1, e.payload));
      setBars((prev) =>
        prev.map((h, i) => {
          const target =
            BAR_MIN + (BAR_MAX - BAR_MIN) * level * envelope(i) * (0.5 + Math.random() * 0.5);
          return h + (target - h) * 0.55;
        }),
      );
    });
    return () => {
      un.then((f) => f());
    };
  }, []);

  // Transcript / state updates from the backend.
  useEffect(() => {
    const un = listen<DictationUpdate>("ghostpen://dictation", (e) => {
      const u = e.payload;
      switch (u.state) {
        case "listening":
          setPhase("listening");
          if (u.text) setText(u.text);
          break;
        case "transcribing":
        case "proofreading":
          setPhase(u.state);
          if (u.text) setText(u.text);
          setBars(restingBars());
          break;
        case "done":
          // The result is on the clipboard; keep it on screen for review until dismissed.
          setPhase("done");
          setText(u.text);
          break;
        case "cancelled":
          setPhase("idle");
          setText("");
          break;
        case "error":
          setPhase("error");
          setText(u.text);
          setBars(restingBars());
          break;
      }
    });
    return () => {
      un.then((f) => f());
    };
  }, []);

  const finish = () => {
    if (phaseRef.current === "listening") dictationStop().catch(() => {});
    else dictationCancel().catch(() => {});
  };

  // The mic badge is the in-pill toggle: start a new dictation from a finished/errored
  // overlay (the backend emits `dictation-show`, which resets the UI), or finish a live one.
  const micToggle = () => {
    const p = phaseRef.current;
    if (p === "listening") {
      dictationStop().catch(() => {});
    } else if (p !== "transcribing" && p !== "proofreading") {
      dictationStart().catch((e) => {
        setPhase("error");
        setText(String(e));
      });
    }
  };
  const cancel = () => {
    dictationCancel().catch(() => {});
    setPhase("idle");
    setText("");
  };

  // Esc cancels, Enter finishes (or dismisses a finished/errored overlay), and Space starts
  // the next dictation — but ONLY from the end screen (done/error/idle): while listening it
  // does nothing, and it can never be the very first start (that's the keybind/click), so a
  // stray Space while typing elsewhere can't arm the mic.
  useEffect(() => {
    const onKey = (ev: KeyboardEvent) => {
      if (ev.key === "Escape") {
        ev.preventDefault();
        cancel();
      } else if (ev.key === "Enter") {
        ev.preventDefault();
        finish();
      } else if (ev.key === " ") {
        const p = phaseRef.current;
        if (p === "done" || p === "error" || p === "idle") {
          ev.preventDefault();
          dictationStart().catch((e) => {
            setPhase("error");
            setText(String(e));
          });
        }
      }
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, []);

  const busyPhase = phase === "transcribing" || phase === "proofreading";
  const hint =
    phase === "listening"
      ? "Listening — ⏎ to finish · Esc to cancel"
      : phase === "transcribing"
        ? "Transcribing…"
        : phase === "proofreading"
          ? "Polishing with AI…"
          : phase === "done"
            ? "Copied — press Ctrl+V · Space to dictate again · Esc to close"
            : phase === "error"
              ? "Space to try again · Esc to close"
              : "";

  return (
    <div className="dictation">
      <div className={`dict-pill ${phase}`}>
        <div className="dict-top">
          {/* tabIndex -1 + focus suppression on every button: a focused button would be
              re-activated by a stray Space/Enter, silently starting a recording. Recording
              starts ONLY by a deliberate click or the compositor keybind. */}
          <button
            className={`dict-mic ${phase === "listening" ? "live" : ""}`}
            onClick={micToggle}
            disabled={busyPhase}
            tabIndex={-1}
            onMouseDown={(e) => e.preventDefault()}
            title={phase === "listening" ? "Finish dictation" : "Dictate again"}
          >
            <svg viewBox="0 0 24 24" width="16" height="16" aria-hidden="true">
              <path
                fill="currentColor"
                d="M12 14a3 3 0 0 0 3-3V6a3 3 0 1 0-6 0v5a3 3 0 0 0 3 3Zm5-3a5 5 0 0 1-10 0H5a7 7 0 0 0 6 6.93V21h2v-3.07A7 7 0 0 0 19 11h-2Z"
              />
            </svg>
          </button>

          <div className={`dict-wave ${busyPhase ? "busy" : ""}`}>
            {bars.map((h, i) => (
              <span
                key={i}
                className="dict-bar"
                style={{ height: `${Math.round(h)}px`, animationDelay: `${i * 36}ms` }}
              />
            ))}
          </div>

          {/* Spoken language — "auto" detects; changing it mid-dictation re-transcribes in
              the new language on the next pass. Not keyboard-focusable (see button note). */}
          <select
            className="dict-lang"
            value={lang}
            onChange={(e) => changeLang(e.target.value)}
            tabIndex={-1}
            title="Spoken language"
          >
            {CAPTION_LANGUAGES.map((l) => (
              <option key={l} value={l}>
                {l === "auto" ? "auto 🌐" : l}
              </option>
            ))}
          </select>

          <div className="dict-actions">
            {/* AI-proofread slider switch: persists + flips live (the backend reads it at the
                proofread decision point, so toggling off after Finish still skips the AI). */}
            <button
              className={`dict-switch ${proofread ? "on" : ""}`}
              role="switch"
              aria-checked={proofread}
              onClick={toggleProofread}
              tabIndex={-1}
              onMouseDown={(e) => e.preventDefault()}
              title={
                proofread
                  ? "AI proofread: ON — click for raw transcript"
                  : "AI proofread: OFF — click to polish with AI"
              }
            >
              <span className="dict-switch-knob" aria-hidden="true" />
            </button>
            <button
              className="dict-btn"
              onClick={() => openSettings()}
              tabIndex={-1}
              onMouseDown={(e) => e.preventDefault()}
              title="Dictation settings"
            >
              ⚙
            </button>
            <button
              className="dict-btn"
              onClick={cancel}
              tabIndex={-1}
              onMouseDown={(e) => e.preventDefault()}
              title="Cancel (Esc)"
            >
              ✕
            </button>
            <button
              className="dict-btn ok"
              onClick={finish}
              disabled={busyPhase}
              tabIndex={-1}
              onMouseDown={(e) => e.preventDefault()}
              title="Finish & paste (⏎)"
            >
              ✓
            </button>
          </div>
        </div>

        <div className={`dict-text ${phase === "error" ? "error" : ""}`}>
          {text ||
            (phase === "listening"
              ? status && !status.model_ready
                ? `Whisper model “${status.model}” not downloaded — Settings → Captions.`
                : "Speak now…"
              : "")}
        </div>

        {/* Always rendered (nbsp when empty) so the pill geometry never changes — a transparent
            WebKitGTK window doesn't clear old frames, and size changes leave ghost outlines. */}
        <div className="dict-hint">{hint || " "}</div>
      </div>
    </div>
  );
}
