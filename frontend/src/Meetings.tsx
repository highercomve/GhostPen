import { Fragment, useCallback, useEffect, useMemo, useRef, useState, type KeyboardEvent as ReactKeyboardEvent, type ReactNode } from "react";
import { listen } from "./events";
import { renderMarkdown } from "./markdown";
import { renderDiagrams } from "./diagrams";
import { Icon } from "./icons";
import { singleWindow } from "./mode";
import MeetingRecorder from "./MeetingRecorder";
import PageHeader, { ModelPill } from "./PageHeader";
import { whisperName } from "./WhisperModels";
import MeetingNotes, { flushMeetingNotes } from "./MeetingNotes";
import { MeetingChatProgressView, StatsForNerds } from "./MeetingChatDiagnostics";
import {
  copyText,
  getStatus,
  openSettings,
  type Status,
  meetingsDelete,
  meetingsExport,
  meetingsGet,
  meetingsList,
  meetingsOpenFolder,
  meetingsReleaseAudio,
  meetingsReprocess,
  meetingsAsk,
  meetingsChatStatus,
  listenVoice,
  ttsSpeak,
  ttsStop,
  ttsWarmUp,
  type TtsState,
  type MeetingNote,
  type MeetingChatProgress,
  meetingsUpdate,
  meetingsVoices,
  meetingsRememberVoice,
  meetingsForgetVoice,
  type KnownVoice,
  type Meeting,
  type MeetingDetail,
  type MeetingEdit,
  type MeetingExport,
  type MeetingProgress,
  type MeetingSegment,
  type MeetingSpeaker,
  type MeetingSummary,
} from "./api";

// The Meetings window (MEETINGS.md): saved meetings, a player that follows
// the transcript, speakers to rename/merge/reassign, lines to edit, the
// clean (proofread) text, export and management. The Zig side owns the
// files (src/meetings.zig); every edit goes through meetings_update.

const MEETING_QUESTIONS = [
  "What do I have to do after this meeting?",
  "What was decided, in three bullets?",
  "What were the key takeaways?",
  "What action items, owners, and deadlines were agreed on?",
  "What questions are still unresolved?",
  "Draft a short follow-up message for this meeting.",
];

const STATE_LABEL: Record<string, string> = {
  recording: "Recording",
  saving: "Saving",
  transcribing: "Transcribing",
  diarizing: "Finding speakers",
  proofreading: "Proofreading",
  summarizing: "Summarizing",
  asking: "Answering",
  ready: "Ready",
  error: "Needs attention",
};

const SPEEDS = [0.75, 1, 1.25, 1.5, 1.75, 2];
const SPEAKER_COLORS = 8;

/** One person in the speaker row: the voices the diarizer split off that
 * carry the same name, shown as one chip. */
interface SpeakerGroup {
  key: string;
  name: string;
  ids: string[];
  /** The voice to act on: the one that talks most. */
  main: string;
  share: number;
  known: boolean;
  hasEmbedding: boolean;
  color: number;
}

function groupSpeakers(speakers: MeetingSpeaker[], talk: Record<string, number>): SpeakerGroup[] {
  const byName = new Map<string, SpeakerGroup>();
  let next = 0;
  for (const sp of speakers) {
    const key = sp.id === "me" ? "me" : sp.name.trim().toLowerCase();
    let g = byName.get(key);
    if (!g) {
      // Colours follow the order people first appear, so they stay put.
      g = { key, name: sp.name, ids: [], main: sp.id, share: 0, known: false, hasEmbedding: false, color: sp.id === "me" ? 0 : (next++ % (SPEAKER_COLORS - 1)) + 1 };
      byName.set(key, g);
    }
    const t = talk[sp.id] ?? 0;
    if (g.ids.length === 0 || t > (talk[g.main] ?? 0)) g.main = sp.id;
    g.ids.push(sp.id);
    g.share += t;
    g.known ||= !!sp.voice;
    g.hasEmbedding ||= !!sp.embedding?.length;
  }
  return [...byName.values()];
}

function clock(seconds: number): string {
  const t = Math.max(0, Math.floor(Number.isFinite(seconds) ? seconds : 0));
  const h = Math.floor(t / 3600);
  const mm = String(Math.floor(t / 60) % 60).padStart(2, "0");
  const ss = String(t % 60).padStart(2, "0");
  return h > 0 ? `${h}:${mm}:${ss}` : `${mm}:${ss}`;
}

function duration(ms: number): string {
  const m = Math.round(ms / 60000);
  // Whole seconds rounded down, like the player's clock, so the two agree.
  if (m < 1) return `${Math.max(1, Math.floor(ms / 1000))} s`;
  if (m < 60) return `${m} min`;
  return `${Math.floor(m / 60)} h ${m % 60} min`;
}

const busyState = (s: string) => s !== "ready" && s !== "error";

// A meeting that was never renamed is titled "Meeting 2026-11-03 09:55". The
// window shows "Recording · Nov 3, 09:55" for it; the stored title is untouched.
const DEFAULT_TITLE = /^Meeting (\d{4}-\d{2}-\d{2} \d{2}:\d{2})(?:-\d+)?$/;
const LOCAL_TIME = /^(\d{4})-(\d{2})-(\d{2}) (\d{2}):(\d{2})/;

function parseLocal(s: string): Date | null {
  const m = LOCAL_TIME.exec(s);
  return m ? new Date(+m[1], +m[2] - 1, +m[3], +m[4], +m[5]) : null;
}

/** "Nov 3" (with the year when it isn't this one). */
function shortDate(d: Date): string {
  const sameYear = d.getFullYear() === new Date().getFullYear();
  return d.toLocaleDateString(undefined, { month: "short", day: "numeric", ...(sameYear ? {} : { year: "numeric" }) });
}

const hhmm = (d: Date) => `${String(d.getHours()).padStart(2, "0")}:${String(d.getMinutes()).padStart(2, "0")}`;

/** "Today 09:55", "Yesterday 09:55", "Oct 29, 09:43". */
function friendlyWhen(local: string): string {
  const d = parseLocal(local);
  if (!d) return local;
  const day = new Date(d.getFullYear(), d.getMonth(), d.getDate()).getTime();
  const now = new Date();
  const today = new Date(now.getFullYear(), now.getMonth(), now.getDate()).getTime();
  if (day === today) return `Today ${hhmm(d)}`;
  if (day === today - 86400000) return `Yesterday ${hhmm(d)}`;
  return `${shortDate(d)}, ${hhmm(d)}`;
}

/** The title to show: the default timestamp title becomes "Recording · Nov 3, 09:55". */
function displayTitle(title: string, startedLocal: string): string {
  const t = title.trim();
  const m = DEFAULT_TITLE.exec(t);
  if (t && !m) return t;
  const d = parseLocal(m ? m[1] : startedLocal);
  return d ? `Recording · ${shortDate(d)}, ${hhmm(d)}` : t || "Recording";
}

const isDefaultTitle = (title: string) => !title.trim() || DEFAULT_TITLE.test(title.trim());

/** "en" → "English"; codes the browser doesn't know stay as they are. */
function languageName(code: string): string {
  try {
    return new Intl.DisplayNames(undefined, { type: "language" }).of(code) ?? code;
  } catch {
    return code;
  }
}

/** The headings of a summary, with an id each, for the table of contents. */
interface TocEntry { id: string; text: string; level: number }
function summaryWithToc(markdown: string | undefined): { html: string; toc: TocEntry[] } {
  if (!markdown) return { html: "", toc: [] };
  const html = renderMarkdown(markdown);
  const doc = new DOMParser().parseFromString(`<div>${html}</div>`, "text/html");
  const toc: TocEntry[] = [];
  doc.querySelectorAll("h1, h2, h3").forEach((h, i) => {
    const id = `mt-sum-${i}`;
    h.id = id;
    toc.push({ id, text: h.textContent?.trim() ?? "", level: Number(h.tagName[1]) });
  });
  return { html: doc.body.firstElementChild?.innerHTML ?? html, toc: toc.filter((t) => t.text) };
}

/** The index of the line being said at `t` (the last one started, until
 * shortly after it ends), or -1 in the silence between lines. */
function lineAt(lines: MeetingSegment[], t: number): number {
  let lo = 0;
  let hi = lines.length - 1;
  let found = -1;
  while (lo <= hi) {
    const mid = (lo + hi) >> 1;
    if (lines[mid].start <= t) {
      found = mid;
      lo = mid + 1;
    } else hi = mid - 1;
  }
  // Past its end (the line's times are its words'): nothing is being said.
  if (found >= 0 && t > lines[found].end + 0.4) return -1;
  return found;
}

/** Lines sorted by start (the two tracks interleave). */
function byStart(lines: MeetingSegment[]): MeetingSegment[] {
  return [...lines].sort((a, b) => a.start - b.start);
}

function nextSpeakerId(speakers: MeetingSpeaker[]): string {
  let n = 1;
  while (speakers.some((s) => s.id === `s${n}`)) n++;
  return `s${n}`;
}

/** Text with the find matches marked. */
function Highlighted({ text, find }: { text: string; find: string }) {
  if (!find) return <>{text}</>;
  const parts: ReactNode[] = [];
  const lower = text.toLowerCase();
  const q = find.toLowerCase();
  let at = 0;
  let k = 0;
  for (;;) {
    const i = lower.indexOf(q, at);
    if (i < 0) break;
    if (i > at) parts.push(text.slice(at, i));
    parts.push(<mark key={k++}>{text.slice(i, i + q.length)}</mark>);
    at = i + q.length;
  }
  parts.push(text.slice(at));
  return <>{parts}</>;
}

/** The line's words with their times, unless the text was edited since. */
function timedWords(l: MeetingSegment) {
  if (!l.words?.length) return null;
  const squash = (s: string) => s.replace(/\s+/g, "").toLowerCase();
  return squash(l.words.map((w) => w.text).join("")) === squash(l.text) ? l.words : null;
}

/** A playing line's words by their times: said, being said, still to come. */
function TimedWords({ words, time }: { words: { start: number; end: number; text: string }[]; time: number }) {
  let current = -1;
  for (let i = 0; i < words.length && words[i].start <= time; i++) current = i;
  return (
    <>
      {words.map((w, i) => (
        <Fragment key={i}>
          {i > 0 && " "}
          <span className={i === current && time <= w.end + 0.3 ? "mt-word now" : i <= current ? "mt-word said" : "mt-word"}>{w.text}</span>
        </Fragment>
      ))}
    </>
  );
}

/** A playing line's words, the one being spoken (estimated from the time) marked:
 * lines without word times (edited, the clean text, older meetings). */
function SpokenWords({ text, fraction }: { text: string; fraction: number }) {
  const words = text.split(/(\s+)/);
  const real = words.filter((w) => w.trim()).length;
  const current = Math.min(real - 1, Math.floor(fraction * real));
  let n = -1;
  return (
    <>
      {words.map((w, i) => {
        if (!w.trim()) return <Fragment key={i}>{w}</Fragment>;
        n++;
        return (
          <span key={i} className={n === current ? "mt-word now" : n < current ? "mt-word said" : "mt-word"}>
            {w}
          </span>
        );
      })}
    </>
  );
}

export default function Meetings() {
  const [list, setList] = useState<MeetingSummary[]>([]);
  const [query, setQuery] = useState("");
  const queryRef = useRef(query);
  useEffect(() => { queryRef.current = query; }, [query]);
  const [selected, setSelected] = useState<string | null>(null);
  // Phones: the list, or one meeting full-screen (styles.css); wide windows show both.
  const [opened, setOpened] = useState(false);
  const [detail, setDetail] = useState<MeetingDetail | null>(null);
  const [progress, setProgress] = useState<Record<string, MeetingProgress>>({});
  const [error, setError] = useState<string | null>(null);
  const [notice, setNotice] = useState<string | null>(null);
  const [tab, setTab] = useState<"transcript" | "final" | "summary" | "notes" | "chat">("transcript");
  // A meeting opens on its clean text when it has one, else on the transcript,
  // until the user picks a tab; from then on their choice stays for the session.
  const tabPicked = useRef(false);
  const autoTab = useRef<{ id: string; clean: boolean } | null>(null);
  const pickTab = (t: typeof tab) => { tabPicked.current = true; setTab(t); };
  const [find, setFind] = useState("");
  const [loadingList, setLoadingList] = useState(true);
  const detailRequest = useRef(0);

  // The player.
  const audioRef = useRef<HTMLAudioElement>(null);
  const [playing, setPlaying] = useState(false);
  const [time, setTime] = useState(0);
  const [length, setLength] = useState(0);
  const [speed, setSpeed] = useState(1);
  const [follow, setFollow] = useState(true);
  const [audioError, setAudioError] = useState<string | null>(null);

  // Editing.
  const [editingTitle, setEditingTitle] = useState(false);
  const [titleDraft, setTitleDraft] = useState("");
  const [editingLine, setEditingLine] = useState<number | null>(null);
  const [lineDraft, setLineDraft] = useState("");
  const [renaming, setRenaming] = useState<string | null>(null);
  const [nameDraft, setNameDraft] = useState("");
  const [speakerMenu, setSpeakerMenu] = useState<string | null>(null);
  const [forgetAsk, setForgetAsk] = useState<string | null>(null);
  // The open "⋯" menu of one person in the Speakers panel, and which of its two views.
  const [rowMenu, setRowMenu] = useState<{ key: string; view: "main" | "merge" } | null>(null);
  const [activeToc, setActiveToc] = useState<string | null>(null);
  const summaryRef = useRef<HTMLDivElement>(null);
  const [lineMenu, setLineMenu] = useState<number | null>(null);
  const [confirmDelete, setConfirmDelete] = useState(false);
  const [menuOpen, setMenuOpen] = useState<"export" | "rerun" | "more" | null>(null);
  // The profile and model that answer the chat (the active AI profile).
  const [chatStatus, setChatStatus] = useState<Status | null>(null);
  // Questions about the meeting: the box, the answer it replaces (Edit), the ones in flight.
  const [askDraft, setAskDraft] = useState("");
  const [askReplace, setAskReplace] = useState<MeetingNote | null>(null);
  const [asking, setAsking] = useState<{ prompt: string; note: string }[]>([]);
  const [liveAnswer, setLiveAnswer] = useState<{ prompt: string; text: string } | null>(null);
  const [chatProgress, setChatProgress] = useState<MeetingChatProgress | null>(null);
  const activePrompt = liveAnswer?.prompt ?? chatProgress?.prompt;
  const pendingAnswers = activePrompt && !asking.some((a) => a.prompt === activePrompt)
    ? [{ prompt: activePrompt, note: "" }, ...asking] : asking;
  const chatHistoryRef = useRef<HTMLDivElement>(null);
  const chatAtBottom = useRef(true);
  const [confirmNote, setConfirmNote] = useState<string | null>(null);
  // Read aloud (the built-in voice, as the link summary's): what is being read.
  const [voice, setVoice] = useState<TtsState>({ phase: "idle", message: "", progress: 0, voice: "" });
  const [reading, setReading] = useState<string | null>(null);
  const voiceBusy = voice.phase === "playing" || voice.phase === "generating" || voice.phase === "downloading";
  // The list's right-click menu: which meeting, where, and whether Delete was clicked once.
  const [ctxMenu, setCtxMenu] = useState<{ id: string; x: number; y: number; confirm: boolean } | null>(null);

  // An open menu is a step of its own for back (a bottom sheet on phones:
  // android.css): Android's back closes it rather than leaving the page.
  const anyMenu = menuOpen !== null || speakerMenu !== null || lineMenu !== null || ctxMenu !== null;
  const closeMenus = () => {
    setSpeakerMenu(null);
    setRowMenu(null);
    setLineMenu(null);
    setMenuOpen(null);
    setCtxMenu(null);
    setConfirmDelete(false);
  };
  const menuEntry = useRef(false);
  useEffect(() => {
    if (anyMenu && !menuEntry.current) {
      window.history.pushState({ ghostpenSheet: true }, "");
      menuEntry.current = true;
    } else if (!anyMenu && menuEntry.current) {
      menuEntry.current = false;
      if (window.history.state?.ghostpenSheet) window.history.back();
    }
  }, [anyMenu]);
  useEffect(() => {
    const onPop = () => {
      if (!menuEntry.current) return;
      menuEntry.current = false;
      closeMenus();
    };
    window.addEventListener("popstate", onPop);
    return () => window.removeEventListener("popstate", onPop);
  }, []);
  const [known, setKnown] = useState<KnownVoice[]>([]);

  const linesRef = useRef<HTMLDivElement>(null);
  const userScrolledAt = useRef(0);

  const meeting = detail?.meeting ?? null;

  // A meeting opened is its own page, #/meetings/<id>: Android's back (the
  // WebView's history), the app bar's back arrow and the drawer return to the
  // list. Phones show one or the other; wide windows show both.
  useEffect(() => {
    const sync = () => {
      const m = window.location.hash.match(/^#\/meetings\/(.+)$/);
      if (m) {
        setSelected(decodeURIComponent(m[1]));
        setOpened(true);
      } else if (window.location.hash.startsWith("#/meetings")) {
        setOpened(false);
      }
    };
    sync();
    window.addEventListener("hashchange", sync);
    return () => window.removeEventListener("hashchange", sync);
  }, []);
  const openMeeting = (id: string) => {
    setSelected(id);
    if (window.location.hash.startsWith("#/meetings")) window.location.hash = "/meetings/" + encodeURIComponent(id);
    else setOpened(true); // its own window (no page routes there)
  };
  // The app bar while one is open (Shell.tsx): a back arrow to "Meetings" (the
  // title stays on the page, where it's renamed).
  useEffect(() => {
    window.dispatchEvent(new CustomEvent("ghostpen:subtitle", { detail: opened ? "Meetings" : "" }));
  }, [opened]);
  const editable = !!meeting && !detail?.busy && !busyState(meeting.state);

  // ---- data ----

  const refreshList = useCallback(async (q = queryRef.current) => {
    try {
      setList(await meetingsList(q));
    } catch (e) {
      setError(String(e));
    } finally {
      setLoadingList(false);
    }
  }, []);

  const loadDetail = useCallback(async (id: string) => {
    const request = ++detailRequest.current;
    try {
      const d = await meetingsGet(id);
      if (request !== detailRequest.current) return;
      setDetail(d);
      setError(null);
    } catch (e) {
      if (request !== detailRequest.current) return;
      setDetail(null);
      setError(String(e));
    }
  }, []);

  const recordingSelected = useCallback((id: string) => {
    setQuery("");
    setSelected(id);
    void refreshList("");
  }, [refreshList]);

  useEffect(() => {
    const t = window.setTimeout(() => refreshList(query), 200);
    return () => window.clearTimeout(t);
  }, [query]); // eslint-disable-line react-hooks/exhaustive-deps

  // The first meeting opens by itself.
  useEffect(() => {
    if (!selected && list.length > 0) setSelected(list[0].id);
  }, [list, selected]);

  useEffect(() => {
    detailRequest.current++;
    setDetail(null);
    setEditingLine(null);
    setRenaming(null);
    setConfirmDelete(false);
    setMenuOpen(null);
    setTime(0);
    setPlaying(false);
    setAudioError(null);
    if (selected) loadDetail(selected);
    else setDetail(null);
  }, [selected, loadDetail]);

  // Pipeline progress: the list's badges, and the open meeting reloaded when a step ends.
  const selectedRef = useRef(selected);
  selectedRef.current = selected;
  useEffect(() => {
    const un = listen<MeetingProgress>("ghostpen://meeting", (e) => {
      const p = e.payload;
      setProgress((prev) => ({ ...prev, [p.id]: p }));
      setList((prev) => {
        return prev.map((m) => (m.id === p.id ? { ...m, state: p.state } : m));
      });
      if (p.id === selectedRef.current && (p.state === "ready" || p.state === "error" || p.progress === 0)) {
        loadDetail(p.id);
        if (p.state === "ready" || p.state === "error") { setAsking([]); setLiveAnswer(null); setChatProgress(null); }
      }
      if (p.progress === 0 || p.state === "ready" || p.state === "error") refreshList();
    });
    return () => {
      un.then((f) => f());
    };
  }, [loadDetail, refreshList]);

  useEffect(() => {
    const un = listen<{ id: string; prompt: string; text: string; reset: boolean }>("ghostpen://meeting-answer", (e) => {
      const p = e.payload;
      if (p.id !== selectedRef.current) return;
      setLiveAnswer((prev) => ({ prompt: p.prompt, text: p.reset ? p.text : (prev?.prompt === p.prompt ? prev.text : "") + p.text }));
    });
    return () => { un.then((f) => f()); };
  }, []);

  useEffect(() => { setLiveAnswer(null); }, [selected]);

  useEffect(() => {
    setChatProgress(null);
    if (!selected) return;
    let active = true;
    let eventSeen = false;
    const un = listen<MeetingChatProgress>("ghostpen://meeting-chat-progress", (e) => {
      if (!active || e.payload.id !== selected) return;
      eventSeen = true;
      setChatProgress(e.payload);
    });
    void meetingsChatStatus(selected).then((status) => { if (active && !eventSeen) setChatProgress(status); }).catch(() => {});
    return () => { active = false; un.then((f) => f()); };
  }, [selected]);

  useEffect(() => {
    const history = chatHistoryRef.current;
    if (tab === "chat" && history && chatAtBottom.current) history.scrollTop = history.scrollHeight;
  }, [tab, meeting?.notes, liveAnswer, asking, chatProgress]);

  useEffect(() => { chatAtBottom.current = true; }, [selected, tab]);

  // The chat's empty state names the model that answers.
  useEffect(() => {
    if (tab !== "chat") return;
    getStatus().then(setChatStatus).catch(() => {});
  }, [tab]);

  // Mermaid fences (a summary or an answer may have them) render once their
  // document is final: while an answer still streams the nodes change every
  // chunk, which would redraw the whole diagram per token.
  useEffect(() => {
    if (liveAnswer?.text) return;
    void renderDiagrams(document.querySelector(".mt-main"));
  }, [tab, meeting?.summary, meeting?.notes, liveAnswer, chatProgress]);

  // Hidden window: stop playing and serving the audio; shown again: reload.
  useEffect(() => {
    const onVis = () => {
      if (document.hidden) {
        audioRef.current?.pause();
        meetingsReleaseAudio().catch(() => {});
      } else {
        refreshList();
        if (selectedRef.current) loadDetail(selectedRef.current);
      }
    };
    document.addEventListener("visibilitychange", onVis);
    return () => document.removeEventListener("visibilitychange", onVis);
  }, [loadDetail, refreshList]);

  useEffect(() => {
    const un = listenVoice(setVoice);
    return () => {
      un.then((f) => f());
    };
  }, []);
  // The voice finished (or failed): nothing is being read.
  useEffect(() => {
    if (!voiceBusy) setReading(null);
  }, [voiceBusy]);

  /** Read `text` aloud as `key` ("summary" or a question's id); again stops it. */
  const readAloud = (key: string, text: string) => {
    if (reading === key && voiceBusy) {
      ttsStop().catch(() => {});
      setReading(null);
      return;
    }
    if (voiceBusy) ttsStop().catch(() => {});
    setReading(key);
    // Times like [00:42:10] help on screen; read aloud they're just numbers.
    ttsSpeak(text.replace(/\[\d{1,2}:\d{2}(?::\d{2})?\]\s*/g, "")).catch((e) => {
      setReading(null);
      setError(String(e));
    });
  };

  const ReadButton = ({ id, text, className }: { id: string; text: string; className: string }) => (
    <button
      className={className}
      title={reading === id && voiceBusy ? "Stop the built-in voice" : "Read it through the built-in voice"}
      onMouseEnter={() => ttsWarmUp().catch(() => {})}
      onClick={() => readAloud(id, text)}
    >
      {reading === id && voiceBusy ? (voice.phase === "downloading" ? `■ Downloading ${Math.round(voice.progress * 100)}%` : "■ Stop") : "🔊 Read"}
    </button>
  );

  const refreshVoices = () => meetingsVoices().then(setKnown).catch(() => {});
  useEffect(() => {
    refreshVoices();
  }, []);

  const rememberVoice = async (sp: MeetingSpeaker) => {
    if (!detail) return;
    setSpeakerMenu(null);
    try {
      const m = await meetingsRememberVoice(detail.id, sp.id);
      setDetail({ ...detail, meeting: m });
      refreshVoices();
      flash(`GhostPen will recognise ${sp.name} in the next meetings`);
    } catch (e) {
      setError(String(e));
    }
  };

  const forgetVoice = async (name: string) => {
    setForgetAsk(null);
    try {
      await meetingsForgetVoice(name);
      refreshVoices();
    } catch (e) {
      setError(String(e));
    }
  };

  const flash = (msg: string) => {
    setNotice(msg);
    window.setTimeout(() => setNotice((n) => (n === msg ? null : n)), 2500);
  };

  const save = async (edit: MeetingEdit) => {
    if (!detail) return;
    try {
      const m = await meetingsUpdate(detail.id, edit);
      setDetail({ ...detail, meeting: m });
      if (edit.title !== undefined) refreshList();
    } catch (e) {
      setError(String(e));
    }
  };

  // ---- lines ----

  const lines = useMemo<MeetingSegment[]>(() => {
    if (!meeting) return [];
    if (tab !== "transcript" && tab !== "final") return [];
    return byStart(tab === "final" ? meeting.final : meeting.segments);
  }, [meeting, tab]);

  const current = useMemo(() => lineAt(lines, time), [lines, time]);

  const matches = useMemo(() => {
    if (!find.trim()) return [];
    const q = find.trim().toLowerCase();
    return lines.flatMap((l, i) => (l.text.toLowerCase().includes(q) ? [i] : []));
  }, [lines, find]);

  const talk = useMemo(() => {
    const out: Record<string, number> = {};
    if (!meeting) return out;
    let total = 0;
    for (const s of meeting.segments) {
      const d = Math.max(0, s.end - s.start);
      out[s.speaker] = (out[s.speaker] ?? 0) + d;
      total += d;
    }
    for (const k of Object.keys(out)) out[k] = total > 0 ? out[k] / total : 0;
    return out;
  }, [meeting]);

  const speakerGroups = useMemo(() => (meeting ? groupSpeakers(meeting.speakers, talk) : []), [meeting, talk]);
  const groupColor = (id: string) => speakerGroups.find((g) => g.ids.includes(id))?.color ?? 0;
  const byShare = useMemo(() => [...speakerGroups].sort((a, b) => b.share - a.share), [speakerGroups]);
  const summaryDoc = useMemo(() => summaryWithToc(meeting?.summary), [meeting?.summary]);

  // Pick the opening tab once per meeting; if the clean text only arrives later
  // (proofreading finishes), move to it unless the user is playing the audio.
  useEffect(() => {
    if (!detail || tabPicked.current) return;
    const clean = detail.meeting.final.length > 0;
    const prev = autoTab.current;
    const sameMeeting = prev?.id === detail.id;
    if (sameMeeting && (prev.clean || !clean)) return;
    autoTab.current = { id: detail.id, clean };
    if (sameMeeting && playing) return;
    setTab(clean ? "final" : "transcript");
  }, [detail]); // eslint-disable-line react-hooks/exhaustive-deps

  useEffect(() => { if (speakerMenu !== "panel") { setRowMenu(null); setForgetAsk(null); } }, [speakerMenu]);

  // "On this page": the section being read is the one whose heading most
  // recently passed the top of the summary's scroll area. The first section is
  // active at the very top and the last one at the very bottom (a short last
  // section may never reach the top).
  useEffect(() => {
    const root = summaryRef.current;
    if (tab !== "summary" || !root || summaryDoc.toc.length < 2) return;
    const heads = summaryDoc.toc.flatMap((t) => { const el = document.getElementById(t.id); return el ? [el] : []; });
    if (!heads.length) return;
    const LINE = 24; // px below the container's top edge
    const update = () => {
      const scrollable = root.scrollHeight - root.clientHeight > 2;
      const atTop = root.scrollTop <= 1;
      const atEnd = scrollable && root.scrollTop + root.clientHeight >= root.scrollHeight - 2;
      let at = 0;
      if (atEnd) at = heads.length - 1;
      else if (!atTop) {
        const top = root.getBoundingClientRect().top;
        heads.forEach((h, i) => { if (h.getBoundingClientRect().top - top <= LINE) at = i; });
      }
      setActiveToc(heads[at].id);
    };
    update();
    root.addEventListener("scroll", update, { passive: true });
    let io: IntersectionObserver | undefined;
    if (typeof IntersectionObserver !== "undefined") {
      // The top margin puts the observed edge on the same line as `update`, so
      // a heading crossing it (ratio 1 <-> partial) re-runs the check.
      io = new IntersectionObserver(update, { root, rootMargin: `-${LINE}px 0px 0px 0px`, threshold: [0, 1] });
      heads.forEach((h) => io!.observe(h));
    }
    return () => { root.removeEventListener("scroll", update); io?.disconnect(); };
  }, [tab, summaryDoc, detail?.id]);

  // Follow the playing line, unless the user scrolled in the last few seconds.
  useEffect(() => {
    if (!follow || !playing || current < 0) return;
    if (Date.now() - userScrolledAt.current < 4000) return;
    const el = linesRef.current?.querySelector<HTMLElement>(`[data-line="${current}"]`);
    el?.scrollIntoView({ block: "center", behavior: "smooth" });
  }, [current, follow, playing]);

  const scrollToLine = (i: number) => {
    linesRef.current?.querySelector<HTMLElement>(`[data-line="${i}"]`)?.scrollIntoView({ block: "center", behavior: "smooth" });
  };

  // ---- the player ----

  // Stereo recordings (the others left, you right) play as they are: a Web
  // Audio mono mix played silence in WebKitGTK (the media server's audio
  // came out of MediaElementSource as nothing).
  const play = useCallback(async () => {
    const el = audioRef.current;
    if (!el) return;
    try {
      await el.play();
    } catch (e) {
      setAudioError(`Can't play the recording (${e}).`);
    }
  }, []);

  const toggle = useCallback(() => (audioRef.current?.paused ? play() : audioRef.current?.pause()), [play]);

  const seek = useCallback((t: number, andPlay = false) => {
    const el = audioRef.current;
    if (!el) return;
    el.currentTime = Math.max(0, Math.min(t, el.duration || t));
    setTime(el.currentTime);
    userScrolledAt.current = 0;
    if (andPlay && el.paused) play();
  }, [play]);

  useEffect(() => {
    if (audioRef.current) audioRef.current.playbackRate = speed;
  }, [speed, detail?.audio]);

  // timeupdate comes about 4 times a second: too coarse for a word at a
  // time. While playing, read the position every frame.
  useEffect(() => {
    if (!playing) return;
    let frame = 0;
    let previous = "";
    const tick = () => {
      const el = audioRef.current;
      if (el) {
        const t = el.currentTime;
        const index = lineAt(lines, t);
        const line = lines[index];
        const words = line ? timedWords(line) : null;
        let word = -1;
        let highlighted = false;
        if (words) {
          for (let i = 0; i < words.length && words[i].start <= t; i++) word = i;
          highlighted = word >= 0 && t <= words[word].end + 0.3;
        } else if (line && line.end > line.start) {
          const count = line.text.split(/(\s+)/).filter((w) => w.trim()).length;
          word = Math.min(count - 1, Math.floor(((t - line.start) / (line.end - line.start)) * count));
        }
        // The slider steps by 0.1 s; words can change between those steps.
        const position = `${Math.round(t * 10)}:${Math.floor(t)}:${index}:${word}:${highlighted}`;
        if (position !== previous) {
          previous = position;
          setTime(t);
        }
      }
      frame = requestAnimationFrame(tick);
    };
    frame = requestAnimationFrame(tick);
    return () => cancelAnimationFrame(frame);
  }, [playing, lines]);

  // Keyboard: Space play/pause, ←/→ 5 s, J/L 10 s, Ctrl+F find.
  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      const t = e.target as HTMLElement;
      const typing = t && (t.tagName === "INPUT" || t.tagName === "TEXTAREA" || t.tagName === "SELECT" || t.isContentEditable);
      if ((e.ctrlKey || e.metaKey) && e.key.toLowerCase() === "f") {
        e.preventDefault();
        document.getElementById("mt-find")?.focus();
        return;
      }
      if (typing || !audioRef.current) return;
      const el = audioRef.current;
      if (e.key === " ") {
        e.preventDefault();
        toggle();
      } else if (e.key === "ArrowLeft") seek(el.currentTime - 5);
      else if (e.key === "ArrowRight") seek(el.currentTime + 5);
      else if (e.key.toLowerCase() === "j") seek(el.currentTime - 10);
      else if (e.key.toLowerCase() === "l") seek(el.currentTime + 10);
      else if (e.key === "Escape") {
        setSpeakerMenu(null);
        setRowMenu(null);
        setLineMenu(null);
        setMenuOpen(null);
      }
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [toggle, seek]);

  // ---- speakers ----

  // A chip stands for every voice with its name: renaming renames them all.
  const renameSpeaker = (group: SpeakerGroup, name: string) => {
    if (!meeting) return;
    const n = name.trim();
    setRenaming(null);
    if (!n || n === group.name) return;
    save({ speakers: meeting.speakers.map((s) => (group.ids.includes(s.id) ? { ...s, name: n } : s)) });
  };

  /** Fold the voices `from` into the voice `into` (lines and all). */
  const mergeVoices = (from: string[], into: string) => {
    if (!meeting) return;
    const gone = from.filter((id) => id !== into);
    if (!gone.length) return;
    setSpeakerMenu(null);
    save({
      speakers: meeting.speakers.filter((s) => !gone.includes(s.id)),
      segments: meeting.segments.map((s) => (gone.includes(s.speaker) ? { ...s, speaker: into } : s)),
      final: meeting.final.map((s) => (gone.includes(s.speaker) ? { ...s, speaker: into } : s)),
    });
  };

  const mergeSpeaker = (from: SpeakerGroup, into: SpeakerGroup) => {
    if (from.key === into.key) return;
    mergeVoices(from.ids, into.main);
    flash(`${from.name} merged into ${into.name}`);
  };

  const combineVoices = (group: SpeakerGroup) => {
    mergeVoices(group.ids, group.main);
    flash(`${group.ids.length} voices of ${group.name} combined`);
  };

  /** Give one line (of the open tab) to `speaker` ("" = a new speaker). */
  const reassign = (index: number, speaker: string) => {
    if (!meeting) return;
    setLineMenu(null);
    let speakers = meeting.speakers;
    let id = speaker;
    if (!id) {
      id = nextSpeakerId(speakers);
      speakers = [...speakers, { id, name: `Speaker ${speakers.filter((s) => s.id !== "me").length + 1}` }];
    }
    const line = lines[index];
    const swap = (arr: MeetingSegment[]) => arr.map((s) => (s === line ? { ...s, speaker: id } : s));
    save(tab === "final" ? { speakers, final: swap(meeting.final) } : { speakers, segments: swap(meeting.segments) });
  };

  const saveLine = (index: number) => {
    if (!meeting) return;
    const line = lines[index];
    const text = lineDraft.trim();
    setEditingLine(null);
    if (!text || text === line.text) return;
    const edit = (arr: MeetingSegment[]) => arr.map((s) => (s === line ? { ...s, text } : s));
    save(tab === "final" ? { final: edit(meeting.final) } : { segments: edit(meeting.segments) });
  };

  // ---- actions ----

  const doExport = async (format: MeetingExport, label: string) => {
    if (!detail) return;
    setMenuOpen(null);
    try {
      await copyText(await meetingsExport(detail.id, format));
      flash(`${label} copied`);
    } catch (e) {
      setError(String(e));
    }
  };

  const rerun = async (step: "transcribe" | "speakers" | "proofread" | "summary") => {
    if (!detail) return;
    setMenuOpen(null);
    try {
      await meetingsReprocess(detail.id, step);
      await loadDetail(detail.id);
    } catch (e) {
      setError(String(e));
    }
  };

  const askAbout = async (prompt: string, note = "") => {
    if (!detail || !prompt.trim()) return;
    const pending = { prompt: prompt.trim(), note };
    try {
      await flushMeetingNotes(detail.id, detail.folder);
      if (selectedRef.current === detail.id) setAsking((a) => [...a, pending]);
      await meetingsAsk(detail.id, prompt.trim(), note);
      if (selectedRef.current === detail.id) { setAskDraft(""); setAskReplace(null); }
    } catch (e) {
      if (selectedRef.current === detail.id) { setAsking((a) => a.filter((item) => item !== pending)); setError(String(e)); }
    }
  };

  const deleteNote = (id: string) => {
    if (!meeting) return;
    setConfirmNote(null);
    save({ notes: (meeting.notes ?? []).filter((n) => n.id !== id) });
  };

  const removeId = async (id: string) => {
    try {
      if (id === detail?.id) audioRef.current?.pause();
      await meetingsDelete(id);
      if (id === selected) setSelected(null);
      setConfirmDelete(false);
      await refreshList();
    } catch (e) {
      setError(String(e));
    }
  };

  const remove = () => (detail ? removeId(detail.id) : Promise.resolve());

  // The list's menu actions.
  const ctxAction = async (action: "open" | "rename" | "copy" | "folder") => {
    if (!ctxMenu) return;
    const { id } = ctxMenu;
    setCtxMenu(null);
    try {
      if (action === "folder") await meetingsOpenFolder(id);
      else if (action === "copy") {
        await copyText(await meetingsExport(id, "text"));
        flash("Clean text copied");
      } else {
        setSelected(id);
        if (action === "rename") pendingRename.current = id;
      }
    } catch (e) {
      setError(String(e));
    }
  };
  const pendingRename = useRef<string | null>(null);
  // Rename from the list: once the meeting is open, its title turns into the field.
  useEffect(() => {
    if (detail && pendingRename.current === detail.id && editable) {
      pendingRename.current = null;
      setTitleDraft(detail.meeting.title);
      setEditingTitle(true);
    }
  }, [detail, editable]);

  // No WebKit menu (Back, Reload…) anywhere in the window; a click or Esc closes ours.
  useEffect(() => {
    const block = (e: MouseEvent) => {
      const t = e.target as HTMLElement;
      if (t.closest("input, textarea")) return; // keep copy/paste in fields
      e.preventDefault();
    };
    const close = (e: KeyboardEvent) => e.key === "Escape" && setCtxMenu(null);
    window.addEventListener("contextmenu", block);
    window.addEventListener("keydown", close);
    return () => {
      window.removeEventListener("contextmenu", block);
      window.removeEventListener("keydown", close);
    };
  }, []);

  // The Meetings section of Settings: a page of the app window in single-window
  // mode; else the Settings window (it opens on its first section).
  const openMeetingSettings = () => {
    if (singleWindow) window.location.hash = "/settings/meetings";
    else openSettings().catch((e) => setError(String(e)));
  };

  // ---- render ----

  const live = detail ? progress[detail.id] : undefined;
  const liveState = live && meeting && live.state !== meeting.state && busyState(live.state) ? live : undefined;
  const state = liveState?.state ?? meeting?.state;
  // Nothing was said (or transcription failed): no speakers, find or full player to show.
  const noSpeech = !!meeting && !!state && !busyState(state) && meeting.segments.length === 0;
  // A silent recording has nothing for the other tabs: it shows only the recovery panel.
  const view = noSpeech ? "transcript" : tab;

  const wideHeader = useWideHeader();

  return (
    <div className={`meetings ${opened ? "opened" : "browsing"}`} onClick={closeMenus}>
      {/* Phones: the dimmed backdrop behind a menu shown as a bottom sheet. */}
      {anyMenu && <div className="mt-sheet-scrim" onClick={(e) => { e.stopPropagation(); closeMenus(); }} />}
      <PageHeader
        className="mt-page-head"
        title="Meetings"
        subtitle="Record a meeting, then read, search, summarize or ask about it."
      >
        {/* Wide windows: Record sits in the header; narrow ones hide the
            header, so it heads the main column instead (one recorder at a time). */}
        {wideHeader && <MeetingRecorder onRecorded={recordingSelected} />}
      </PageHeader>
      <aside className="mt-side">
        <div className="mt-side-head">
          <h2>Saved meetings</h2>
          <button className="mt-icon-btn" aria-label="Open the meetings folder" title="Open the meetings folder" onClick={() => meetingsOpenFolder().catch((e) => setError(String(e)))}>
            <Icon name="folder" />
          </button>
        </div>
        <input
          className="mt-search"
          type="search"
          aria-label="Search meetings"
          placeholder="Search titles, speakers, words…"
          value={query}
          onChange={(e) => setQuery(e.target.value)}
        />
        <div className="mt-list" role="listbox" aria-label="Saved meetings">
          {loadingList && <div className="mt-empty">Loading…</div>}
          {!loadingList && list.length === 0 && (
            <div className="mt-empty">
              {query ? "No meeting matches." : (
                <>
                  Saved meetings appear here. Choose Record meeting to start one.
                </>
              )}
            </div>
          )}
          {list.map((m) => {
            const p = progress[m.id];
            const st = p && busyState(p.state) ? p.state : m.state;
            return (
              <button
                key={m.id}
                role="option"
                aria-selected={m.id === selected}
                className={`mt-item ${m.id === selected ? "active" : ""}`}
                onClick={() => openMeeting(m.id)}
                onContextMenu={(e) => {
                  e.preventDefault();
                  e.stopPropagation();
                  setCtxMenu({ id: m.id, x: e.clientX, y: e.clientY, confirm: false });
                }}
              >
                <span className="mt-item-avatar" aria-hidden="true"><Icon name="mic" /></span>
                <span className="mt-item-text">
                <span className="mt-item-title" title={displayTitle(m.title, m.startedLocal)}>{displayTitle(m.title, m.startedLocal)}</span>
                <span className="mt-item-meta">
                  {isDefaultTitle(m.title) ? "" : `${friendlyWhen(m.startedLocal)} · `}{st === "recording" ? "In progress" : duration(m.durationMs)}
                  {st !== "ready" && (
                    <span className={`mt-badge ${st}`}>
                      {STATE_LABEL[st] ?? st}
                      {p && busyState(p.state) && p.progress > 0 ? ` ${Math.round(p.progress * 100)}%` : ""}
                    </span>
                  )}
                </span>
                {m.preview && <span className="mt-item-preview">{m.preview}</span>}
                </span>
              </button>
            );
          })}
        </div>
        <div className="mt-side-foot" onClick={(e) => e.stopPropagation()}>
          <button className="mt-voices-btn" onClick={openMeetingSettings} title="Where meetings are saved, speaker detection, proofreading and summaries">
            <span className="mt-voices-glyph" aria-hidden="true"><Icon name="settings" /></span> Meeting settings
          </button>
        </div>
      </aside>

      {ctxMenu && (() => {
        const m = list.find((x) => x.id === ctxMenu.id);
        const busy = !m || busyState(progress[ctxMenu.id]?.state ?? m.state);
        return (
          <div
            className="mt-menu mt-ctx"
            style={{ left: Math.min(ctxMenu.x, window.innerWidth - 210), top: Math.min(ctxMenu.y, window.innerHeight - 200) }}
            onClick={(e) => e.stopPropagation()}
          >
            <button onClick={() => ctxAction("open")}>Open</button>
            <button disabled={busy} onClick={() => ctxAction("rename")}>Rename…</button>
            <button onClick={() => ctxAction("copy")}>Copy clean text</button>
            <button onClick={() => ctxAction("folder")}>Open folder</button>
            <div className="mt-menu-sep" />
            {ctxMenu.confirm ? (
              <button className="danger" onClick={() => { const id = ctxMenu.id; setCtxMenu(null); removeId(id); }}>
                Delete “{m ? displayTitle(m.title, m.startedLocal) : "Meeting"}” for good
              </button>
            ) : (
              <button className="danger" disabled={busy} title={busy ? "Wait until it's saved" : undefined} onClick={() => setCtxMenu({ ...ctxMenu, confirm: true })}>
                Delete…
              </button>
            )}
          </div>
        );
      })()}

      <main className="mt-main">
        {!wideHeader && <MeetingRecorder onRecorded={recordingSelected} />}
        <button className="mt-back" onClick={() => window.history.back()}>‹ Meetings</button>
        {error && (
          <div className="mt-error" role="alert">
            {error}<button aria-label="Dismiss error" onClick={() => setError(null)}>×</button>
          </div>
        )}
        {notice && <div className="mt-notice">{notice}</div>}

        {!meeting && !error && <div className="mt-placeholder">
          <span className="mt-empty-symbol"><Icon name="mic" /></span>
          <h2>{selected ? "Opening your meeting…" : "No meetings yet"}</h2>
          <p>{selected ? "Loading the recording and transcript." : "Choose Record meeting to start."}</p>
        </div>}

        {meeting && detail && (
          <>
            <header className="mt-head">
              <div className="mt-head-text">
                {editingTitle ? (
                  <input
                    className="mt-title-input"
                    autoFocus
                    value={titleDraft}
                    onChange={(e) => setTitleDraft(e.target.value)}
                    onBlur={() => {
                      setEditingTitle(false);
                      if (titleDraft.trim() && titleDraft.trim() !== meeting.title) save({ title: titleDraft.trim() });
                    }}
                    onKeyDown={(e) => {
                      if (e.key === "Enter") (e.target as HTMLInputElement).blur();
                      if (e.key === "Escape") {
                        setTitleDraft(meeting.title);
                        setEditingTitle(false);
                      }
                    }}
                  />
                ) : (
                  <h2
                    className={editable ? "mt-title editable" : "mt-title"}
                    title={editable ? "Rename" : undefined}
                    onClick={() => {
                      if (!editable) return;
                      setTitleDraft(meeting.title);
                      setEditingTitle(true);
                    }}
                  >
                    {displayTitle(meeting.title, meeting.startedLocal)}
                  </h2>
                )}
                <div className="mt-meta">
                  {[
                    // The default title already carries the date and time.
                    isDefaultTitle(meeting.title) ? "" : friendlyWhen(meeting.startedLocal),
                    state === "recording" ? "Recording in progress" : duration(meeting.durationMs),
                    state === "ready" && !meeting.segments.length ? "No speech found" : "",
                    meeting.language && meeting.language !== "auto" ? languageName(meeting.language) : "",
                    meeting.model ? whisperName(meeting.model).replace(/, \d-bit/, "") : "",
                  ].filter(Boolean).join(" · ")}
                </div>
              </div>
              <div className="mt-actions" onClick={(e) => e.stopPropagation()}>
                {!noSpeech && <div className="mt-dropdown">
                  <button className="mt-btn" disabled={!meeting.segments.length} title={meeting.segments.length ? "Copy the summary or the text" : "Nothing to copy yet"} onClick={() => setMenuOpen(menuOpen === "export" ? null : "export")}>
                    Copy ▾
                  </button>
                  {menuOpen === "export" && (
                    <div className="mt-menu">
                      <button disabled={!meeting.summary} onClick={() => doExport("summary", "Summary")}>Summary</button>
                      <button onClick={() => doExport("text", "Clean text")}>Clean text</button>
                      <button onClick={() => doExport("final", "Markdown (clean)")}>Markdown, clean</button>
                      <button onClick={() => doExport("transcript", "Markdown transcript")}>Markdown, transcript with times</button>
                      <button onClick={() => doExport("srt", "Subtitles")}>Subtitles (SRT)</button>
                    </div>
                  )}
                </div>}
                {/* A silent recording's only step is "Transcribe again", in its own panel. */}
                {!noSpeech && <div className="mt-dropdown">
                  <button className="mt-btn" disabled={!editable} title={editable ? "Run a step of the processing again" : "Wait until the meeting is processed"} onClick={() => setMenuOpen(menuOpen === "rerun" ? null : "rerun")}>
                    Re-process ▾
                  </button>
                  {menuOpen === "rerun" && (
                    <div className="mt-menu">
                      <div className="mt-menu-label">Run again</div>
                      <button onClick={() => rerun("summary")}>{meeting.summary ? "Summarize again" : "Summarize"}</button>
                      <button onClick={() => rerun("proofread")}>Proofread again</button>
                      <button onClick={() => rerun("speakers")}>Find the speakers again</button>
                      <button onClick={() => rerun("transcribe")} title="Your edits to the lines are replaced">
                        Transcribe again (replaces edits)
                      </button>
                    </div>
                  )}
                </div>}
                <div className="mt-dropdown">
                  <button className="mt-btn mt-more" aria-label="More actions" aria-haspopup="menu" title="More actions" onClick={() => { setConfirmDelete(false); setMenuOpen(menuOpen === "more" ? null : "more"); }}>
                    ⋯
                  </button>
                  {menuOpen === "more" && (
                    <div className="mt-menu" role="menu">
                      <button role="menuitem" onClick={() => { setMenuOpen(null); meetingsOpenFolder(detail.id).catch((e) => setError(String(e))); }} title={detail.folder}>
                        Open the meeting's folder
                      </button>
                      <div className="mt-menu-sep" />
                      {confirmDelete ? (
                        <>
                          <div className="mt-menu-label">This can't be undone</div>
                          <button role="menuitem" className="danger solid" onClick={remove}>Delete for good</button>
                          <button role="menuitem" onClick={() => setConfirmDelete(false)}>Keep it</button>
                        </>
                      ) : (
                        <button role="menuitem" className="danger" disabled={detail.busy} title={detail.busy ? "Wait until it's saved" : undefined} onClick={() => setConfirmDelete(true)}>
                          Delete meeting…
                        </button>
                      )}
                    </div>
                  )}
                </div>
              </div>
            </header>

            {state && busyState(state) && (
              <div className="mt-progress">
                <span>
                  {STATE_LABEL[state] ?? state}…
                  {state === "recording" ? " Audio is being saved. Transcription begins after Stop and save." : ""}
                </span>
                <div className="mt-bar">
                  <div className="mt-bar-fill" style={{ width: `${Math.round((liveState?.progress ?? live?.progress ?? 0) * 100)}%` }} />
                </div>
              </div>
            )}
            {meeting.message && !busyState(meeting.state) && <div className={`mt-note ${meeting.state}`}>{meeting.message}</div>}

            {!noSpeech && (() => {
              const pct = (g: SpeakerGroup) => (g.share > 0 && g.share < 0.01 ? "under 1%" : `${Math.round(g.share * 100)}%`);
              const tip = (g: SpeakerGroup) =>
                `${g.name}: ${pct(g)} of the talking${g.ids.length > 1 ? ` (${g.ids.length} voices found, shown as one)` : ""}`;
              const open = speakerMenu === "panel";
              const talkers = byShare.filter((g) => g.share > 0);
              // A badge marks the exception: "New voice" only means something
              // when other voices in this meeting were recognised.
              const others = byShare.filter((g) => g.key !== "me");
              const anyKnown = others.some((g) => g.known);
              const allKnown = others.length > 0 && others.every((g) => g.known);
              const rememberOf = (g: SpeakerGroup) => {
                const sp = meeting.speakers.find((x) => x.id === g.main && x.embedding?.length) ?? meeting.speakers.find((x) => g.ids.includes(x.id) && x.embedding?.length);
                if (sp) { setRowMenu(null); rememberVoice({ ...sp, name: g.name }); }
              };
              return (
                <div className="mt-speakers-wrap" onClick={(e) => e.stopPropagation()}>
                  <div className="mt-speakers-row">
                    <button
                      className={`mt-speakers-btn ${open ? "open" : ""}`}
                      aria-expanded={open}
                      aria-haspopup="true"
                      title="Rename, merge and remember the voices in this meeting"
                      onClick={() => setSpeakerMenu(open ? null : "panel")}
                    >
                      <span className="mt-dots" aria-hidden="true">
                        {byShare.slice(0, 5).map((g) => <span key={g.key} className={`mt-dot c${g.color}`} />)}
                      </span>
                      Speakers{byShare.length ? ` (${byShare.length})` : ""} <span aria-hidden="true">{open ? "▴" : "▾"}</span>
                    </button>
                    {byShare.length > 1 && talkers.length > 0 && (
                      <div className="mt-share">
                        <div className="mt-share-top">
                          <span className="mt-share-caption">Share of speech</span>
                          <div className="mt-share-bar" role="img" aria-label={`Share of speech: ${talkers.map((g) => `${g.name} ${pct(g)}`).join(", ")}`}>
                            {talkers.map((g) => (
                              <span key={g.key} className={`c${g.color}`} style={{ flexGrow: g.share }} title={tip(g)} />
                            ))}
                          </div>
                        </div>
                        <div className="mt-share-legend" aria-hidden="true">
                          {talkers.slice(0, 5).map((g) => (
                            <span key={g.key} className={`mt-share-key c${g.color}`} title={tip(g)}>
                              <span className="mt-dot" />{g.name} {pct(g)}
                            </span>
                          ))}
                          {talkers.length > 5 && <span className="mt-share-key" title={talkers.slice(5).map((g) => `${g.name} ${pct(g)}`).join(", ")}>+{talkers.length - 5} more</span>}
                        </div>
                      </div>
                    )}
                  </div>
                  {open && (
                    <div className="mt-menu mt-spk-panel" role="group" aria-label="Speakers">
                      {byShare.length === 0 && <div className="mt-voices-empty">No speakers were found in this meeting.</div>}
                      {byShare.map((g) => {
                        const menu = rowMenu?.key === g.key ? rowMenu : null;
                        return (
                          <div key={g.key} className={`mt-spk-row c${g.color}`}>
                            <div className="mt-spk-main">
                              <span className="mt-dot" aria-hidden="true" />
                              {renaming === g.key ? (
                                <input
                                  className="mt-speaker-input"
                                  autoFocus
                                  aria-label={`New name for ${g.name}`}
                                  value={nameDraft}
                                  onFocus={(e) => e.currentTarget.select()}
                                  onChange={(e) => setNameDraft(e.target.value)}
                                  onBlur={() => renameSpeaker(g, nameDraft)}
                                  onKeyDown={(e) => {
                                    if (e.key === "Enter") (e.target as HTMLInputElement).blur();
                                    if (e.key === "Escape") setRenaming(null);
                                  }}
                                />
                              ) : editable ? (
                                <button
                                  className="mt-spk-name editable"
                                  title={`Click to rename · ${tip(g)}`}
                                  onClick={() => {
                                    setNameDraft(g.name);
                                    setRenaming(g.key);
                                    setRowMenu(null);
                                  }}
                                >
                                  {g.name}<span className="mt-spk-edit" aria-hidden="true">✎</span>
                                </button>
                              ) : (
                                <span className="mt-spk-name" title={tip(g)}>{g.name}</span>
                              )}
                              {!g.known && anyKnown && g.key !== "me" && <span className="mt-new" title="Not matched to a voice you saved. Use ⋯ → Remember this voice to name them in later meetings.">New voice</span>}
                              <span className="mt-spk-share" title={tip(g)}>
                                {g.ids.length > 1 && <span className="mt-spk-voices" title="GhostPen found several separate voices for this person">{g.ids.length} voices</span>}
                              </span>
                              <button
                                className={`mt-spk-more ${menu ? "open" : ""}`}
                                aria-label={`More actions for ${g.name}`}
                                aria-haspopup="menu"
                                aria-expanded={!!menu}
                                title="More actions"
                                onClick={() => setRowMenu(menu ? null : { key: g.key, view: "main" })}
                              >
                                ⋯
                              </button>
                            </div>
                            {menu && menu.view === "main" && (
                              <div className="mt-spk-menu" role="menu" aria-label={`Actions for ${g.name}`}>
                                {g.ids.length > 1 && (
                                  <button role="menuitem" disabled={!editable} onClick={() => { setRowMenu(null); combineVoices(g); }} title={`Put the lines of all ${g.ids.length} voices under one speaker`}>
                                    Treat as one person ({g.ids.length} voices)
                                  </button>
                                )}
                                <button
                                  role="menuitem"
                                  disabled={!editable || !g.hasEmbedding}
                                  title="Later meetings label this voice with this name"
                                  onClick={() => rememberOf(g)}
                                >
                                  Remember this voice
                                </button>
                                {!g.hasEmbedding && <div className="mt-spk-hint">Not analysed yet: use Re-process → Find the speakers again.</div>}
                                {byShare.length > 1 && (
                                  <button role="menuitem" disabled={!editable} onClick={() => setRowMenu({ key: g.key, view: "merge" })}>
                                    Merge into another speaker…
                                  </button>
                                )}
                              </div>
                            )}
                            {menu && menu.view === "merge" && (
                              <div className="mt-spk-menu" role="menu" aria-label={`Merge ${g.name} into`}>
                                <div className="mt-menu-label">Give {g.name}'s lines to</div>
                                {byShare.filter((o) => o.key !== g.key).map((o) => (
                                  <button key={o.key} role="menuitem" className={`mt-spk-target c${o.color}`} onClick={() => { setRowMenu(null); mergeSpeaker(g, o); }}>
                                    <span className="mt-dot" aria-hidden="true" />{o.name}
                                  </button>
                                ))}
                                <button role="menuitem" className="mt-spk-back" onClick={() => setRowMenu({ key: g.key, view: "main" })}>‹ Back</button>
                              </div>
                            )}
                          </div>
                        );
                      })}
                      {allKnown && <div className="mt-spk-all">All voices recognized</div>}
                      <div className="mt-menu-sep" />
                      <div className="mt-menu-label">Known voices{known.length ? ` (${known.length})` : ""}</div>
                      <div className="mt-voices">
                        {known.length === 0 && (
                          <div className="mt-voices-empty">
                            None yet. Use ⋯ → <b>Remember this voice</b> on a named speaker: later meetings name them.
                          </div>
                        )}
                        {known.map((v) => (
                          <span key={`${v.family}/${v.name}`} className={`mt-voice ${forgetAsk === v.name ? "asking" : ""}`} title={`${v.name}: heard in ${v.meetings} meeting${v.meetings === 1 ? "" : "s"}`}>
                            <span className="mt-voice-name">{v.name}</span>
                            <span className="mt-voice-n">{v.meetings} meeting{v.meetings === 1 ? "" : "s"}</span>
                            {forgetAsk === v.name ? (
                              <span className="mt-voice-ask" role="group" aria-label={`Forget ${v.name}'s voice?`}>
                                <span>Forget {v.name}?</span>
                                <button className="danger" autoFocus onClick={() => forgetVoice(v.name)}>Forget</button>
                                <button onClick={() => setForgetAsk(null)}>Keep</button>
                              </span>
                            ) : (
                              <button title={`Forget ${v.name}'s voice`} aria-label={`Forget ${v.name}'s voice`} onClick={() => setForgetAsk(v.name)}>✕</button>
                            )}
                          </span>
                        ))}
                      </div>
                    </div>
                  )}
                </div>
              );
            })()}

            <div className="mt-toolbar">
              {!noSpeech && <div className="mt-tabs" role="tablist">
                <button role="tab" aria-selected={view === "transcript"} className={view === "transcript" ? "active" : ""} onClick={() => pickTab("transcript")}>
                  Transcript
                </button>
                <button role="tab" aria-selected={view === "final"} className={view === "final" ? "active" : ""} onClick={() => pickTab("final")}>
                  Clean text
                </button>
                <button role="tab" aria-selected={view === "summary"} className={view === "summary" ? "active" : ""} onClick={() => pickTab("summary")}>
                  Summary
                </button>
                <button role="tab" aria-selected={view === "notes"} className={view === "notes" ? "active" : ""} onClick={() => pickTab("notes")}>
                  Notes
                </button>
                <button role="tab" aria-selected={view === "chat"} className={view === "chat" ? "active" : ""} onClick={() => pickTab("chat")}>
                  Chat
                </button>
              </div>}
              {!noSpeech && (view === "transcript" || view === "final") && <div className="mt-find">
                <input
                  id="mt-find"
                  type="search"
                  placeholder="Find (Ctrl+F)"
                  value={find}
                  onChange={(e) => setFind(e.target.value)}
                  onKeyDown={(e: ReactKeyboardEvent<HTMLInputElement>) => {
                    if (e.key === "Enter" && matches.length) {
                      const after = matches.find((i) => i > (current < 0 ? -1 : current)) ?? matches[0];
                      seek(lines[after].start);
                      scrollToLine(after);
                    }
                  }}
                />
                {find.trim() && <span className="mt-find-count">{matches.length}</span>}
              </div>}
              {!noSpeech && (view === "transcript" || view === "final") && (
                <button className="mt-follow mt-follow-switch" role="switch" aria-checked={follow} aria-label="Follow playback"
                  title="Scroll to the line being played" onClick={() => setFollow(!follow)}>
                  <span className="switch-track" aria-hidden="true"><span className="switch-thumb" /></span>
                  <span>Follow</span>
                </button>
              )}
              {view === "summary" && meeting.summary && (
                <div className="mt-summary-actions">
                  <ReadButton id="summary" text={meeting.summary} className="mt-btn" />
                  <button className="mt-btn" disabled={!editable} onClick={() => rerun("summary")}>Summarize again</button>
                </div>
              )}
            </div>

            <MeetingNotes key={detail.folder} id={detail.id} folder={detail.folder} initial={detail.personalNotes ?? ""} hidden={view !== "notes"} />

            {view === "summary" && (
              <div className="mt-summary" ref={summaryRef}>
                {state === "summarizing" ? (
                  <div className="mt-empty">
                    Summarizing{liveState && liveState.progress > 0 ? ` (${Math.round(liveState.progress * 100)}%)` : ""}… A long meeting is read in parts, then
                    summarized as a whole. You can close this window meanwhile.
                  </div>
                ) : meeting.summary ? (
                  <div className={`mt-summary-layout ${summaryDoc.toc.length > 1 ? "has-toc" : ""}`}>
                    <article className="mt-summary-body" dangerouslySetInnerHTML={{ __html: summaryDoc.html }} />
                    {summaryDoc.toc.length > 1 && (
                      <nav className="mt-toc" aria-label="Summary sections">
                        <div className="mt-toc-title">On this page</div>
                        {summaryDoc.toc.map((t) => (
                          <button
                            key={t.id}
                            className={`mt-toc-item l${Math.min(t.level, 3)} ${activeToc === t.id ? "active" : ""}`}
                            aria-current={activeToc === t.id ? "location" : undefined}
                            onClick={() => { setActiveToc(t.id); document.getElementById(t.id)?.scrollIntoView({ behavior: "smooth", block: "start" }); }}
                          >
                            {t.text}
                          </button>
                        ))}
                      </nav>
                    )}
                  </div>
                ) : state === "asking" ? null : (
                  <div className="mt-empty">
                    <p>An overview, key points, decisions, action items and open questions, written by your AI profile.</p>
                    <button className="mt-btn mt-summarize" disabled={!editable || !meeting.segments.length} onClick={() => rerun("summary")}>
                      ✨ Summarize this meeting
                    </button>
                    {meeting.durationMs > 30 * 60 * 1000 && (
                      <p className="mt-hint">A long meeting: it's read in parts, so this takes a few minutes.</p>
                    )}
                  </div>
                )}

              </div>
            )}

            {view === "chat" && (
              <div className="mt-chat">
                <section className="mt-chat-shell" aria-label="Meeting chat">
                  <div className="mt-chat-history" role="log" aria-label="Conversation history" ref={chatHistoryRef}
                    onScroll={(e) => { const el = e.currentTarget; chatAtBottom.current = el.scrollHeight - el.scrollTop - el.clientHeight < 80; }}>
                  {!meeting.notes?.length && !pendingAnswers.length && (
                    <div className="mt-chat-empty">
                      <span className="mt-empty-symbol"><Icon name="chat" /></span>
                      <h3>Ask about this meeting</h3>
                      <p>
                        {meeting.segments.length
                          ? "Answers come from this meeting's transcript and your Notes tab. Questions and answers are saved with the meeting."
                          : "This meeting has no transcript yet, so answers can only use your Notes tab."}
                      </p>
                      <div className="mt-chat-model">
                        <span>Answered by</span>
                        {chatStatus?.active_profile ? <ModelPill status={chatStatus} /> : <span>your active AI profile</span>}
                      </div>
                      <div className="mt-ask-suggest">
                        {MEETING_QUESTIONS.map((q) => (
                          <button key={q} className="mt-chip" disabled={meeting.state === "recording"} onClick={() => { setAskDraft(q); document.querySelector<HTMLTextAreaElement>(".mt-ask-input")?.focus(); }}>
                            {q}
                          </button>
                        ))}
                      </div>
                    </div>
                  )}
                  {(meeting.notes ?? []).map((n) => (
                    <article key={n.id} className="mt-note">
                      <div className="mt-note-head">
                        <div className="mt-note-q">{n.prompt}</div>
                      </div>
                      <div className="mt-summary-body" dangerouslySetInnerHTML={{ __html: renderMarkdown(n.answer) }} />
                      <div className="mt-note-foot">
                        <div className="mt-note-actions">
                          <ReadButton id={n.id} text={`${n.prompt}\n\n${n.answer}`} className="mt-link" />
                          <button className="mt-link" onClick={() => copyText(`## ${n.prompt}\n\n${n.answer}`).then(() => flash("Answer copied"))}>Copy</button>
                          <button className="mt-link" onClick={() => { setAskReplace(n); setAskDraft(n.prompt); }}>Edit</button>
                          <button className="mt-link" onClick={() => askAbout(n.prompt, n.id)}>Ask again</button>
                          {confirmNote === n.id ? (
                            <button className="mt-link danger" onClick={() => deleteNote(n.id)}>Delete for good</button>
                          ) : (
                            <button className="mt-link danger" disabled={!editable} onClick={() => setConfirmNote(n.id)}>Delete</button>
                          )}
                        </div>
                        <div className="mt-note-meta">{n.askedAt ? new Date(n.askedAt).toLocaleString() : ""}</div>
                      </div>
                      <StatsForNerds stats={n.stats} />
                    </article>
                  ))}
                  {pendingAnswers.map((a, i) => (
                    <article key={`pending-${i}`} className="mt-note pending">
                      <div className="mt-note-q">{a.prompt}</div>
                      <MeetingChatProgressView progress={chatProgress?.prompt === a.prompt ? chatProgress : null} writing={liveAnswer?.prompt === a.prompt && !!liveAnswer.text} />
                      {liveAnswer?.prompt === a.prompt && liveAnswer.text && <div className="mt-summary-body" dangerouslySetInnerHTML={{ __html: renderMarkdown(liveAnswer.text) }} />}
                    </article>
                  ))}
                  </div>
                  <div className="mt-chat-composer">
                  <form
                    className="mt-ask-form"
                    onSubmit={(e) => {
                      e.preventDefault();
                      askAbout(askDraft, askReplace?.id ?? "");
                    }}
                  >
                    <textarea
                      className="mt-ask-input"
                      aria-label="Ask a question about this meeting…"
                      maxLength={4000}
                      rows={2}
                      value={askDraft}
                      placeholder={meeting.state === "recording" ? "Available once the recording is saved" : "Ask a question about this meeting…"}
                      disabled={meeting.state === "recording"}
                      onChange={(e) => setAskDraft(e.target.value)}
                      onKeyDown={(e) => {
                        if (e.key === "Enter" && !e.shiftKey) {
                          e.preventDefault();
                          askAbout(askDraft, askReplace?.id ?? "");
                        }
                        if (e.key === "Escape" && askReplace) {
                          setAskReplace(null);
                          setAskDraft("");
                        }
                      }}
                    />
                    <button className="mt-btn mt-ask-go" type="submit" disabled={!askDraft.trim() || meeting.state === "recording"} title={askDraft.trim() ? "Send (Enter)" : "Type a question first"}>
                      {askReplace ? "Ask again" : "Send"}
                    </button>
                  </form>
                  {askReplace && <div className="mt-hint">Replaces the answer to “{askReplace.prompt}”. Esc to cancel.</div>}

                  </div>
                </section>
              </div>
            )}

            <div
              hidden={view !== "transcript" && view !== "final"}
              className="mt-lines"
              ref={linesRef}
              onWheel={() => (userScrolledAt.current = Date.now())}
              onTouchMove={() => (userScrolledAt.current = Date.now())}
            >
              {lines.length === 0 && (
                <div className="mt-empty">
                  {view === "final" ? (
                    meeting.segments.length ? (
                      <>
                        No clean text yet.{" "}
                        {editable && (
                          <button className="mt-link" onClick={() => rerun("proofread")}>
                            Proofread now
                          </button>
                        )}
                      </>
                    ) : "The clean text comes after the transcript."
                  ) : busyState(meeting.state) ? "The transcript shows here once the meeting is transcribed." : (
                    <div className="mt-silent" onClick={(e) => e.stopPropagation()}>
                      <strong>No speech was found in this recording.</strong>
                      <p>The audio may have been silent, or the wrong input was recorded. You can:</p>
                      <div className="mt-silent-actions">
                        <button className="mt-btn" disabled={!editable || !detail.audio} onClick={() => rerun("transcribe")}>Transcribe again</button>
                        <button className="mt-btn" onClick={openMeetingSettings}>Check meeting settings</button>
                        <button className="mt-btn danger" disabled={!editable} onClick={() => setConfirmDelete(true)}>Delete this recording</button>
                      </div>
                      {confirmDelete && (
                        <div className="mt-silent-confirm">
                          Delete this recording for good?
                          <button className="mt-btn danger solid" onClick={remove}>Delete for good</button>
                          <button className="mt-btn" onClick={() => setConfirmDelete(false)}>Keep</button>
                        </div>
                      )}
                    </div>
                  )}
                </div>
              )}
              {lines.map((l, i) => {
                const active = i === current;
                const fraction = active && l.end > l.start ? (time - l.start) / (l.end - l.start) : 0;
                const prev = i > 0 ? lines[i - 1] : null;
                const newTurn = !prev || prev.speaker !== l.speaker;
                return (
                  <div
                    key={`${l.start}-${i}`}
                    data-line={i}
                    className={`mt-line ${active ? "active" : ""} ${newTurn ? "turn" : ""} ${matches.includes(i) ? "match" : ""}`}
                  >
                    <button className="mt-time" title="Play from here" onClick={() => seek(l.start, true)}>
                      {clock(l.start)}
                    </button>
                    <div className="mt-who" onClick={(e) => e.stopPropagation()}>
                      {newTurn && (
                        <button
                          className={`mt-who-name c${groupColor(l.speaker)}`}
                          disabled={!editable}
                          title="Change the speaker of this line"
                          onClick={() => setLineMenu(lineMenu === i ? null : i)}
                        >
                          {meeting.speakers.find((s) => s.id === l.speaker)?.name ?? l.speaker}
                        </button>
                      )}
                      {!newTurn && editable && (
                        <button className="mt-who-more" title="Change the speaker of this line" onClick={() => setLineMenu(lineMenu === i ? null : i)}>
                          ·
                        </button>
                      )}
                      {lineMenu === i && (
                        <div className="mt-menu">
                          <div className="mt-menu-label">This line is from</div>
                          {byShare.map((g) => (
                            <button key={g.key} className={g.ids.includes(l.speaker) ? "current" : ""} onClick={() => reassign(i, g.ids.includes(l.speaker) ? l.speaker : g.main)}>
                              {g.name}
                            </button>
                          ))}
                          <button onClick={() => reassign(i, "")}>+ A new speaker</button>
                        </div>
                      )}
                    </div>
                    {editingLine === i ? (
                      <textarea
                        className="mt-line-edit"
                        autoFocus
                        value={lineDraft}
                        rows={Math.max(2, Math.ceil(lineDraft.length / 80))}
                        onChange={(e) => setLineDraft(e.target.value)}
                        onBlur={() => saveLine(i)}
                        onKeyDown={(e) => {
                          if (e.key === "Enter" && !e.shiftKey) {
                            e.preventDefault();
                            (e.target as HTMLTextAreaElement).blur();
                          }
                          if (e.key === "Escape") setEditingLine(null);
                        }}
                      />
                    ) : (
                      <p
                        className="mt-text"
                        title={editable ? "Click to play from here · double-click to edit" : "Click to play from here"}
                        onClick={() => seek(l.start, true)}
                        onDoubleClick={() => {
                          if (!editable) return;
                          audioRef.current?.pause();
                          setLineDraft(l.text);
                          setEditingLine(i);
                        }}
                      >
                        {active && playing && !find ? (
                          timedWords(l) ? <TimedWords words={timedWords(l)!} time={time} /> : <SpokenWords text={l.text} fraction={fraction} />
                        ) : (
                          <Highlighted text={l.text} find={find.trim()} />
                        )}
                      </p>
                    )}
                  </div>
                );
              })}
            </div>

            {!(noSpeech && !detail.audio) && <footer className={`mt-player ${noSpeech ? "silent" : ""}`}>
              {detail.audio ? (
                <audio
                  ref={audioRef}
                  key={detail.audio}
                  src={detail.audio}
                  preload="metadata"
                  onPlay={() => setPlaying(true)}
                  onPause={(e) => { setPlaying(false); setTime(e.currentTarget.currentTime); }}
                  onEnded={(e) => { setPlaying(false); setTime(e.currentTarget.currentTime); }}
                  onTimeUpdate={(e) => { if (!playing) setTime(e.currentTarget.currentTime); }}
                  onLoadedMetadata={(e) => setLength(e.currentTarget.duration)}
                  onError={() => setAudioError("The recording can't be played (the file is missing, or the window can't reach it).")}
                />
              ) : null}
              <button className="mt-play" disabled={!detail.audio} onClick={toggle} title="Play/pause (Space)">
                {playing ? "❚❚" : "▶"}
              </button>
              <button className="mt-skip" disabled={!detail.audio} onClick={() => seek((audioRef.current?.currentTime ?? time) - 10)} title="Back 10 s (J)" aria-label="Back 10 seconds">
                −10 s
              </button>
              <button className="mt-skip" disabled={!detail.audio} onClick={() => seek((audioRef.current?.currentTime ?? time) + 10)} title="Forward 10 s (L)" aria-label="Forward 10 seconds">
                +10 s
              </button>
              <span className="mt-clock">{clock(time)}</span>
              {noSpeech ? <span className="mt-clock">/ {clock(meeting.durationMs / 1000 || length)}</span> : <>
              <input
                className="mt-seek"
                type="range"
                min={0}
                max={length || meeting.durationMs / 1000 || 0}
                step={0.1}
                value={time}
                disabled={!detail.audio}
                onChange={(e) => seek(Number(e.target.value))}
                aria-label="Position"
              />
              <span className="mt-clock">{clock(length || meeting.durationMs / 1000)}</span>
              <select className="mt-speed" value={speed} onChange={(e) => setSpeed(Number(e.target.value))} title="Playback speed" aria-label="Playback speed">
                {SPEEDS.map((s) => (
                  <option key={s} value={s}>
                    {s}×
                  </option>
                ))}
              </select>
              </>}
              {audioError && <span className="mt-audio-error">{audioError}</span>}
              {!detail.audio && meeting.state === "recording" && <span className="mt-audio-error">Recording…</span>}
            </footer>}
          </>
        )}
      </main>
    </div>
  );
}

/** Whether the page header shows (it hides at 720 px and below, styles.css). */
function useWideHeader(): boolean {
  const query = "(min-width: 721px)";
  const [wide, setWide] = useState(() => (typeof window.matchMedia === "function" ? window.matchMedia(query).matches : true));
  useEffect(() => {
    if (typeof window.matchMedia !== "function") return;
    const mq = window.matchMedia(query);
    const on = () => setWide(mq.matches);
    mq.addEventListener("change", on);
    return () => mq.removeEventListener("change", on);
  }, []);
  return wide;
}
