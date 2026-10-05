import { useEffect, useRef, useState } from "react";
import { Icon } from "./icons";
import { cancelAi, clipboardText, copyText, summarizeLink, summaryState } from "./api";
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

export default function Summary() {
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

  // The events, and the pickup for what the page missed while it loaded
  // (listeners attach after the first status was broadcast).
  useEffect(() => {
    const ups: Promise<unknown>[] = [];
    ups.push(
      listen<SummaryState>("ghostpen://summary-status", (e) => {
        stateRef.current = e.payload;
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
    summaryState()
      .then((s) => {
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
    <div className="summary">
      <header className="summary-head">
        <span className="summary-brand">
          <Icon name="link" className="summary-brand-icon" />
          Summary
        </span>
        <button
          className={`icon-btn ${copied ? "done" : ""}`}
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
      </header>

      <form
        className="summary-bar"
        onSubmit={(e) => {
          e.preventDefault();
          void go();
        }}
      >
        <input
          className="summary-url"
          type="url"
          placeholder="https://…"
          value={url}
          disabled={running}
          spellCheck={false}
          onChange={(e) => setUrl(e.target.value)}
        />
        <div className="seg summary-level" role="group" aria-label="Summary depth">
          {LEVELS.map(([id, label]) => (
            <button
              key={id}
              type="button"
              className={`seg-btn ${level === id ? "active" : ""}`}
              disabled={running}
              onClick={() => setLevel(id)}
            >
              {label}
            </button>
          ))}
        </div>
        <button className="summary-go" type="submit" disabled={!canGo}>
          {running ? <span className="spinner summary-go-spinner" /> : <Icon name="send" className="summary-go-icon" />}
          Summarize
        </button>
      </form>

      <main className="summary-body" ref={bodyRef}>
        {state.state === "error" ? (
          <div className="summary-error">
            <p className="summary-error-title">{state.message || "The summary failed."}</p>
            {state.title ? <p className="hint">{state.title}</p> : null}
          </div>
        ) : (
          <>
            {running && (
              <div className="summary-status">
                <div className="spinner" />
                <div className="summary-status-text">
                  <span className="summary-stage">{STAGE[state.state] || "Working…"}</span>
                  {state.title ? <span className="summary-title">{state.title}</span> : null}
                  {state.chars > 0 && (state.state === "reading" || state.state === "writing") ? (
                    <span className="summary-chars">{state.chars.toLocaleString()} characters read</span>
                  ) : null}
                </div>
              </div>
            )}
            {html ? (
              <article className="md" dangerouslySetInnerHTML={{ __html: html }} />
            ) : running ? null : (
              <p className="hint summary-empty">Paste a link above and hit Summarize: GhostPen reads the page and writes the summary here.</p>
            )}
          </>
        )}
      </main>
    </div>
  );
}
