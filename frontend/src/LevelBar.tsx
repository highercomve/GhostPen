import { Level, LEVELS } from "./api";

export default function LevelBar({
  level,
  setLevel,
}: {
  level: Level;
  setLevel: (l: Level) => void;
}) {
  return (
    <div className="level" title="Applies to Professional / Casual / Concise / Expand">
      <span className="level-label">Intensity</span>
      <div className="seg" role="group" aria-label="Intensity">
        {LEVELS.map((l) => (
          <button
            key={l}
            className={`seg-btn ${level === l ? "active" : ""}`}
            aria-pressed={level === l}
            onClick={() => setLevel(l)}
          >
            {l[0].toUpperCase() + l.slice(1)}
          </button>
        ))}
      </div>
    </div>
  );
}
