# Proposal A — "Command Palette" UI redesign

*Frontend-only redesign of all four GhostPen surfaces toward a Raycast / Spotlight /
PowerToys Advanced Paste aesthetic: utilitarian, keyboard-first, dense, dark launcher look
with system light/dark via the existing CSS custom properties. Derived from the UI review
and ADR-009.*

## Design philosophy

The whole app should feel like a developer launcher: one summoned, centered surface you
drive entirely from the keyboard, where typing is the primary verb. The review confirmed the
centered-palette pattern is correct on every platform (the only one possible on Wayland), so
this proposal doubles down on it rather than chasing near-selection anchoring.

## What changed per surface

**Action menu (`Menu.tsx`) — the centerpiece.** The freeform prompt bar moved from the
bottom to a **search/prompt input pinned at the top**, autofocused on every summon. It is
dual-purpose: typing fuzzy-filters the action list (case-insensitive substring over
label+hint); pressing Enter with no matching row runs the query as a custom instruction. Each
row shows icon · label · hint · a **numbered badge (1–9)** on the right. The intensity control
shrank into a compact segmented control in a **footer hint strip** that also shows the active
keybindings (`↑↓ navigate · ↵ run · esc close`) and the destination (`→ Ollama · gemma4:e4b`,
with a `manual` badge in manual mode). Choosing an action opens a **result-preview view** that
**streams** the model output via `processTextStream` over the current selection; footer offers
`↵ paste/replace · c copy · r retry · e edit · esc back`. Confirming calls the real
`processAiAction`/`processAiCustom`, preserving the clipboard-snapshot/paste/restore contract
and manual-copy degradation.

**Captions (`Captions.tsx`).** Slim monospace-leaning strip with **hover-reveal** controls
(idle = caption text only; mouse-over fades the control bar in), a `● listening…` status dot
when running with no captions yet, and the unchanged opaque caption pill (load-bearing for the
wlroots repaint bug), ghost/click-through mode, and `captions-show` handler. MAX_LINES stays 2.

**Settings (`Settings.tsx`).** One long scroll → a **left-rail tabbed** layout (General ·
AI Profiles · Actions · Captions). Same controls, grouped; Save button retained.

**Playground (`Playground.tsx`).** Restyled dense/dark via CSS; functionality unchanged.

## Keyboard model

Search input always focused. `↑↓` move the row cursor; `Enter` runs the highlighted row or
the query-as-instruction; `Ctrl/Alt+1–9` quick-run a numbered row (plain digits type into the
search box). `Esc` clears a query, then dismisses; from any sub-view it steps back to the menu
first. Translate grid uses arrows + Enter. The preview view: `Enter` apply, `c/r/e` copy /
retry / edit, `Esc` back.

## Screenshots in words

A 560×440 dark rounded card. Top: a large search field with a sparkle glyph and 🧪/⚙ on the
right. Below: a tight list of rows, each a faint pill that fills accent-blue when selected,
trailing a small monospace number chip. A thin bottom strip holds a tri-segment intensity
toggle, grey `kbd`-styled hints, and the right-aligned destination. The preview view swaps the
list for streaming monospace text with a blinking caret and a paste/copy/retry hint strip.

## Known tradeoff

The preview re-runs the model: the streamed preview (`processTextStream`) and the apply step
(`processAiAction`) are two separate generations, so output can differ between what was
previewed and what is pasted, and the model runs twice. The proper fix is the backend
**generate/apply split** (TODO 12.1 / ADR-009 P1.1) — generate streams once with no clipboard
side-effects, apply writes/pastes that exact text. Freeform instructions additionally have no
streaming command today, so their preview shows an "apply to see the result" note and applies
directly via `processAiCustom`.
