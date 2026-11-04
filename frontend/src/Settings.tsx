import PageHeader from "./PageHeader";
import { useEffect, useRef, useState, Fragment, type ChangeEvent, type InputHTMLAttributes, type KeyboardEvent } from "react";
import {
  Settings as SettingsType,
  Profile,
  CustomAction,
  CaptionsSettings,
  DictationSettings,
  OcrSettings,
  Status,
  CaptionsStatus,
  AudioDevice,
  getSettings,
  saveSettings,
  fetchModels,
  getStatus,
  hideWindow,
  captionsStatus,
  captionsListDevices,
  dictationListDevices,
  openCaptions,
  openMeetings,
  meetingsFolder,
  type MeetingsSettings,
  PRESETS,
  CAPTION_LANGUAGES,
  TRANSLATE_LANGUAGES,
  LocalLlmSettings,
  ServerSettings,
  isLocal,
  llmModelsStatus,
  LlmStatus,
  uiState,
  restartApp,
  ttsSpeak,
  isSystem,
  systemAiStatus,
  systemAiDownload,
  type SystemAiStatus,
} from "./api";
import WhisperModels, { whisperName } from "./WhisperModels";
import Voices, { sampleFor } from "./Voices";
import LocalModels, { CONTEXT_SIZES, DEFAULT_LOCAL, ctxLabel } from "./LocalModels";
import AboutUpdates from "./AboutUpdates";
import { singleWindow } from "./mode";

import { SECTIONS, type SettingsSection } from "./settingsSections";

function newProfile(): Profile {
  return {
    id: `profile-${Date.now()}`,
    name: "New profile",
    baseUrl: "http://localhost:11434/v1",
    apiKey: "",
    model: "",
    temperature: 0.2,
  };
}

/** A device picker's entries by readable name (Windows ids mean nothing),
 *  plus the saved choice when it isn't connected now. */
function DeviceOptions({ devices, selected }: { devices: AudioDevice[]; selected: string }) {
  const missing = selected !== "" && !devices.some((d) => d.name === selected);
  return (
    <>
      {devices.map((d) => (
        <option key={d.name} value={d.name}>
          {d.monitor ? `🔊 ${d.label}` : `🎙 ${d.label}`}
        </option>
      ))}
      {missing && <option value={selected}>{selected} (not connected)</option>}
    </>
  );
}

/** Whisper language codes by name; "auto" reads as what it does. */
const LANGUAGE_NAMES: Record<string, string> = {
  auto: "Auto-detect", en: "English", es: "Spanish", fr: "French", de: "German", it: "Italian",
  pt: "Portuguese", nl: "Dutch", zh: "Chinese", ja: "Japanese", ko: "Korean", ru: "Russian", ar: "Arabic",
};

/** Captions' translation as one choice: off, English by Whisper, or another language by the AI profile. */
type TranslateMode = "off" | "english" | "other";

/** A key combo as the shortcut fields write it ("Ctrl+Shift+A"), or null when the key isn't a
 *  combo worth capturing (plain typing, Super combos and unnamed keys are left to the field). */
function comboFrom(e: KeyboardEvent): string | null {
  if (e.metaKey || !(e.ctrlKey || e.altKey)) return null;
  const key = /^Key([A-Z])$/.test(e.code) ? e.code.slice(3) : /^Digit(\d)$/.test(e.code) ? e.code.slice(5) : /^F\d{1,2}$/.test(e.code) ? e.code : null;
  if (!key) return null;
  return [e.ctrlKey && "Ctrl", e.altKey && "Alt", e.shiftKey && "Shift", key].filter(Boolean).join("+");
}

type Fields = Record<string, unknown>;
const isObject = (v: unknown): v is Fields => typeof v === "object" && v !== null && !Array.isArray(v);
const same = (a: unknown, b: unknown) => JSON.stringify(a) === JSON.stringify(b);

/** `fresh` (the settings saved now) with only what the form changed since
 *  `base` (what it loaded): edits made elsewhere meanwhile (the overlays'
 *  toggles, another window) survive. One level into objects, lists whole. */
function mergeChanges(fresh: SettingsType, base: SettingsType, form: SettingsType): SettingsType {
  const out: Fields = { ...(fresh as unknown as Fields) };
  const f = form as unknown as Fields;
  const b = base as unknown as Fields;
  for (const k of Object.keys(f)) {
    const fv = f[k];
    const bv = b[k];
    if (same(fv, bv)) continue;
    const cur = out[k];
    if (isObject(fv) && isObject(bv) && isObject(cur)) {
      const sub: Fields = { ...cur };
      for (const sk of Object.keys(fv)) if (!same(fv[sk], bv[sk])) sub[sk] = fv[sk];
      out[k] = sub;
    } else out[k] = fv;
  }
  return out as unknown as SettingsType;
}

const errorText = (e: unknown) => (e instanceof Error ? e.message : String(e));

/** How long a change waits before it is saved: text and sliders keep changing while they are
 *  used, so they wait for a pause; a checkbox or a choice is final at once. */
const SAVE_AFTER_TYPING_MS = 700;
const SAVE_AFTER_CHOICE_MS = 200;

/** Which kind of control changed: typing and sliders save after a pause, choices almost at once. */
const isTypedControl = (el: EventTarget) =>
  el instanceof HTMLTextAreaElement ||
  (el instanceof HTMLInputElement && !["checkbox", "radio"].includes(el.type));

/**
 * A field that keeps what is typed to itself and hands it over when it is finished (blur or Enter),
 * so half a shortcut or half a port number is never saved: saving re-registers the shortcuts.
 * With `captureCombo` a pressed key combo ("Ctrl+Shift+A") is finished at once.
 * `onCommit` returns false for a value it refuses: the field goes back to the saved one.
 */
function DraftInput({
  value,
  onCommit,
  captureCombo,
  ...rest
}: Omit<InputHTMLAttributes<HTMLInputElement>, "value" | "onChange" | "onBlur" | "onKeyDown"> & {
  value: string;
  onCommit: (v: string) => boolean | void;
  captureCombo?: boolean;
}) {
  const [draft, setDraft] = useState(value);
  useEffect(() => setDraft(value), [value]);
  const commit = (v: string) => {
    if (v === value) return;
    if (onCommit(v) === false) setDraft(value);
  };
  return (
    <input
      {...rest}
      value={draft}
      onChange={(e: ChangeEvent<HTMLInputElement>) => setDraft(e.target.value)}
      onBlur={() => commit(draft)}
      onKeyDown={(e) => {
        const combo = captureCombo ? comboFrom(e) : null;
        if (combo) {
          e.preventDefault();
          setDraft(combo);
          commit(combo);
        } else if (e.key === "Enter") e.currentTarget.blur();
        else if (e.key === "Escape") setDraft(value);
      }}
    />
  );
}

const START_DISMISSED_KEY = "ghostpen-settings-start-dismissed";

/** The first-run card at the top of the AI profile page: the hotkey, a model, and where
 *  the speech tools live. Dismissed for good once closed (localStorage). */
function GettingStarted({ hotkey, hotkeysUnavailable, android, goTo }: {
  hotkey: string;
  hotkeysUnavailable: boolean;
  android: boolean;
  goTo: (id: SettingsSection) => void;
}) {
  const [hidden, setHidden] = useState(() => {
    try { return localStorage.getItem(START_DISMISSED_KEY) === "1"; } catch { return false; }
  });
  if (hidden) return null;
  const dismiss = () => {
    setHidden(true);
    try { localStorage.setItem(START_DISMISSED_KEY, "1"); } catch { /* Storage may be unavailable. */ }
  };
  const link = (id: SettingsSection, label: string) => (
    <button className="link-btn" type="button" onClick={() => goTo(id)}>{label}</button>
  );
  return (
    <section className="pg-start settings-start" aria-label="Getting started">
      <button type="button" className="settings-start-close" onClick={dismiss} aria-label="Dismiss getting started" title="Dismiss">×</button>
      <h2>Getting started</h2>
      <ol>
        <li>
          Pick a profile below, or download a model under {link("models", "Built-in models")}.
        </li>
        {android ? (
          <li>Paste text in Playground and pick an action.</li>
        ) : (
          <li>
            Select text in any app, then{" "}
            {hotkeysUnavailable ? <>run <code>ghostpen --trigger</code> (bind it to a key in your desktop)</> : <>press <kbd>{hotkey}</kbd></>}
            {" "}and pick an action.
          </li>
        )}
        <li>
          Speech tools: {link("captions", "Captions")}, {link("dictation", "Dictation")} and {link("meetings", "Meetings")} each have a page under Speech.
        </li>
      </ol>
    </section>
  );
}

export default function Settings() {
  const [settings, setSettings] = useState<SettingsType | null>(null);
  // The settings as last loaded or saved: what a save diffs the form against.
  const [base, setBase] = useState<SettingsType | null>(null);
  const [loadError, setLoadError] = useState("");
  const [status, setStatus] = useState<Status | null>(null);
  const [models, setModels] = useState<string[]>([]);
  const [modelMsg, setModelMsg] = useState<string>("");
  // Changes save by themselves. `dirty`: edits not saved yet (waiting out their pause, or being
  // saved); `saveError.retry`: a failed save can be tried again (a hotkey that didn't register
  // is not one: the settings were saved).
  const [saveError, setSaveError] = useState<{ text: string; retry: boolean } | null>(null);
  const [dirty, setDirty] = useState(false);
  const [saving, setSaving] = useState(false);
  const failWith = (e: unknown) => setSaveError({ text: errorText(e), retry: false });
  // In the single app window the section is in the hash (#/settings/<id>): the app
  // sidebar lists the sections and goes to them.
  const sectionInHash = (): SettingsSection | null => {
    const id = window.location.hash.match(/^#\/settings\/(\w+)/)?.[1];
    return SECTIONS.some((x) => x.id === id) ? (id as SettingsSection) : null;
  };
  const [section, setSectionState] = useState<SettingsSection>(() => (singleWindow && sectionInHash()) || "ai");
  const setSection = (id: SettingsSection) => {
    // Sections are one screen for back: switching replaces, it doesn't add.
    if (singleWindow) window.location.replace("#/settings/" + id);
    else setSectionState(id);
  };
  useEffect(() => {
    if (!singleWindow) return;
    const onHash = () => {
      const id = sectionInHash();
      if (id) setSectionState(id);
    };
    window.addEventListener("hashchange", onHash);
    return () => window.removeEventListener("hashchange", onHash);
  }, []);
  const [capStatus, setCapStatus] = useState<CaptionsStatus | null>(null);
  const [defaultMeetingsDir, setDefaultMeetingsDir] = useState("");
  const [android, setAndroid] = useState(false);
  /** The layout GhostPen started with (a saved change applies after a restart). */
  const [runningLayout, setRunningLayout] = useState<"single" | "windows" | null>(null);
  const [systemAi, setSystemAi] = useState<SystemAiStatus | null>(null);
  const refreshSystemAi = () => systemAiStatus().then(setSystemAi).catch(() => {});
  useEffect(() => {
    uiState().then((u) => {
      setAndroid(u.android);
      setRunningLayout(u.single ? "single" : "windows");
    }).catch(() => {});
    refreshSystemAi();
  }, []);
  const downloadSystemAi = async () => {
    setSystemAi((s) => (s ? { ...s, state: "downloading" } : s));
    try {
      await systemAiDownload();
    } catch (e) {
      console.warn("system ai download:", e);
    }
    refreshSystemAi();
  };
  const [capDevices, setCapDevices] = useState<AudioDevice[]>([]);
  const [dictDevices, setDictDevices] = useState<AudioDevice[]>([]);
  const [llm, setLlm] = useState<LlmStatus | null>(null);
  // The form's latest state and what it loaded, kept in refs too: a save that runs after a pause
  // (or when the window is left) must see edits made a moment ago, not the render it started in.
  const settingsRef = useRef<SettingsType | null>(null);
  const baseRef = useRef<SettingsType | null>(null);
  // Edits not saved yet; also what the focus handler checks: an untouched form follows changes made elsewhere.
  const dirtyRef = useRef(false);
  const saveTimer = useRef<number | undefined>(undefined);
  const running = useRef<Promise<void> | null>(null);
  const rerun = useRef(false);
  // The pause for the next edit, set by the control that changed (see `onChangeCapture` below).
  const pauseRef = useRef(SAVE_AFTER_CHOICE_MS);
  // The profile whose "Delete" is waiting for a second click, and the same for a custom action.
  const [confirmDeleteProfile, setConfirmDeleteProfile] = useState<string | null>(null);
  const [confirmDeleteAction, setConfirmDeleteAction] = useState<string | null>(null);

  const loadSettings = () =>
    getSettings()
      .then((s) => {
        settingsRef.current = s;
        baseRef.current = s;
        setSettings(s);
        setBase(s);
        setLoadError("");
      })
      .catch((e) => setLoadError(errorText(e)));

  /**
   * Save what the form changed. On top of the settings saved now, only the fields edited here: a
   * form opened earlier doesn't undo what changed elsewhere since (the overlays' toggles, another
   * window). Edits made while a save runs are saved right after it. The backend can reject after
   * saving (e.g. a hotkey that didn't register): that is shown, but isn't retried.
   */
  const persist = (): Promise<void> => {
    window.clearTimeout(saveTimer.current);
    saveTimer.current = undefined;
    if (running.current) {
      rerun.current = true;
      return running.current;
    }
    const run = async () => {
      setSaving(true);
      try {
        do {
          rerun.current = false;
          const form = settingsRef.current;
          const from = baseRef.current;
          if (!dirtyRef.current || !form) break;
          if (from && same(form, from)) {
            // Edited and put back: nothing to save.
            dirtyRef.current = false;
            setDirty(false);
            break;
          }
          let warning = "";
          try {
            const fresh = await getSettings();
            const next = from ? mergeChanges(fresh, from, form) : form;
            try {
              await saveSettings(next);
            } catch (e) {
              const message = errorText(e);
              if (!message.startsWith("Settings saved, but")) throw e;
              warning = message;
            }
            if (settingsRef.current === form) {
              settingsRef.current = next;
              baseRef.current = next;
              setSettings(next);
              setBase(next);
              dirtyRef.current = false;
              setDirty(false);
            } else {
              // Edited meanwhile: what was saved is the base for the next round.
              baseRef.current = form;
              setBase(form);
              rerun.current = true;
            }
            setSaveError(warning ? { text: warning, retry: false } : null);
          } catch (e) {
            setSaveError({ text: errorText(e), retry: true });
            break;
          }
        } while (rerun.current);
      } finally {
        setSaving(false);
        running.current = null;
      }
      getStatus().then(setStatus).catch(() => {});
    };
    running.current = run();
    return running.current;
  };
  /** Save after `ms` of no further edits (each edit starts the wait again). */
  const saveSoon = (ms: number) => {
    window.clearTimeout(saveTimer.current);
    saveTimer.current = window.setTimeout(() => void persist(), ms);
  };
  // Leaving the window or the page must not lose an edit that is still waiting.
  useEffect(() => {
    const flush = () => {
      if (dirtyRef.current && !running.current) void persist();
    };
    const onHide = () => document.visibilityState === "hidden" && flush();
    window.addEventListener("blur", flush);
    window.addEventListener("pagehide", flush);
    document.addEventListener("visibilitychange", onHide);
    return () => {
      window.removeEventListener("blur", flush);
      window.removeEventListener("pagehide", flush);
      document.removeEventListener("visibilitychange", onHide);
      flush();
    };
  }, []);

  useEffect(() => {
    loadSettings();
    // The window is only hidden on close: re-read the live state each time
    // it is shown again, and the settings too while the form is unedited.
    const refresh = () => {
      if (!dirtyRef.current) loadSettings();
      getStatus().then(setStatus).catch(() => {});
      captionsStatus().then(setCapStatus).catch(() => {});
      captionsListDevices().then(setCapDevices).catch(() => {});
      meetingsFolder().then(setDefaultMeetingsDir).catch(() => {});
      dictationListDevices().then(setDictDevices).catch(() => {});
      llmModelsStatus().then(setLlm).catch(() => {});
    };
    refresh();
    window.addEventListener("focus", refresh);
    return () => window.removeEventListener("focus", refresh);
  }, []);

  if (!settings)
    return loadError ? (
      <div className="settings loading-page" role="alert">
        <p>Could not load the settings: {loadError}</p>
        <button className="btn" type="button" onClick={() => { setLoadError(""); loadSettings(); }}>Try again</button>
      </div>
    ) : (
      <div className="settings loading-page">Loading…</div>
    );

  const active =
    settings.profiles.find((p) => p.id === settings.activeProfileId) ?? settings.profiles[0];

  // On Wayland the app can't grab global keys — the compositor owns the binds, so the
  // shortcut fields become "recommended binding" reference rather than something we register.
  const onWayland = status?.session?.includes("Wayland") ?? false;

  /** Apply an edit and save it soon: after the pause the changed control asked for, or `ms`. */
  const update = (patch: Partial<SettingsType>, ms?: number) => {
    const next = { ...(settingsRef.current ?? settings), ...patch };
    settingsRef.current = next;
    setSettings(next);
    dirtyRef.current = true;
    setDirty(true);
    setSaveError(null);
    saveSoon(ms ?? pauseRef.current);
    pauseRef.current = SAVE_AFTER_CHOICE_MS;
  };

  const updateProfile = (id: string, patch: Partial<Profile>, ms?: number) => {
    // From the latest state: "Find models" finishes long after the render that started it.
    const profiles = (settingsRef.current ?? settings).profiles;
    update({ profiles: profiles.map((p) => (p.id === id ? { ...p, ...patch } : p)) }, ms);
  };

  const addProfile = () => {
    const p = newProfile();
    update({ profiles: [...settings.profiles, p], activeProfileId: p.id });
  };

  const deleteProfile = (id: string) => {
    if (settings.profiles.length <= 1) return;
    const profiles = settings.profiles.filter((p) => p.id !== id);
    // Gone at once: its confirmation was the step before.
    update({
      profiles,
      activeProfileId:
        settings.activeProfileId === id ? profiles[0].id : settings.activeProfileId,
    }, 0);
  };

  const applyPreset = (name: string) => {
    const preset = PRESETS.find((p) => p.name === name);
    if (!preset || !active) return;
    updateProfile(active.id, {
      name: preset.name === "Custom" ? active.name : preset.name,
      baseUrl: preset.baseUrl || active.baseUrl,
      model: preset.exampleModel || active.model,
    });
    setModels([]);
    setModelMsg("");
  };

  const doFetchModels = async () => {
    if (!active) return;
    setModelMsg("Fetching…");
    setModels([]);
    try {
      const list = await fetchModels(active.baseUrl, active.apiKey);
      setModels(list);
      setModelMsg(`${list.length} model${list.length === 1 ? "" : "s"} found`);
      // If the current model isn't actually available, select the first real one.
      if (list.length > 0 && !list.includes(active.model)) {
        updateProfile(active.id, { model: list[0] });
      }
    } catch (e) {
      setModelMsg(String(e));
    }
  };

  // ---- built-in models (GhostPen runs them) ----
  // Defaults fill in what older saved settings don't have (moeCpu).
  const local = { ...DEFAULT_LOCAL, ...settings.localLlm };
  const updateLocal = (patch: Partial<LocalLlmSettings>) => update({ localLlm: { ...local, ...patch } });
  // ---- model & speech service ----
  const server: ServerSettings = settings.server ?? { host: "127.0.0.1", port: 8771 };
  const updateServer = (patch: Partial<ServerSettings>) => update({ server: { ...server, ...patch } });
  // The active profile when it's a built-in one, else the first built-in one.
  const localProfile = isLocal(active) ? active : settings.profiles.find((p) => isLocal(p));
  /** Installed built-in models, for the profile's model picker. */
  const localChoices = [
    ...(llm?.status.models.filter((m) => m.path !== "").map((m) => ({ id: m.id, name: m.name })) ?? []),
    ...(llm?.status.others.map((o) => ({ id: o.id, name: o.name })) ?? []),
  ];

  // "Use" in Built-in models: point the built-in profile at the model
  // (creating the profile if needed) and make it active.
  const useLocalModel = (id: string) => {
    const profiles = settings.profiles;
    const targetId = localProfile?.id ?? "built-in";
    update({
      profiles: localProfile
        ? profiles.map((p) => (p.id === localProfile.id ? { ...p, model: id } : p))
        : [...profiles, { id: "built-in", name: "Built-in (GhostPen)", provider: "local" as const, baseUrl: "", apiKey: "", model: id, temperature: 0.2 }],
      activeProfileId: targetId,
    }, 0);
  };

  const customActions = settings.customActions ?? [];

  const addCustomAction = () => {
    const a: CustomAction = {
      id: `action-${Date.now()}`,
      label: "My action",
      prompt: "Rewrite the text. Return ONLY the result, with no explanations.",
      model: "",
    };
    update({ customActions: [...customActions, a] });
  };

  const updateCustomAction = (id: string, patch: Partial<CustomAction>) => {
    update({ customActions: customActions.map((a) => (a.id === id ? { ...a, ...patch } : a)) });
  };

  const deleteCustomAction = (id: string) => {
    setConfirmDeleteAction(null);
    update({ customActions: customActions.filter((a) => a.id !== id) }, 0);
  };

  const captions = settings.captions;
  const updateCaptions = (patch: Partial<CaptionsSettings>, ms?: number) => {
    update({ captions: { ...captions, ...patch } }, ms);
  };

  const meetingsCfg: MeetingsSettings = settings.meetings ?? { enabled: false, dir: "", mic: true, proofread: true, speakers: true, speakerModel: "", expectedSpeakers: 0, liveSpeakers: true };
  const updateMeetings = (patch: Partial<MeetingsSettings>, ms?: number) => {
    update({ meetings: { ...meetingsCfg, ...patch } }, ms);
  };

  const dictation = settings.dictation;
  const updateDictation = (patch: Partial<DictationSettings>) => {
    update({ dictation: { ...dictation, ...patch } });
  };

  const ocr = settings.ocr ?? { maxDimension: 1024, systemPrompt: "", modelOverride: "" };
  const updateOcr = (patch: Partial<OcrSettings>) => {
    update({ ocr: { ...ocr, ...patch } });
  };

  // Captions and dictation share this model.
  const useWhisperModel = async (id: string) => {
    updateCaptions({ model: id }, 0);
    await persist();
    captionsStatus().then(setCapStatus).catch(() => {});
  };

  const setAutoUpdate = (on: boolean) => update({ autoUpdate: on });

  // Closing waits for the last edit to be saved; if that fails the window stays, with the reason.
  const closeSettings = async () => {
    await persist();
    if (dirtyRef.current) return;
    await hideWindow();
  };

  const currentSection = SECTIONS.find((item) => item.id === section) ?? SECTIONS[0];
  const goTo = (id: SettingsSection) => { setSection(id); window.scrollTo(0, 0); };
  // About has little to save: no save status there unless a save is under way or failed, and in
  // the app window (nothing to close) no footer at all.
  const aboutIdle = section === "about" && !dirty && !saving && !saveError;
  const showFooter = !aboutIdle || !singleWindow;

  const translateMode: TranslateMode = captions.aiTranslate ? "other" : captions.whisperTranslate ? "english" : "off";
  const setTranslateMode = (mode: TranslateMode) =>
    updateCaptions({ whisperTranslate: mode === "english", aiTranslate: mode === "other" });
  const speakersOn = meetingsCfg.speakers ?? true;
  // Only the one-window layout has a choice of floating or not; a window per tool always floats.
  const oneWindow = (settings.interfaceMode ?? "windows") === "single";
  /** A shortcut field: types as usual (saved when you leave it), or takes a key combo pressed in it. */
  const shortcutField = (value: string, onChange: (v: string) => void, placeholder: string) => (
    <DraftInput
      className="shortcut-input"
      value={value}
      placeholder={placeholder}
      spellCheck={false}
      autoComplete="off"
      captureCombo
      onCommit={onChange}
    />
  );

  return (
    <div className="settings">
      <div className="settings-shell">
        <PageHeader
          className="settings-header"
          title="Settings"
          subtitle="Choose the AI, the speech models and how GhostPen behaves."
          status={status}
          onPillClick={() => goTo("ai")}
        />

        <div className="settings-layout">
          <nav className="settings-nav" aria-label="Settings sections">
            {SECTIONS.map((item, i) => (
              <Fragment key={item.id}>
                {SECTIONS[i - 1]?.group !== item.group && <div className="settings-nav-group">{item.group}</div>}
                <button
                  type="button"
                  className={`settings-nav-item ${section === item.id ? "active" : ""}`}
                  aria-current={section === item.id ? "page" : undefined}
                  onClick={() => goTo(item.id)}
                >
                  <span>{item.label}</span>
                  <small>{item.hint}</small>
                </button>
              </Fragment>
            ))}
          </nav>

          <main
            className="settings-main"
            onChangeCapture={(e) => { pauseRef.current = isTypedControl(e.target) ? SAVE_AFTER_TYPING_MS : SAVE_AFTER_CHOICE_MS; }}
          >
            <header className="settings-section-header">
              <h2>{currentSection.label}</h2>
              <p>{currentSection.description}</p>
            </header>

      <div className="settings-panel" hidden={section !== "ai"}>
      <GettingStarted hotkey={settings.hotkey} hotkeysUnavailable={!!status?.hotkeys_unavailable} android={android} goTo={goTo} />

      {/* Profiles */}
      <div className="settings-grid">
      <section className="card">
        <h2>Choose a profile</h2>
        <div className="profile-tabs">
          {settings.profiles.map((p) => (
            <button
              key={p.id}
              type="button"
              className={`tab ${p.id === settings.activeProfileId ? "active" : ""}`}
              aria-pressed={p.id === settings.activeProfileId}
              onClick={() => update({ activeProfileId: p.id })}
            >
              {p.name}
            </button>
          ))}
          <button className="tab add" type="button" onClick={addProfile}>+ New profile</button>
        </div>

        {active && (
          <>
            <div className="settings-field-title">Where should the AI run?</div>
            <div className="settings-provider-options" role="group" aria-label="AI provider">
              <label className={`settings-provider-option ${!isLocal(active) && !isSystem(active) ? "selected" : ""}`}>
                <input type="radio" name="ai-provider" checked={!isLocal(active) && !isSystem(active)}
                  onChange={() => updateProfile(active.id, { provider: "openai", baseUrl: active.baseUrl || "http://localhost:11434/v1", model: "" })} />
                <span><strong>Connected service</strong><small>Use Ollama, LM Studio, or a cloud provider</small></span>
              </label>
              <label className={`settings-provider-option ${isLocal(active) ? "selected" : ""}`}>
                <input type="radio" name="ai-provider" checked={isLocal(active)}
                  onChange={() => updateProfile(active.id, { provider: "local", model: localChoices[0]?.id ?? "" })} />
                <span><strong>Built-in model</strong><small>Run on this {android ? "device" : "computer"} without another service</small></span>
              </label>
              {systemAi?.built && (
                <label className={`settings-provider-option ${isSystem(active) ? "selected" : ""}`}>
                  <input type="radio" name="ai-provider" checked={isSystem(active)}
                    onChange={() => updateProfile(active.id, { provider: "system", model: "gemini-nano" })} />
                  <span><strong>On this device</strong><small>The phone’s own model (Gemini Nano), nothing to set up</small></span>
                </label>
              )}
            </div>
          </>
        )}
      </section>

      {active && (
      <section className="card profile-form">
        <h2>Settings for “{active.name}”</h2>
            {isSystem(active) ? (
              <>
                <label>
                  Profile name
                  <input value={active.name} onChange={(e) => updateProfile(active.id, { name: e.target.value })} />
                </label>
                <div className="settings-callout">
                  <span>
                    {systemAi?.state === "available"
                      ? "Gemini Nano is ready on this device."
                      : systemAi?.state === "downloadable"
                        ? "This device can run Gemini Nano once it's downloaded."
                        : systemAi?.state === "downloading"
                          ? "The device is downloading Gemini Nano…"
                          : `Not available here${systemAi?.reason ? `: ${systemAi.reason}` : "."}`}
                  </span>
                  {systemAi?.state === "downloadable" && (
                    <button className="btn" type="button" onClick={downloadSystemAi}>Download</button>
                  )}
                  {systemAi?.state === "downloading" && (
                    <button className="btn" type="button" onClick={refreshSystemAi}>Check again</button>
                  )}
                </div>
              </>
            ) : isLocal(active) ? (
              <>
                <label>
                  Profile name
                  <input value={active.name} onChange={(e) => updateProfile(active.id, { name: e.target.value })} />
                </label>
                <label>
                  Model
                  <select value={active.model} onChange={(e) => updateProfile(active.id, { model: e.target.value })}>
                    {!localChoices.some((c) => c.id === active.model) && (
                      <option value={active.model}>{active.model ? `${active.model} (not downloaded)` : "Choose a model…"}</option>
                    )}
                    {localChoices.map((c) => <option key={c.id} value={c.id}>{c.name}</option>)}
                  </select>
                  <span className="muted small">Only downloaded models appear here.</span>
                </label>
                <div className="settings-callout">
                  <span>{localChoices.length === 0 ? "No built-in models are ready yet." : "Need a different model?"}</span>
                  <button className="btn" type="button" onClick={() => goTo("models")}>Browse built-in models</button>
                </div>
              </>
            ) : (
            <>
            <label>
              Start from a preset
              <select key={active.id} defaultValue="" onChange={(e) => applyPreset(e.target.value)}>
                <option value="" disabled>Choose a preset…</option>
                {PRESETS.map((p) => (
                  <option key={p.name} value={p.name}>{p.name}</option>
                ))}
              </select>
            </label>
            <label>
              Profile name
              <input value={active.name} onChange={(e) => updateProfile(active.id, { name: e.target.value })} />
            </label>
            <label>
              Service URL
              <input value={active.baseUrl} onChange={(e) => updateProfile(active.id, { baseUrl: e.target.value })} placeholder="http://localhost:11434/v1" />
            </label>
            <label>
              API key
              <input type="password" value={active.apiKey} onChange={(e) => updateProfile(active.id, { apiKey: e.target.value })} placeholder="sk-…" />
              <span className="muted small">Leave blank when the service needs no key.</span>
            </label>
            <label>
              Model
              <div className="row">
                <input value={active.model} onChange={(e) => updateProfile(active.id, { model: e.target.value })} placeholder="gemma4:e4b" />
                <button className="btn" type="button" onClick={doFetchModels}>Find models</button>
              </div>
              {models.length > 0 && (
                <select
                  value={models.includes(active.model) ? active.model : ""}
                  onChange={(e) => updateProfile(active.id, { model: e.target.value })}
                >
                  <option value="" disabled>Pick a fetched model…</option>
                  {models.map((m) => <option key={m} value={m}>{m}</option>)}
                </select>
              )}
              {modelMsg && <span className="muted small" role="status">{modelMsg}</span>}
            </label>
            </>
            )}
            <label>
              Temperature: {active.temperature.toFixed(2)}
              <input type="range" min={0} max={1} step={0.05} value={active.temperature}
                onChange={(e) => updateProfile(active.id, { temperature: parseFloat(e.target.value) })} />
              <span className="muted small">Lower is more predictable; higher allows more variation.</span>
            </label>
            {settings.profiles.length > 1 && (
              <div className="settings-danger-zone">
                {confirmDeleteProfile === active.id ? (
                  <>
                    <span>Delete “{active.name}”? This can’t be undone.</span>
                    <button className="btn danger solid" type="button" onClick={() => { setConfirmDeleteProfile(null); deleteProfile(active.id); }}>Yes, delete profile</button>
                    <button className="btn" type="button" onClick={() => setConfirmDeleteProfile(null)}>Keep it</button>
                  </>
                ) : (
                  <button className="btn danger" type="button" onClick={() => setConfirmDeleteProfile(active.id)}>Delete profile…</button>
                )}
              </div>
            )}
      </section>
      )}
      </div>

      </div>

      <div className="settings-panel" hidden={section !== "voices"}>
      {android && (
        <section className="card">
          <h2>Who reads aloud</h2>
          <label>
            Voice
            <select value={settings.voiceEngine ?? "auto"} onChange={(e) => update({ voiceEngine: e.target.value as "auto" | "kokoro" | "system" })}>
              <option value="auto">Automatic: this device’s voices until a Kokoro model is downloaded</option>
              <option value="system">This device’s voices (nothing to download)</option>
              <option value="kokoro">Kokoro (the voices below, offline)</option>
            </select>
          </label>
          <button className="btn" type="button" onClick={() => ttsSpeak(sampleFor("en"), "en-us", "system").catch(failWith)}>
            ▶ Play this device’s voice
          </button>
        </section>
      )}
      <Voices />
      </div>

      <div className="settings-panel" hidden={section !== "models"}>
      <LocalModels
        local={local}
        onLocalChange={updateLocal}
        activeModel={isLocal(active) ? active.model : null}
        onUse={(id) => useLocalModel(id)}
        onChanged={() => llmModelsStatus().then(setLlm).catch(() => {})}
      />
      </div>

      <div className="settings-panel" hidden={section !== "actions"}>

      {/* Shortcuts */}
      <section className="card">
        <h2>Keyboard shortcuts</h2>
        <p className="muted small">
          {status?.hotkeys_unavailable ? (
            <>No global shortcuts on this desktop: bind <code>ghostpen --trigger</code>, <code>--voice-input</code>, <code>--captions</code>, <code>--meetings</code> and <code>--summary</code> in its settings.</>
          ) : onWayland ? (
            <>Registered through your desktop’s shortcuts portal; it may ask you to confirm. Blank means unbound.</>
          ) : (
            <>Click a field and press the keys, with Ctrl or Alt. Blank means unbound.</>
          )}
        </p>

        <label>
          Action menu
          {shortcutField(settings.hotkey, (v) => update({ hotkey: v }), "Ctrl+Shift+A")}
        </label>
        <label>
          Dictation
          {shortcutField(settings.dictationHotkey, (v) => update({ dictationHotkey: v }), "Ctrl+Shift+D")}
        </label>
        <label>
          Live captions
          {shortcutField(settings.captionsHotkey, (v) => update({ captionsHotkey: v }), "Ctrl+Shift+L")}
        </label>
        <label>
          Open Meetings
          {shortcutField(settings.meetingsHotkey ?? "", (v) => update({ meetingsHotkey: v }), "Not set")}
        </label>
        <label>
          Open Summarize a link
          {shortcutField(settings.summaryHotkey ?? "", (v) => update({ summaryHotkey: v }), "Not set")}
        </label>
      </section>

      <section className="card">
        <h2>Action results</h2>
        <label>
          After an action
          <select value={settings.afterAction ?? "paste"}
            onChange={(e) => update({ afterAction: e.target.value as "paste" | "show" })}>
            <option value="paste">Paste the result over the selection</option>
            <option value="show">Show the result in the menu (with Copy)</option>
          </select>
        </label>
        <p className="muted small">Hold <kbd>Shift</kbd> when you pick an action to get the other one, e.g. to translate text you can't edit (a web page, a chat).</p>
        <details className="settings-advanced">
          <summary><span>Advanced: copy and paste</span></summary>
          <div className="settings-advanced-body">
            <label className="checkbox">
              <input type="checkbox" checked={settings.forceSynthetic}
                onChange={(e) => update({ forceSynthetic: e.target.checked })} />
              <span>Force synthetic copy/paste on Wayland<span className="checkbox-help">Needs libei. Off means you copy by hand.</span></span>
            </label>
            <label>
              Clipboard restore delay (ms)
              <input type="number" min={0} max={2000} value={settings.restoreDelayMs}
                onChange={(e) => update({ restoreDelayMs: parseInt(e.target.value || "0", 10) })} />
            </label>
          </div>
        </details>
      </section>

      {/* Custom actions */}
      <section className="card">
        <h2>Custom actions</h2>
        {customActions.length === 0 && (
          <p className="muted small">None yet. Add one to define your own prompt — it appears in the menu and Playground.</p>
        )}
        {customActions.map((a, index) => (
          <div key={a.id} className="custom-action">
            <h3>Action {index + 1}</h3>
            <label>
              Name
              <input
                value={a.label}
                placeholder="e.g. Bullet points"
                onChange={(e) => updateCustomAction(a.id, { label: e.target.value })}
              />
            </label>
            <label>
              Instruction
              <textarea
                value={a.prompt}
                placeholder="e.g. Convert the text into concise bullet points. Return only the bullets."
                onChange={(e) => updateCustomAction(a.id, { prompt: e.target.value })}
              />
            </label>
            <label>
              Model override <span className="muted">(optional)</span>
              <input
                value={a.model}
                placeholder="Blank uses the selected profile's model"
                onChange={(e) => updateCustomAction(a.id, { model: e.target.value })}
              />
            </label>
            {confirmDeleteAction === a.id ? (
              <div className="settings-danger-zone">
                <span>Delete “{a.label}”? This can’t be undone.</span>
                <button className="btn danger solid" type="button" onClick={() => deleteCustomAction(a.id)}>Yes, delete action</button>
                <button className="btn" type="button" onClick={() => setConfirmDeleteAction(null)}>Keep it</button>
              </div>
            ) : (
              <button className="btn danger" type="button" onClick={() => setConfirmDeleteAction(a.id)}>Delete action…</button>
            )}
          </div>
        ))}
        <button className="btn" onClick={addCustomAction}>+ Add custom action</button>
      </section>

      {/* Image Text Extraction (OCR) */}
      <details className="card settings-disclosure">
        <summary>
          <span>Extract text from images</span>
          <small>Optional settings for vision models</small>
        </summary>
        <div className="settings-disclosure-body">
        <p className="muted small">
          When the clipboard contains an image, GhostPen can extract its text through your
          active AI profile. The image is sent to the configured endpoint, which may be a cloud
          provider. The model must support vision (e.g. <code>gemma4:e4b</code>).
        </p>

        <label>
          Max dimension: {ocr.maxDimension}px
          <span className="muted small">
            Images are downscaled so their largest side is at most this value before being sent.
          </span>
          <input
            type="range"
            min={512}
            max={2048}
            step={64}
            value={ocr.maxDimension}
            onChange={(e) => updateOcr({ maxDimension: parseInt(e.target.value, 10) })}
          />
        </label>

        <label>
          System prompt
          <span className="muted small">Leave empty to use the built-in default.</span>
          <textarea
            value={ocr.systemPrompt}
            placeholder="Extract all visible text from the image. Preserve line breaks and paragraph structure as closely as possible. Return ONLY the extracted text..."
            onChange={(e) => updateOcr({ systemPrompt: e.target.value })}
          />
        </label>

        <label>
          Model override
          <span className="muted small">Blank uses the active profile's model.</span>
          <input
            value={ocr.modelOverride}
            placeholder="gemma4:e4b"
            onChange={(e) => updateOcr({ modelOverride: e.target.value })}
          />
        </label>
        </div>
      </details>

      </div>

      <div className="settings-panel" hidden={section !== "speech"}>
      {android && (dictation.engine ?? "auto") !== "whisper" && (
        <p className="settings-panel-note">
          <b>Dictation</b> uses this device’s own speech recognition: nothing to download (change it in <button className="link-btn" type="button" onClick={() => goTo("dictation")}>Dictation</button>).
          {" "}<b>Captions and meetings</b> use a Whisper model from this list: the device’s recognizer only hears the
          microphone live, not what other apps play or a saved recording.
        </p>
      )}
      <WhisperModels activeModel={captions.model} onUse={useWhisperModel} />
      </div>

      <div className="settings-panel" hidden={section !== "captions"}>
      {/* Live captions (system audio) */}
      <section className="card">
        {capStatus && !capStatus.available && (
          <p className="muted small">
            This build does not include live captions.
          </p>
        )}
        <p className="muted small">
          Speech model: <b>{whisperName(captions.model)}</b>
          {capStatus && !capStatus.model_ready && " (not downloaded)"}.{" "}
          <button className="link-btn" type="button" onClick={() => goTo("speech")}>Change it in Speech models</button>
        </p>

        <label>
          Spoken language
          <select value={captions.language} onChange={(e) => updateCaptions({ language: e.target.value })}>
            {CAPTION_LANGUAGES.map((l) => <option key={l} value={l}>{LANGUAGE_NAMES[l] ?? l}</option>)}
          </select>
        </label>

        <label>
          Translate captions
          <select value={translateMode} onChange={(e) => setTranslateMode(e.target.value as TranslateMode)}>
            <option value="off">Don’t translate</option>
            <option value="english">To English: on this computer, free</option>
            <option value="other">To another language: uses your AI profile</option>
          </select>
        </label>
        {translateMode === "other" && (
          <label className="settings-sub">
            Translate into
            <select value={captions.targetLang} onChange={(e) => updateCaptions({ targetLang: e.target.value })}>
              {TRANSLATE_LANGUAGES.map((l) => <option key={l} value={l}>{l}</option>)}
            </select>
          </label>
        )}

        <label>
          Chunk length: {captions.chunkSeconds.toFixed(0)}s
          <span className="muted small">Lower is snappier with less context (it may clip words); higher is more accurate with more lag.</span>
          <input type="range" min={1} max={15} step={1} value={captions.chunkSeconds}
            onChange={(e) => updateCaptions({ chunkSeconds: parseInt(e.target.value, 10) })} />
        </label>

        <label>
          What to caption
          <select value={captions.device} onChange={(e) => updateCaptions({ device: e.target.value })}>
            <option value="">Automatic: what you hear now (recommended)</option>
            <DeviceOptions devices={capDevices} selected={captions.device} />
          </select>
          <span className="muted small">
            Automatic follows your current system output. Pick a 🔊 system-audio source to caption what you hear; a 🎙 microphone to caption your voice.
          </span>
        </label>

        <label>
          Caption font size: {captions.fontSize}px
          <input type="range" min={16} max={48} step={2} value={captions.fontSize}
            onChange={(e) => updateCaptions({ fontSize: parseInt(e.target.value, 10) })} />
        </label>

        <div className="settings-actions">
          <button className="btn" type="button" onClick={() => openCaptions()}>Open captions overlay</button>
        </div>
      </section>
      </div>

      <div className="settings-panel" hidden={section !== "meetings"}>
      {/* Meetings (captions that record, keep and proofread) */}
      <section className="card">
        <p className="muted small">Use a headset: through speakers, the others end up in your microphone too.</p>

        <h3>While recording</h3>
        <label className="checkbox">
          <input type="checkbox" checked={meetingsCfg.enabled} onChange={(e) => updateMeetings({ enabled: e.target.checked })} />
          <span>Start captions in meeting mode</span>
        </label>
        <label className="checkbox">
          <input type="checkbox" checked={meetingsCfg.mic} onChange={(e) => updateMeetings({ mic: e.target.checked })} />
          <span>Record my microphone too, as “Me”<span className="checkbox-help">Uses the microphone chosen in <button className="link-btn" type="button" onClick={() => goTo("dictation")}>Dictation</button>.</span></span>
        </label>

        <h3>Speakers</h3>
        <label className="checkbox">
          <input type="checkbox" checked={speakersOn} onChange={(e) => updateMeetings({ speakers: e.target.checked })} />
          <span>Tell the speakers apart by voice<span className="checkbox-help">Needs a 26 MB speaker model, downloaded the first time.</span></span>
        </label>
        <div className={`settings-sub ${speakersOn ? "" : "is-off"}`}>
          <label className="checkbox">
            <input type="checkbox" disabled={!speakersOn} checked={meetingsCfg.liveSpeakers ?? true} onChange={(e) => updateMeetings({ liveSpeakers: e.target.checked })} />
            <span>Label them live in the captions too<span className="checkbox-help">Live labels are a guess; when the meeting is saved they are redone over the whole recording.</span></span>
          </label>
          <label>
            Number of other people
            <select disabled={!speakersOn} value={meetingsCfg.expectedSpeakers ?? 0} onChange={(e) => updateMeetings({ expectedSpeakers: parseInt(e.target.value, 10) })}>
              <option value={0}>Detect automatically</option>
              {[1, 2, 3, 4, 5, 6, 7, 8].map((n) => <option key={n} value={n}>{n === 1 ? "1 other person" : `${n} other people`}</option>)}
            </select>
            <span className="muted small">When you know it, it helps when two voices sound alike.</span>
          </label>
          <label>
            Speaker model
            <select disabled={!speakersOn} value={meetingsCfg.speakerModel ?? ""} onChange={(e) => updateMeetings({ speakerModel: e.target.value })}>
              <option value="">WeSpeaker ResNet34, VoxCeleb (recommended, 26 MB)</option>
              <option value="ecapa-tdnn-voxceleb">ECAPA-TDNN, VoxCeleb (64 MB; tells voices apart less well here)</option>
            </select>
            <span className="muted small">Known voices are kept per model: switching models means naming people again.</span>
          </label>
        </div>

        <h3>When it ends</h3>
        <label className="checkbox">
          <input type="checkbox" checked={meetingsCfg.proofread} onChange={(e) => updateMeetings({ proofread: e.target.checked })} />
          <span>Proofread the transcript with the AI profile<span className="checkbox-help">Also saves a cleaned-up version of the transcript: fixed punctuation and no filler words.</span></span>
        </label>
        <label className="checkbox">
          <input type="checkbox" checked={meetingsCfg.summary ?? false} onChange={(e) => updateMeetings({ summary: e.target.checked })} />
          <span>Summarize it too<span className="checkbox-help">Off means the meeting’s Summary tab writes it when you ask.</span></span>
        </label>

        <h3>Where meetings are saved</h3>
        <label>
          <span>Folder{meetingsCfg.dir === "" && <span className="settings-default-tag">Default</span>}</span>
          <div className="row">
            {/* Blank in the settings means the default folder: it is shown as the real path, not as a hint. */}
            <DraftInput
              value={meetingsCfg.dir || defaultMeetingsDir}
              placeholder="Documents/GhostPen/Meetings"
              spellCheck={false}
              onCommit={(v) => {
                const dir = v.trim();
                updateMeetings({ dir: dir === defaultMeetingsDir ? "" : dir });
              }}
            />
            <button className="btn" type="button" disabled={meetingsCfg.dir === ""} onClick={() => updateMeetings({ dir: "" }, 0)}>Reset to default</button>
          </div>
          <span className="muted small">Each meeting gets its own folder with the audio, meeting.json and Markdown.</span>
        </label>
        <div className="settings-actions">
          <button className="btn" type="button" onClick={() => openMeetings()}>Open Meetings</button>
        </div>
      </section>
      </div>

      <div className="settings-panel" hidden={section !== "dictation"}>
      {/* Voice dictation (microphone) */}
      {android && (
        <p className="muted small settings-lead">
          Start it from Dictation in the sidebar, then stop: the text is copied, ready to paste anywhere.
        </p>
      )}
      <div className="settings-grid">
      <section className="card">
        <h2>Listening</h2>
        {android && (
          <label>
            Speech recognition
            <select value={dictation.engine ?? "auto"} onChange={(e) => updateDictation({ engine: e.target.value as "auto" | "whisper" | "system" })}>
              <option value="auto">Automatic: this device’s, when it has one (recommended)</option>
              <option value="system">This device’s speech recognition (nothing to download)</option>
              <option value="whisper">Whisper (offline, the model chosen in Speech models)</option>
            </select>
          </label>
        )}

        <label>
          Microphone
          <select value={dictation.device} onChange={(e) => updateDictation({ device: e.target.value })}>
            <option value="">Automatic: your default microphone (recommended)</option>
            <DeviceOptions devices={dictDevices} selected={dictation.device} />
          </select>
        </label>

        <label>
          Spoken language
          <select value={dictation.language} onChange={(e) => updateDictation({ language: e.target.value })}>
            {CAPTION_LANGUAGES.map((l) => <option key={l} value={l}>{LANGUAGE_NAMES[l] ?? l}</option>)}
          </select>
        </label>

      </section>

      <section className="card">
        <h2>When you finish</h2>
        <label className="checkbox">
          <input type="checkbox" checked={dictation.proofread}
            onChange={(e) => updateDictation({ proofread: e.target.checked })} />
          <span>Proofread with the AI profile before copying<span className="checkbox-help">Off means you get the raw transcript.</span></span>
        </label>
        {/* Android: apps can't paste into another app; the text is always copied. */}
        {!android && (
          <label className="checkbox">
            <input type="checkbox" checked={dictation.paste ?? true}
              onChange={(e) => updateDictation({ paste: e.target.checked })} />
            <span>Paste at the cursor when finished<span className="checkbox-help">Off means the text is only copied, so you can review it first.</span></span>
          </label>
        )}
        {android && <p className="muted small">The text is always copied: apps can’t paste into another app on Android.</p>}
      </section>
      </div>

      </div>

      <div className="settings-panel" hidden={section !== "general"}>
      {android ? (
        <p className="settings-panel-note">GhostPen on Android is always one app window: there is nothing to arrange here.</p>
      ) : (
        <div className="settings-grid">
        <section className="card">
          <h2>Window layout</h2>
          <label>
            GhostPen opens
            <select value={settings.interfaceMode ?? "windows"}
              onChange={(e) => update({ interfaceMode: e.target.value as "windows" | "single" })}>
              <option value="windows">A window per tool (the menu, Settings, Playground…)</option>
              <option value="single">One app window, with the tools in a sidebar</option>
            </select>
          </label>
          <p className="muted small">
            {oneWindow && "The shortcut opens Actions in the app window with the selected text; the result still replaces the selection. "}
            Applies the next time GhostPen starts.
          </p>
          {runningLayout && !dirty && (base?.interfaceMode ?? "windows") !== runningLayout && (
            <div className="settings-callout">
              <span>Saved: restart GhostPen to switch to {base?.interfaceMode === "single" ? "one app window" : "a window per tool"}.</span>
              <button className="btn" type="button" onClick={() => restartApp().catch(failWith)}>Restart now</button>
            </div>
          )}
        </section>

        <section className="card">
          <h2>Captions and dictation</h2>
          <div className={`settings-sub-flat ${oneWindow ? "" : "is-off"}`}>
            <label className="checkbox">
              <input type="checkbox" disabled={!oneWindow} checked={captions.float ?? true}
                onChange={(e) => updateCaptions({ float: e.target.checked })} />
              <span>Captions float over other windows<span className="checkbox-help">Off makes captions a page of the app window.</span></span>
            </label>
            <label className="checkbox">
              <input type="checkbox" disabled={!oneWindow} checked={dictation.float ?? true}
                onChange={(e) => updateDictation({ float: e.target.checked })} />
              <span>Dictation floats over other windows<span className="checkbox-help">Off makes dictation a page of the app window.</span></span>
            </label>
          </div>
          {!oneWindow && (
            <p className="muted small">
              Fixed for now: with a window per tool, captions and dictation always float. Choose “One app window” to change this.
            </p>
          )}
        </section>
        </div>
      )}
      </div>

      <div className="settings-panel" hidden={section !== "service"}>
      {/* Model & speech service (what other local apps connect to) */}
      <div className="settings-grid">
      <section className="card">
        <h2>Who can connect</h2>
        <label>
          Reachable from
          <select value={server.host} onChange={(e) => updateServer({ host: e.target.value })}>
            <option value="127.0.0.1">This computer only (recommended)</option>
            <option value="0.0.0.0">Other devices on your network (no password)</option>
          </select>
        </label>
        {server.host === "0.0.0.0" && (
          <div className="settings-warning" role="note">
            <b>Anyone on your network can use your models and GPU, and there is no password.</b>{" "}
            Choose this only on a network you trust.
          </div>
        )}
        <label>
          Port
          <DraftInput
            type="number"
            className="narrow-field"
            min={1024}
            max={65535}
            value={String(server.port)}
            onCommit={(v) => {
              const n = parseInt(v, 10);
              if (!(n >= 1024 && n <= 65535)) return false;
              updateServer({ port: n });
            }}
          />
          <span className="muted small">Takes effect the next time GhostPen starts.</span>
        </label>
        <p className="muted small settings-url-line">
          Apps on this computer connect to <code className="settings-url">{`http://127.0.0.1:${server.port}`}</code>
        </p>
      </section>

      <section className="card">
        <h2>Context window for other apps</h2>
        <label>
          Room per request
          <select
            value={server.ctxTokens ?? 0}
            onChange={(e) => updateServer({ ctxTokens: parseInt(e.target.value, 10) })}
          >
            <option value={0}>Same as Built-in models ({ctxLabel(local.ctxTokens)})</option>
            {CONTEXT_SIZES.map((n) => (
              <option key={n} value={n}>
                {ctxLabel(n)}
              </option>
            ))}
          </select>
          <span className="muted small">Larger uses more memory. An app can still ask for more per request.</span>
        </label>
      </section>
      </div>

      </div>

      <div className="settings-panel" hidden={section !== "about"}>
      <AboutUpdates
        autoUpdate={settings.autoUpdate ?? true}
        onAutoUpdate={setAutoUpdate}
        extra={status && (
          <section className="card diag">
            <h2>Copy and paste</h2>
            <div className="diag-grid">
              <span>Clipboard</span><b>{status.clipboard_backend === "oriel" ? "Built in" : status.clipboard_backend}</b>
              <span>Typing into other apps</span><b>{status.input_available ? "Works" : "Not available"}</b>
              <span>Paste method</span><b>{status.manual_mode ? "Copy only, paste yourself" : "Automatic"}</b>
            </div>
          </section>
        )}
      />
      </div>
          {showFooter && (
          <div className="footer settings-footer">
            <div className="settings-save-feedback" role="status" aria-live="polite">
              {saveError ? (
                <span className="save-error">
                  ⚠ {saveError.text}
                  {saveError.retry && (
                    <button className="btn" type="button" onClick={() => void persist()}>Retry</button>
                  )}
                </span>
              ) : dirty || saving ? (
                <span className="settings-saving">Saving…</span>
              ) : (
                <span className="muted">All changes saved</span>
              )}
            </div>
            {!singleWindow && (
              <button className="btn" type="button" onClick={closeSettings}>Close</button>
            )}
          </div>
          )}
          </main>
        </div>
      </div>
    </div>
  );
}
