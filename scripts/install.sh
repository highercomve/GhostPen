#!/usr/bin/env bash
# Install a GhostPen release for this user (Linux x86_64): the AppImage from
# GitHub, checked against the release's SHA256SUMS, plus its CLI, launcher and icons.
#
#   ~/.local/bin/ghostpen                              the AppImage (it updates itself)
#   ~/.local/lib/ghostpen/ghostpen-cli                 the CLI, taken out of the AppImage
#   ~/.local/bin/ghostpen-cli                          runs it, re-extracting it after the AppImage updates
#   ~/.local/share/applications/dev.ghostpen.Oriel.desktop
#   ~/.local/share/icons/hicolor/*/apps/dev.ghostpen.Oriel.png
#
#   curl -fsSL https://raw.githubusercontent.com/highercomve/GhostPen/main/scripts/install.sh | bash
#   scripts/install.sh                 the latest release
#   scripts/install.sh 0.5.2           a given version (v0.5.2 works too)
#   scripts/install.sh --cuda          the -cuda AppImage (picked by default when nvidia-smi is found)
#   scripts/install.sh --no-cuda       the Vulkan/CPU AppImage
#   scripts/install.sh --no-start      don't start GhostPen afterwards
#   scripts/install.sh --uninstall     remove what this script installs (settings and models stay)
#
# BIN_DIR, LIB_DIR and XDG_DATA_HOME move the install.
set -euo pipefail

repo="highercomve/GhostPen"
bin_dir="${BIN_DIR:-$HOME/.local/bin}"
lib_dir="${LIB_DIR:-$HOME/.local/lib/ghostpen}"
data_dir="${XDG_DATA_HOME:-$HOME/.local/share}"
app_id="dev.ghostpen.Oriel"
desktop_file="$data_dir/applications/$app_id.desktop"

die() { echo "error: $*" >&2; exit 1; }
usage() {
  if [ -f "$0" ]; then sed -n '2,/^set -euo/{/^set -euo/d;s/^# \{0,1\}//;p}' "$0"
  else echo "usage: install.sh [VERSION] [--cuda|--no-cuda] [--no-start] [--uninstall]"; fi
}

version="" cuda="" start=1 uninstall=""
for a in "$@"; do
  case "$a" in
    --cuda) cuda=1 ;;
    --no-cuda) cuda=0 ;;
    --no-start) start="" ;;
    --uninstall) uninstall=1 ;;
    -h|--help) usage; exit 0 ;;
    -*) die "unknown option $a (see --help)" ;;
    *) version="${a#v}" ;;
  esac
done

# Stop the running copy: the app inside the AppImage first, then the runtime.
# A runtime stopped at the same time unmounts the image under the app, which
# then dies of SIGBUS while it shuts down.
stop_running() {
  pgrep -x ghostpen >/dev/null || return 0
  echo "Stopping the running GhostPen"
  local inner='^/tmp/\.mount_[^/]*/usr/bin/ghostpen'
  pkill -f "$inner" || true
  for _ in $(seq 50); do pgrep -f "$inner" >/dev/null || break; sleep 0.1; done
  pkill -x ghostpen 2>/dev/null || true
  for _ in $(seq 50); do pgrep -x ghostpen >/dev/null || break; sleep 0.1; done
  pkill -9 -x ghostpen 2>/dev/null || true
}

refresh_menus() {
  command -v update-desktop-database >/dev/null && update-desktop-database -q "$data_dir/applications" 2>/dev/null || true
  command -v gtk-update-icon-cache >/dev/null && gtk-update-icon-cache -q -t "$data_dir/icons/hicolor" 2>/dev/null || true
}

if [ -n "$uninstall" ]; then
  stop_running
  rm -f "$bin_dir/ghostpen" "$bin_dir/ghostpen-cli" "$lib_dir/ghostpen-cli" "$desktop_file"
  rmdir "$lib_dir" 2>/dev/null || true
  rm -f "$data_dir"/icons/hicolor/*/apps/"$app_id".png
  refresh_menus
  echo "Removed GhostPen. Settings and downloaded models are left where they are."
  exit 0
fi

[ "$(uname -s)" = Linux ] || die "this script installs the Linux AppImage; get the other systems' installers from https://github.com/$repo/releases"
[ "$(uname -m)" = x86_64 ] || die "GhostPen's Linux builds are x86_64 only (this machine is $(uname -m))"
command -v curl >/dev/null || die "curl is needed"
command -v sha256sum >/dev/null || die "sha256sum is needed"

if [ -z "$version" ]; then
  # /releases/latest redirects to /releases/tag/vX.Y.Z (no API token or jq needed).
  url=$(curl -fsSLI -o /dev/null -w '%{url_effective}' "https://github.com/$repo/releases/latest") ||
    die "could not reach GitHub to find the latest release"
  version="${url##*/v}"
  [ "$version" != "$url" ] || die "no release found at $url"
fi

if [ -z "$cuda" ]; then
  cuda=0
  command -v nvidia-smi >/dev/null && nvidia-smi -L >/dev/null 2>&1 && cuda=1
fi
asset="ghostpen-$version-x86_64.AppImage"
[ "$cuda" = 1 ] && asset="ghostpen-$version-x86_64-cuda.AppImage"
base="https://github.com/$repo/releases/download/v$version"

tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT

echo "Downloading GhostPen $version ($asset)"
curl -fsSL -o "$tmp/SHA256SUMS" "$base/SHA256SUMS" || die "GhostPen $version has no release at https://github.com/$repo/releases/tag/v$version"
grep -q "  $asset\$" "$tmp/SHA256SUMS" || die "release $version has no $asset"
curl -fL --progress-bar -o "$tmp/$asset" "$base/$asset" || die "download of $asset failed"
(cd "$tmp" && grep "  $asset\$" SHA256SUMS | sha256sum -c --quiet -) || die "$asset does not match the release's SHA256SUMS"
chmod +x "$tmp/$asset"

# The CLI, launcher and icons from inside the AppImage (no FUSE needed to extract).
(cd "$tmp" && "./$asset" --appimage-extract usr/bin/ghostpen-cli >/dev/null &&
  "./$asset" --appimage-extract usr/share >/dev/null) ||
  die "could not unpack $asset"
root="$tmp/squashfs-root"

stop_running

mkdir -p "$bin_dir" "$lib_dir" "$data_dir/applications"
# rm first: replaces a symlink rather than writing through it, and a running
# binary rather than failing with "text file busy".
rm -f "$bin_dir/ghostpen" "$bin_dir/ghostpen-cli"
install -m755 "$tmp/$asset" "$bin_dir/ghostpen"
if [ -f "$root/usr/bin/ghostpen-cli" ]; then
  install -m755 "$root/usr/bin/ghostpen-cli" "$lib_dir/ghostpen-cli"
  # A launcher, not a link: the in-app updater replaces only the AppImage, so
  # the CLI is taken out of it again whenever the AppImage is newer than the
  # copy, and the two never run different versions.
  cat > "$bin_dir/ghostpen-cli" <<LAUNCHER
#!/bin/sh
# GhostPen's CLI, kept at the installed AppImage's version (written by install.sh).
app="$bin_dir/ghostpen"
cli="$lib_dir/ghostpen-cli"
if [ ! -x "\$cli" ] || [ "\$app" -nt "\$cli" ]; then
  tmp=\$(mktemp -d) || exit 1
  if (cd "\$tmp" && "\$app" --appimage-extract usr/bin/ghostpen-cli >/dev/null 2>&1); then
    install -m755 "\$tmp/squashfs-root/usr/bin/ghostpen-cli" "\$cli.\$\$" && mv -f "\$cli.\$\$" "\$cli"
  fi
  rm -rf "\$tmp"
fi
exec "\$cli" "\$@"
LAUNCHER
  chmod 755 "$bin_dir/ghostpen-cli"
fi

for icon in "$root"/usr/share/icons/hicolor/*/apps/"$app_id".png; do
  [ -f "$icon" ] || continue
  size=$(basename "$(dirname "$(dirname "$icon")")")
  install -Dm644 "$icon" "$data_dir/icons/hicolor/$size/apps/$app_id.png"
done

# The AppImage's own entry, pointed at the installed file.
src_desktop="$root/usr/share/applications/$app_id.desktop"
if [ -f "$src_desktop" ]; then
  sed "s|^Exec=.*|Exec=$bin_dir/ghostpen|; s|^TryExec=.*|TryExec=$bin_dir/ghostpen|" "$src_desktop" > "$desktop_file"
else
  cat > "$desktop_file" <<EOF
[Desktop Entry]
Type=Application
Name=GhostPen
Comment=AI text editing anywhere on your desktop
Exec=$bin_dir/ghostpen
Icon=$app_id
Categories=Utility;
Terminal=false
StartupNotify=true
StartupWMClass=$app_id
EOF
fi
chmod 644 "$desktop_file"
refresh_menus

echo "Installed GhostPen $version to $bin_dir/ghostpen ($(du -h "$bin_dir/ghostpen" | cut -f1)), with a launcher in $desktop_file"
[ "$cuda" = 1 ] && echo "This is the CUDA build: it needs the CUDA 13 runtime and uses Vulkan without it."
case ":$PATH:" in *":$bin_dir:"*) ;; *) echo "Note: $bin_dir is not on your PATH." ;; esac

if [ -n "$start" ] && { [ -n "${WAYLAND_DISPLAY:-}" ] || [ -n "${DISPLAY:-}" ]; }; then
  log="${XDG_STATE_HOME:-$HOME/.local/state}/ghostpen/ghostpen.log"
  mkdir -p "$(dirname "$log")"
  # A plain launch only starts the tray; open Settings so the start is visible.
  nohup setsid "$bin_dir/ghostpen" --settings >>"$log" 2>&1 </dev/null &
  echo "Started GhostPen (log: $log)"
fi
