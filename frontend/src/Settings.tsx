import { useEffect, useState } from "react";
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
  PRESETS,
  CAPTION_LANGUAGES,
  TRANSLATE_LANGUAGES,
  LocalLlmSettings,
  ServerSettings,
  isLocal,
  llmModelsStatus,
  LlmStatus,
} from "./api";
import WhisperModels from "./WhisperModels";
import Voices from "./Voices";
import LocalModels, { CONTEXT_SIZES, DEFAULT_LOCAL, ctxLabel } from "./LocalModels";
import AboutUpdates from "./AboutUpdates";

type SettingsSection = "ai" | "models" | "voices" | "actions" | "speech" | "service" | "about";

const SECTIONS: { id: SettingsSection; label: string; hint: string; description: string }[] = [
  { id: "ai", label: "AI profile", hint: "Choose your provider", description: "Choose the model GhostPen uses for writing, proofreading, and optional translation." },
  { id: "models", label: "Built-in models", hint: "Download and tune", description: "Download models that run on this computer and adjust how they use memory." },
  { id: "voices", label: "Voices", hint: "Read text aloud", description: "The built-in Kokoro voice: download the model and voice packs it reads with." },
  { id: "actions", label: "Actions", hint: "Shortcuts and results", description: "Choose how actions start, where results go, and add your own instructions." },
  { id: "speech", label: "Speech", hint: "Captions and dictation", description: "Choose a speech model and set up captions and dictation." },
  { id: "service", label: "Connections", hint: "Sharing and diagnostics", description: "Choose whether other apps can use your models and check system status." },
  { id: "about", label: "About", hint: "Updates and version", description: "Check for updates and see which GhostPen version is installed." },
];

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

export default function Settings() {
  const [settings, setSettings] = useState<SettingsType | null>(null);
  const [status, setStatus] = useState<Status | null>(null);
  const [models, setModels] = useState<string[]>([]);
  const [modelMsg, setModelMsg] = useState<string>("");
  const [saved, setSaved] = useState(false);
  const [saveError, setSaveError] = useState("");
  const [dirty, setDirty] = useState(false);
  const [saving, setSaving] = useState(false);
  const [section, setSection] = useState<SettingsSection>("ai");
  const [capStatus, setCapStatus] = useState<CaptionsStatus | null>(null);
  const [capDevices, setCapDevices] = useState<AudioDevice[]>([]);
  const [dictDevices, setDictDevices] = useState<AudioDevice[]>([]);
  const [llm, setLlm] = useState<LlmStatus | null>(null);

  useEffect(() => {
    getSettings().then(setSettings);
    // The window is only hidden on close: re-read the live state (not the
    // settings being edited) each time it is shown again.
    const refresh = () => {
      getStatus().then(setStatus).catch(() => {});
      captionsStatus().then(setCapStatus).catch(() => {});
      captionsListDevices().then(setCapDevices).catch(() => {});
      dictationListDevices().then(setDictDevices).catch(() => {});
      llmModelsStatus().then(setLlm).catch(() => {});
    };
    refresh();
    window.addEventListener("focus", refresh);
    return () => window.removeEventListener("focus", refresh);
  }, []);

  if (!settings) return <div className="settings loading-page">Loading…</div>;

  const active =
    settings.profiles.find((p) => p.id === settings.activeProfileId) ?? settings.profiles[0];

  // On Wayland the app can't grab global keys — the compositor owns the binds, so the
  // shortcut fields become "recommended binding" reference rather than something we register.
  const onWayland = status?.session?.includes("Wayland") ?? false;

  const update = (patch: Partial<SettingsType>) => {
    setSettings({ ...settings, ...patch });
    setDirty(true);
    setSaved(false);
    setSaveError("");
  };

  const updateProfile = (id: string, patch: Partial<Profile>) => {
    update({
      profiles: settings.profiles.map((p) => (p.id === id ? { ...p, ...patch } : p)),
    });
  };

  const addProfile = () => {
    const p = newProfile();
    update({ profiles: [...settings.profiles, p], activeProfileId: p.id });
  };

  const deleteProfile = (id: string) => {
    if (settings.profiles.length <= 1) return;
    const profiles = settings.profiles.filter((p) => p.id !== id);
    update({
      profiles,
      activeProfileId:
        settings.activeProfileId === id ? profiles[0].id : settings.activeProfileId,
    });
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
  // (creating the profile if needed) and make it active. Saved at once, on top
  // of the saved settings: other unsaved edits in the form stay unsaved.
  const useLocalModel = async (id: string) => {
    const withModel = (profiles: Profile[], target: Profile | undefined) =>
      target
        ? profiles.map((p) => (p.id === target.id ? { ...p, model: id } : p))
        : [...profiles, { id: "built-in", name: "Built-in (GhostPen)", provider: "local" as const, baseUrl: "", apiKey: "", model: id, temperature: 0.2 }];
    const targetId = localProfile?.id ?? "built-in";
    try {
      const saved = await getSettings();
      const savedTarget = saved.profiles.find((p) => p.id === targetId);
      await saveSettings({ ...saved, profiles: withModel(saved.profiles, savedTarget), activeProfileId: targetId });
      setSettings({ ...settings, profiles: withModel(settings.profiles, localProfile), activeProfileId: targetId });
      getStatus().then(setStatus).catch(() => {});
    } catch (e) {
      setModelMsg(String(e));
    }
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
    update({ customActions: customActions.filter((a) => a.id !== id) });
  };

  const captions = settings.captions;
  const updateCaptions = (patch: Partial<CaptionsSettings>) => {
    update({ captions: { ...captions, ...patch } });
  };

  const dictation = settings.dictation;
  const updateDictation = (patch: Partial<DictationSettings>) => {
    update({ dictation: { ...dictation, ...patch } });
  };

  const ocr = settings.ocr ?? { maxDimension: 1024, systemPrompt: "", modelOverride: "" };
  const updateOcr = (patch: Partial<OcrSettings>) => {
    update({ ocr: { ...ocr, ...patch } });
  };

  // Captions and dictation share this model: saved right away, like a built-in model's Use.
  const useWhisperModel = async (id: string) => {
    const saved = await getSettings();
    await saveSettings({ ...saved, captions: { ...saved.captions, model: id } });
    setSettings({ ...settings, captions: { ...captions, model: id } });
    captionsStatus().then(setCapStatus).catch(() => {});
  };

  // The backend can reject after saving (e.g. a hotkey that didn't register): show why.
  const save = async () => {
    if (!dirty || saving) return;
    setSaving(true);
    try {
      await saveSettings(settings);
      setDirty(false);
      setSaved(true);
      setSaveError("");
    } catch (e) {
      setSaved(false);
      setSaveError(e instanceof Error ? e.message : String(e));
    } finally {
      setSaving(false);
    }
    getStatus().then(setStatus).catch(() => {});
  };

  const closeSettings = async () => {
    if (dirty) {
      try {
        setSettings(await getSettings());
        setDirty(false);
        setSaved(false);
        setSaveError("");
      } catch (e) {
        setSaveError(e instanceof Error ? e.message : String(e));
        return;
      }
    }
    await hideWindow();
  };

  const currentSection = SECTIONS.find((item) => item.id === section) ?? SECTIONS[0];

  return (
    <div className="settings">
      <div className="settings-shell">
        <header className="settings-header" data-oriel-drag-region>
          <div>
            <span className="settings-eyebrow">GhostPen</span>
            <h1>Settings</h1>
          </div>
          {active && (
            <button className="settings-profile-summary" type="button" title="Edit AI profile" onClick={() => { setSection("ai"); window.scrollTo(0, 0); }}>
              <span>AI profile in use</span>
              <strong>{active.name}</strong>
            </button>
          )}
        </header>

        <div className="settings-layout">
          <nav className="settings-nav" aria-label="Settings sections">
            {SECTIONS.map((item) => (
              <button
                key={item.id}
                type="button"
                className={`settings-nav-item ${section === item.id ? "active" : ""}`}
                aria-current={section === item.id ? "page" : undefined}
                onClick={() => { setSection(item.id); window.scrollTo(0, 0); }}
              >
                <span>{item.label}</span>
                <small>{item.hint}</small>
              </button>
            ))}
          </nav>

          <main className="settings-main">
            <header className="settings-section-header">
              <h2>{currentSection.label}</h2>
              <p>{currentSection.description}</p>
            </header>

      <div className="settings-panel" hidden={section !== "ai"}>

      {/* Profiles */}
      <section className="card">
        <h2>Choose a profile</h2>
        <p className="muted small">The active profile handles text actions, dictation proofreading, and optional caption translation. Save after changing profiles.</p>
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
          <div className="profile-form">
            <div className="settings-field-title">Where should the AI run?</div>
            <div className="settings-provider-options" role="group" aria-label="AI provider">
              <label className={`settings-provider-option ${!isLocal(active) ? "selected" : ""}`}>
                <input type="radio" name="ai-provider" checked={!isLocal(active)}
                  onChange={() => updateProfile(active.id, { provider: "openai", baseUrl: active.baseUrl || "http://localhost:11434/v1", model: "" })} />
                <span><strong>Connected service</strong><small>Use Ollama, LM Studio, or a cloud provider</small></span>
              </label>
              <label className={`settings-provider-option ${isLocal(active) ? "selected" : ""}`}>
                <input type="radio" name="ai-provider" checked={isLocal(active)}
                  onChange={() => updateProfile(active.id, { provider: "local", model: localChoices[0]?.id ?? "" })} />
                <span><strong>Built-in model</strong><small>Run on this computer without another service</small></span>
              </label>
            </div>
            {isLocal(active) ? (
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
                  <button className="btn" type="button" onClick={() => { setSection("models"); window.scrollTo(0, 0); }}>Browse built-in models</button>
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
              API key <span className="muted">(blank = no auth header)</span>
              <input type="password" value={active.apiKey} onChange={(e) => updateProfile(active.id, { apiKey: e.target.value })} placeholder="sk-…" />
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
              <button className="btn danger" type="button" onClick={() => deleteProfile(active.id)}>Delete profile</button>
            )}
          </div>
        )}
      </section>

      </div>

      <div className="settings-panel" hidden={section !== "voices"}>
      <Voices />
      </div>

      <div className="settings-panel" hidden={section !== "models"}>
      <p className="settings-panel-note">Downloading a model does not change your AI profile. Choose <b>Use</b> to switch to it immediately.</p>
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
        {onWayland ? (
          <div className="kbd-note">
            On Wayland an app can’t grab global keys — <b>bind these in your compositor</b> to the
            commands below. The values here are your own reference (they aren’t registered).
            <br />
            On Hyprland, e.g.: <code>bind = CTRL SHIFT, A, exec, ghostpen --trigger</code>
          </div>
        ) : (
          <p className="muted small">
            Registered globally while GhostPen runs. Blank = unbound. (On Wayland these are bound
            in your compositor instead.)
          </p>
        )}

        <label>
          Action menu <span className="muted">(ghostpen --trigger)</span>
          <input value={settings.hotkey} onChange={(e) => update({ hotkey: e.target.value })} placeholder="Ctrl+Shift+A" />
        </label>
        <label>
          Dictation <span className="muted">(ghostpen --voice-input)</span>
          <input value={settings.dictationHotkey} onChange={(e) => update({ dictationHotkey: e.target.value })} placeholder="Ctrl+Shift+D" />
        </label>
        <label>
          Live captions <span className="muted">(ghostpen --captions)</span>
          <input value={settings.captionsHotkey} onChange={(e) => update({ captionsHotkey: e.target.value })} placeholder="Ctrl+Shift+L" />
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
          <summary>Advanced copy and paste</summary>
          <div className="settings-advanced-body">
            <label className="checkbox">
              <input type="checkbox" checked={settings.forceSynthetic}
                onChange={(e) => update({ forceSynthetic: e.target.checked })} />
              Force synthetic copy/paste on Wayland (needs libei; off = manual copy)
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
            <button className="btn danger" onClick={() => deleteCustomAction(a.id)}>Delete action</button>
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
      <p className="settings-panel-note">Captions and dictation share one speech model. Choosing <b>Use</b> applies it immediately; save the options below when you change them.</p>
      <WhisperModels activeModel={captions.model} onUse={useWhisperModel} />

      {/* Live captions (system audio) */}
      <section className="card">
        <h2>Live Captions <span className="muted small">system audio → subtitles</span></h2>
        {capStatus && !capStatus.available && (
          <p className="muted small">
            This build does not include live captions.
          </p>
        )}
        <p className="muted small">
          Captures what you hear (meetings, videos, podcasts), transcribes it on-device with
          Whisper, and shows subtitles in a click-through overlay. Optionally translate via your
          active AI profile.
        </p>

        <p className="muted small">
          Model: <code>{captions.model}</code>
          {capStatus && !capStatus.model_ready && " (not downloaded)"}, chosen in Speech models above.
        </p>


        <label>
          Source language
          <select value={captions.language} onChange={(e) => updateCaptions({ language: e.target.value })}>
            {CAPTION_LANGUAGES.map((l) => <option key={l} value={l}>{l}</option>)}
          </select>
        </label>

        <label className="checkbox">
          <input type="checkbox" checked={captions.whisperTranslate}
            onChange={(e) => updateCaptions({ whisperTranslate: e.target.checked })} />
          Translate to English with Whisper <span className="muted">(free, English-only target)</span>
        </label>

        <label className="checkbox">
          <input type="checkbox" checked={captions.aiTranslate}
            onChange={(e) => updateCaptions({ aiTranslate: e.target.checked })} />
          Translate transcript via AI profile <span className="muted">(for non-English targets)</span>
        </label>
        {captions.aiTranslate && (
          <label>
            Target language
            <select value={captions.targetLang} onChange={(e) => updateCaptions({ targetLang: e.target.value })}>
              {TRANSLATE_LANGUAGES.map((l) => <option key={l} value={l}>{l}</option>)}
            </select>
          </label>
        )}

        <label>
          Chunk length: {captions.chunkSeconds.toFixed(0)}s
          <span className="muted small">lower = snappier captions, less context (may clip words); higher = more accurate, more lag</span>
          <input type="range" min={1} max={15} step={1} value={captions.chunkSeconds}
            onChange={(e) => updateCaptions({ chunkSeconds: parseInt(e.target.value, 10) })} />
        </label>

        <label>
          Capture device <span className="muted">(what to transcribe — “Auto” follows your current system output)</span>
          <select value={captions.device} onChange={(e) => updateCaptions({ device: e.target.value })}>
            <option value="">Auto — current system output (recommended)</option>
            <DeviceOptions devices={capDevices} selected={captions.device} />
          </select>
          <span className="muted small">
            Pick a 🔊 system-audio source to caption what you hear; a 🎙 microphone to caption your voice.
          </span>
        </label>

        <label>
          Caption font size: {captions.fontSize}px
          <input type="range" min={16} max={48} step={2} value={captions.fontSize}
            onChange={(e) => updateCaptions({ fontSize: parseInt(e.target.value, 10) })} />
        </label>

        <button className="btn" onClick={() => openCaptions()}>Open captions overlay</button>
      </section>

      {/* Voice dictation (microphone) */}
      <section className="card">
        <h2>Dictation <span className="muted small">speak to type</span></h2>
        <p className="muted small">
          Start dictation with your shortcut or <code>ghostpen --voice-input</code>, then stop to
          copy or paste the transcript. You can have your active AI profile proofread it first.
        </p>

        <label>
          Microphone <span className="muted">(“Auto” follows your default input device)</span>
          <select value={dictation.device} onChange={(e) => updateDictation({ device: e.target.value })}>
            <option value="">Auto — default microphone (recommended)</option>
            <DeviceOptions devices={dictDevices} selected={dictation.device} />
          </select>
          <span className="muted small">
            Captions listen to your <em>output</em> (what you hear); dictation always listens to a
            real <em>input</em> — monitor sources aren’t offered here.
          </span>
        </label>

        <label>
          Spoken language
          <select value={dictation.language} onChange={(e) => updateDictation({ language: e.target.value })}>
            {CAPTION_LANGUAGES.map((l) => <option key={l} value={l}>{l}</option>)}
          </select>
        </label>

        <label className="checkbox">
          <input type="checkbox" checked={dictation.proofread}
            onChange={(e) => updateDictation({ proofread: e.target.checked })} />
          Proofread with the AI profile before copying <span className="muted">(off = raw transcript)</span>
        </label>
        <label className="checkbox">
          <input type="checkbox" checked={dictation.paste ?? true}
            onChange={(e) => updateDictation({ paste: e.target.checked })} />
          Paste at the cursor when finished <span className="muted">(off = copy only, to review first)</span>
        </label>
      </section>

      </div>

      <div className="settings-panel" hidden={section !== "service"}>
      {/* Model & speech service (what other local apps connect to) */}
      <section className="card">
        <h2>
          Model &amp; speech service{" "}
          <span className="muted small">built-in and speech models, served to other apps</span>
        </h2>
        <p className="muted small">
          GhostPen serves its <b>Built-in</b> chat models and the speech models (transcription,
          OpenAI-compatible API) on <code>http://{server.host}:{server.port}</code>. Apps like
          GhostReel or <code>ghostpen-cli</code> use it; the address is advertised as{" "}
          <code>http://127.0.0.1:{server.port}</code> on this machine whatever the setting.
        </p>
        <label>
          Reachable from
          <select value={server.host} onChange={(e) => updateServer({ host: e.target.value })}>
            <option value="127.0.0.1">This computer only — 127.0.0.1 (recommended)</option>
            <option value="0.0.0.0">All networks — 0.0.0.0 (other machines can use your models)</option>
          </select>
          <span className="muted small">
            All networks is open to your LAN with no password — anyone could use your models and
            GPU. Only for a trusted network.
          </span>
        </label>
        <label>
          Port
          <input
            type="number"
            min={1024}
            max={65535}
            value={server.port}
            onChange={(e) => {
              const n = parseInt(e.target.value, 10);
              if (n >= 1024 && n <= 65535) updateServer({ port: n });
            }}
          />
          <span className="muted small">Takes effect the next time GhostPen starts.</span>
        </label>
        <label>
          Context window for other apps
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
          <span className="muted small">
            Room for the prompt and the answer in chat requests from other apps. Larger uses more
            memory. An app can still ask for more per request; the model's maximum is the limit.
          </span>
        </label>
      </section>

      {status && (
        <section className="card diag">
          <h2>System diagnostics</h2>
          <p className="muted small">Useful when shortcuts, copy and paste, or input control do not work as expected.</p>
          <div className="diag-grid">
            <span>Session</span><b>{status.session}</b>
            <span>Clipboard</span><b>{status.clipboard_backend}</b>
            <span>Input synthesis</span><b>{status.input_available ? "available" : "unavailable"}</b>
            <span>Mode</span><b>{status.manual_mode ? "manual copy" : "automatic"}</b>
          </div>
        </section>
      )}
      </div>

      <div className="settings-panel" hidden={section !== "about"}>
      <AboutUpdates autoUpdate={settings.autoUpdate ?? true} onAutoUpdate={(on) => update({ autoUpdate: on })} />
      </div>
          </main>
        </div>

        <div className="footer settings-footer">
          <div className="settings-save-feedback" role="status" aria-live="polite">
            {saveError ? <span className="save-error">⚠ {saveError}</span>
              : saved ? <span className="save-ok">Saved ✓</span>
              : dirty ? <span className="settings-unsaved">Unsaved changes</span>
              : <span className="muted">All changes saved</span>}
          </div>
          <button className="btn" type="button" onClick={closeSettings} disabled={saving}>
            {dirty ? "Discard & close" : "Close"}
          </button>
          <button className="btn primary" type="button" onClick={save} disabled={!dirty || saving}>
            {saving ? "Saving…" : "Save changes"}
          </button>
        </div>
      </div>
    </div>
  );
}
