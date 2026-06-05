import { useEffect, useState } from "react";
import {
  Settings as SettingsType,
  Profile,
  CustomAction,
  Status,
  getSettings,
  saveSettings,
  fetchModels,
  getStatus,
  closeSettings,
  PRESETS,
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

  useEffect(() => {
    getSettings().then(setSettings);
    getStatus().then(setStatus).catch(() => {});
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

      <div className="footer">
        {saved && <span className="muted">Saved ✓</span>}
        <button className="btn" onClick={() => closeSettings()}>Close</button>
        <button className="btn primary" onClick={save}>Save</button>
      </div>
    </div>
  );
}
