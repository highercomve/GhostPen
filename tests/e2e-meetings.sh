#!/usr/bin/env bash
# Meeting mode end to end, headless: captions in meeting mode over
# tests/speech.wav ($GHOSTPEN_TEST_AUDIO), stop → the save pipeline
# (merge, whisper over the recording, speakers, proofread by the mock AI) →
# meeting.json, transcript.md, final.md; then the Meetings window, and its
# audio served over 127.0.0.1 with range requests.
# Needs a whisper model: WHISPER_MODEL=path/to/ggml-tiny.bin (default: the one
# GhostPen downloaded, ~/.local/share/GhostPen/models/ggml-tiny.bin).
#
# Speakers by voice: SPEAKER_MODEL=path/to/ecapa-tdnn-voxceleb.gguf (else the
# step is skipped), TEST_AUDIO=a conversation (default tests/speech.wav),
# RECORD_SECONDS=how long to record it (default 10), EXPECT_SPEAKERS=n to
# check the count, and TRUTH="s1 s2 s1 …" (the speaker of each line, in
# order) to check who said what.
# RECORD_ONLY=1 exercises Record meeting / Stop and save in Meetings,
# without the captions overlay or any live transcription.
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
oriel_repo="${ORIEL_REPO:-$here/../oriel}"
model="${WHISPER_MODEL:-$HOME/.local/share/GhostPen/models/ggml-tiny.bin}"
if [ -z "${ORIEL_HEADLESS_INNER:-}" ]; then exec "$oriel_repo/scripts/headless.sh" "$0" "$@"; fi

tmp=$(mktemp -d); trap 'kill $pid $mock 2>/dev/null; rm -rf "$tmp"' EXIT
out="${OUT:-$tmp}"
export GSK_RENDERER=cairo
export XDG_DATA_HOME=$tmp/data XDG_CONFIG_HOME=$tmp/config XDG_CACHE_HOME=$tmp/cache
mkdir -p "$XDG_CONFIG_HOME/dev.ghostpen.Oriel" "$XDG_DATA_HOME/GhostPen/models"
ln -s "$model" "$XDG_DATA_HOME/GhostPen/models/ggml-tiny.bin"
if [ -n "${SPEAKER_MODEL:-}" ]; then
  mkdir -p "$XDG_DATA_HOME/GhostPen/models/speakers"
  ln -s "$SPEAKER_MODEL" "$XDG_DATA_HOME/GhostPen/models/speakers/$(basename "$SPEAKER_MODEL")"
fi
audio="${TEST_AUDIO:-$here/tests/speech.wav}"
meetings="$tmp/Meetings"
printf '{"settings":{"activeProfileId":"m","profiles":[{"id":"m","name":"Mock","baseUrl":"http://127.0.0.1:18766/v1","model":"mock","temperature":0.2}],"captions":{"model":"tiny","chunkSeconds":3},"meetings":{"enabled":%s,"dir":"%s","proofread":true,"summary":true,"speakers":%s}}}' "$([ "${RECORD_ONLY:-0}" = 1 ] && echo false || echo true)" "$meetings" "$([ -n "${SPEAKER_MODEL:-}" ] && echo true || echo false)" \
  > "$XDG_CONFIG_HOME/dev.ghostpen.Oriel/settings.json"
python3 "$here/tests/mock_openai.py" 18766 & mock=$!
app="$here/zig-out/bin/ghostpen"
GHOSTPEN_TEST_ASK="What did they say about me?" GHOSTPEN_SPEAKERS_DUMP="$out/windows.json" GHOSTPEN_TEST_AUDIO="$audio" "$app" > "$tmp/app.log" 2>&1 & pid=$!
sleep 4
fail=0
check() { if eval "$2"; then echo "ok: $1"; else echo "FAIL: $1"; fail=1; fi; }

if [ "${RECORD_ONLY:-0}" = 1 ]; then
  "$app" --meetings
  sleep 2
  window=$(xdotool search --onlyvisible --name 'GhostPen Meetings' | tail -1)
  # The default 1040x760 Meetings window: Record / Stop in the reader header.
  xdotool mousemove --window "$window" 930 70 click 1
else
  "$app" --captions
fi
sleep "${RECORD_SECONDS:-10}"
import -window root "$out/meeting-recording.png"
id=$(ls "$meetings" 2>/dev/null | head -1)
check "a meeting folder while recording ($id)" '[ -n "$id" ] && [ -f "$meetings/$id/others.wav" ]'
if [ "${RECORD_ONLY:-0}" = 1 ]; then
  check "the captions overlay stayed hidden" '! xdotool search --onlyvisible --name "GhostPen Captions" >/dev/null 2>&1'
  check "no live Whisper helper during recording" '! ps --ppid "$pid" -o args= | grep -q -- "--whisper-helper"'
  xdotool mousemove --window "$window" 930 70 click 1
else
  "$app" --captions   # stop → save
fi
for _ in $(seq 180); do
  # Saved, and the test question (GHOSTPEN_TEST_ASK) answered after it.
  grep -q '"state": "ready"\|"state": "error"' "$meetings/$id/meeting.json" 2>/dev/null &&
    grep -q '"prompt"\|"state": "error"' "$meetings/$id/meeting.json" && break
  sleep 1
done
json="$meetings/$id/meeting.json"
check "the meeting is ready" 'grep -q "\"state\": \"ready\"" "$json"'
check "audio.wav replaced the track" '[ -f "$meetings/$id/audio.wav" ] && [ ! -f "$meetings/$id/others.wav" ]'
check "segments transcribed" 'python3 -c "import json,sys;m=json.load(open(sys.argv[1]));sys.exit(0 if m[\"segments\"] and m[\"segments\"][0][\"text\"] else 1)" "$json"'
check "words timed inside their lines" 'python3 -c "import json,sys;m=json.load(open(sys.argv[1]));ok=all(s[\"words\"] and s[\"start\"]<=s[\"words\"][0][\"start\"]+0.01 and s[\"words\"][-1][\"end\"]<=s[\"end\"]+0.01 for s in m[\"segments\"]);sys.exit(0 if ok else 1)" "$json"'
check "clean text from the proofread" 'python3 -c "import json,sys;m=json.load(open(sys.argv[1]));t=m[\"final\"][0][\"text\"];sys.exit(0 if m[\"final\"] and t==t.upper() and not t.startswith(\"[\") else 1)" "$json"'
check "the title came from the AI" 'grep -q "\"title\": \"Mock meeting\"" "$json"'
check "a notification said it was saved" 'grep -q "Meeting saved" "$tmp/app.log"'
check "the summary (fence taken off)" 'python3 -c "import json,sys;s=json.load(open(sys.argv[1]))[\"summary\"];sys.exit(0 if s.startswith(\"## Overview\") and \"\`\`\`\" not in s else 1)" "$json" && [ -s "$meetings/$id/summary.md" ]'
check "a question asked about it, answered and saved" 'python3 -c "import json,sys;n=json.load(open(sys.argv[1]))[\"notes\"];sys.exit(0 if len(n)==1 and n[0][\"id\"]==\"n1\" and n[0][\"answer\"]==\"**Answer** to: What did they say about me?\" else 1)" "$json" && grep -q "## Questions" "$meetings/$id/summary.md"'
check "transcript.md and final.md" '[ -s "$meetings/$id/transcript.md" ] && [ -s "$meetings/$id/final.md" ]'
python3 -c "import json,sys;m=json.load(open(sys.argv[1]));print('  title:',m['title'],'| duration ms:',m['durationMs'],'| speakers:',[s['name'] for s in m['speakers']]);[print('  ',s['start'],s['speaker'],s['text']) for s in m['segments'][:3]];[print('  final:',s['text']) for s in m['final'][:2]]" "$json"

if [ -n "${EXPECT_SPEAKERS:-}" ]; then
  n=$(python3 -c "import json,sys;m=json.load(open(sys.argv[1]));print(len([s for s in m['speakers'] if s['id']!='me']))" "$json")
  check "speakers by voice: $n (expected $EXPECT_SPEAKERS)" '[ "$n" = "$EXPECT_SPEAKERS" ]'
  python3 -c "import json,sys;m=json.load(open(sys.argv[1]));[print('  %6.2f %-4s %s'%(s['start'],s['speaker'],s['text'][:70])) for s in m['segments']]" "$json"
fi
if [ -n "${TRUTH:-}" ]; then
  # The best mapping of found speakers onto the truth's, line by line: the share right.
  acc=$(python3 - "$json" $TRUTH <<'PY'
import json, sys, itertools
m = json.load(open(sys.argv[1])); truth = sys.argv[2:]
segs = [s for s in m["segments"] if s["speaker"] != "me"]
# Whisper may split a line in several segments: each segment's line is the
# truth slot by order of the gaps (a new line after a pause > 0.5 s).
lines, last_end = [], None
for s in segs:
    if last_end is None or s["start"] - last_end > 0.5: lines.append([])
    lines[-1].append(s["speaker"]); last_end = s["end"]
found = sorted({x for l in lines for x in l}); want = sorted(set(truth))
best = 0
for perm in itertools.permutations(found, min(len(found), len(want))):
    mp = dict(zip(perm, want))
    ok = sum(1 for l, t in zip(lines, truth) if max(set(l), key=l.count) in mp and mp[max(set(l), key=l.count)] == t)
    best = max(best, ok)
print(f"{best}/{len(truth)} lines ({len(lines)} found)")
PY
)
  echo "  who said what: $acc"
  check "who said what ($acc)" '[ "${acc%%/*}" -ge $(( $(echo $TRUTH | wc -w) - 1 )) ]'
fi

"$app" --meetings; sleep 5
import -window root "$out/meetings-window.png"
port=$(grep -o "audio served on 127.0.0.1:[0-9]*" "$tmp/app.log" | tail -1 | cut -d: -f2)
check "the window started the audio server ($port)" '[ -n "$port" ]'
if [ -n "$port" ]; then
  code=$(curl -s -o "$tmp/range" -w '%{http_code}' -r 0-43 "http://127.0.0.1:$port/$id/audio.wav")
  check "range request answered 206 with the WAV header" '[ "$code" = 206 ] && head -c 4 "$tmp/range" | grep -q RIFF'
  code=$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$port/../settings.json")
  check "no path outside the meetings folder ($code)" '[ "$code" != 200 ]'
fi
grep -iE "meeting|error|warn" "$tmp/app.log" | grep -v atspi | tail -12
cp "$tmp/app.log" "$out/app.log" 2>/dev/null; cp -r "$meetings" "$out/" 2>/dev/null
exit $fail
