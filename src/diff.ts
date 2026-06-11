// Tiny word-level diff (LCS) for the Proofread preview — no dependencies.
// Tokenizes on whitespace boundaries (keeping the whitespace as its own tokens so
// reconstruction is faithful), runs a classic longest-common-subsequence over the tokens,
// and emits a flat list of segments tagged equal / added / removed. The UI renders removed
// words struck-through (red) and added words highlighted (green), Apple-style.

export type DiffSeg = { type: "equal" | "added" | "removed"; text: string };

// Split into word + whitespace tokens, e.g. "a  b" -> ["a", "  ", "b"].
function tokenize(s: string): string[] {
  return s.match(/\s+|\S+/g) ?? [];
}

export function wordDiff(before: string, after: string): DiffSeg[] {
  const a = tokenize(before);
  const b = tokenize(after);
  const n = a.length;
  const m = b.length;

  // LCS table ((n+1) x (m+1)). For typical selection sizes this is small.
  const dp: number[][] = Array.from({ length: n + 1 }, () => new Array(m + 1).fill(0));
  for (let i = n - 1; i >= 0; i--) {
    for (let j = m - 1; j >= 0; j--) {
      dp[i][j] = a[i] === b[j] ? dp[i + 1][j + 1] + 1 : Math.max(dp[i + 1][j], dp[i][j + 1]);
    }
  }

  const segs: DiffSeg[] = [];
  const push = (type: DiffSeg["type"], text: string) => {
    if (!text) return;
    const last = segs[segs.length - 1];
    if (last && last.type === type) last.text += text;
    else segs.push({ type, text });
  };

  let i = 0;
  let j = 0;
  while (i < n && j < m) {
    if (a[i] === b[j]) {
      push("equal", a[i]);
      i++;
      j++;
    } else if (dp[i + 1][j] >= dp[i][j + 1]) {
      push("removed", a[i]);
      i++;
    } else {
      push("added", b[j]);
      j++;
    }
  }
  while (i < n) push("removed", a[i++]);
  while (j < m) push("added", b[j++]);
  return segs;
}
