import { useEffect, useState } from "react";
import { listen } from "./events";
import { openExternal } from "./oriel";
import {
  AppInfo,
  UpdateCheck,
  UpdateProgress,
  appInfo,
  updateCheck,
  updateInstall,
  updateRestart,
  formatBytes,
} from "./api";

const KIND_TEXT: Record<string, string> = {
  windows: "Installed with the Windows installer: GhostPen updates itself.",
  appimage: "Running as an AppImage: GhostPen updates the AppImage itself.",
  macos_app: "Installed as a macOS app: GhostPen updates itself.",
  package: "Installed with your system's package manager (deb/rpm): update it there, or download the new version.",
  source: "Built from source: GhostPen shows new releases but doesn't replace itself.",
};

/**
 * Settings → About & updates: the version, "Check for updates", installing
 * one (where GhostPen can replace itself), and the automatic-updates switch.
 */
export default function AboutUpdates(props: { autoUpdate: boolean; onAutoUpdate: (on: boolean) => void }) {
  const [info, setInfo] = useState<AppInfo | null>(null);
  const [check, setCheck] = useState<UpdateCheck | null>(null);
  const [message, setMessage] = useState("");
  const [busy, setBusy] = useState<"" | "checking" | "installing">("");
  const [progress, setProgress] = useState<UpdateProgress | null>(null);

  useEffect(() => {
    appInfo().then(setInfo).catch(() => {});
    const un = listen<UpdateProgress>("ghostpen://update-progress", (e) => setProgress(e.payload));
    return () => {
      un.then((f) => f());
    };
  }, []);

  const doCheck = async () => {
    setBusy("checking");
    setMessage("");
    setCheck(null);
    try {
      setCheck(await updateCheck());
    } catch (e) {
      setMessage(String(e));
    } finally {
      setBusy("");
    }
  };

  const doInstall = async () => {
    setBusy("installing");
    setMessage("");
    setProgress(null);
    try {
      await updateInstall();
      setInfo(await appInfo());
    } catch (e) {
      setMessage(String(e));
    } finally {
      setBusy("");
      setProgress(null);
    }
  };

  const restart = () => updateRestart().catch((e) => setMessage(String(e)));

  const installed = info?.installed_version;
  const pct = progress && progress.total ? Math.min(100, (progress.downloaded / progress.total) * 100) : 0;

  return (
    <section className="card">
      <h2>About &amp; updates</h2>
      <div className="about-row">
        <div>
          <b>GhostPen {info?.version ?? ""}</b>
          <span className="muted small about-kind">{info ? KIND_TEXT[info.install_kind] ?? "" : ""}</span>
        </div>
        <button className="btn" type="button" onClick={doCheck} disabled={busy !== ""}>
          {busy === "checking" ? "Checking…" : "Check for updates"}
        </button>
      </div>

      {installed && (
        <div className="update-box">
          <span>GhostPen {installed} is installed. It starts the next time GhostPen opens.</span>
          <button className="btn primary" type="button" onClick={restart}>Restart now</button>
        </div>
      )}

      {check && !installed && (
        check.available ? (
          <div className="update-box">
            <span>GhostPen {check.version} is available (you have {info?.version}).</span>
            {check.can_install ? (
              <button className="btn primary" type="button" onClick={doInstall} disabled={busy !== ""}>
                {busy === "installing" ? "Installing…" : "Update"}
              </button>
            ) : (
              <button className="btn primary" type="button" onClick={() => openExternal(check.releases_url)}>
                Download
              </button>
            )}
          </div>
        ) : (
          <p className="muted small">You have the latest version.</p>
        )
      )}

      {busy === "installing" && progress && (
        <div className="llm-progress">
          <div className="llm-bar"><div style={{ width: `${pct}%` }} /></div>
          <span className="muted small">{formatBytes(progress.downloaded)}{progress.total ? ` of ${formatBytes(progress.total)}` : ""}</span>
        </div>
      )}

      {message && <p className="muted small llm-message">{message}</p>}

      <label className="checkbox">
        <input type="checkbox" checked={props.autoUpdate} onChange={(e) => props.onAutoUpdate(e.target.checked)} />
        Update automatically
        <span className="muted">
          {info?.can_install === false
            ? " (checks and tells you about new versions)"
            : " (installs new versions in the background; they start next time)"}
        </span>
      </label>
      <p className="muted small">
        Releases are signed; GhostPen only installs an update whose signature matches the key built into it.{" "}
        <a href="#" onClick={(e) => { e.preventDefault(); if (info) openExternal(info.releases_url); }}>Release notes</a>
      </p>
    </section>
  );
}
