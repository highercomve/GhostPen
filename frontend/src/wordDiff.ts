// A small word-level diff (longest common subsequence) for the Playground's
// "Show changes": what the result added to the input and what it dropped.

export type DiffOp = { type: "same" | "ins" | "del"; text: string };

/** Words and single punctuation marks, each with the whitespace before it, so
 * joining the pieces gives the text back. Punctuation is its own piece: fixing
 * "tomorow." marks the word, not the full stop. */
function tokens(text: string): string[] {
  return text.match(/\s*(?:[\p{L}\p{N}_]+(?:['\u2019-][\p{L}\p{N}_]+)*|[^\s\p{L}\p{N}_])/gu) ?? [];
}

const WORD_CHAR = /[\p{L}\p{N}_]/u;

const key = (t: string) => t.trim();

// The LCS table is n×m; past this a precise diff isn't worth the memory, and
// the changed middle shows as one removal and one insertion.
const MAX_CELLS = 4_000_000;

function push(out: DiffOp[], type: DiffOp["type"], text: string) {
  if (!text) return;
  const last = out[out.length - 1];
  if (last && last.type === type) last.text += text;
  else out.push({ type, text });
}

/** Adds a piece to the result, keeping neighbouring words apart. The piece's
 * leading whitespace stays outside a marked change, and a deleted word keeps
 * the space it had, so "hey" replaced by "Hey" reads "hey Hey", not "heyHey". */
function emit(out: DiffOp[], type: DiffOp["type"], raw: string) {
  let text = raw;
  const startsChange = type !== "same" && out[out.length - 1]?.type !== type;
  const lead = startsChange ? (raw.match(/^\s+/)?.[0] ?? "") : "";
  if (startsChange && lead) {
    text = raw.slice(lead.length);
    // A deletion's spacing came from the old text; the insertion's is the result's own.
    if (type === "ins") push(out, "same", lead);
  }
  if (!text) return;

  const prev = out[out.length - 1];
  if (prev && (type !== "same" || prev.type !== "same")) {
    const before = prev.text[prev.text.length - 1];
    const apart = /\s/.test(before) || /^\s/.test(text);
    const touching = WORD_CHAR.test(before) && WORD_CHAR.test(text[0]);
    if (!apart && (touching || (type === "del" && lead))) push(out, "same", " ");
  }
  push(out, type, text);
}

/** The edits that turn `before` into `after`: unchanged words, insertions
 * (only in `after`) and deletions (only in `before`). */
export function wordDiff(before: string, after: string): DiffOp[] {
  const a = tokens(before);
  const b = tokens(after);
  const out: DiffOp[] = [];

  // The unchanged start and end need no table.
  let head = 0;
  while (head < a.length && head < b.length && key(a[head]) === key(b[head])) head++;
  let tail = 0;
  while (tail < a.length - head && tail < b.length - head && key(a[a.length - 1 - tail]) === key(b[b.length - 1 - tail])) tail++;

  for (let i = 0; i < head; i++) emit(out, "same", b[i]);

  const am = a.slice(head, a.length - tail);
  const bm = b.slice(head, b.length - tail);
  const n = am.length;
  const m = bm.length;

  if (n * m > MAX_CELLS) {
    emit(out, "del", am.join(""));
    emit(out, "ins", bm.join(""));
  } else if (n === 0 || m === 0) {
    emit(out, "del", am.join(""));
    emit(out, "ins", bm.join(""));
  } else {
    // lcs[i][j]: the common length of am[i..] and bm[j..].
    const w = m + 1;
    const lcs = new Uint16Array((n + 1) * w);
    for (let i = n - 1; i >= 0; i--) {
      for (let j = m - 1; j >= 0; j--) {
        lcs[i * w + j] = key(am[i]) === key(bm[j])
          ? lcs[(i + 1) * w + j + 1] + 1
          : Math.max(lcs[(i + 1) * w + j], lcs[i * w + j + 1]);
      }
    }
    let i = 0;
    let j = 0;
    while (i < n && j < m) {
      if (key(am[i]) === key(bm[j])) {
        emit(out, "same", bm[j]);
        i++;
        j++;
      } else if (lcs[(i + 1) * w + j] >= lcs[i * w + j + 1]) {
        emit(out, "del", am[i++]);
      } else {
        emit(out, "ins", bm[j++]);
      }
    }
    while (i < n) emit(out, "del", am[i++]);
    while (j < m) emit(out, "ins", bm[j++]);
  }

  for (let i = b.length - tail; i < b.length; i++) emit(out, "same", b[i]);
  // Trailing whitespace of the result.
  push(out, "same", after.slice(after.trimEnd().length));
  return out;
}
