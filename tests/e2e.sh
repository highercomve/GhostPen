#!/usr/bin/env bash
# End-to-end test on a private X display (Xvfb + D-Bus; never the real
# desktop), against a mock OpenAI-compatible endpoint:
#   type text in the Playground, select it, `--trigger` (synthetic Ctrl+C),
#   press 1 (Proofread) in the menu, and check the answer was pasted back.
# Needs: Oriel's scripts/headless.sh (ORIEL_REPO or ../ziguri), xdotool, python3.
# Build first: `oriel build`. Screenshots go to $OUT (default: a temp dir).
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
oriel_repo="${ORIEL_REPO:-$here/../ziguri}"
if [ -z "${ORIEL_HEADLESS_INNER:-}" ]; then exec "$oriel_repo/scripts/headless.sh" "$0" "$@"; fi

tmp=$(mktemp -d); trap 'kill $pid $mock 2>/dev/null; rm -rf "$tmp"' EXIT
out="${OUT:-$tmp}"
# Xvfb has no Vulkan presentation: GTK draws in software.
export GSK_RENDERER=cairo
export XDG_DATA_HOME=$tmp/data XDG_CONFIG_HOME=$tmp/config XDG_CACHE_HOME=$tmp/cache
mkdir -p "$XDG_CONFIG_HOME/dev.ghostpen.Oriel"
printf '{"settings":{"activeProfileId":"m","profiles":[{"id":"m","name":"Mock","baseUrl":"http://127.0.0.1:18765/v1","model":"mock","temperature":0.2}]}}' \
  > "$XDG_CONFIG_HOME/dev.ghostpen.Oriel/settings.json"
python3 "$here/tests/mock_openai.py" 18765 & mock=$!
app="$here/zig-out/bin/ghostpen"
"$app" > "$tmp/app.log" 2>&1 & pid=$!
sleep 4

"$app" --playground; sleep 2
wid=$(xdotool search --name "GhostPen Playground" | head -1)
xdotool windowfocus --sync "$wid"; xdotool mousemove 300 130 click 1; sleep 0.3
xdotool type --delay 10 "teh quick brown fox"; xdotool key ctrl+a; sleep 0.3
"$app" --trigger; sleep 2
import -window root "$out/menu.png"
xdotool key 1; sleep 2.5
import -window root "$out/pasted.png"

# The Playground input now holds the mock's answer: select it and read it back.
xdotool windowfocus --sync "$wid"; xdotool mousemove 300 130 click 1; xdotool key ctrl+a ctrl+c; sleep 0.5
got=$(xsel -ob)
if [ "$got" = "OK: TEH QUICK BROWN FOX" ]; then
  echo "ok: pasted \"$got\""
else
  echo "FAIL: the field holds \"$got\""; tail -20 "$tmp/app.log"; exit 1
fi

# Playground streaming: Proofread button → chunks → done, in the Result box.
xdotool mousemove 63 273 click 1; sleep 3
import -window root "$out/playground-stream.png"
xdotool mousemove 300 430 click 1; xdotool key ctrl+a ctrl+c; sleep 0.5
got=$(xsel -ob)
if [ "$got" = "OK: OK: TEH QUICK BROWN FOX" ]; then
  echo "ok: streamed \"$got\""
else
  echo "FAIL: the Result box holds \"$got\""; exit 1
fi
