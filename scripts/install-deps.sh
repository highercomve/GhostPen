#!/usr/bin/env bash
#
# GhostPen — system dependency installer
#
# Installs the system libraries Tauri v2 + GhostPen need to BUILD, across the common
# package managers. It does NOT install the Rust or Node toolchains (those have their own
# installers) — but it checks for them at the end and prints how to get them.
#
# Supported: Debian/Ubuntu & derivatives (apt), Arch & derivatives (pacman),
#            Fedora/RHEL family (dnf), openSUSE (zypper), Alpine (apk), macOS (xcode + brew).
#
# Usage:
#   ./scripts/install-deps.sh           # detect + install
#   ./scripts/install-deps.sh --dry-run # print what it would do, install nothing
#
set -euo pipefail

DRY_RUN=0
[ "${1:-}" = "--dry-run" ] && DRY_RUN=1

# ---- logging -------------------------------------------------------------------------
info()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn()  { printf '\033[1;33m[warn]\033[0m %s\n' "$*" >&2; }
die()   { printf '\033[1;31m[error]\033[0m %s\n' "$*" >&2; exit 1; }

# Run a privileged command (no-op under --dry-run; uses sudo if not root).
SUDO=""
if [ "$(id -u)" -ne 0 ] && command -v sudo >/dev/null 2>&1; then SUDO="sudo"; fi
run() {
  if [ "$DRY_RUN" -eq 1 ]; then printf '    [dry-run] %s\n' "$*"; return 0; fi
  $SUDO "$@"
}

# ---- package sets (arrays → safe word-splitting into args) ---------------------------
APT_PKGS=(build-essential curl wget file libxdo-dev libssl-dev libayatana-appindicator3-dev librsvg2-dev)
PACMAN_PKGS=(webkit2gtk-4.1 base-devel curl wget file openssl appmenu-gtk-module libappindicator-gtk3 librsvg xdotool)
DNF_PKGS=(webkit2gtk4.1-devel openssl-devel curl wget file libappindicator-gtk3-devel librsvg2-devel libxdo-devel)
ZYPPER_PKGS=(webkit2gtk3-soup2-devel libopenssl-devel curl wget file libappindicator3-1 librsvg-devel xdotool-devel)
APK_PKGS=(build-base webkit2gtk-4.1-dev curl wget file openssl-dev libayatana-appindicator-dev librsvg-dev xdotool-dev)

# ---- installers ----------------------------------------------------------------------
install_apt() {
  info "Debian/Ubuntu family detected (apt)."
  run apt-get update
  run apt-get install -y "${APT_PKGS[@]}"
  # Tauri v2 needs webkit 4.1; fall back to 4.0 on older releases.
  if ! run apt-get install -y libwebkit2gtk-4.1-dev; then
    warn "libwebkit2gtk-4.1-dev unavailable — trying libwebkit2gtk-4.0-dev (older Tauri)."
    run apt-get install -y libwebkit2gtk-4.0-dev || die "No webkit2gtk dev package found. Check 'apt-cache search libwebkit2gtk'."
  fi
}

install_pacman() {
  info "Arch family detected (pacman)."
  run pacman -Syu --needed --noconfirm "${PACMAN_PKGS[@]}"
}

install_dnf() {
  info "Fedora/RHEL family detected (dnf)."
  run dnf group install -y "c-development" "development-tools" 2>/dev/null \
    || run dnf groupinstall -y "Development Tools"
  run dnf install -y "${DNF_PKGS[@]}"
}

install_zypper() {
  info "openSUSE detected (zypper)."
  run zypper install -y -t pattern devel_basis || warn "devel_basis pattern step failed (continuing)."
  if ! run zypper install -y "${ZYPPER_PKGS[@]}"; then
    warn "Some package names differ across openSUSE versions; try 'webkit2gtk3-devel' and see https://v2.tauri.app/start/prerequisites/"
  fi
}

install_apk() {
  info "Alpine detected (apk)."
  run apk add "${APK_PKGS[@]}"
}

install_macos() {
  info "macOS detected."
  # The webview (WKWebView) is built into macOS — the only hard requirement is the
  # Xcode Command Line Tools (clang, headers).
  if xcode-select -p >/dev/null 2>&1; then
    info "Xcode Command Line Tools already installed."
  else
    info "Installing Xcode Command Line Tools (a GUI dialog may appear)…"
    if [ "$DRY_RUN" -eq 1 ]; then printf '    [dry-run] xcode-select --install\n'; else xcode-select --install || true; fi
    warn "If a dialog appeared, finish it, then re-run this script."
  fi
  command -v brew >/dev/null 2>&1 || warn "Homebrew not found — optional, but handy for node/ollama: https://brew.sh"
}

# ---- OS / distro detection -----------------------------------------------------------
detect_and_install() {
  case "$(uname -s)" in
    Darwin) install_macos; return ;;
    Linux)  : ;;
    *)      die "Unsupported OS: $(uname -s). See https://v2.tauri.app/start/prerequisites/" ;;
  esac

  # Prefer /etc/os-release (ID + ID_LIKE) so derivatives map to their parent family.
  local id="" like=""
  if [ -r /etc/os-release ]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    id="${ID:-}"; like="${ID_LIKE:-}"
  fi
  local hay=" $id $like "

  case "$hay" in
    *debian*|*ubuntu*|*mint*|*pop*|*elementary*|*raspbian*|*kali*) install_apt;    return ;;
    *arch*|*manjaro*|*endeavour*|*garuda*|*artix*|*cachyos*)       install_pacman; return ;;
    *fedora*|*rhel*|*centos*|*rocky*|*almalinux*)                  install_dnf;    return ;;
    *suse*)                                                        install_zypper; return ;;
    *alpine*)                                                      install_apk;    return ;;
  esac

  # Fallback: detect by which package manager is present.
  warn "Could not map distro '$id' (ID_LIKE='$like') — falling back to package-manager detection."
  if   command -v apt-get >/dev/null 2>&1; then install_apt
  elif command -v pacman  >/dev/null 2>&1; then install_pacman
  elif command -v dnf     >/dev/null 2>&1; then install_dnf
  elif command -v zypper  >/dev/null 2>&1; then install_zypper
  elif command -v apk     >/dev/null 2>&1; then install_apk
  else die "No supported package manager found. Install Tauri deps manually: https://v2.tauri.app/start/prerequisites/"
  fi
}

# ---- toolchain reminder (not auto-installed) -----------------------------------------
check_toolchain() {
  # rustup installs to ~/.cargo/bin, which a non-login shell may not have on PATH yet.
  export PATH="$HOME/.cargo/bin:$PATH"
  info "Checking build toolchains (not installed by this script):"
  if command -v cargo >/dev/null 2>&1; then info "  rust/cargo: $(cargo --version)"
  else warn "  rust/cargo: MISSING — install: curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh"; fi
  if command -v node >/dev/null 2>&1; then info "  node: $(node -v)"
  else warn "  node: MISSING — install Node.js LTS: https://nodejs.org (or nvm)"; fi
  if command -v ollama >/dev/null 2>&1; then info "  ollama: $(ollama --version 2>&1 | head -1)"
  else warn "  ollama: MISSING (optional, for the default local backend): https://ollama.com/download"; fi
}

# ---- main ----------------------------------------------------------------------------
[ "$DRY_RUN" -eq 1 ] && info "Running in --dry-run mode; nothing will be installed."
detect_and_install
check_toolchain
info "Done. Next: 'npm install' then 'npm run tauri dev'."
