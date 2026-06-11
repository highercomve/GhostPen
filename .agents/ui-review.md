# UI/UX Review — GhostPen interfaces vs. OS-native equivalents

*Architect review, 2026-06-11. Companion to ADR-009 in [`architecture.md`](./architecture.md).*

GhostPen's two user-facing surfaces have direct OS-native equivalents that have been through
years of design iteration and accessibility research:

- the **action menu** ↔ Apple Intelligence Writing Tools, Windows Click to Do / PowerToys
  Advanced Paste, Grammarly, Raycast AI;
- the **captions overlay** ↔ Windows 11 Live Captions, macOS Live Captions, Android Live
  Caption, Chrome Live Caption.

This document audits the current UI, summarizes what the OS vendors converged on (and why),
and proposes a prioritized redesign. Verdict up front: **the current UX is structurally
right** — centered summoned palette, keyboard-first, opaque bottom caption pill — and most
of what the research surfaced are refinements, not rewrites. Two gaps are fundamental:
the menu **pastes AI output without showing it first**, and captions **appear only in 5 s
finalized chunks** with chrome that is always visible.

---

## 1. Current state (audited 2026-06-11)

### 1.1 Action menu (`Menu.tsx`, `main` window 320×620)
- Header (brand + 🧪/⚙), active profile/model line, selection preview, intensity
  segmented control (subtle/balanced/strong), 5 preset actions + Translate submenu +
  custom actions, freeform **prompt bar at the bottom**.
- Fully keyboard-driven: ↑/↓ or j/k, ←/→ intensity, Enter, 1–9 quick-run, Esc.
- `process_ai_action` runs the model and **pastes immediately**; the result view appears
  *after* the paste already happened (in manual mode it shows "Result copied").
- Streaming exists in the backend (`process_text_stream`, `ghostpen://chunk`) but only the
  Playground uses it.

### 1.2 Captions overlay (`Captions.tsx`, `captions` window 900×170)
- Control bar (Start/Stop, 🌐 Translate, 👻 Ghost, ⚙, ✕) **always visible** unless the user
  explicitly enters ghost (click-through) mode; getting controls back requires the tray.
- One opaque bottom pill, max 2 lines, final-only captions every `chunkSeconds` (default 5 s).
  No partial/in-progress text, no drag, no auto-hide on silence, fixed bottom-center
  placement (Hyprland rules / OS default), font size set in Settings only.

### 1.3 Settings (`Settings.tsx`)
One long scrolling page (Diagnostics, AI Profiles, Behaviour, Custom Actions, Live
Captions) with an explicit Save button. Functional, but the Captions section now holds 8
controls and the page keeps growing.

---

## 2. What the OS vendors do (research summary)

Full sourced reports were gathered from Microsoft/Apple/Google support & design docs,
WWDC sessions, GNOME/KDE HIGs, and product manuals. Condensed findings:

### 2.1 Selection-based AI text actions

| Product | Invocation | Placement | Action set | Result handling |
|---|---|---|---|---|
| **Apple Writing Tools** (macOS 15) | right-click / hover affordance on selection | popover **anchored to selection** (possible only because Apple owns the text stack) | "Describe your change" free-text on top; Proofread, Rewrite; tone chips Friendly/Professional/Concise; Summary/Key Points/List/Table | replaces inline **with preview**: proofread underlines each change, arrows step through, Original/Revert toggle; Copy is the fallback for read-only text |
| **Windows Click to Do** (Copilot+) | Win+click freezes screen into overlay | menu next to selected entity | Summarize, bulleted list, Rewrite (Casual/Formal/Refine) — on-device Phi Silica | result panel, **copy only** (it OCRs rendered pixels; can't paste back — GhostPen's clipboard path is strictly more capable) |
| **PowerToys Advanced Paste** | Win+Shift+V | small centered popup | list of paste-as transforms + **AI prompt box**; **Ctrl+1…n numbered shortcuts** | transforms clipboard, then pastes |
| **Grammarly desktop** | always-on floating widget | anchored near every text field | suggestion cards with old→new + explanation | apply per card. Top user complaint: **intrusiveness** of ambient chrome |
| **Raycast AI** | global hotkey | **centered command palette** | input-first; fuzzy-filtered commands; Fix Spelling, Improve Writing, Change Tone…; per-command hotkeys; "Quick Fix" = one hotkey, no UI at all | **streams into a result view**; ⌘↵ paste-replace, ⌥↵ insert, Copy, Continue in Chat |

**Positioning verdict.** Near-selection anchoring requires being inside the text stack
(Apple), injecting per-app (Grammarly), or being the compositor (Click to Do). A
third-party cross-platform overlay has none of these, and on Wayland clients cannot read
cursor/selection coordinates or self-position at all. The launcher ecosystem
(Raycast/Alfred/KRunner/GNOME search) settled on the **centered palette** even where
positioning *is* possible — same place every time builds muscle memory. GhostPen's centered
menu is therefore the *correct* pattern, not a compromise. (Optional: wlr-layer-shell
placement on Hyprland/KDE/Sway; never XWayland cursor tricks.)

**Result-handling verdict.** Every surveyed product **shows generative output before
committing it** (Apple inline-with-revert, Word hover-preview candidates, Raycast result
view, Click to Do panel). Only deterministic fixes apply instantly (Raycast Quick Fix).
GhostPen's paste-without-preview is the one place it diverges from the entire field.

### 2.2 Live captions overlays

| Product | Placement & movement | Chrome | Text flow | Idle behavior |
|---|---|---|---|---|
| **Windows 11 Live Captions** (Win+Ctrl+L) | Top (default) / Bottom **docked in reserved desktop space** (never occludes), or Floating; drag edge = taller = more history | one ⚙ inside the window holds *everything*: position, mic-include, profanity, language, caption style (system caption themes + custom editor with live preview) | continuous paragraph, words appear as recognized and are **revised in place** | shows status text ("Ready to caption…") |
| **macOS Live Captions** | floating dark translucent panel, drag anywhere, resize any edge; menu-bar item has **"Restore Default Position"** | **chromeless until hover** — hover reveals pause, mic toggle, font A/A | progressive | **auto-hides when no audio; reappears with sound**; "Keep Onscreen" pins it |
| **Android Live Caption** | small black box, lower third; **touch-hold-drag** to move, **double-tap to expand** (2 → ~12 lines) | none at all | progressive, self-correcting | **appears with media, disappears when it stops**; toggle lives under the volume rocker |
| **Chrome Live Caption** | bubble pinned bottom of browser, draggable, expand chevron for history | minimal (expand + close) | progressive | per-media-session bubble |
| **GNOME LiveCaptions** (aprilasr) | small always-on-top dark window | minimal | **token-confidence fading: low-confidence words render grey and solidify** | — |

**Subtitle readability conventions** (BBC/Netflix/FCC/WCAG): max **2 lines**, **~37–42
chars/line**, bottom-center, white on a semi-opaque dark band (≥4.5:1 contrast), break at
clause boundaries, ~160–180 WPM, and **user-restylable captions are themselves an
accessibility requirement** (the core advance of CEA-708).

**Partial-result consensus** (Azure Speech captioning guidance, GNOME, Meet/Teams): render
word-by-word — it feels alive and lowers perceived latency — but **stabilize**: withhold or
visually fade the unstable trailing words so visible text never backtracks/flickers;
replace with the final on utterance end.

---

## 3. Review verdict

### What the current UI already gets right (keep)
1. **Centered summoned palette** — the only placement correct on every platform incl.
   Wayland; also the Linux DE convention (KRunner/GNOME search).
2. **Keyboard-first** menu (arrows/jk, 1–9, Esc) — matches Advanced Paste/Raycast.
3. **Summoned, never ambient** — avoids Grammarly's #1 complaint. Nothing renders until
   the hotkey; Esc dismisses.
4. **Opaque bottom caption pill, 2 lines, white-on-dark** — matches broadcast/WCAG
   convention *and* is load-bearing for the wlroots repaint bug.
5. **Free-text prompt escape hatch** — Apple ("Describe your change") and PowerToys both
   ship it.
6. **Active-destination line** ("→ Ollama (local)") — a privacy affordance none of the big
   vendors surface this clearly.
7. **Manual-copy degradation** — Click to Do ships copy-only as its *only* mode; ours is a
   proven pattern, not a broken state.

### Gaps (ranked by impact)

**G1 — No result preview before paste (menu).** The entire field shows generative output
before committing. We paste blind, into someone's email. Streaming infra already exists.

**G2 — Captions are 5 s finalized chunks.** Every OS captioner renders progressively.
Chunked-only display reads as laggy and drops the "live" feel.

**G3 — Captions chrome always visible.** A control bar permanently on top of a video is
what ghost mode papers over; macOS solves it with hover-reveal, Android with no chrome.

**G4 — No auto-hide on silence / no keep-onscreen choice (captions).**

**G5 — No drag / position memory / restore-default (captions).** All four OS captioners
are user-movable; FCC explicitly requires captions not to block essential content, and
only the user knows what matters (Google's deaf/HoH co-design finding).

**G6 — Prompt bar is at the bottom and is prompt-only.** Palette convention is input on
top, focused on open, doubling as fuzzy filter; with custom actions the list will outgrow
ten items.

**G7 — No diff for Proofread.** Apple underlines changes; Word/Grammarly show old→new.
Diff = trust before Replace.

**G8 — Settings is one long page; caption styling is minimal** (size only; no
presets/colors/opacity — CEA-708 spirit says viewers restyle captions).

---

## 4. Proposed design

### 4.1 Action menu → "result-preview palette"

Flow change (the big one):

```
hotkey → palette (same as today)
  → user picks action / types instruction
  → RESULT VIEW in the same window:
       output streams in (ghostpen://chunk), spinner→text progressively
       header: "Proofread · → Ollama (local)"
       Proofread: inline word-diff (changed spans highlighted)
       [Enter] Paste/Replace   [C] Copy   [R] Retry   [E] Edit instruction   [Esc] back
  → paste + clipboard restore happen ONLY on confirm
```

- Backend: split `process_ai_action` into *generate* (streamed, no clipboard side effects)
  and *apply* (write clipboard → hide → paste → restore). Manual mode: "apply" = copy +
  "press Ctrl+V" hint (unchanged contract, ADR-003/005 untouched).
- **Prompt bar moves to the top** and becomes dual-purpose: typing fuzzy-filters the action
  list; Enter with no matching action runs the text as a custom instruction. Focus it on
  open; first ↓ moves into the list. 1–9 still quick-run (shown as small numbered badges).
- Keep: intensity bar, translate submenu, selection preview, destination line.
- Window: from 320×620 portrait to a palette-shaped ~520×420 (input row + ≤7 action rows;
  result view reuses the same box). Resizable result view later.
- Later (separate ADR if pursued): per-action global "Quick Fix" hotkey that runs
  proofread+paste with no UI (Raycast's end-state for power users) — opt-in because it
  reintroduces blind paste deliberately.

### 4.2 Captions overlay → "chromeless, alive, movable"

- **Hover-reveal controls** (macOS): idle = caption pill only; mouse-over fades in the
  control bar. Ghost mode remains the explicit click-through state (hover can't work
  there); tray stays the escape hatch.
- **Progressive text**: emit `ghostpen://caption-partial` alongside the final event.
  v1: re-transcribe the accumulating window every ~0.5–1 s, render the changing tail
  **faded/grey**, solidify on chunk finalization (never backtrack solid text — Azure
  stable-partial guidance, GNOME confidence-fading). This pairs with the existing
  overlap/VAD follow-up (TODO 11.10) but doesn't require it.
- **Auto-hide on silence**: fade the pill out after ~6 s without captions, back in on the
  next one; "Keep onscreen" pin in the control bar. (CSS fade only — the window stays
  mapped, so no Wayland focus churn.)
- **Drag + position memory + restore default**: `data-tauri-drag-region` on the pill
  (works on Wayland — interactive move is compositor-driven), persist outer position on
  Win/macOS/X11; on Wayland placement stays compositor-side (document Hyprland rule),
  tray gets "Reset captions position".
- **Wrap discipline**: cap lines at ~42 chars (split at clause/punctuation before
  emitting), keep 2-line max; "expand" affordance (double-click pill) showing more history
  can come later (Android/Windows size→history mapping).
- **Caption style**: presets (default white-on-black, yellow-on-black, large text) +
  size/opacity sliders — in a gear popover *inside the overlay* (Windows pattern), backed
  by the same settings store.

### 4.3 Settings → tabbed
Sidebar/tabs: **General** (hotkey, behaviour, diagnostics) · **AI Profiles** · **Actions**
(custom actions) · **Captions**. Auto-save on change with a transient "Saved ✓" (current
explicit Save stays until then; lowest priority).

### 4.4 Explicitly rejected
- **Popup-near-selection** — impossible on Wayland, fragile elsewhere, and the centered
  palette is independently the stronger pattern. (Optional layer-shell nicety later.)
- **Always-on floating widget** (Grammarly) — intrusiveness is its defining complaint.
- **Auto-apply without preview** as default — only acceptable as the opt-in Quick Fix.
- **Docked reserved-space captions** (Windows top-dock) — needs OS work-area APIs per
  platform; floating + drag covers the need.

## 5. Prioritized roadmap

| # | Change | Surface | Effort | Why first |
|---|---|---|---|---|
| P1.1 | Result preview + streaming before paste (generate/apply split) | menu + backend | M | Trust-anchor; the one real divergence from the whole field |
| P1.2 | Prompt bar → top, dual filter/instruction; numbered badges | menu | S | Palette convention; scales custom actions |
| P1.3 | Hover-reveal caption controls | captions | S | Biggest visual win; pure CSS/JSX |
| P1.4 | Auto-hide on silence + Keep-onscreen pin | captions | S | macOS/Android behavior; pure frontend |
| P2.1 | Partial captions w/ faded tail | captions + STT worker | M–L | "Live" feel; pairs with 11.10 |
| P2.2 | Proofread inline diff in result view | menu | S–M | Trust before Replace |
| P2.3 | Drag + position memory + restore default | captions | M | Wayland caveats documented |
| P2.4 | Caption style presets + gear popover in overlay | captions | M | CEA-708/Windows pattern |
| P3.1 | Tabbed Settings + auto-save | settings | M | Quality of life |
| P3.2 | Opt-in Quick Fix global hotkey (no-UI proofread) | backend | M | Power users; deliberate blind paste |
| P3.3 | Expandable caption history; ~42-char line shaping | captions | M | Nice-to-have |

**Validation criteria.** P1.1: a wrong/hallucinated result must be discardable with Esc and
leave the user's document and clipboard untouched. P2.1: solid text never changes once
rendered. All: menu interaction stays fully keyboard-completable; captions stay legible at
4.5:1 over arbitrary backgrounds; no regression of Critical rules 1–4 (PAL routing,
clipboard contract, no panics, bounded network).

---
*Last updated: 2026-06-11*
