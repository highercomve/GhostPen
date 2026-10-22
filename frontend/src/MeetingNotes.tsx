import { useCallback, useEffect, useRef, useState } from "react";
import { meetingsSaveNotes } from "./api";
import { renderMarkdown } from "./markdown";
import { renderDiagrams } from "./diagrams";

// Keep writes ordered even when a meeting is closed and reopened mid-save.
const pendingSaves = new Map<string, Promise<void>>();

/** Chat must include edits made just before leaving the Notes tab. */
export async function flushMeetingNotes(id: string, folder: string) {
  const cacheKey = `ghostpen:meeting-notes:${folder}`;
  const pending = (pendingSaves.get(cacheKey) ?? Promise.resolve()).then(async () => {
    let text: string | null = null;
    try { text = localStorage.getItem(cacheKey); } catch { /* Wait for the regular save above. */ }
    if (text === null) return;
    await meetingsSaveNotes(id, text);
    try { if (localStorage.getItem(cacheKey) === text) localStorage.removeItem(cacheKey); } catch { /* Saved on disk. */ }
  });
  const barrier = pending.catch(() => {});
  pendingSaves.set(cacheKey, barrier);
  void barrier.then(() => { if (pendingSaves.get(cacheKey) === barrier) pendingSaves.delete(cacheKey); });
  await pending;
}

/** Keep a local draft until the atomic notes.md write succeeds. */
export default function MeetingNotes({ id, folder, initial, hidden }: { id: string; folder: string; initial: string; hidden: boolean }) {
  const cacheKey = `ghostpen:meeting-notes:${folder}`;
  const [text, setText] = useState(() => {
    try { return localStorage.getItem(cacheKey) ?? initial; } catch { return initial; }
  });
  const [saved, setSaved] = useState(initial);
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState("");
  const [preview, setPreview] = useState(false);
  const draft = useRef(text);
  const persisted = useRef(initial);
  const mounted = useRef(false);

  const save = useCallback(() => {
    const target = draft.current;
    // Serialize writes: a slow earlier save must never overwrite a later edit.
    const pending = (pendingSaves.get(cacheKey) ?? Promise.resolve()).then(async () => {
      if (persisted.current === target) return;
      if (mounted.current) { setSaving(true); setError(""); }
      try {
        await meetingsSaveNotes(id, target);
        persisted.current = target;
        if (draft.current === target) {
          try {
            if (localStorage.getItem(cacheKey) === target) localStorage.removeItem(cacheKey);
          } catch { /* The disk copy is saved. */ }
        }
        if (mounted.current) setSaved(target);
      } catch (e) {
        if (mounted.current) setError(String(e));
      } finally {
        if (mounted.current) setSaving(false);
      }
    });
    pendingSaves.set(cacheKey, pending);
    void pending.then(() => { if (pendingSaves.get(cacheKey) === pending) pendingSaves.delete(cacheKey); });
    return pending;
  }, [id, cacheKey]);

  useEffect(() => {
    mounted.current = true;
    return () => { mounted.current = false; void save(); };
  }, [save]);

  useEffect(() => {
    if (text === saved) return;
    const timer = window.setTimeout(save, 700);
    return () => window.clearTimeout(timer);
  }, [text, saved, save]);

  useEffect(() => {
    if (preview) void renderDiagrams(document.querySelector(".mt-main"));
  }, [preview, text, saved]);

  return (
    <section className="mt-personal-notes" hidden={hidden} aria-label="Meeting notes">
      <div className="mt-notes-heading">
        <h3>Notes</h3>
        <div className="mt-notes-actions">
          <span role="status">{error ? "Not saved" : saving ? "Saving…" : text !== saved ? "Unsaved changes" : "Saved"}</span>
          <button className="mt-btn" aria-pressed={preview} onClick={() => setPreview(!preview)}>{preview ? "Edit notes" : "Preview"}</button>
          <button className="mt-btn" disabled={saving || text === saved} onClick={() => void save()}>Save notes</button>
        </div>
      </div>
      {error && <div className="mt-error" role="alert">{error} Your draft is kept here. Use Save notes to retry.</div>}
      {preview ? (
        <article className="mt-summary-body mt-notes-preview" dangerouslySetInnerHTML={{ __html: renderMarkdown(text || "*Your notes will appear here.*") }} />
      ) : (
        <textarea className="mt-notes-editor" aria-label="Your meeting notes" value={text}
          placeholder={"What matters to you?\n\n- Ideas to explore\n- Decisions to remember\n- Next steps"}
          onChange={(e) => {
            const next = e.target.value;
            draft.current = next;
            setText(next);
            try { localStorage.setItem(cacheKey, next); } catch { /* Autosave still writes to disk. */ }
          }}
          onBlur={() => void save()}
          onKeyDown={(e) => {
            if ((e.ctrlKey || e.metaKey) && e.key.toLowerCase() === "s") { e.preventDefault(); void save(); }
          }} />
      )}
    </section>
  );
}
