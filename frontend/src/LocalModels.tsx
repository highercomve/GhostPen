import { useEffect, useState } from "react";
import { listen } from "./events";
import {
  LlmStatus,
  LlmProgress,
  LocalLlmSettings,
  llmModelsStatus,
  llmDownloadModel,
  llmCancelDownload,
  llmDeleteModel,
  llmUnload,
  formatBytes,
  systemInfo,
} from "./api";

/** Sampling defaults for other apps (Qwen's for agents; src/settings.zig's `LocalLlm`). */
export const DEFAULT_SAMPLING = {
  temperature: 0.6, topP: 0.95, topK: 20, minP: 0, presencePenalty: 1.0, frequencyPenalty: 0, repeatPenalty: 1.0,
};

export const DEFAULT_LOCAL: LocalLlmSettings = { ctxTokens: 8192, gpu: true, moePct: 0, idleMinutes: 10, ...DEFAULT_SAMPLING };

type SamplingKey = keyof typeof DEFAULT_SAMPLING;

/** The sampling controls: label, range, step and what it does. */
const SAMPLING: { key: SamplingKey; label: string; min: number; max: number; step: number; help: string }[] = [
  { key: "temperature", label: "Temperature", min: 0, max: 2, step: 0.05,
    help: "Lower is more predictable. Near 0, thinking models repeat themselves." },
  { key: "topP", label: "Top P", min: 0, max: 1, step: 0.01, help: "Keeps the likeliest tokens up to this share of the probability (1 = off)." },
  { key: "topK", label: "Top K", min: 0, max: 200, step: 1, help: "Keeps this many of the likeliest tokens (0 = all)." },
  { key: "minP", label: "Min P", min: 0, max: 1, step: 0.01, help: "Drops tokens less likely than this share of the likeliest one (0 = off)." },
  { key: "presencePenalty", label: "Presence penalty", min: -2, max: 2, step: 0.1,
    help: "Discourages any token it already wrote; what stops an agent from repeating itself (0 = off)." },
  { key: "frequencyPenalty", label: "Frequency penalty", min: -2, max: 2, step: 0.1, help: "Discourages tokens by how often it wrote them (0 = off)." },
  { key: "repeatPenalty", label: "Repeat penalty", min: 0, max: 2, step: 0.05, help: "llama.cpp's repetition penalty (1 = off)." },
];

export const CONTEXT_SIZES = [2048, 4096, 8192, 16384, 32768, 65536, 131072, 262144];

export const ctxLabel = (n: number) => (n >= 1024 * 1024 ? `${n / (1024 * 1024)}M tokens` : `${n / 1024}k tokens`);

/** The catalog's recommended model (src/models.zig `default_id`). */
export const RECOMMENDED_MODEL = "gemma-4-e4b-it";
const RECOMMENDED_REASON = "Best balance of speed and quality on most computers";

/** A catalog note as one sentence-case phrase: "fastest; fine for proofreading" reads "Fastest, fine for proofreading". */
export function noteText(note: string): string {
  const t = note.trim().replace(/\s*;\s*/g, ", ");
  return t.charAt(0).toUpperCase() + t.slice(1);
}

/** The app a model file was found in, from its path ("" when it isn't recognisable). */
export function sourceApp(path: string): string {
  const p = path.toLowerCase().replace(/\\/g, "/");
  if (p.includes("lmstudio") || p.includes("lm-studio") || p.includes("lm studio")) return "LM Studio";
  if (p.includes("ghostreel")) return "GhostReel";
  if (p.includes("ollama")) return "Ollama";
  if (p.includes("gpt4all")) return "GPT4All";
  if (p.includes("huggingface")) return "the Hugging Face cache";
  if (/\/jan\//.test(p)) return "Jan";
  return "";
}

/** "From LM Studio" for a model found in another app's folder; the folder's name when the app isn't known. */
export function sourceLabel(path: string): string {
  const app = sourceApp(path);
  if (app) return `From ${app}`;
  const parts = path.replace(/\\/g, "/").split("/").filter(Boolean);
  const dir = parts.length > 1 ? parts[parts.length - 2] : "";
  return dir ? `From the folder “${dir}”` : "Found on this computer";
}

/** A model file's name as people say it: "flint-UD-Q4_K_XL" is "Flint" with the quantization "UD-Q4_K_XL". */
export function friendlyModel(raw: string): { name: string; quant: string } {
  const base = raw.replace(/\.gguf$/i, "");
  const m = base.match(/^(.+?)[-_.]((?:UD[-_])?(?:I?Q\d(?:_[A-Z0-9]+)*|PQ\d(?:_\d)?|BF16|F16|F32|MXFP4))$/i);
  const stem = (m ? m[1] : base).replace(/[-_]gguf$/i, "");
  const name = stem.includes(" ") ? stem : stem.replace(/[-_]+/g, " ");
  return { name: name.charAt(0).toUpperCase() + name.slice(1), quant: m ? m[2] : "" };
}

/** A 1-5 score as five small bars. */
export function Meter({ label, value }: { label: string; value: number }) {
  return (
    <span className="meter-item">
      {label}
      <span className="meter" role="img" aria-label={`${label} ${value} of 5`}>
        {[1, 2, 3, 4, 5].map((i) => <i key={i} className={i <= value ? "on" : ""} />)}
      </span>
    </span>
  );
}

/** Why a model of this size may not run here, from the computer's memory ("" when it fits or the memory isn't known). */
export function fitWarning(size: number, memoryMb: number): string {
  if (memoryMb <= 0 || size <= 0) return "";
  const memory = memoryMb * 1048576;
  const gb = `${Math.round(memoryMb / 1024)} GB`;
  if (size > memory * 0.95) return `Bigger than this computer's memory (${gb}): it won't run.`;
  if (size > memory * 0.7) return `Needs most of this computer's memory (${gb}): it may be slow or fail to load.`;
  return "";
}

/**
 * Sizes to offer: the usual steps up to the model's trained maximum, which is
 * always among them even when it isn't a round step; the current value stays
 * listed even when it's above the maximum (the runner caps it).
 */
const contextChoices = (max: number, current: number): number[] => {
  const out = (max > 0 ? CONTEXT_SIZES.filter((n) => n <= max) : [...CONTEXT_SIZES]).slice();
  if (max > 0 && !out.includes(max)) out.push(max);
  if (!out.includes(current)) out.push(current);
  return out.sort((a, b) => a - b);
};

/**
 * Settings → Built-in models: download the catalog models (resumable, verified),
 * pick one for the "Built-in" profile, and tune the runner.
 */
export default function LocalModels(props: {
  local: LocalLlmSettings;
  onLocalChange: (patch: Partial<LocalLlmSettings>) => void;
  /** The model the local profile uses (catalog id or "file:<path>"), if any. */
  activeModel: string | null;
  /** Use this model for the "Built-in" profile (and make it active). */
  onUse: (id: string, name: string) => void;
  /** A model was downloaded or deleted. */
  onChanged?: () => void;
}) {
  const [status, setStatus] = useState<LlmStatus | null>(null);
  const [progress, setProgress] = useState<LlmProgress | null>(null);
  const [message, setMessage] = useState("");
  const [confirmDelete, setConfirmDelete] = useState<string | null>(null);
  const [memoryMb, setMemoryMb] = useState(0);

  const refresh = () =>
    llmModelsStatus()
      .then((st) => {
        setStatus(st);
        props.onChanged?.();
      })
      .catch((e) => setMessage(String(e)));

  useEffect(() => {
    refresh();
    systemInfo().then((i) => setMemoryMb(i.memory_mb)).catch(() => {});
    const un = listen<LlmProgress>("ghostpen://llm-download", (e) => {
      const p = e.payload;
      if (p.state === "done" || p.state === "cancelled" || p.state === "error") {
        setProgress(null);
        if (p.state === "error") setMessage(p.message);
        if (p.state === "cancelled") setMessage("Download paused: resume it any time.");
        refresh();
      } else {
        setProgress(p);
      }
    });
    // Loaded / downloaded state changes while the window is hidden.
    window.addEventListener("focus", refresh);
    return () => {
      window.removeEventListener("focus", refresh);
      un.then((f) => f());
    };
  }, []);

  const download = async (id: string) => {
    setMessage("");
    setProgress({ id, state: "downloading", done: 0, total: 0, message: "" });
    try {
      await llmDownloadModel(id);
    } catch (e) {
      setMessage(String(e));
    } finally {
      setProgress(null);
      refresh();
    }
  };

  const remove = async (id: string) => {
    setConfirmDelete(null);
    try {
      await llmDeleteModel(id);
    } catch (e) {
      setMessage(String(e));
    }
    refresh();
  };

  const local = props.local;
  // The recommended model first, the rest smallest first (the catalog's order).
  const models = [...(status?.status.models ?? [])].sort(
    (a, b) => Number(b.id === RECOMMENDED_MODEL) - Number(a.id === RECOMMENDED_MODEL),
  );
  const others = status?.status.others ?? [];
  const busy = progress !== null || (status?.downloading ?? false);
  const activeCtxMax =
    models.find((m) => m.id === props.activeModel)?.ctx_max ||
    others.find((o) => o.id === props.activeModel)?.ctx_max ||
    0;

  /** The "Use" control: a state when it's the model in use, else a secondary button. */
  const useControl = (id: string, name: string, active: boolean) =>
    active ? (
      <span className="llm-state" title={status?.loaded ? "The model is in memory now" : "Loads when it is first used"}>
        ✓ In use{status?.loaded ? " · Loaded" : ""}
      </span>
    ) : (
      <button className="btn" title="Switch your AI profile to this model now" onClick={() => props.onUse(id, name)}>Use</button>
    );

  return (
    <section className="card">
      <h2>Available models</h2>

      <div className="llm-list">
        {models.map((m) => {
          const installed = m.path !== "";
          const active = props.activeModel === m.id;
          const p = progress && progress.id === m.id ? progress : null;
          const pct = p && p.total > 0 ? Math.min(100, (p.done / p.total) * 100) : 0;
          const recommended = m.id === RECOMMENDED_MODEL;
          return (
            <div key={m.id} className={`llm-row ${active ? "active" : ""}`}>
              <div className="llm-info">
                <div>
                  <b>{m.name}</b> <span className="muted small">{formatBytes(m.size)}</span>
                  {recommended && <span className="llm-badge recommended">Recommended</span>}
                  {m.vision && <span className="llm-badge vision" title="Can also read text from screenshots (Extract text)">Reads images</span>}
                </div>
                <span className="llm-meta muted small">
                  <Meter label="Speed" value={m.speed} />
                  <Meter label="Quality" value={m.quality} />
                  <span>{recommended ? RECOMMENDED_REASON : noteText(m.note.replace(/^recommended;\s*/i, ""))}</span>
                </span>
                {fitWarning(m.size, memoryMb) && <span className="llm-warn small">{fitWarning(m.size, memoryMb)}</span>}
                {installed && m.vision_available && !m.vision && !p && (
                  <span className="muted small">
                    Its image projector ({formatBytes(m.projector_size)}) isn't downloaded: without it, Extract text can't use this model.
                  </span>
                )}
                {installed && m.external && (
                  <span className="muted small" title={m.path}>{sourceLabel(m.path)}, reused</span>
                )}
                {p && (
                  <div className="llm-progress">
                    <div className="llm-bar"><div style={{ width: `${pct}%` }} /></div>
                    <span className="muted small">
                      {p.state === "verifying"
                        ? p.message || "Checking…"
                        : `${formatBytes(p.done)} of ${formatBytes(p.total || m.size)}`}
                    </span>
                  </div>
                )}
              </div>
              <div className="llm-actions">
                {p ? (
                  <button className="btn" onClick={() => llmCancelDownload()}>Pause</button>
                ) : installed ? (
                  <>
                    {useControl(m.id, m.name, active)}
                    {m.vision_available && !m.vision && (
                      <button className="btn" disabled={busy} onClick={() => download(m.id)}>Add image support</button>
                    )}
                    {!m.external &&
                      (confirmDelete === m.id ? (
                        <>
                          <button className="btn" onClick={() => setConfirmDelete(null)}>Keep</button>
                          <button className="btn danger solid llm-delete" title={active ? "Your AI profile uses this model" : undefined} onClick={() => remove(m.id)}>
                            {active ? `Delete ${formatBytes(m.size)} (in use)?` : `Delete ${formatBytes(m.size)}?`}
                          </button>
                        </>
                      ) : (
                        <button className="btn danger llm-delete" onClick={() => setConfirmDelete(m.id)}>Delete…</button>
                      ))}
                  </>
                ) : m.partial > 0 ? (
                  <>
                    <button className="btn download" disabled={busy} onClick={() => download(m.id)}>
                      Resume ({Math.round((m.partial / m.size) * 100)}%)
                    </button>
                    <button className="btn danger llm-delete" disabled={busy} onClick={() => remove(m.id)}>Clear</button>
                  </>
                ) : (
                  <button className="btn download" disabled={busy} onClick={() => download(m.id)}>Download</button>
                )}
              </div>
            </div>
          );
        })}
      </div>

      {others.length > 0 && (
        <details className="settings-advanced" open={others.some((o) => o.id === props.activeModel)}>
          <summary>
            <span>Models from other apps ({others.length})</span>
            <small>{[...new Set(others.map((o) => sourceApp(o.path)).filter(Boolean))].join(", ") || "found on this computer"}</small>
          </summary>
          <div className="settings-advanced-body">
            <div className="llm-list">
              {others.map((o) => {
                const active = props.activeModel === o.id;
                const { name, quant } = friendlyModel(o.name);
                const warning = fitWarning(o.size, memoryMb);
                return (
                  <div key={o.id} className={`llm-row ${active ? "active" : ""}`} title={o.path}>
                    <div className="llm-info">
                      <div>
                        <b>{name}</b> <span className="muted small">{formatBytes(o.size)}</span>
                        {o.vision && <span className="llm-badge vision">Reads images</span>}
                      </div>
                      <span className="muted small">{sourceLabel(o.path)}{quant && ` · ${quant}`}</span>
                      {warning && <span className="llm-warn small">{warning}</span>}
                    </div>
                    <div className="llm-actions">{useControl(o.id, o.name, active)}</div>
                  </div>
                );
              })}
            </div>
          </div>
        </details>
      )}

      {message && <p className="muted small llm-message">{message}</p>}

      <h3>Runner</h3>
      <label className="checkbox">
        <input type="checkbox" checked={local.gpu} onChange={(e) => props.onLocalChange({ gpu: e.target.checked })} />
        <span>Use the GPU<span className="checkbox-help">Puts as much of the model on the GPU as its free memory holds. Off means CPU only.</span></span>
      </label>
      <label>
        Unload after {local.idleMinutes === 0 ? "never" : `${local.idleMinutes} min`} idle
        <input type="range" min={0} max={60} step={5} value={local.idleMinutes}
          onChange={(e) => props.onLocalChange({ idleMinutes: parseInt(e.target.value, 10) })} />
      </label>

      <details className="settings-advanced">
        <summary><span>Advanced: memory and context</span></summary>
        <div className="settings-advanced-body">
          <label>
            Context window
            <select value={local.ctxTokens} onChange={(e) => props.onLocalChange({ ctxTokens: parseInt(e.target.value, 10) })}>
              {contextChoices(activeCtxMax, local.ctxTokens).map((n) => (
                <option key={n} value={n}>
                  {`${ctxLabel(n)}${n === 8192 ? " (recommended)" : ""}${n === activeCtxMax ? " — this model's maximum" : ""}`}
                </option>
              ))}
            </select>
            <span className="muted small">
              Room for the text and the answer. Larger uses more memory.
              {activeCtxMax > 0
                ? ` The model in use allows up to ${ctxLabel(activeCtxMax)}.`
                : " With a model selected, its maximum appears here."}
              {" "}Other apps use this too, unless you set their own under Connections.
            </span>
          </label>
          <label>
            Keep part of the model in system RAM:{" "}
            {local.moePct === 0 ? "none" : local.moePct === 100 ? "all" : `${local.moePct}%`}
            <input
              type="range"
              min={0}
              max={100}
              step={5}
              value={local.moePct}
              onChange={(e) => props.onLocalChange({ moePct: parseInt(e.target.value, 10) })}
            />
            <span className="muted small">
              Lets a model bigger than your GPU's memory still run, a little slower. It only
              applies to mixture-of-experts models (Qwen3.5 and similar) and needs the GPU on.
              Try 50%, then lower it while the model still fits.
            </span>
          </label>
        </div>
      </details>

      <details className="settings-advanced">
        <summary><span>Advanced: sampling for other apps</span></summary>
        <div className="settings-advanced-body">
          <p className="muted small">
            How requests from other apps and agents (pi, Codex, GhostReel, …) to the model service sample, unless a
            request sets its own. The defaults are Qwen's recommendation for agents. GhostPen's own actions use their
            profile's temperature.
          </p>
          <div className="sampling-grid">
            {SAMPLING.map((c) => (
              <label key={c.key}>
                {c.label}: {local[c.key]}
                <input type="range" min={c.min} max={c.max} step={c.step} value={local[c.key]}
                  onChange={(e) => props.onLocalChange({ [c.key]: parseFloat(e.target.value) })} />
                <span className="muted small">{c.help}</span>
              </label>
            ))}
          </div>
          <div className="row">
            <button className="btn" type="button" onClick={() => props.onLocalChange({ ...DEFAULT_SAMPLING })}>
              Reset sampling to defaults
            </button>
          </div>
        </div>
      </details>

      <div className="row llm-footer">
        <span className="muted small">
          {status?.loaded ? "Loaded in memory." : "Loads on first use."} Models folder: <code>{status?.status.dir}</code>
        </span>
        {status?.loaded && (
          <button className="btn" onClick={() => llmUnload().then(refresh)}>Unload now</button>
        )}
      </div>
    </section>
  );
}
