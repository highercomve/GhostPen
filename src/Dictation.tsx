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

// Waveform: a continuous flowing wave (Apple-dictation style), not 36 independent bars each
// jumping to a random height on every level tick. The mic's ~10 Hz RMS events only set a
// *target* amplitude; a requestAnimationFrame loop eases the displayed amplitude toward it and
// renders a traveling multi-sine ripple at 60 fps, so the wave flows and breathes. Bars are
// driven directly via DOM refs to avoid re-rendering React 60×/s.
const BAR_COUNT = 40;
const BAR_MIN = 4; // px — resting height
const BAR_MAX = 38; // px — full-loudness center bar (≈ the wave area height)
const AMP_GAIN = 1.9; // boosts mic level so normal speech drives tall bars, not a timid wiggle

type Phase =
  | "idle"
  | "listening"
  | "transcribing"
  | "proofreading"
  | "done"
  | "error";

/** Window that stays tall across the width and tapers only at the very ends — like Wispr's /
 *  Apple's audio waveform — rather than a narrow centre bell. (Flat-topped raised cosine.) */
function envelope(i: number): number {
  const w = Math.sin((Math.PI * (i + 0.5)) / BAR_COUNT); // 0 at the ends, 1 at the centre
  return Math.pow(w, 0.45); // <1 power flattens the middle, keeps the end taper
}

export default function Dictation() {
  const [phase, setPhase] = useState<Phase>("idle");
  const [text, setText] = useState("");
  const [status, setStatus] = useState<DictationStatus | null>(null);
  // Waveform animation, all DOM-driven (no React re-render at 60 fps):
  const barEls = useRef<(HTMLSpanElement | null)[]>([]);
  const levelTarget = useRef(0); // latest mic amplitude (0..1) from level events
  const levelNow = useRef(0); // eased, displayed amplitude
  // Frozen per-bar height character so the wave reads like real audio (irregular neighbours)
  // instead of a clean math curve. Generated once at mount, stable across frames.
  const grain = useRef<number[]>(
    Array.from({ length: BAR_COUNT }, () => 0.55 + Math.random() * 0.45),
  );
  // Phase inside event handlers without re-subscribing.
  const phaseRef = useRef<Phase>("idle");
  phaseRef.current = phase;

  const [lang, setLang] = useState("auto");
  const [proofread, setProofread] = useState(true);
  // Current language inside the keydown handler without re-subscribing (like phaseRef).
  const langRef = useRef(lang);
  langRef.current = lang;

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

  // Polish (AI proofread) toggle. Functional update keeps it correct from the keydown handler;
  // the flag is read live at the proofread decision point, so it even takes effect between
  // clicking Finish and the AI call starting. Revert on persist failure so the switch never lies.
  const toggleProofread = () => {
    setProofread((p) => {
      const next = !p;
      dictationSetProofread(next).catch(() => setProofread(!next));
      return next;
    });
  };

  // ←/→ cycle the spoken language; reads langRef so the keydown handler isn't stale.
  const cycleLang = (dir: number) => {
    const i = CAPTION_LANGUAGES.indexOf(langRef.current);
    const next = CAPTION_LANGUAGES[(i + dir + CAPTION_LANGUAGES.length) % CAPTION_LANGUAGES.length];
    changeLang(next);
  };

  // A fresh trigger (hotkey/tray) resets the overlay for the new session.
  useEffect(() => {
    const un = listen("ghostpen://dictation-show", () => {
      setPhase("listening");
      setText("");
      refreshStatus();
    });
    refreshStatus();
    return () => {
      un.then((f) => f());
    };
  }, []);

  // Mic level → target amplitude only; the rAF loop below turns it into the flowing wave.
  useEffect(() => {
    const un = listen<number>("ghostpen://dictation-level", (e) => {
      levelTarget.current =
        phaseRef.current === "listening" ? Math.max(0, Math.min(1, e.payload)) : 0;
    });
    return () => {
      un.then((f) => f());
    };
  }, []);

  // The wave. While listening it flows with the eased mic level plus a faint idle ripple;
  // while whisper/AI is working the .dict-wave.busy shimmer owns the bars (we skip writes);
  // otherwise it settles flat. Two traveling sines at different speeds give an organic,
  // non-repeating flow; the bell envelope keeps it tall in the middle like Siri's.
  useEffect(() => {
    let raf = 0;
    let t = 0;
    let prev = performance.now();
    const tick = (now: number) => {
      const dt = Math.min(0.05, (now - prev) / 1000);
      prev = now;
      t += dt;
      const p = phaseRef.current;
      const listening = p === "listening";
      raf = requestAnimationFrame(tick);
      if (p === "transcribing" || p === "proofreading") return; // shimmer drives the bars
      const target = listening ? levelTarget.current : 0;
      // Attack fast, release slow (like an audio meter): peaks pop, tails linger.
      const k = target > levelNow.current ? 0.3 : 0.07;
      levelNow.current += (target - levelNow.current) * k;
      const amp = Math.min(1, levelNow.current * AMP_GAIN);
      const idle = listening ? 0.05 : 0; // gentle breathing line when silent
      for (let i = 0; i < BAR_COUNT; i++) {
        const el = barEls.current[i];
        if (!el) continue;
        // Two traveling sines (a slow body + a faster ripple) give flowing audio texture;
        // the frozen grain[i] makes neighbouring bars uneven like a real waveform.
        const flow = 0.6 + 0.4 * (0.6 * Math.sin(i * 0.6 - t * 7) + 0.4 * Math.sin(i * 1.7 + t * 4.5));
        const swell = Math.min(1, envelope(i) * (idle + amp) * flow * grain.current[i]);
        el.style.height = `${(BAR_MIN + (BAR_MAX - BAR_MIN) * Math.max(0, swell)).toFixed(1)}px`;
      }
    };
    raf = requestAnimationFrame(tick);
    return () => cancelAnimationFrame(raf);
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
      } else if (ev.key === "p" || ev.key === "P") {
        ev.preventDefault();
        toggleProofread();
      } else if (ev.key === "ArrowLeft") {
        ev.preventDefault();
        cycleLang(-1);
      } else if (ev.key === "ArrowRight") {
        ev.preventDefault();
        cycleLang(1);
      }
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, []);

  const busyPhase = phase === "transcribing" || phase === "proofreading";
  const hint =
    phase === "listening"
      ? `Listening — ⏎ finish · Esc cancel · P polish ${proofread ? "on" : "off"}`
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
            {Array.from({ length: BAR_COUNT }, (_, i) => (
              <span
                key={i}
                ref={(el) => {
                  barEls.current[i] = el;
                }}
                className="dict-bar"
                style={{ height: `${BAR_MIN}px`, animationDelay: `${i * 36}ms` }}
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

          {/* AI polish (proofread) switch — iOS-style slider. Not focusable (same safety
              note as the buttons); toggle it with the mouse or the "P" key. */}
          <label className="dict-polish" title="AI polish after dictation (P)">
            <input
              type="checkbox"
              checked={proofread}
              onChange={toggleProofread}
              tabIndex={-1}
            />
            <span className="dict-polish-track">
              <span className="dict-polish-thumb" />
            </span>
            <span className="dict-polish-label">Polish</span>
          </label>

          <div className="dict-actions">
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
