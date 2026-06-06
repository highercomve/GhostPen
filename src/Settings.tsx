import { useEffect, useState } from "react";
import {
  Settings as SettingsType,
  Profile,
  CustomAction,
  CaptionsSettings,
  Status,
  CaptionsStatus,
  getSettings,
  saveSettings,
  fetchModels,
  getStatus,
  closeSettings,
  captionsStatus,
  captionsDownloadModel,
  captionsListDevices,
  openCaptions,
  PRESETS,
  WHISPER_MODELS,
  CAPTION_LANGUAGES,
  TRANSLATE_LANGUAGES,
} from "./api";

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

export default function Settings() {
  const [settings, setSettings] = useState<SettingsType | null>(null);
  const [status, setStatus] = useState<Status | null>(null);
  const [models, setModels] = useState<string[]>([]);
  const [modelMsg, setModelMsg] = useState<string>("");
  const [saved, setSaved] = useState(false);
  const [capStatus, setCapStatus] = useState<CaptionsStatus | null>(null);
  const [capDevices, setCapDevices] = useState<string[]>([]);
  const [capMsg, setCapMsg] = useState<string>("");
  const [downloading, setDownloading] = useState(false);

  useEffect(() => {
    getSettings().then(setSettings);
    getStatus().then(setStatus).catch(() => {});
    captionsStatus().then(setCapStatus).catch(() => {});
    captionsListDevices().then(setCapDevices).catch(() => {});
  }, []);

  if (!settings) return <div className="settings loading-page">Loading…</div>;

  const active =
    settings.profiles.find((p) => p.id === settings.activeProfileId) ?? settings.profiles[0];

  const update = (patch: Partial<SettingsType>) => {
    setSettings({ ...settings, ...patch });
    setSaved(false);
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

  // Download the configured whisper model, then save + refresh status so the UI reflects it.
  const downloadModel = async () => {
    setDownloading(true);
    setCapMsg(`Downloading ${captions.model}… (this can take a while)`);
    try {
      await saveSettings(settings); // persist so the backend reads the chosen model id
      await captionsDownloadModel(captions.model);
      setCapMsg(`Model “${captions.model}” ready ✓`);
      captionsStatus().then(setCapStatus).catch(() => {});
    } catch (e) {
      setCapMsg(String(e));
    } finally {
      setDownloading(false);
    }
  };

  const save = async () => {
    await saveSettings(settings);
    setSaved(true);
    getStatus().then(setStatus).catch(() => {});
  };

  return (
    <div className="settings">
      <h1>GhostPen Settings</h1>

      {/* Diagnostics */}
      {status && (
        <section className="card diag">
          <h2>Diagnostics</h2>
          <div className="diag-grid">
            <span>Session</span><b>{status.session}</b>
            <span>Clipboard</span><b>{status.clipboard_backend}</b>
            <span>Input synthesis</span><b>{status.input_available ? "available" : "unavailable"}</b>
            <span>Mode</span><b>{status.manual_mode ? "manual-copy" : "auto (synthetic)"}</b>
          </div>
        </section>
      )}

      {/* Profiles */}
      <section className="card">
        <h2>AI Profiles</h2>
        <div className="profile-tabs">
          {settings.profiles.map((p) => (
            <button
              key={p.id}
              className={`tab ${p.id === settings.activeProfileId ? "active" : ""}`}
              onClick={() => update({ activeProfileId: p.id })}
            >
              {p.name}
            </button>
          ))}
          <button className="tab add" onClick={addProfile}>+ Add</button>
        </div>

        {active && (
          <div className="profile-form">
            <label>
              Preset
              <select defaultValue="" onChange={(e) => applyPreset(e.target.value)}>
                <option value="" disabled>Choose a preset…</option>
                {PRESETS.map((p) => (
                  <option key={p.name} value={p.name}>{p.name}</option>
                ))}
              </select>
            </label>
            <label>
              Name
              <input value={active.name} onChange={(e) => updateProfile(active.id, { name: e.target.value })} />
            </label>
            <label>
              Base URL
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
                <button className="btn" type="button" onClick={doFetchModels}>Fetch models</button>
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
              {modelMsg && <span className="muted small">{modelMsg}</span>}
            </label>
            <label>
              Temperature: {active.temperature.toFixed(2)}
              <input type="range" min={0} max={1} step={0.05} value={active.temperature}
                onChange={(e) => updateProfile(active.id, { temperature: parseFloat(e.target.value) })} />
            </label>
            {settings.profiles.length > 1 && (
              <button className="btn danger" onClick={() => deleteProfile(active.id)}>Delete profile</button>
            )}
          </div>
        )}
      </section>

      {/* Behaviour */}
      <section className="card">
        <h2>Behaviour</h2>
        <label>
          Hotkey <span className="muted">(Windows/macOS/X11; on Wayland bind in your compositor)</span>
          <input value={settings.hotkey} onChange={(e) => update({ hotkey: e.target.value })} placeholder="Ctrl+Shift+A" />
        </label>
        <label className="checkbox">
          <input type="checkbox" checked={settings.forceSynthetic}
            onChange={(e) => update({ forceSynthetic: e.target.checked })} />
          Force synthetic copy/paste on Wayland (needs libei; off = manual-copy mode)
        </label>
        <label>
          Clipboard restore delay (ms)
          <input type="number" min={0} max={2000} value={settings.restoreDelayMs}
            onChange={(e) => update({ restoreDelayMs: parseInt(e.target.value || "0", 10) })} />
        </label>
      </section>

      {/* Custom actions */}
      <section className="card">
        <h2>Custom Actions</h2>
        {customActions.length === 0 && (
          <p className="muted small">None yet. Add one to define your own prompt — it appears in the menu and Playground.</p>
        )}
        {customActions.map((a) => (
          <div key={a.id} className="custom-action">
            <input
              value={a.label}
              placeholder="Label (e.g. Bullet points)"
              onChange={(e) => updateCustomAction(a.id, { label: e.target.value })}
            />
            <textarea
              value={a.prompt}
              placeholder="System prompt — e.g. 'Convert the text into concise bullet points. Return ONLY the bullets.'"
              onChange={(e) => updateCustomAction(a.id, { prompt: e.target.value })}
            />
            <div className="row">
              <input
                value={a.model}
                placeholder="Model override (optional — blank uses the active profile's model)"
                onChange={(e) => updateCustomAction(a.id, { model: e.target.value })}
              />
              <button className="btn danger" onClick={() => deleteCustomAction(a.id)}>Delete</button>
            </div>
          </div>
        ))}
        <button className="btn" onClick={addCustomAction}>+ Add custom action</button>
      </section>

      {/* Live captions (system audio) */}
      <section className="card">
        <h2>Live Captions <span className="muted small">system audio → subtitles</span></h2>
        {capStatus && !capStatus.available && (
          <p className="muted small">
            This build was compiled without captions support. Rebuild with
            {" "}<code>--features captions</code> to enable on-device transcription.
          </p>
        )}
        <p className="muted small">
          Captures what you hear (meetings, videos, podcasts), transcribes it on-device with
          Whisper, and shows subtitles in a click-through overlay. Optionally translate via your
          active AI profile.
        </p>

        <label>
          Whisper model <span className="muted">(smaller = faster, larger = more accurate)</span>
          <div className="row">
            <select value={captions.model} onChange={(e) => updateCaptions({ model: e.target.value })}>
              {WHISPER_MODELS.map((m) => <option key={m} value={m}>{m}</option>)}
            </select>
            <button className="btn" type="button" onClick={downloadModel} disabled={downloading}>
              {capStatus?.model_ready && capStatus.model === captions.model ? "Re-download" : "Download model"}
            </button>
          </div>
          {capStatus && (
            <span className="muted small">
              {capStatus.model_ready ? `“${capStatus.model}” downloaded ✓` : `“${captions.model}” not downloaded`}
            </span>
          )}
          {capMsg && <span className="muted small">{capMsg}</span>}
        </label>

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
          <input type="range" min={2} max={15} step={1} value={captions.chunkSeconds}
            onChange={(e) => updateCaptions({ chunkSeconds: parseInt(e.target.value, 10) })} />
        </label>

        <label>
          Capture device <span className="muted">(blank = auto-detect system-audio loopback)</span>
          <input list="cap-devices" value={captions.device}
            placeholder="auto"
            onChange={(e) => updateCaptions({ device: e.target.value })} />
          <datalist id="cap-devices">
            {capDevices.map((d) => <option key={d} value={d} />)}
          </datalist>
        </label>

        <label>
          Caption font size: {captions.fontSize}px
          <input type="range" min={16} max={48} step={2} value={captions.fontSize}
            onChange={(e) => updateCaptions({ fontSize: parseInt(e.target.value, 10) })} />
        </label>

        <button className="btn" onClick={() => openCaptions()}>Open captions overlay</button>
      </section>

      <div className="footer">
        {saved && <span className="muted">Saved ✓</span>}
        <button className="btn" onClick={() => closeSettings()}>Close</button>
        <button className="btn primary" onClick={save}>Save</button>
      </div>
    </div>
  );
}
