# Proposal C — "Glass HUD" (minimal, chromeless, fast)

*Frontend-only redesign, companion to [`../ui-review.md`](../ui-review.md) and ADR-009.*

## Philosophy

Speed over ceremony. Where the result-preview palette (Proposal A) optimizes for *trust*,
Glass HUD optimizes for *velocity*: a tiny, frosted, icon-forward overlay that summons,
applies, and dismisses in one glance — closer to macOS Live Captions minimalism and
Raycast's "Quick Fix" than to a card. Everything is ambient and translucent; nothing
lingers. This is the deliberate opposite end of the spectrum from a preview-heavy design.

The defining tradeoff: **instant-apply, no result preview.** Clicking or pressing Enter on
a tile calls `processAiAction` directly and shows only a tiny confirmation ("✓ Pasted" /
"✓ Copied — Ctrl+V"), mirroring today's behavior. ADR-009 / the UI review note that
auto-apply-without-preview is acceptable *only as an opt-in Quick Fix* — this proposal
embraces that mode as its **default**, for users who knowingly prioritize speed and trust a
local model on short edits. The output is still shown after the fact and remains on the
clipboard, so it is never lost; what is skipped is the *gate* before paste.

## Per-surface changes

- **Action menu (`Menu.tsx`).** Chromeless glass panel (`backdrop-filter: blur()` over a
  translucent fill, with an **opaque fallback** color underneath for compositors lacking
  alpha). Actions become a **3-column grid of square icon tiles** (Proofread, Pro, Casual,
  Concise, Expand, Translate, + custom actions) with numbered badges. Keyboard nav is true
  **grid movement** (←/→ within a row, ↑/↓ across rows), Enter activates, 1–9 quick-run, Esc
  closes. Intensity collapses to three inline dots; the prompt bar shrinks to a compact
  pill at the bottom for freeform `processAiCustom`. Destination is a small model chip in
  the header. Window: 360×400, `transparent: true`, shadow off.
- **Captions (`Captions.tsx`).** Fully **chromeless** — idle shows only the opaque caption
  pill. Controls (Start/Stop, 🌐, 📌 pin, 👻 Ghost, ⚙, ✕) live in a glass bar that
  **fades in only on hover**. **Auto-hide on silence**: after ~6 s with no caption the pill
  fades out (CSS opacity only — the window stays mapped, no Wayland focus churn) and fades
  back on the next caption; the **📌 "Keep onscreen" pin** disables this. The pill is
  **draggable** via `data-tauri-drag-region`. The text bar stays **opaque** (wlroots repaint
  bug — required), MAX_LINES=2, ghost mode + `ghostpen://captions-show` preserved.
- **Settings / Playground.** Restyled minimal/glassy (rounded cards, pill buttons);
  controls and behavior unchanged.

## Contracts preserved

`ghostpen://show` resets to the grid + re-reads selection; plain `focus` only refreshes
(never wipes a result); Esc steps sub-view → menu → hide; manual-copy mode degrades to the
"Copied — Ctrl+V" confirmation; full keyboard operability throughout. No backend changes.

## Caveats

Drag on Wayland is compositor-driven and **position is not persisted** in this
frontend-only pass (would need backend window-state work / a tray "reset position"). Glass
blur depends on compositor support; the opaque fallback guarantees legibility without it.
