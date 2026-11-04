import { useEffect, useState, type ReactNode } from "react";
import { getStatus, type Status } from "./api";

/** The active AI profile and model, kept fresh when the window comes back
 * (the profile may have changed in Settings meanwhile). Pass `given` to use a
 * status the page already tracks instead of fetching one. */
export function useActiveModel(given?: Status | null): Status | null {
  const [fetched, setFetched] = useState<Status | null>(null);
  useEffect(() => {
    if (given !== undefined) return;
    const load = () => { getStatus().then(setFetched).catch(() => {}); };
    load();
    window.addEventListener("focus", load);
    return () => window.removeEventListener("focus", load);
  }, [given]);
  return given !== undefined ? given : fetched;
}

/** The pill's text: profile, a separator, model. Each part is its own element so the
 * pill's flex gap spaces the dot evenly on both sides (loose spaces in a flex row collapse). */
function PillLabel({ profile, model }: { profile: string; model?: string | null }) {
  return (
    <>
      <span className="page-header-name">{profile}</span>
      {model ? (
        <>
          <span className="page-header-sep" aria-hidden="true">·</span>
          <span className="page-header-model">{model}</span>
        </>
      ) : null}
    </>
  );
}

/** The profile and model as the accent-tinted pill the page headers show (or
 * nothing while the status is unknown). */
export function ModelPill({ status }: { status: Status | null }) {
  if (!status?.active_profile) return null;
  return (
    <span className="page-header-pill" title="The AI profile and model in use">
      <span className="page-header-pill-dot" aria-hidden="true" />
      <PillLabel profile={status.active_profile} model={status.active_model} />
    </span>
  );
}

/**
 * The one header every window shares (Settings, Playground, Summary,
 * Meetings): a title, a subtitle line beneath it, and on the right the
 * profile and model that do the AI work, as one accent-tinted pill, then any
 * actions of the page.
 */
export default function PageHeader({
  title,
  subtitle,
  status,
  onPillClick,
  children,
  className = "",
}: {
  title: string;
  subtitle?: ReactNode;
  /** The page's own status, when it keeps one; omitted, the header fetches it. */
  status?: Status | null;
  /** Makes the pill a button (Settings: jump to the AI profile). */
  onPillClick?: () => void;
  /** Page actions, shown after the pill. */
  children?: ReactNode;
  className?: string;
}) {
  const s = useActiveModel(status);
  const label = s?.active_profile
    ? <PillLabel profile={s.active_profile} model={s.active_model} />
    : null;
  return (
    <header className={`page-header ${className}`.trim()} data-oriel-drag-region>
      <div className="page-header-text">
        <h1 className="page-header-title">{title}</h1>
        {subtitle ? <p className="page-header-sub">{subtitle}</p> : null}
      </div>
      <div className="page-header-side">
        {label && (onPillClick ? (
          <button type="button" className="page-header-pill" title="The AI profile and model in use. Click to change." onClick={onPillClick}>
            <span className="page-header-pill-dot" aria-hidden="true" />{label}
          </button>
        ) : (
          <span className="page-header-pill" title="The AI profile and model in use">
            <span className="page-header-pill-dot" aria-hidden="true" />{label}
          </span>
        ))}
        {children}
      </div>
    </header>
  );
}
