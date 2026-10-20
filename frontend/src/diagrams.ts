// Mermaid diagrams inside rendered Markdown (the ```mermaid fences):
// markdown.ts leaves their readable source as a `<pre class="mermaid">` and
// this turns those nodes into SVGs. The diagram renderer loads once, on the
// first diagram, and failures (an unknown shape, a mid-typing document)
// keep the readable source where the diagram would be.

type Mermaid = typeof import("mermaid").default;

let loader: Promise<Mermaid> | null = null;
let diagramId = 0;

/** Mermaid inserts an error SVG into its rendering container on failure.
 * Keep that work offscreen and remove it on every exit path. */
async function drawing(mermaid: Mermaid, source: string) {
  const stage = document.createElement("div");
  stage.style.cssText = "position:absolute;left:-100000px;top:0;visibility:hidden;pointer-events:none";
  document.body.append(stage);
  try {
    return await mermaid.render(`gp-diagram-${++diagramId}`, source, stage);
  } finally {
    stage.remove();
  }
}

const library = () => {
  loader ??= import("mermaid")
    .then((m) => {
      m.default.initialize({
        startOnLoad: false,
        securityLevel: "strict",
        theme: window.matchMedia("(prefers-color-scheme: light)").matches ? "neutral" : "dark",
      });
      return m.default;
    })
    .catch((err) => {
      loader = null;
      throw err;
    });
  return loader;
};

/** Render every not-yet-rendered diagram under `root`. Safe to call again
 * after the next chunk of HTML renders: only fresh nodes are touched. */
export async function renderDiagrams(root: Element | null | undefined): Promise<void> {
  if (!root) return;
  const nodes = Array.from(root.querySelectorAll<HTMLElement>("pre.mermaid")).filter((n) => !("diagram" in n.dataset));
  if (!nodes.length) return;
  for (const node of nodes) node.dataset.diagram = "pending";
  try {
    const mermaid = await library();
    for (const node of nodes) {
      const source = node.textContent ?? "";
      try {
        const { svg, bindFunctions } = await drawing(mermaid, source);
        node.innerHTML = svg;
        bindFunctions?.(node);
        node.dataset.diagram = "done";
      } catch {
        node.textContent = source;
        node.dataset.diagram = "failed";
      }
    }
  } catch {
    for (const node of nodes) delete node.dataset.diagram;
  }
}

// ---- the PDF export's diagrams ----------------------------------------------------------

export interface ExportDiagram {
  /** The fence's source (its key in the export call). */
  key: string;
  /** A JPEG (base64, no data-url prefix) the PDF goes on a white page with. */
  jpeg: string;
  /** The JPEG's sample size (twice the drawing's CSS pixel size). */
  width: number;
  height: number;
}

/** The ```mermaid fences of `markdown` as JPEG images for the PDF: each one
 * renders fresh in the neutral (light) palette — the page is white — and
 * rasterizes onto a white canvas. A diagram that refuses (bad shape,
 * rasterization off) just keeps its code block in the PDF. */
export async function exportDiagrams(markdown: string): Promise<ExportDiagram[]> {
  const sources: string[] = [];
  const seen = new Set<string>();
  // Use the Markdown reader's fence rules, including CRLF and tilde fences.
  let fence: string[] | null = null;
  let isMermaid = false;
  const collect = () => {
    const source = fence?.join("\n").trim() ?? "";
    if (isMermaid && source && !seen.has(source)) {
      seen.add(source);
      sources.push(source);
    }
  };
  for (const line of markdown.replace(/\r\n?/g, "\n").split("\n")) {
    if (/^\s*(```|~~~)/.test(line)) {
      if (fence !== null) {
        collect();
        fence = null;
      } else {
        isMermaid = (/^\s*(?:```|~~~)\s*([A-Za-z0-9_-]*)/.exec(line)?.[1] ?? "").toLowerCase() === "mermaid";
        fence = [];
      }
    } else if (fence !== null) fence.push(line);
  }
  if (fence !== null) collect();
  if (!sources.length) return [];
  let mermaid: Mermaid;
  try {
    mermaid = await library();
  } catch {
    return [];
  }
  const stages: ExportDiagram[] = [];
  for (let i = 0; i < sources.length; i++) {
    // A neutral palette for a white page, no HTML labels: every box draws
    // as SVG shapes and text, which rasterizes cleanly.
    const source = "%%{init: {'theme':'neutral','darkMode':false,\"htmlLabels\":false}}%%\n" + sources[i];
    try {
      const { svg } = await drawing(mermaid, source);
      stages.push(await rasterize(sources[i], svg));
    } catch {
      /* that fence keeps its code block */
    }
  }
  return stages;
}

/** An SVG document as a JPEG on a white canvas, twice the CSS size. */
async function rasterize(key: string, svg: string): Promise<ExportDiagram> {
  const holder = document.createElement("div");
  holder.style.position = "absolute";
  holder.style.opacity = "0";
  holder.style.pointerEvents = "none";
  const doc = new DOMParser().parseFromString(svg, "image/svg+xml");
  if (doc.querySelector("parsererror")) throw new Error("bad svg");
  const el = doc.documentElement;
  const svgEl = el as unknown as SVGSVGElement;
  document.body.append(holder);
  holder.append(el);
  try {
    const vb = svgEl.viewBox?.baseVal;
    const box = el.getBoundingClientRect();
    const width = Math.ceil(vb?.width || box.width) || 800;
    const height = Math.ceil(vb?.height || box.height) || 600;
    if (width <= 0 || height <= 0 || width * 2 > 16384 || height * 2 > 16384 || width * height * 4 > 32 * 1024 * 1024) {
      throw new Error("diagram exceeds canvas limits");
    }
    // The SVG-in-<img> bitmap only exists at the root's declared size: an
    // unchecked mermaid root (width="100%", no height — its useMaxWidth
    // trick) draws at the default 300x150 and the diagram crops away. The
    // declaration becomes explicit pixels, and the max-width goes.
    el.setAttribute("width", String(width));
    el.setAttribute("height", String(height));
    el.style.maxWidth = "none";
    el.style.overflow = "visible";
    const scale = 2;
    const canvas = document.createElement("canvas");
    canvas.width = width * scale;
    canvas.height = height * scale;
    const ctx = canvas.getContext("2d");
    if (!ctx) throw new Error("no canvas");
    ctx.fillStyle = "#ffffff";
    ctx.fillRect(0, 0, canvas.width, canvas.height);
    const src = "data:image/svg+xml;charset=utf-8," + encodeURIComponent(new XMLSerializer().serializeToString(el));
    const img = new Image(width, height);
    const ready = new Promise<void>((resolve, reject) => {
      img.onload = () => resolve();
      img.onerror = () => reject(new Error("svg did not rasterize"));
      img.src = src;
    });
    await ready;
    ctx.drawImage(img, 0, 0, canvas.width, canvas.height);
    const url = canvas.toDataURL("image/jpeg", 0.94);
    const prefix = "data:image/jpeg;base64,";
    if (!url.startsWith(prefix)) throw new Error("no jpeg");
    // The XObject's /Width /Height must be the JPEG's own sample size (the
    // canvas at 2x), or the PDF renders a slice of it.
    return { key, jpeg: url.slice(prefix.length), width: canvas.width, height: canvas.height };
  } finally {
    holder.remove();
  }
}
