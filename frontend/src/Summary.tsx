import { useCallback, useEffect, useRef, useState, type CSSProperties } from "react";
import { Icon } from "./icons";
import { cancelAi, clipboardText, copyText, exportSummary, listenVoice, summarizeLink, summaryState, ttsSpeak, ttsStop, ttsWarmUp, type TtsState, type SummaryState, type SummaryDelta, type SummaryStatus } from "./api";
import { listen } from "./events";
import { renderMarkdown } from "./markdown";
import { renderDiagrams, exportDiagrams } from "./diagrams";
import { openExternal } from "./oriel";

// What the Zig side reports while it fetches and summarizes
// (src/main.zig's summarize_link): the stage, the page it found and the
// markdown so far — the page can miss events while it loads, so it also
// picks the state up through `summary_state`.
const EMPTY: SummaryState = { state: "", title: "", chars: 0, message: "", markdown: "", thinking: "", thinking_requested: false, revision: 0 };

const STAGE: Record<string, string> = {
  fetching: "Fetching the page…",
  reading: "Reading the document…",
  writing: "Writing the summary…",
  ready: "Summary ready",
  error: "Couldn't summarize this link",
};

// What the box takes: web links (http/https/file) or files on this
// machine (~/words.md, /home/me/doc, ./relative, ../back).
const TARGET_SHAPE = /^(?:https?:\/\/\S+|file:\/\/\S+|(?:~\/|\.\.\/|\.\/|\/)\S*)$/;

// The summary's links open in the browser, never inside this window
// (markdown.ts only writes http(s) hrefs).
function openLink(e: { target: EventTarget | null; preventDefault(): void }) {
  const a = (e.target as Element | null)?.closest?.("a");
  if (!a) return;
  e.preventDefault();
  const href = a.getAttribute("href") ?? "";
  if (/^https?:\/\//i.test(href)) openExternal(href).catch((err) => console.warn("open link:", err));
}

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
  showThinking: boolean;
}

const READER_DEFAULTS: ReaderSettings = { size: 17, font: "serif", spacing: "comfortable", showThinking: false };

function loadReaderSettings(): ReaderSettings {
  try {
    const saved = JSON.parse(localStorage.getItem("ghostpen-summary-reader") || "null");
    return {
      size: typeof saved?.size === "number" && Number.isFinite(saved.size) ? Math.max(14, Math.min(24, saved.size)) : 17,
      font: saved?.font === "sans" ? "sans" : "serif",
      spacing: saved?.spacing === "compact" ? "compact" : "comfortable",
      showThinking: saved?.showThinking === true,
    };
  } catch {
    return READER_DEFAULTS;
  }
}

// Render at a bounded cadence during continuous output. A trailing debounce
// can postpone every update until the model stops sending chunks.
function useStreamingMarkdown(source: string): string {
  const latest = useRef(source);
  const timer = useRef<number | null>(null);
  const [html, setHtml] = useState("");
  useEffect(() => {
    latest.current = source;
    if (!source) {
      if (timer.current !== null) window.clearTimeout(timer.current);
      timer.current = null;
      setHtml("");
    } else if (timer.current === null) {
      timer.current = window.setTimeout(() => {
        timer.current = null;
        setHtml(renderMarkdown(latest.current));
      }, 90);
    }
  }, [source]);
  useEffect(() => () => {
    if (timer.current !== null) window.clearTimeout(timer.current);
    timer.current = null;
  }, []);
  // Hide/reset immediately, even before the effect clears the previous HTML.
  return source ? html : "";
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
  const [markdown, setMarkdown] = useState("");
  const [thinking, setThinking] = useState("");
  const summary = markdown.trim();
  const html = useStreamingMarkdown(summary);
  const thinkingHtml = useStreamingMarkdown(reader.showThinking ? thinking : "");
  const [copied, setCopied] = useState(false);
  const [menu, setMenu] = useState(false);
  const [exported, setExported] = useState("");
  // Export: Markdown (the answer's own text) or PDF (typed from it); the
  // save dialog and the write run on the backend, the busy flag only spins
  // the button.
  const [saving, setSaving] = useState<"markdown" | "pdf" | null>(null);
  const doExport = async (format: "markdown" | "pdf") => {
    if (!summary || saving) return;
    setMenu(false);
    setSaving(format);
    try {
      // The PDF gets the diagrams as images: each Mermaid fence renders
      // fresh in the light palette; a refusal keeps the code block.
      const images = format === "pdf" ? await exportDiagrams(summary).catch(() => []) : [];
      setExported(await exportSummary(state.title, summary, images, format));
      window.setTimeout(() => setExported(""), 2400);
    } catch (e) {
      setExported(String(e).replace(/.*"message":"([^"]+)".*/s, "$1"));
    }
    setSaving(null);
  };
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
    type Update = { kind: "status"; data: SummaryStatus } | { kind: "delta"; data: SummaryDelta };
    const waiting: Update[] = [];
    let ready = false;
    let active = true;
    let revision = 0;
    const apply = (update: Update) => {
      if (!active || update.data.revision <= revision) return;
      revision = update.data.revision;
      if (update.kind === "delta") {
        const append = update.data.channel === "thinking" ? setThinking : setMarkdown;
        append((text) => text + update.data.text);
      } else {
        const s = update.data;
        if (s.page_text !== undefined) pageTextRef.current = s.page_text || "";
        setState((previous) => ({ ...previous, ...s }));
        if (s.state === "fetching") {
          setMarkdown("");
          setThinking("");
        }
      }
    };
    const receive = (update: Update) => {
      if (!active) return;
      if (ready) apply(update);
      else waiting.push(update);
    };
    ups.push(
      listen<SummaryStatus>("ghostpen://summary-status", (e) => receive({ kind: "status", data: e.payload })),
    );
    ups.push(
      listen<SummaryDelta>("ghostpen://summary-chunk", (e) => receive({ kind: "delta", data: e.payload })),
    );
    ups.push(listenVoice(setVoice));
    // The reader opened: load the voice now so Read starts sooner.
    ttsWarmUp().catch(() => {});
    Promise.all(ups).then(() => summaryState())
      .then((s) => {
        if (!active) return;
        pageTextRef.current = s.page_text || "";
        setState(s);
        setMarkdown(s.markdown);
        setThinking(s.thinking);
        revision = s.revision;
        ready = true;
        // A snapshot includes events emitted before its lock was acquired.
        // Replay only newer ones, avoiding dropped or duplicated text.
        for (const update of waiting) apply(update);
        waiting.length = 0;
      })
      .catch(() => {
        ready = true;
        for (const update of waiting) apply(update);
        waiting.length = 0;
      });
    return () => {
      active = false;
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
        if (TARGET_SHAPE.test(u)) setUrl(u);
      })
      .catch(() => {});
  }, []);

  // While it writes, follow the bottom — but never drag the user back after
  // they scrolled up to read.
  useEffect(() => {
    const el = bodyRef.current;
    if (!el || state.state !== "writing") return;
    const chasing = el.scrollHeight - el.scrollTop - el.clientHeight < 200;
    if (chasing) el.scrollTop = el.scrollHeight;
  }, [html, thinkingHtml, state.state]);

  // Mermaid fences in the answer render on every pass; only fresh nodes are
  // touched, so a streamed document draws once the fence changes to final.
  useEffect(() => {
    void renderDiagrams(bodyRef.current);
  }, [html, thinkingHtml]);

  // Revealing a section above the answer must bring it into view, even if
  // the reader finished at the bottom of a long summary.
  useEffect(() => {
    if (reader.showThinking && bodyRef.current) bodyRef.current.scrollTop = 0;
  }, [reader.showThinking]);

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
  const canGo = TARGET_SHAPE.test(url.trim()) && !running;

  const go = async () => {
    const u = url.trim();
    if (!TARGET_SHAPE.test(u) || running) return;
    setPending(true);
    try {
      await summarizeLink(u, level, reader.showThinking);
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
            className={`summary-copy ${exported ? "done" : ""}`}
            title="Save the summary as a file (Markdown or PDF)"
            disabled={!summary || !!saving}
            onClick={() => setMenu((m) => !m)}
            aria-haspopup="menu"
            aria-expanded={menu}
          >
            <Icon name="download" />
            {saving ? "Exporting…" : exported ? exported : "Export"}
          </button>
          {menu && (
            <div className="summary-export-menu" role="menu" onMouseLeave={() => setMenu(false)}>
              <button role="menuitem" onClick={() => void doExport("markdown")}>Markdown (.md)</button>
              <button role="menuitem" onClick={() => void doExport("pdf")}>PDF</button>
            </div>
          )}
          <button
            className={`summary-copy ${copied ? "done" : ""}`}
            title="Copy the whole summary (Markdown)"
            disabled={!summary}
            onClick={async () => {
              try {
                await copyText(summary);
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
            disabled={!summary && !voicePlaying}
            onClick={() => speak(summary)}
          >
            {voicePlaying ? "■ Stop" : <><Icon name="read" />Read</>}
          </button>
          {pageTextRef.current.trim().length > 0 && (
            <button
              className="summary-copy summary-speak"
              title={voicePlaying ? "Stop the built-in voice" : "Read the whole page through the built-in voice"}
              disabled={voicePlaying}
              onClick={() => speak(pageTextRef.current.trim())}
            >
              {voicePlaying ? "■ Stop" : <><Icon name="read" />Read page</>}
            </button>
          )}
        </div>
      </header>

      <details className="summary-source" open={!html}>
        <summary hidden={!html}><Icon name="link" /> Summarize another link or file <span>+</span></summary>
        <form
          className="summary-bar"
          onSubmit={(e) => {
            e.preventDefault();
            void go();
          }}
        >
          <label className="summary-label" htmlFor="summary-url">Start with a link or a file</label>
          <div className="summary-url-field">
            <Icon name="link" />
            <input
              id="summary-url"
              className="summary-url"
              type="text"
              placeholder="Paste an article URL or a file path (~/notes.md)…"
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
        <label className="summary-thinking-switch" title="Show received thinking and request it for the next summary">
          <input
            type="checkbox"
            role="switch"
            checked={reader.showThinking}
            onChange={(e) => setReader((r) => ({ ...r, showThinking: e.target.checked }))}
          />
          <span className="switch-track" aria-hidden="true"><span className="switch-thumb" /></span>
          <span>Show thinking</span>
        </label>
        <div className="summary-font-size" role="group" aria-label="Font size">
          <button aria-label="Decrease font size" disabled={reader.size <= 14} onClick={() => setReader((r) => ({ ...r, size: Math.max(14, r.size - 1) }))}>A<span>−</span></button>
          <output aria-live="polite" aria-label="Current font size">{reader.size}px</output>
          <button aria-label="Increase font size" disabled={reader.size >= 24} onClick={() => setReader((r) => ({ ...r, size: Math.min(24, r.size + 1) }))}>A<span>+</span></button>
        </div>
      </div>
      <main className="summary-body" ref={bodyRef}>
        {state.state === "error" && (
          <div className="summary-error" role="alert">
            <span className="summary-eyebrow">Let's try again</span>
            <h2>We couldn't read this link.</h2>
            <p className="summary-error-title">{state.message || "Check the URL and try summarizing again."}</p>
            {state.title ? <p className="hint">{state.title}</p> : null}
          </div>
        )}
        {running && state.state !== "error" && (
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
        {reader.showThinking && (
          <section className="summary-thinking" aria-label="Model thinking">
            <h2>Thinking</h2>
            {thinkingHtml ? (
              <div className="md" onClick={openLink} dangerouslySetInnerHTML={{ __html: thinkingHtml }} />
            ) : (
              <p className="summary-thinking-empty" role="status">
                {!state.state || (pending && state.state === "ready")
                  ? "Thinking will be requested when you summarize."
                  : !state.thinking_requested
                    ? "Thinking wasn't requested for this summary. Summarize again with Show thinking on to request it."
                    : state.state === "ready" || state.state === "error"
                      ? "This response didn't include thinking, even though it was requested."
                      : "Waiting for the model's thinking…"}
              </p>
            )}
          </section>
        )}
        {html ? (
          <div className="summary-paper">
            <div className="summary-paper-meta">
              <span className="summary-eyebrow">The essentials</span>
              <span>{running ? "Writing…" : "Ready to read"}</span>
            </div>
            {state.title && <h2 className="summary-document-title">{state.title}</h2>}
            <article className="md" onClick={openLink} dangerouslySetInnerHTML={{ __html: html }} />
          </div>
        ) : running || state.state === "error" ? null : (
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
      </main>
      <footer className="summary-footer">
        <span><span className={`summary-status-dot ${running ? "busy" : ""}`} />{running ? "Making sense of your source" : summary ? "Your reading, distilled" : "A fresh perspective starts here"}</span>
        <span>{running ? "Esc to stop" : "Made with GhostPen"}</span>
      </footer>
    </div>
  );
}
