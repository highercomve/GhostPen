import { Level } from "./api";

const LEVELS: Level[] = ["subtle", "balanced", "strong"];

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
      <div className="seg">
        {LEVELS.map((l) => (
          <button
            key={l}
            className={`seg-btn ${level === l ? "active" : ""}`}
            onClick={() => setLevel(l)}
          >
            {l[0].toUpperCase() + l.slice(1)}
          </button>
        ))}
      </div>
    </div>
  );
}
