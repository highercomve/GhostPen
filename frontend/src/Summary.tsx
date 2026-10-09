import { useCallback, useEffect, useRef, useState, type CSSProperties } from "react";
import { Icon } from "./icons";
import { cancelAi, clipboardText, copyText, listenVoice, summarizeLink, summaryState, ttsSpeak, ttsStop, ttsWarmUp, type TtsState } from "./api";
import { listen } from "./events";
import { renderMarkdown } from "./markdown";

// What the Zig side reports while it fetches and summarizes
// (src/main.zig's summarize_link): the stage, the page it found and the
// markdown so far — the page can miss events while it loads, so it also
// picks the state up through `summary_state`.
interface SummaryState {
  state: string;
  title: string;
  chars: number;
  message: string;
  markdown: string;
  /** The page's readable text (the read-aloud's whole-page source). */
  page_text?: string;
}

const EMPTY: SummaryState = { state: "", title: "", chars: 0, message: "", markdown: "" };

const STAGE: Record<string, string> = {
  fetching: "Fetching the page…",
  reading: "Reading the document…",
  writing: "Writing the summary…",
  ready: "Summary ready",
  error: "Couldn't summarize this link",
};

const URL_SHAPE = /^https?:\/\/\S+$/i;

// The summary's depth: the id as the protocol sends it (web_page.Level),
// the label as the picker shows it.
const LEVELS: [string, string][] = [
  ["brief", "Brief"],
  ["standard", "Standard"],
  ["detailed", "Detailed"],
];

interface ReaderSettings {
  size: number;
  font: "serif" | "sans";
  spacing: "comfortable" | "compact";
}

const READER_DEFAULTS: ReaderSettings = { size: 17, font: "serif", spacing: "comfortable" };

function loadReaderSettings(): ReaderSettings {
  try {
    const saved = JSON.parse(localStorage.getItem("ghostpen-summary-reader") || "null");
    return {
      size: typeof saved?.size === "number" && Number.isFinite(saved.size) ? Math.max(14, Math.min(24, saved.size)) : 17,
      font: saved?.font === "sans" ? "sans" : "serif",
      spacing: saved?.spacing === "compact" ? "compact" : "comfortable",
    };
  } catch {
    return READER_DEFAULTS;
  }
}

export default function Summary() {
  const [reader, setReader] = useState<ReaderSettings>(loadReaderSettings);
  useEffect(() => {
    try { localStorage.setItem("ghostpen-summary-reader", JSON.stringify(reader)); } catch { /* Storage may be unavailable. */ }
  }, [reader]);
  const [url, setUrl] = useState("");
  // The summary's depth (web_page.Level): what the picker picks, the next
  // run summarizes with.
  const [level, setLevel] = useState("standard");
  // A summarize request is in flight (the button's own await; the state
  // events may lag behind it).
  const [pending, setPending] = useState(false);
  const [state, setState] = useState<SummaryState>(EMPTY);
  const stateRef = useRef(state);
  const [markdown, setMarkdown] = useState("");
  const [html, setHtml] = useState("");
  const [copied, setCopied] = useState(false);
  const bodyRef = useRef<HTMLElement>(null);
  // The built-in voice: the read-aloud controls below listen to its state.
  const [voice, setVoice] = useState<TtsState>({ phase: "idle", message: "", progress: 0, voice: "" });
  const pageTextRef = useRef("");
  const voicePlaying = voice.phase === "playing" || voice.phase === "generating" || voice.phase === "downloading";
  const speak = useCallback((text: string) => {
    if (voicePlaying) ttsStop().catch(() => {});
    else ttsSpeak(text, "", "", "").catch(() => {});
  }, [voicePlaying]);

  // The events, and the pickup for what the page missedwhile it loaded
  // (listeners attach after the first status was broadcast).
  useEffect(() => {
    const ups: Promise<unknown>[] = [];
    ups.push(
      listen<SummaryState>("ghostpen://summary-status", (e) => {
        stateRef.current = e.payload;
        if (e.payload.page_text !== undefined) pageTextRef.current = e.payload.page_text || "";
        setState(e.payload);
        // A fresh run resets the body (the picker-up never does: it only
        // fills a page that started empty).
        if (e.payload.state === "fetching") setMarkdown("");
      }),
    );
    ups.push(
      listen<string>("ghostpen://summary-chunk", (e) => {
        setMarkdown((m) => m + e.payload);
      }),
    );
    ups.push(listenVoice(setVoice));
    // The reader opened: load the voice now so Read starts sooner.
    ttsWarmUp().catch(() => {});
    summaryState()
      .then((s) => {
        pageTextRef.current = s.page_text || "";
        if (!stateRef.current.state && s.state) {
          stateRef.current = s;
          setState(s);
          setMarkdown(s.markdown || "");
        }
      })
      .catch(() => {});
    return () => {
      Promise.allSettled(ups).then((all) => {
        for (const r of all) if (r.status === "fulfilled") (r.value as () => void)();
      });
    };
  }, []);

  // The link is usually already on the clipboard: prefill it once.
  useEffect(() => {
    clipboardText()
      .then((t) => {
        const u = t.trim();
        if (URL_SHAPE.test(u)) setUrl(u);
      })
      .catch(() => {});
  }, []);

  // The markdown goes through the renderer a beat after it lands: the
  // summary can be long, and chunk-by-chunk parsing is waste.
  useEffect(() => {
    const t = window.setTimeout(() => setHtml(renderMarkdown(markdown)), 90);
    return () => window.clearTimeout(t);
  }, [markdown]);

  // While it writes, follow the bottom — but never drag the user back after
  // they scrolled up to read.
  useEffect(() => {
    const el = bodyRef.current;
    if (!el || state.state !== "writing") return;
    const chasing = el.scrollHeight - el.scrollTop - el.clientHeight < 200;
    if (chasing) el.scrollTop = el.scrollHeight;
  }, [html, state.state]);

  // Esc: stop the model (its answer so far stays); the window's close
  // button hides it.
  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if (e.key === "Escape") cancelAi().catch(() => {});
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, []);

  const running = pending || (state.state !== "" && state.state !== "ready" && state.state !== "error");
  const canGo = URL_SHAPE.test(url.trim()) && !running;

  const go = async () => {
    const u = url.trim();
    if (!URL_SHAPE.test(u) || running) return;
    setPending(true);
    try {
      await summarizeLink(u, level);
    } catch {
      // The failure is in the window's body already (summarize_link reports
      // there, not here).
    }
    setPending(false);
  };

  return (
    <div className={`summary ${html ? "has-content" : ""}`} style={{
      "--reader-size": `${reader.size}px`,
      "--reader-font": reader.font === "serif" ? 'Georgia, "Times New Roman", serif' : '"Trebuchet MS", sans-serif',
      "--reader-leading": reader.spacing === "comfortable" ? 1.85 : 1.55,
    } as CSSProperties}>
      <header className="summary-head" data-oriel-drag-region>
        <div className="summary-heading">
          <span className="summary-eyebrow"><Icon name="link" /> GhostPen / Link reader</span>
          <h1>Summary<span className="summary-heading-dot">.</span></h1>
          <p>A little less reading. A lot more understanding.</p>
        </div>
        <div className="summary-head-btns">
          <button
            className={`summary-copy ${copied ? "done" : ""}`}
            title="Copy the whole summary (Markdown)"
            disabled={!markdown}
            onClick={async () => {
              try {
                await copyText(markdown);
                setCopied(true);
                window.setTimeout(() => setCopied(false), 1600);
              } catch {
                /* ignore */
              }
            }}
          >
            <Icon name="copy" />
            {copied ? "Copied" : "Copy"}
          </button>
          <button
            className="summary-copy summary-speak"
            title={voicePlaying ? "Stop the built-in voice" : "Read the summary through the built-in voice"}
            disabled={!markdown && !voicePlaying}
            onClick={() => speak(markdown)}
          >
            {voicePlaying ? "■ Stop" : "🔊 Read summary"}
          </button>
          {pageTextRef.current.trim().length > 0 && (
            <button
              className="summary-copy summary-speak"
              title={voicePlaying ? "Stop the built-in voice" : "Read the whole page through the built-in voice"}
              disabled={voicePlaying}
              onClick={() => speak(pageTextRef.current.trim())}
            >
              {voicePlaying ? "■ Stop" : "🔊 Read page"}
            </button>
          )}
        </div>
      </header>

      <details className="summary-source" open={!html}>
        <summary hidden={!html}><Icon name="link" /> Summarize another link <span>+</span></summary>
        <form
          className="summary-bar"
          onSubmit={(e) => {
            e.preventDefault();
            void go();
          }}
        >
          <label className="summary-label" htmlFor="summary-url">Start with a link</label>
          <div className="summary-url-field">
            <Icon name="link" />
            <input
              id="summary-url"
              className="summary-url"
              type="url"
              placeholder="Paste an article or webpage URL…"
              value={url}
              disabled={running}
              spellCheck={false}
              onChange={(e) => setUrl(e.target.value)}
            />
          </div>
          <div className="summary-options">
            <div className="summary-depth">
              <span className="summary-depth-label">How much detail?</span>
              <div className="summary-level" role="group" aria-label="Summary depth">
                {LEVELS.map(([id, label]) => (
                  <button
                    key={id}
                    type="button"
                    className={`summary-level-btn ${level === id ? "active" : ""}`}
                    aria-pressed={level === id}
                    disabled={running}
                    onClick={() => setLevel(id)}
                  >
                    {label}
                  </button>
                ))}
              </div>
            </div>
            <button className="summary-go" type="submit" disabled={!canGo}>
              {running ? <span className="spinner summary-go-spinner" /> : <Icon name="send" className="summary-go-icon" />}
              {running ? "Summarizing…" : "Summarize"}
            </button>
          </div>
        </form>
      </details>

      <div className="summary-reader-bar" aria-label="Reading preferences">
        <details className="summary-reader-settings">
          <summary><Icon name="concise" /> Reading settings</summary>
          <div className="summary-reader-options">
            <label>Typeface
              <select value={reader.font} onChange={(e) => setReader((r) => ({ ...r, font: e.target.value as ReaderSettings["font"] }))}>
                <option value="serif">Serif</option><option value="sans">Sans serif</option>
              </select>
            </label>
            <label>Line spacing
              <select value={reader.spacing} onChange={(e) => setReader((r) => ({ ...r, spacing: e.target.value as ReaderSettings["spacing"] }))}>
                <option value="comfortable">Relaxed</option><option value="compact">Compact</option>
              </select>
            </label>
            <button className="summary-reader-reset" onClick={() => setReader(READER_DEFAULTS)}>Reset</button>
          </div>
        </details>
        <div className="summary-font-size" role="group" aria-label="Font size">
          <button aria-label="Decrease font size" disabled={reader.size <= 14} onClick={() => setReader((r) => ({ ...r, size: Math.max(14, r.size - 1) }))}>A<span>−</span></button>
          <output aria-live="polite" aria-label="Current font size">{reader.size}px</output>
          <button aria-label="Increase font size" disabled={reader.size >= 24} onClick={() => setReader((r) => ({ ...r, size: Math.min(24, r.size + 1) }))}>A<span>+</span></button>
        </div>
      </div>
      <main className="summary-body" ref={bodyRef}>
        {state.state === "error" ? (
          <div className="summary-error" role="alert">
            <span className="summary-eyebrow">Let's try again</span>
            <h2>We couldn't read this link.</h2>
            <p className="summary-error-title">{state.message || "Check the URL and try summarizing again."}</p>
            {state.title ? <p className="hint">{state.title}</p> : null}
          </div>
        ) : (
          <>
            {running && (
              <div className="summary-status" role="status" aria-live="polite">
                <div className="spinner" />
                <div className="summary-status-text">
                  <span className="summary-stage">{STAGE[state.state] || "Working…"}</span>
                  {state.title ? <span className="summary-title">{state.title}</span> : null}
                  {state.chars > 0 && (state.state === "reading" || state.state === "writing") ? (
                    <span className="summary-chars">{state.chars.toLocaleString()} characters read</span>
                  ) : null}
                </div>
                <button className="summary-stop" onClick={() => cancelAi().catch(() => {})}>Stop</button>
              </div>
            )}
            {html ? (
              <div className="summary-paper">
                <div className="summary-paper-meta">
                  <span className="summary-eyebrow">The essentials</span>
                  <span>{running ? "Writing…" : "Ready to read"}</span>
                </div>
                {state.title && <h2 className="summary-document-title">{state.title}</h2>}
                <article className="md" dangerouslySetInnerHTML={{ __html: html }} />
              </div>
            ) : running ? null : (
              <div className="summary-empty">
                <div className="summary-illustration" aria-hidden="true">
                  <div className="summary-mini-page"><span /><i /><i /><i /><b /><i /><i /></div>
                  <span className="summary-illustration-badge"><Icon name="concise" /></span>
                </div>
                <span className="summary-eyebrow">From the page to the point</span>
                <h2>Big ideas. Less noise.</h2>
                <p>Drop in a link and we'll bring the key ideas,<br className="summary-empty-break" /> useful details, and takeaways into focus.</p>
                <div className="summary-empty-note"><Icon name="link" /> Articles, essays, and webpages</div>
              </div>
            )}
          </>
        )}
      </main>
      <footer className="summary-footer">
        <span><span className={`summary-status-dot ${running ? "busy" : ""}`} />{running ? "Making sense of your source" : markdown ? "Your reading, distilled" : "A fresh perspective starts here"}</span>
        <span>{running ? "Esc to stop" : "Made with GhostPen"}</span>
      </footer>
    </div>
  );
}
