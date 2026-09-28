#!/usr/bin/env bash
# Build GhostPen's AppImage with CUDA and Vulkan (like the release's
# -cuda AppImage) and install it for this user, replacing the running copy:
#   ~/.local/bin/ghostpen                 the AppImage
#   ~/.local/lib/ghostpen/ghostpen-cli    the CLI (~/.local/bin/ghostpen-cli links to it)
#
#   scripts/install-local.sh              build and install, restart GhostPen
#   NO_RESTART=1 scripts/install-local.sh leave GhostPen stopped
#   CUDA_PREBUILT=/path/libggml-cuda.so   reuse this libggml-cuda.so (built by the
#                                         same Oriel version) instead of the cache
#   CUDA_REBUILD=1                        run nvcc even when the cache has one
#   ORIEL_FORK=~/Code/oriel               build against a local Oriel checkout
#
# libggml-cuda.so takes minutes of nvcc, so it's cached per Oriel version in
# ${XDG_CACHE_HOME:-~/.cache}/ghostpen/cuda/<oriel>/: the first build makes it,
# later ones reuse it. A local Oriel (ORIEL_FORK) is keyed by its commit and
# rebuilt when it has uncommitted changes.
#
# Needs the CUDA toolkit (/opt/cuda) for nvcc, and glslc.
# The in-app updater replaces this build when a newer release comes out.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$here"

export CUDA_PATH="${CUDA_PATH:-/opt/cuda}"
export PATH="$CUDA_PATH/bin:$PATH"
args=(-Dvulkan -Dupdate_target=x86_64-linux-cuda)
[ -n "${ORIEL_FORK:-}" ] && args+=(--fork="$(realpath "$ORIEL_FORK")")

# The CUDA library's cache: one per Oriel version (the pinned package hash, or
# the fork's commit; a dirty fork isn't cached).
if [ -n "${ORIEL_FORK:-}" ]; then
  oriel_key="fork-$(git -C "$ORIEL_FORK" rev-parse --short=12 HEAD)"
  [ -n "$(git -C "$ORIEL_FORK" status --porcelain -- src build build.zig build.zig.zon)" ] && oriel_key=""
else
  oriel_key=$(sed -n '/\.oriel = /,/}/s/.*\.hash = "\(.*\)".*/\1/p' build.zig.zon)
fi
cuda_cache=""
[ -n "$oriel_key" ] && cuda_cache="${XDG_CACHE_HOME:-$HOME/.cache}/ghostpen/cuda/$oriel_key/libggml-cuda.so"

if [ -n "${CUDA_PREBUILT:-}" ]; then
  args+=(-Dcuda_prebuilt="$(realpath "$CUDA_PREBUILT")")
elif [ -n "$cuda_cache" ] && [ -f "$cuda_cache" ] && [ -z "${CUDA_REBUILD:-}" ]; then
  echo "Reusing $cuda_cache"
  args+=(-Dcuda_prebuilt="$cuda_cache")
else
  args+=(-Dcuda)
fi

version=$(sed -n 's/^const version = "\(.*\)";/\1/p' build.zig)
appimage="zig-out/package/ghostpen-$version-x86_64.AppImage"
rm -f "$appimage"
echo "Building GhostPen $version: oriel package ${args[*]}"
oriel package "${args[@]}"
[ -f "$appimage" ] || { echo "error: $appimage was not produced" >&2; exit 1; }

# Just built by nvcc: keep it for the next build.
if [[ " ${args[*]} " == *" -Dcuda "* ]] && [ -n "$cuda_cache" ] && [ -f zig-out/bin/libggml-cuda.so ]; then
  mkdir -p "$(dirname "$cuda_cache")"
  cp zig-out/bin/libggml-cuda.so "$cuda_cache"
  echo "Cached libggml-cuda.so in $cuda_cache"
fi

# The CLI from inside the AppImage (the one built with it).
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
(cd "$tmp" && "$here/$appimage" --appimage-extract usr/bin/ghostpen-cli >/dev/null)

# Stop the running copy (the AppImage runtime and the app inside it).
if pgrep -x ghostpen >/dev/null; then
  echo "Stopping the running GhostPen"
  pkill -x ghostpen || true
  for _ in $(seq 50); do pgrep -x ghostpen >/dev/null || break; sleep 0.1; done
  pkill -9 -x ghostpen 2>/dev/null || true
fi

mkdir -p ~/.local/bin ~/.local/lib/ghostpen
install -m755 "$appimage" ~/.local/bin/ghostpen
install -m755 "$tmp/squashfs-root/usr/bin/ghostpen-cli" ~/.local/lib/ghostpen/ghostpen-cli
ln -sf ~/.local/lib/ghostpen/ghostpen-cli ~/.local/bin/ghostpen-cli
echo "Installed GhostPen $version ($(du -h ~/.local/bin/ghostpen | cut -f1)) to ~/.local/bin/ghostpen"

if [ -z "${NO_RESTART:-}" ]; then
  log="${XDG_STATE_HOME:-$HOME/.local/state}/ghostpen/ghostpen.log"
  mkdir -p "$(dirname "$log")"
  setsid ~/.local/bin/ghostpen >>"$log" 2>&1 </dev/null &
  echo "Started GhostPen (log: $log)"
fi
