#!/usr/bin/env bash
# Captions and dictation end to end, headless, with tests/speech.wav instead of
# the sound server ($GHOSTPEN_TEST_AUDIO) and the mock AI endpoint.
# Needs a whisper model: WHISPER_MODEL=path/to/ggml-tiny.bin (default: the one
# GhostPen downloaded, ~/.local/share/GhostPen/models/ggml-tiny.bin).
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
oriel_repo="${ORIEL_REPO:-$here/../ziguri}"
model="${WHISPER_MODEL:-$HOME/.local/share/GhostPen/models/ggml-tiny.bin}"
if [ -z "${ORIEL_HEADLESS_INNER:-}" ]; then exec "$oriel_repo/scripts/headless.sh" "$0" "$@"; fi

tmp=$(mktemp -d); trap 'kill $pid $mock 2>/dev/null; rm -rf "$tmp"' EXIT
out="${OUT:-$tmp}"
export XDG_DATA_HOME=$tmp/data XDG_CONFIG_HOME=$tmp/config XDG_CACHE_HOME=$tmp/cache
mkdir -p "$XDG_CONFIG_HOME/dev.ghostpen.Oriel" "$XDG_DATA_HOME/GhostPen/models"
ln -s "$model" "$XDG_DATA_HOME/GhostPen/models/ggml-tiny.bin"
printf '{"settings":{"activeProfileId":"m","profiles":[{"id":"m","name":"Mock","baseUrl":"http://127.0.0.1:18765/v1","model":"mock","temperature":0.2}],"captions":{"model":"tiny","chunkSeconds":3},"dictation":{"proofread":true}}}' \
  > "$XDG_CONFIG_HOME/dev.ghostpen.Oriel/settings.json"
python3 "$here/tests/mock_openai.py" 18765 & mock=$!
app="$here/zig-out/bin/ghostpen-oriel"
GHOSTPEN_TEST_AUDIO="$here/tests/speech.wav" "$app" > "$tmp/app.log" 2>&1 & pid=$!
sleep 4
fail=0

"$app" --captions; sleep 9
import -window root "$out/captions.png"
"$app" --captions; sleep 1   # stop + hide

"$app" --voice-input; sleep 8
import -window root "$out/dictation-listening.png"
"$app" --voice-input; sleep 15  # finish: transcribe → proofread (mock) → copy
import -window root "$out/dictation-done.png"
got=$(xsel -ob)
case "$got" in
  OK:*HELLO*TEST*) echo "ok: dictation copied \"$got\"" ;;
  *) echo "FAIL: dictation clipboard \"$got\""; fail=1 ;;
esac
grep -iE "caption|whisper|dictation|error" "$tmp/app.log" | grep -v atspi | tail -8
exit $fail
