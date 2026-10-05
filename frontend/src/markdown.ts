// A small, safe Markdown renderer for the summaries: HTML-escape the text
// first, then turn back into tags only the subset the summaries use —
// headings, paragraphs, nested ordered/unordered lists, block quotes,
// fenced code, horizontal rules, links, bold, italic and strikethrough.
// Inline code spans are pulled out before the other inline passes so the
// markup inside them can never interact.

export function renderMarkdown(src: string): string {
  const lines = src.replace(/\r\n?/g, "\n").split("\n");
  const out: string[] = [];

  let para: string[] = [];
  let fence: string[] | null = null;
  let quote: string[] = [];
  // The open list tags, outermost first ("ul"/"ol"), and the last item's
  // nesting depth (-1: none open) — a sibling continues its list, a deeper
  // item opens one inside, a shallower one closes down.
  const lists: ("ul" | "ol")[] = [];
  let last_level = -1;

  const closePara = () => {
    if (para.length) {
      out.push(`<p>${inline(para.join(" "))}</p>`);
      para = [];
    }
  };
  const closeQuote = () => {
    if (quote.length) {
      out.push(`<blockquote><p>${inline(quote.join(" "))}</p></blockquote>`);
      quote = [];
    }
  };
  const closeLists = () => {
    while (lists.length) out.push(`</${lists.pop()}>`);
    last_level = -1;
  };
  const closeAll = () => {
    closePara();
    closeQuote();
    closeLists();
  };

  for (const raw of lines) {
    // Fenced code: on until the next fence (all or nothing).
    if (fence !== null) {
      if (/^\s*(```|~~~)/.test(raw)) {
        out.push(`<pre><code>${escape(fence.join("\n"))}</code></pre>`);
        fence = null;
      } else {
        fence.push(raw);
      }
      continue;
    }
    if (/^\s*(```|~~~)/.test(raw)) {
      closeAll();
      fence = [];
      continue;
    }

    // Blank line: everything inline ends.
    if (raw.trim() === "") {
      closeAll();
      continue;
    }

    // Heading: 1-6 `#`s.
    const heading = /^(#{1,6})\s+(.*)$/.exec(raw);
    if (heading) {
      closeAll();
      out.push(`<h${heading[1].length}>${inline(heading[2])}</h${heading[1].length}>`);
      continue;
    }

    // Horizontal rule.
    if (/^\s*---+\s*$/.test(raw) || /^\s*\*\*\*+\s*$/.test(raw)) {
      closeAll();
      out.push("<hr/>");
      continue;
    }

    // Block quote: collect its lines, one block per run.
    if (/^\s*>/.test(raw)) {
      closePara();
      closeLists();
      quote.push(raw.replace(/^\s*>\s?/, ""));
      continue;
    }

    // List item: its indent (2+ spaces nest, one level) and the marker set
    // the kind.
    const item = /^(\s*)([-*+]|\d+[.)])\s+(.*)$/.exec(raw);
    if (item) {
      closePara();
      closeQuote();
      const level = Math.min(item[1].length >= 2 && lists.length >= 1 ? 1 : 0, 1);
      const kind: "ul" | "ol" = /\d/.test(item[2]) ? "ol" : "ul";
      // A sibling or shallower item: close down to its level, switching
      // the marker kind when it changed at this depth. A deeper one just
      // opens a list inside the open one.
      if (level <= last_level) {
        while (lists.length > level + 1) out.push(`</${lists.pop()}>`);
        if (lists.length === level + 1 && lists[lists.length - 1] !== kind) {
          out.push(`</${lists.pop()}>`);
        }
      }
      while (lists.length < level + 1) {
        lists.push(kind);
        out.push(`<${kind}>`);
      }
      last_level = level;
      out.push(`<li>${inline(item[3])}</li>`);
      continue;
    }

    // Everything else: paragraph text.
    closeQuote();
    closeLists();
    para.push(raw.trim());
  }
  if (fence !== null) out.push(`<pre><code>${escape(fence.join("\n"))}</code></pre>`);
  closeAll();
  return out.join("\n");
}

// One spaced dash or bullet, bold/italic pairs, slashes and underscores
// after escape; code spans are stored and put back last.
function inline(text: string): string {
  let s = escape(text);
  const codes: string[] = [];
  s = s.replace(/`([^`]+)`/g, (_m, code: string) => {
    codes.push(`<code>${code}</code>`);
    return `\u0000${codes.length - 1}\u0000`;
  });
  s = s
    .replace(/\[([^\]]+)\]\(([^)\s]+)\)/g, '<a href="$2" target="_blank" rel="noreferrer">$1</a>')
    .replace(/\*\*([^*]+)\*\*/g, "<strong>$1</strong>")
    .replace(/(^|\s)\*([^*\s][^*]*)\*/g, "$1<em>$2</em>")
    .replace(/(^|\s)_([^_\s][^_]*)_([^_\s]|$)/g, "$1<em>$2</em>$3")
    .replace(/~~([^~]+)~~/g, "<del>$1</del>");
  s = s.replace(/\u0000(\d+)\u0000/g, (_m, n: string) => codes[Number(n)]);
  return s;
}

const ESCAPES: Record<string, string> = {
  "&": "&amp;",
  "<": "&lt;",
  ">": "&gt;",
  '"': "&quot;",
  "'": "&#39;",
};

function escape(text: string): string {
  return text.replace(/[&<>"']/g, (c) => ESCAPES[c]);
}
