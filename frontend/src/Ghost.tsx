import { useEffect, useRef } from "react";

/** What the ghost is doing: waiting, hearing you, thinking, pleased, or sorry. */
export type GhostMood = "idle" | "talking" | "working" | "done" | "error";

const BODY: Record<GhostMood, string> = {
  idle: "#e9ecf2",
  talking: "#9db0ff",
  working: "#9db0ff",
  done: "#9be3b8",
  error: "#ffb3b3",
};
const INK = "#1a1d26";
const LEVEL_GAIN = 1.9; // speech sits low in 0..1: boost it so a normal voice opens the mouth
const MOUTH_MIN = 0.5; // ry at rest
const MOUTH_RANGE = 2.4; // ry added at full level

/**
 * The GhostPen mascot, an inline SVG on a 24-grid. The mouth and the bob follow `level` (0..1,
 * the mic's RMS) while `mood` is "talking"; an own requestAnimationFrame loop eases it, so the
 * ~10 Hz level events look smooth and nothing above re-renders at 60 fps.
 * Idle floats (CSS, .ghost-idle). Both motions are off under prefers-reduced-motion.
 */
export default function Ghost({
  mood,
  level = 0,
  size = 27,
  className = "",
}: {
  mood: GhostMood;
  level?: number;
  size?: number;
  className?: string;
}) {
  const svgRef = useRef<SVGSVGElement>(null);
  const mouthRef = useRef<SVGEllipseElement>(null);
  const levelRef = useRef(0);
  levelRef.current = level;

  useEffect(() => {
    const svg = svgRef.current;
    if (mood !== "talking" || !svg) return;
    const still = window.matchMedia?.("(prefers-reduced-motion: reduce)").matches ?? false;
    let shown = 0;
    let raf = 0;
    const tick = () => {
      const target = Math.min(1, Math.max(0, levelRef.current) * LEVEL_GAIN);
      // Attack fast, release slow, like an audio meter.
      shown += (target - shown) * (target > shown ? 0.35 : 0.12);
      mouthRef.current?.setAttribute("ry", (MOUTH_MIN + shown * MOUTH_RANGE).toFixed(2));
      if (!still) svg.style.transform = `translateY(${(-2 * shown).toFixed(2)}px) scale(${(1 + 0.06 * shown).toFixed(3)})`;
      raf = requestAnimationFrame(tick);
    };
    raf = requestAnimationFrame(tick);
    return () => {
      cancelAnimationFrame(raf);
      svg.style.transform = "";
    };
  }, [mood]);

  return (
    <svg
      ref={svgRef}
      className={`ghost ${mood === "idle" ? "ghost-idle" : ""} ${className}`}
      viewBox="0 0 24 24"
      width={size}
      height={size}
      aria-hidden="true"
      focusable="false"
    >
      <path className="ghost-body" fill={BODY[mood]} d="M12 2a8 8 0 0 0-8 8v11l2.7-2 2.6 2 2.7-2 2.7 2 2.6-2L20 21V10a8 8 0 0 0-8-8z" />
      <g fill={INK} stroke={INK} strokeLinecap="round" strokeLinejoin="round">
        {(mood === "idle" || mood === "talking") && (
          <>
            <circle cx="9" cy="10.5" r="1.45" stroke="none" />
            <circle cx="15" cy="10.5" r="1.45" stroke="none" />
          </>
        )}
        {mood === "working" && <path d="M7.7 10.9h2.6M13.7 10.9h2.6" fill="none" strokeWidth="1.5" />}
        {mood === "done" && (
          <>
            <path d="M7.6 11.4q1.4-2.3 2.8 0M13.6 11.4q1.4-2.3 2.8 0" fill="none" strokeWidth="1.4" />
            <path d="M10 14.6q2 1.8 4 0" fill="none" strokeWidth="1.3" />
          </>
        )}
        {mood === "error" && (
          <>
            <circle cx="9" cy="11.6" r="0.95" stroke="none" />
            <circle cx="15" cy="11.6" r="0.95" stroke="none" />
            <path d="M10.2 16q1.8-1.5 3.6 0" fill="none" strokeWidth="1.2" />
          </>
        )}
        {mood === "talking" && <ellipse ref={mouthRef} cx="12" cy="15.4" rx="1.7" ry={MOUTH_MIN} stroke="none" />}
      </g>
    </svg>
  );
}
