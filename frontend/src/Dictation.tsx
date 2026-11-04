import { useEffect, useRef, useState, type ReactNode } from "react";
import { listen } from "./events";
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
  copyText,
  CAPTION_LANGUAGES,
  PASTE_KEYS,
} from "./api";
import { Icon } from "./icons";
import Ghost, { type GhostMood } from "./Ghost";
import { singleWindow } from "./mode";

// As a page of the app window (single-window mode, dictation not floating): a title,
// room for the text, and the dictations of this session below it.
const asPage = singleWindow;
interface Done {
  at: number;
  text: string;
}

// Waveform: a continuous flowing wave (Apple-dictation style), not independent bars each
// jumping to a random height on every level tick. The mic's ~10 Hz RMS events only set a
// *target* amplitude; a requestAnimationFrame loop eases the displayed amplitude toward it and
// renders a traveling multi-sine ripple at 60 fps, so the wave flows and breathes. Bars are
// driven directly via DOM refs to avoid re-rendering React 60×/s.
const BAR_COUNT = 14;
const BAR_MIN = 3; // px — resting height
const BAR_MAX = 24; // px — full-loudness center bar (≈ the wave area height)
const AMP_GAIN = 1.9; // boosts mic level so normal speech drives tall bars, not a timid wiggle
const HEARD_LEVEL = 0.1; // eased, boosted level (0..1) above which "Speak now…" becomes "Listening…"

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

/** A spoken-language option as the picker shows it ("auto" detects). */
function languageName(code: string): string {
  if (code === "auto") return "Auto-detect";
  try {
    const name = new Intl.DisplayNames(["en"], { type: "language" }).of(code);
    return name ? name.charAt(0).toUpperCase() + name.slice(1) : code;
  } catch {
    return code;
  }
}

/** The live text, split so the newest words read brightest and older ones fade back. */
const FRESH_WORDS = 3;
function LiveWords({ text, fade }: { text: string; fade: boolean }) {
  if (!fade) return <>{text}</>;
  const words = text.trim().split(/\s+/).filter(Boolean);
  if (words.length <= FRESH_WORDS) return <span className="dict-new">{words.join(" ")}</span>;
  return (
    <>
      <span className="dict-old">{words.slice(0, -FRESH_WORDS).join(" ")} </span>
      <span className="dict-new">{words.slice(-FRESH_WORDS).join(" ")}</span>
    </>
  );
}

/** A keyboard key in a hint, as a chip. */
function Key({ children }: { children: string }) {
  return <kbd className="dict-key">{children}</kbd>;
}

function clock(seconds: number): string {
  return `${Math.floor(seconds / 60)}:${String(seconds % 60).padStart(2, "0")}`;
}

export default function Dictation() {
  const [phase, setPhase] = useState<Phase>("idle");
  const [text, setText] = useState("");
  const [recent, setRecent] = useState<Done[]>([]);
  useEffect(() => {
    if (asPage && phase === "done" && text.trim()) setRecent((r) => [{ at: Date.now(), text }, ...r].slice(0, 50));
  }, [phase]);
  // An error that kept the dictation (it couldn't be copied): what failed, shown in the hint;
  // `text` then holds the dictated text, copied with C or a click.
  const [keptError, setKeptError] = useState("");
  const [copied, setCopied] = useState(false);
  const textRef = useRef("");
  textRef.current = text;
  const keptRef = useRef("");
  keptRef.current = keptError;
  const [status, setStatus] = useState<DictationStatus | null>(null);
  // Waveform animation, all DOM-driven (no React re-render at 60 fps):
  const barEls = useRef<(HTMLSpanElement | null)[]>([]);
  const levelTarget = useRef(0); // latest mic amplitude (0..1) from level events
  const levelNow = useRef(0); // eased, displayed amplitude
  const [level, setLevel] = useState(0); // the ghost's mouth (it eases this itself)
  // Audio has arrived in this session (latched, so the live text doesn't flip back on a pause).
  const [hearing, setHearing] = useState(false);
  const hearingRef = useRef(false);
  const markHearing = (on: boolean) => {
    if (hearingRef.current === on) return;
    hearingRef.current = on;
    setHearing(on);
  };
  // Frozen per-bar height character so the wave reads like real audio (irregular neighbours)
  // instead of a clean math curve. Generated once at mount, stable across frames.
  const grain = useRef<number[]>(
    Array.from({ length: BAR_COUNT }, () => 0.55 + Math.random() * 0.45),
  );
  // Phase inside event handlers without re-subscribing.
  const phaseRef = useRef<Phase>("idle");
  phaseRef.current = phase;

  // How long this dictation has been listening (whole seconds), next to the pulsing mic.
  const [elapsed, setElapsed] = useState(0);
  useEffect(() => {
    if (phase !== "listening") return;
    const began = Date.now();
    setElapsed(0);
    const t = window.setInterval(() => setElapsed(Math.floor((Date.now() - began) / 1000)), 500);
    return () => window.clearInterval(t);
  }, [phase]);

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
      // Opened by the trigger before this page listened: catch up.
      if (s.listening && phaseRef.current === "idle") setPhase("listening");
    } catch {
      /* ignore */
    }
  };

  // Applies live: a running session uses the new language on its next transcription pass.
  const changeLang = (l: string) => {
    setLang(l);
    dictationSetLanguage(l).catch(() => {});
  };

  // Proofread (AI pass after dictation) toggle. Functional update keeps it correct from the keydown handler;
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
      setKeptError("");
      markHearing(false);
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
      setLevel(levelTarget.current);
    });
    return () => {
      un.then((f) => f());
    };
  }, []);

  // The ghost's mouth rests when nothing is being heard.
  useEffect(() => {
    if (phase !== "listening") {
      setLevel(0);
      markHearing(false);
    }
  }, [phase]);

  // The wave (only shown while listening). It flows with the eased mic level plus a faint idle
  // ripple; once the phase moves on it settles flat and the loop ends. Two traveling sines at different speeds give an organic,
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
      const target = listening ? levelTarget.current : 0;
      // Attack fast, release slow (like an audio meter): peaks pop, tails linger.
      const k = target > levelNow.current ? 0.3 : 0.07;
      levelNow.current += (target - levelNow.current) * k;
      const flat = !listening && levelNow.current * AMP_GAIN * (BAR_MAX - BAR_MIN) < 0.05;
      if (flat) levelNow.current = 0;
      const amp = Math.min(1, levelNow.current * AMP_GAIN);
      if (listening && amp > HEARD_LEVEL) markHearing(true);
      const idle = listening ? 0.08 : 0; // gentle breathing line when silent
      for (let i = 0; i < BAR_COUNT; i++) {
        const el = barEls.current[i];
        if (!el) continue;
        // Two traveling sines (a slow body + a faster ripple) give flowing audio texture;
        // the frozen grain[i] makes neighbouring bars uneven like a real waveform.
        const flow = 0.6 + 0.4 * (0.6 * Math.sin(i * 0.9 - t * 7) + 0.4 * Math.sin(i * 2.1 + t * 4.5));
        const swell = Math.min(1, envelope(i) * (idle + amp) * flow * grain.current[i]);
        el.style.height = `${(BAR_MIN + (BAR_MAX - BAR_MIN) * Math.max(0, swell)).toFixed(1)}px`;
      }
      if (!flat) raf = requestAnimationFrame(tick);
    };
    raf = requestAnimationFrame(tick);
    return () => cancelAnimationFrame(raf);
  }, [phase]);

  // The phone's own speech recognition (Android): oriel.dictation's phrases as they're
  // heard; the backend sends ghostpen://dictation once it's stopped.
  const heard = useRef("");
  useEffect(() => {
    const show = (partial: string) => {
      if (phaseRef.current !== "listening") return;
      setText([heard.current, partial].filter(Boolean).join(" "));
    };
    const un1 = listen<{ text: string }>("dictation:partial", (e) => show(e.payload.text));
    const un2 = listen<{ text: string }>("dictation:final", (e) => {
      heard.current = [heard.current, e.payload.text.trim()].filter(Boolean).join(" ");
      show("");
    });
    const un3 = listen<{ message: string }>("dictation:error", (e) => {
      setPhase("error");
      setText(e.payload.message);
    });
    // Stopped on its own (after an error, or the recognizer gave up): finish what was heard.
    const un4 = listen("dictation:ended", () => {
      if (phaseRef.current === "listening") dictationStop().catch(() => {});
    });
    const un5 = listen("ghostpen://dictation-show", () => {
      heard.current = "";
    });
    return () => {
      for (const u of [un1, un2, un3, un4, un5]) u.then((f) => f());
    };
  }, []);

  // Transcript / state updates from the backend.
  useEffect(() => {
    const un = listen<DictationUpdate>("ghostpen://dictation", (e) => {
      const u = e.payload;
      setKeptError(u.state === "error" && u.message ? u.message : "");
      setCopied(false);
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
    setKeptError("");
  };

  // Copy the dictation an error kept (nothing else is copyable from the pill).
  const copyKept = () => {
    if (!keptRef.current || !textRef.current) return;
    copyText(textRef.current)
      .then(() => setCopied(true))
      .catch((e) => console.warn("copy dictation:", e));
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
      } else if ((ev.key === "c" || ev.key === "C") && phaseRef.current === "error" && keptRef.current) {
        ev.preventDefault();
        copyKept();
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
  const mood: GhostMood =
    phase === "listening" ? "talking" : busyPhase ? "working" : phase === "done" ? "done" : phase === "error" ? "error" : "idle";
  // Language and Proofread live on the island while you can still change them.
  const withOptions = phase === "idle" || phase === "listening";
  // An error with no kept dictation: its message is the live text (and the island only says it failed).
  const plainError = phase === "error" && !keptError;

  // What the live text says before the first words arrive.
  const placeholder =
    phase === "listening"
      ? status && !status.model_ready
        ? `Whisper model “${status.model}” not downloaded — Settings → Captions.`
        : hearing
          ? "Listening…"
          : "Speak now…"
      : phase === "idle"
        ? "Press Space or the ghost to start dictating"
        : "";

  // Only the keys that work in this phase.
  const dot = <span className="dict-dot"> · </span>;
  const options = (
    <>
      <Key>P</Key> proofread{dot}
      <Key>←</Key>
      <Key>→</Key> language
    </>
  );
  const hint: ReactNode =
    phase === "listening" ? (
      <>
        <Key>Enter</Key> finish{dot}
        <Key>Esc</Key> cancel{dot}
        {options}
      </>
    ) : busyPhase ? (
      <>
        <Key>Esc</Key> cancel
      </>
    ) : phase === "done" ? (
      <>
        <Key>{PASTE_KEYS}</Key> to paste where you were
      </>
    ) : phase === "error" ? (
      <>
        <Key>Space</Key> try again{dot}
        {keptError && !copied && (
          <>
            <Key>C</Key> copy{dot}
          </>
        )}
        <Key>Esc</Key> close
      </>
    ) : (
      <>
        <Key>Space</Key> start{dot}
        <Key>Esc</Key> close{dot}
        {options}
      </>
    );

  // tabIndex -1 + focus suppression on every button: a focused button would be re-activated by
  // a stray Space/Enter, silently starting a recording. Recording starts ONLY by a deliberate
  // click or the compositor keybind.
  const noFocus = { tabIndex: -1, onMouseDown: (e: { preventDefault: () => void }) => e.preventDefault() } as const;

  // The ghost is the in-island toggle: start a new dictation from an idle, finished or errored
  // overlay (the backend emits `dictation-show`, which resets the UI), or finish a live one.
  const ghostButton = (
    <button
      className="dict-ghost"
      onClick={micToggle}
      disabled={busyPhase}
      {...noFocus}
      title={phase === "listening" ? "Finish dictation" : phase === "idle" ? "Start dictating (Space)" : "Dictate again (Space)"}
      aria-label={phase === "listening" ? "Finish dictation" : phase === "idle" ? "Start dictating" : "Dictate again"}
    >
      <Ghost mood={mood} level={level} size={30} />
    </button>
  );

  const cancelButton = (
    <button className="dict-btn" onClick={cancel} {...noFocus} title="Cancel (Esc)" aria-label="Cancel dictation">
      <Icon name="close" />
    </button>
  );

  // Settings: shown on hover of the island. It sits before the divider, in the island's slack, and
  // takes no width until then (so nothing shifts when it appears).
  const gearButton = !asPage && (
    <button
      className="dict-btn dict-gear"
      onClick={() => openSettings().catch((e) => console.warn("open settings:", e))}
      {...noFocus}
      title="Dictation settings"
      aria-label="Dictation settings"
    >
      <Icon name="settings" />
    </button>
  );

  const optionChips = (
    <>
      <span className="dict-div push" aria-hidden="true" />
      {/* Spoken language — "auto" detects; changing it mid-dictation re-transcribes in the new
          language on the next pass. The native select is invisible over the chip, so a click
          opens it; ← → cycle. */}
      <label className="dict-chip dict-lang" title="Spoken language (← →)">
        <Icon name="translate" className="dict-chip-icon" />
        <span className="dict-chip-text">{languageName(lang)}</span>
        <span className="dict-caret" aria-hidden="true" />
        <select value={lang} onChange={(e) => changeLang(e.target.value)} tabIndex={-1} aria-label="Spoken language">
          {CAPTION_LANGUAGES.map((l) => (
            <option key={l} value={l}>
              {languageName(l)}
            </option>
          ))}
        </select>
      </label>
      {/* Proofread (AI pass after dictation): a chip, tinted when on. The checkbox is hidden and
          not focusable (same safety note as the buttons); toggle it with a click or "P". */}
      <label className={`dict-chip dict-polish ${proofread ? "on" : ""}`} title="Proofread (P)">
        <input type="checkbox" role="switch" checked={proofread} onChange={toggleProofread} tabIndex={-1} aria-keyshortcuts="P" />
        <span className="dict-switch" aria-hidden="true"><span className="dict-switch-thumb" /></span>
        <span className="dict-chip-text">Proofread</span>
      </label>
    </>
  );

  const finishButton = (
    <button
      className="dict-btn ok"
      onClick={finish}
      disabled={phase === "idle"}
      {...noFocus}
      title={phase === "idle" ? "Nothing to finish yet: start dictating first" : "Finish and paste (Enter)"}
      aria-label="Finish dictation"
    >
      <Icon name="check" />
    </button>
  );

  return (
    <div className={`dictation ${asPage ? "page" : ""}`} data-oriel-drag-region={asPage ? undefined : true}>
      {asPage && (
        <header className="page-head">
          <h1>Dictation</h1>
          <p>Speak, then finish: the text is copied (and pasted where you were, when GhostPen can).</p>
        </header>
      )}

      {/* The live text floats above the island, no card of its own. It is always rendered at the
          same fixed size (nbsp when empty): a transparent WebKitGTK window doesn't clear old
          frames, so geometry that changes between states leaves ghost outlines. */}
      <div
        className={`dict-live ${phase} ${plainError ? "error" : ""} ${!text && placeholder ? "placeholder" : ""} ${text || placeholder ? "has-text" : ""}`}
        onClick={keptError ? copyKept : undefined}
        title={keptError ? "Copy (C)" : undefined}
      >
        <div className={`dict-live-text ${busyPhase ? "shimmer" : ""}`}>
          {text ? <LiveWords text={text} fade={phase === "listening"} /> : placeholder || " "}
        </div>
      </div>

      <div className={`dict-island ${phase}`}>
        {phase === "idle" && (
          <>
            {ghostButton}
            <span className="dict-state">Ready</span>
            <span className="dict-grow" />
            {gearButton}
            {optionChips}
            {finishButton}
          </>
        )}
        {phase === "listening" && (
          <>
            {cancelButton}
            {ghostButton}
            <div className="dict-wave" aria-hidden="true">
              {Array.from({ length: BAR_COUNT }, (_, i) => (
                <span
                  key={i}
                  ref={(el) => {
                    barEls.current[i] = el;
                  }}
                  className="dict-bar"
                  style={{ height: `${BAR_MIN}px` }}
                />
              ))}
            </div>
            <span className="dict-timer" aria-label="Time spent listening">
              {clock(elapsed)}
            </span>
            {gearButton}
            {optionChips}
            {finishButton}
          </>
        )}
        {busyPhase && (
          <>
            {ghostButton}
            <span className="dict-state" role="status">
              {phase === "transcribing" ? "Transcribing…" : "Proofreading with your AI profile…"}
            </span>
          </>
        )}
        {phase === "done" && (
          <>
            {ghostButton}
            {/* The result is on the clipboard (a successful paste hides this window), so this
                screen only ever means "copied". */}
            <span className="dict-state" role="status">Copied</span>
            <span className="dict-div" aria-hidden="true" />
            <span className="dict-keys">
              <Key>Space</Key> again{dot}
              <Key>Esc</Key> close
            </span>
          </>
        )}
        {phase === "error" && (
          <>
            {ghostButton}
            <span className="dict-state dict-state-error" role="status" title={keptError || undefined}>
              {keptError ? (copied ? "Copied" : keptError) : "Couldn’t dictate"}
            </span>
            {cancelButton}
          </>
        )}
      </div>

      {/* Always rendered (nbsp when empty) so the geometry never changes. */}
      <div className="dict-hint">{hint || " "}</div>

      {asPage && recent.length > 0 && (
        <section className="dict-recent">
          <h2>This session</h2>
          {recent.map((d) => (
            <div key={d.at} className="dict-recent-item">
              <span className="dict-recent-time">{new Date(d.at).toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" })}</span>
              <p>{d.text}</p>
              <button className="btn" onClick={() => copyText(d.text).catch(() => {})}>Copy</button>
            </div>
          ))}
        </section>
      )}
    </div>
  );
}
