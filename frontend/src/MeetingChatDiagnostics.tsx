import { useEffect, useState } from "react";
import type { MeetingChatProgress, MeetingChatStats } from "./api";

const duration = (ms: number | null | undefined) => ms == null ? "Not reported" : ms < 1000 ? `${Math.round(ms)} ms` : `${(ms / 1000).toFixed(1)} s`;
const count = (n: number | null | undefined) => n == null ? "Not reported" : n.toLocaleString();
const speed = (tokens: number | null | undefined, ms: number | null | undefined) => tokens == null || ms == null || ms <= 0 ? "Not reported" : `${(tokens * 1000 / ms).toFixed(1)} tok/s`;

export function StatsForNerds({ stats }: { stats?: MeetingChatStats | null }) {
  return <details className="mt-chat-stats">
    <summary>Stats for nerds</summary>
    {stats ? <dl>
      <dt>Total time</dt><dd>{duration(stats.elapsedMs)}</dd>
      <dt>Queue</dt><dd>{duration(stats.queueMs)}</dd>
      <dt>Loading conversation</dt><dd>{duration(stats.conversationMs)}</dd>
      <dt>Loading model</dt><dd>{duration(stats.loadMs)}</dd>
      <dt>Time to first answer token</dt><dd>{duration(stats.firstTokenMs)}</dd>
      <dt>Prefill time</dt><dd>{duration(stats.prefillMs)}</dd>
      <dt>Prefill speed</dt><dd>{speed(stats.evaluatedTokens, stats.prefillMs)}</dd>
      <dt>Input tokens</dt><dd>{count(stats.promptTokens)}</dd>
      <dt>Tokens evaluated</dt><dd>{count(stats.evaluatedTokens)}</dd>
      <dt>Cached tokens reused</dt><dd>{count(stats.cachedTokens)}</dd>
      <dt>Generation time</dt><dd>{duration(stats.generationMs)}</dd>
      <dt>Output tokens</dt><dd>{count(stats.generatedTokens)}</dd>
      <dt>Generation speed</dt><dd>{speed(stats.generatedTokens, stats.generationMs)}</dd>
      <dt>Model calls</dt><dd>{count(stats.requests)}</dd>
      <dt>Context window</dt><dd>{stats.contextTokens ? count(stats.contextTokens) : "Not reported"}</dd>
      <dt>Model</dt><dd>{stats.model || "Not reported"}</dd>
      <dt>Backend / device</dt><dd>{stats.backend || "Not reported"}</dd>
    </dl> : <p>No statistics were recorded for this answer.</p>}
  </details>;
}

const LABEL = {
  loading_conversation: "Loading conversation",
  waiting: "Waiting for the model",
  loading_model: "Loading model",
  prefilling: "Prefilling context",
  generating: "Generating answer",
  complete: "Answer complete",
};

export function MeetingChatProgressView({ progress, writing }: { progress: MeetingChatProgress | null; writing: boolean }) {
  const [elapsed, setElapsed] = useState(0);
  useEffect(() => {
    const received = Date.now();
    const base = progress?.stats.elapsedMs ?? 0;
    const tick = () => setElapsed(base + Date.now() - received);
    tick();
    const timer = window.setInterval(tick, 500);
    return () => window.clearInterval(timer);
  }, [progress]);
  const stage = progress?.stage;
  const stats = progress?.stats;
  const processed = progress?.prefilledTokens;
  const total = progress?.prefillTotalTokens;
  return <div className="mt-chat-progress">
    <div className="mt-chat-progress-title"><span role="status">{stage ? LABEL[stage] : writing ? "Generating answer" : "Queued"}</span><span>{duration(elapsed)}</span></div>
    <progress aria-label="Answer progress" {...(stage === "prefilling" && processed != null && total ? { value: processed, max: total } : {})} />
    <div className="mt-chat-progress-meta">
      {stage === "prefilling" && total != null && <span>{count(processed ?? 0)} / {count(total)} tokens</span>}
      {stage === "prefilling" && <span>{speed(stats?.evaluatedTokens, stats?.prefillMs)}</span>}
      {stage === "generating" && stats?.generatedTokens != null && <span>{count(stats.generatedTokens)} tokens · {speed(stats.generatedTokens, stats.generationMs)}</span>}
      {progress && progress.parts > 1 && <span>Context pass {progress.part} / {progress.parts}</span>}
      {stats?.model && <span className="mt-chat-progress-model">{stats.model}</span>}
    </div>
    {stats && <StatsForNerds stats={{ ...stats, elapsedMs: elapsed }} />}
  </div>;
}
