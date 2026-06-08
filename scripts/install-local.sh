#!/usr/bin/env bash
#
# GhostPen — local build & install (Linux)
#
# Builds a production binary with the Tauri CLI (embedded frontend, no dev server) and
# installs it for the current user, with a desktop entry + icon so it shows in your app
# launcher. This is the "from source" path; for prebuilt packages use the GitHub Releases
# (.deb / .rpm / .AppImage) produced by the release workflow.
#
# IMPORTANT: builds via `tauri build`, NOT `cargo build` — a bare cargo build leaves the app
# pointing at the Vite dev server (blank "Could not connect to localhost" window).
#
# Usage:
#   ./scripts/install-local.sh                 # build + install to ~/.local
#   ./scripts/install-local.sh --prefix ~/.local
#   ./scripts/install-local.sh --no-build      # install the already-built binary only
#   ./scripts/install-local.sh --no-desktop    # binary only, skip .desktop + icon
#   ./scripts/install-local.sh -h
#
set -euo pipefail

# ---- locate the repo root (this script lives in scripts/) ----------------------------
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# ---- logging -------------------------------------------------------------------------
info()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn()  { printf '\033[1;33m[warn]\033[0m %s\n' "$*" >&2; }
die()   { printf '\033[1;31m[error]\033[0m %s\n' "$*" >&2; exit 1; }

# ---- options -------------------------------------------------------------------------
PREFIX="${PREFIX:-$HOME/.local}"
DO_BUILD=1
DO_DESKTOP=1

while [ $# -gt 0 ]; do
  case "$1" in
    --prefix)      PREFIX="${2:?--prefix needs a directory}"; shift 2 ;;
    --prefix=*)    PREFIX="${1#*=}"; shift ;;
    --no-build)    DO_BUILD=0; shift ;;
    --no-desktop)  DO_DESKTOP=0; shift ;;
    -h|--help)
      # Print the leading comment block (everything after the shebang up to the first code line).
      awk 'NR==1{next} /^#/{sub(/^# ?/,""); print; next} {exit}' "${BASH_SOURCE[0]}"
      exit 0 ;;
    *) die "Unknown option: $1 (try -h)" ;;
  esac
done

BIN_DIR="$PREFIX/bin"
APP_DIR="$PREFIX/share/applications"
ICON_DIR="$PREFIX/share/icons/hicolor/128x128/apps"
BIN_SRC="$ROOT/src-tauri/target/release/ghostpen"

# ---- build ---------------------------------------------------------------------------
if [ "$DO_BUILD" -eq 1 ]; then
  command -v cargo >/dev/null 2>&1 || die "cargo not found. Install Rust (https://rustup.rs) and re-run."
  command -v npm   >/dev/null 2>&1 || die "npm not found. Install Node.js and re-run."

  cd "$ROOT"
  if [ ! -d node_modules ]; then
    info "Installing frontend dependencies (npm ci)…"
    npm ci || npm install
  fi

  info "Building release binary (tauri build --no-bundle)…"
  # --no-bundle: we only need the executable for a local install, not deb/rpm/appimage.
  npm run tauri -- build --no-bundle
fi

[ -x "$BIN_SRC" ] || die "Binary not found at $BIN_SRC — run without --no-build first."

# ---- stop any running instance so we can replace the binary --------------------------
if pgrep -x ghostpen >/dev/null 2>&1; then
  info "Stopping the running GhostPen instance…"
  pkill -x ghostpen 2>/dev/null || true
  sleep 1
fi

# ---- install binary ------------------------------------------------------------------
info "Installing binary → $BIN_DIR/ghostpen"
install -Dm755 "$BIN_SRC" "$BIN_DIR/ghostpen"

# ---- desktop entry + icon ------------------------------------------------------------
if [ "$DO_DESKTOP" -eq 1 ]; then
  info "Installing desktop entry + icon"
  install -Dm644 "$ROOT/src-tauri/icons/128x128.png" "$ICON_DIR/ghostpen.png"
  install -d "$APP_DIR"
  cat > "$APP_DIR/ghostpen.desktop" <<DESKTOP
[Desktop Entry]
Type=Application
Name=GhostPen
Comment=AI text editing overlay
Exec=$BIN_DIR/ghostpen
Icon=ghostpen
Terminal=false
Categories=Utility;TextTools;
StartupNotify=false
DESKTOP
  command -v update-desktop-database >/dev/null 2>&1 \
    && update-desktop-database "$APP_DIR" >/dev/null 2>&1 || true
fi

# ---- post-install notes --------------------------------------------------------------
info "Installed: $("$BIN_DIR/ghostpen" --version 2>/dev/null || echo ghostpen)"

case ":$PATH:" in
  *":$BIN_DIR:"*) ;;
  *) warn "$BIN_DIR is not on your PATH. Add it, e.g.:  export PATH=\"$BIN_DIR:\$PATH\"" ;;
esac

cat <<NOTES

GhostPen installed. Next steps:
  - Start it:            ghostpen &        (runs as a tray daemon; menu stays hidden)
                         ghostpen --tray & (explicit form of the same, for autostart)
  - Trigger the overlay: ghostpen --trigger
  - X11/Win/macOS use the in-app hotkey (default Ctrl+Shift+A).
    On Wayland, bind it in your compositor, e.g. Hyprland:
        bind = CTRL SHIFT, A, exec, $BIN_DIR/ghostpen --trigger
  - AI backend: a local Ollama (http://localhost:11434) running gemma4:e4b,
    or LM Studio (http://localhost:1234). Configure in Settings.
NOTES
