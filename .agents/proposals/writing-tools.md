# Proposal B — "Writing Tools Card" (Apple Intelligence aesthetic)

*Frontend-only redesign of all four GhostPen surfaces. Honors ADR-009 (preview before
paste) and the UI review's "result-preview palette" direction.*

## Philosophy

Show the result, let the user approve it. The whole field — Apple Writing Tools, Word,
Raycast, Click to Do — surfaces generative output **before** committing it; GhostPen's only
real divergence was pasting blind. Proposal B leans into the Apple Writing Tools look:
soft 14–20px radii, generous spacing, a gentle accent gradient, light-first with system
dark. Verbs come first (Proofread, Rewrite); tones are chips under Rewrite; the free-text
"Describe your change…" field sits on top. Trust is built three ways: a streaming preview, an
inline word-diff for Proofread, and a clear Replace / Copy / Back choice that only touches
the document on confirm.

## Per-surface changes

**Action menu (`Menu.tsx`).** Rebuilt as a rounded card popover (480×560). Top: the
describe field. Then a soft selection preview and the destination line ("→ Ollama (local)")
with the manual badge. Primary verb **Proofread** as a full-width gradient button; under
**Rewrite**, tone chips Friendly (→ `casual`), Professional, Concise, Expand, plus a
**Translate** chip that opens the existing 2-column language grid. Custom actions appear as
extra chips. Intensity is a subtle inline segmented pill. Full keyboard nav preserved: arrows
/ hjkl between chips, Enter activates, 1–9 quick-run, Esc steps sub-view → menu → hide.

**Result preview.** Choosing a verb/chip streams the result into the card via
`processTextStream(action, targetLang, level, selection)`, accumulating `ghostpen://chunk`
with a soft shimmer while generating. **Proofread** renders an inline word-diff (LCS in
`diff.ts`, no deps): removed tokens struck-through/red, added tokens highlighted/green.
Buttons: **Replace** (primary), **Copy** (`navigator.clipboard`), **← Back**.

**The diff approach.** `diff.ts` tokenizes both strings on whitespace (keeping whitespace as
tokens for faithful reconstruction), runs a classic LCS over the tokens, and emits flat
equal/added/removed segments which the result view styles. Small and dependency-free, sized
for selection-length text.

**Captions (`Captions.tsx`).** Translucent rounded dark control bar that is **hover-reveal**
(idle = text only; mouse-over fades in Start/Stop, 🌐 Translate, A−/A+ live font size, 👻
Ghost, ⚙, ✕). The caption text bar stays a **solid opaque** dark rounded pill — load-bearing
for the wlroots transparent-repaint smear; not negotiable. Ghost mode + `captions-show` +
MAX_LINES=2 unchanged. A−/A+ adjust live `fontSize` in local state.

**Settings / Playground.** Same logical sections, restyled with soft rounded premium cards.
Settings **auto-saves on change** (debounced) with a transient "Saved ✓"; an explicit
"Save now" remains. Playground keeps its functionality, restyled to match.

## The Replace re-run tradeoff

There is no generate-only / apply-only backend command yet, so **Replace re-runs the model**
via `processAiAction(...)` to apply through the clipboard+paste path (manual mode → Copy +
"press Ctrl+V"). The streamed preview and the applied output may therefore differ slightly.
The clean fix is the backend generate/apply split (**TODO 12.1**); until then the re-run is
the honest, contract-preserving choice. Custom instructions have no streaming generate path,
so the describe field applies directly via `process_ai_custom` and then shows the same result
card (Copy + Done).
