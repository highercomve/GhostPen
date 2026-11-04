#!/usr/bin/env bash
# Check the built-in model runner's GPU planning against llama.cpp's own
# accounting, for every local model at several contexts:
#
#   scripts/estimator-check.sh                      every model, 64k/128k/256k
#   scripts/estimator-check.sh a.gguf b.gguf        just these
#   CTX=32768,65536 scripts/estimator-check.sh      other contexts
#   GHOSTPEN=zig-out/bin/ghostpen                   the build to run (default)
#   OUT=results.jsonl                               keep the raw lines (default: a temp file)
#   UPDATE_FIXTURE=1                                also write them to
#                                                   src/fixtures/estimator.jsonl (the unit test's data)
#
# Each model loads `no_alloc` with every layer on the GPU (`ghostpen
# --llm-helper --measure`): nothing is allocated, so models and contexts that
# don't fit this GPU are measured too. It prints the metadata estimate (the
# planner's fallback) beside llama.cpp's sizes, then what the planner does
# with the GPU memory free now. It needs a GPU build (-Dcuda or -Dvulkan):
# the sizes are the GPU backend's.
#
# Models: the GGUFs under ~/.lmstudio/models and GhostPen's model folder,
# without vision projectors, embedding, speaker and MTP draft models.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
bin="${GHOSTPEN:-$here/zig-out/bin/ghostpen}"
ctx="${CTX:-65536,131072,262144}"
out="${OUT:-$(mktemp --suffix=.jsonl)}"
: > "$out"

if [ "$#" -gt 0 ]; then
  models=("$@")
else
  mapfile -t models < <(find "$HOME/.lmstudio/models" "${XDG_DATA_HOME:-$HOME/.local/share}/GhostPen/models" \
    -name '*.gguf' 2>/dev/null | grep -viE '/[^/]*(mmproj|mtp-)[^/]*$|embed|/speakers/' | sort)
fi
[ "${#models[@]}" -gt 0 ] || { echo "no models found" >&2; exit 1; }

for m in "${models[@]}"; do
  echo "measuring $(basename "$m")" >&2
  "$bin" --llm-helper --measure --measure-ctx "$ctx" --model "$m" >>"$out" 2>/dev/null ||
    echo "  failed: $(basename "$m")" >&2
done

python3 -I - "$out" <<'PY'
import json, sys
GiB = 1 << 30
rows = [json.loads(l) for l in open(sys.argv[1]) if l.strip()]
plans = [r for r in rows if 'plan' in r]
rows = [r for r in rows if 'plan' not in r]
print("The metadata estimate (the planner's fallback) against llama.cpp, GPU GiB:")
print(f"{'model':42} {'ctx':>6} {'b/ub':>9} {'est':>6} {'real':>6} {'diff':>6}  real: weights kv compute | host")
under = over = 0
for r in rows:
    if 'error' in r:
        print(f"{r['model'][:42]:42} {r.get('ctx', ''):>6} error: {r['error']}")
        continue
    e, real = r['est'], r['real']
    diff = (e['total'] - r['real_gpu']) / GiB
    slack = max(r['real_gpu'] / 10, 512 << 20) / GiB
    flag = ''
    if diff < 0: under += 1; flag = '  UNDER (out of memory)'
    elif diff > slack: over += 1; flag = '  OVER (needless split)'
    print(f"{r['model'][:42]:42} {r['ctx']//1024:>5}k {r['batch']:>4}/{r['ubatch']:<4} "
          f"{e['total']/GiB:6.2f} {r['real_gpu']/GiB:6.2f} {diff:+6.2f}  "
          f"{real['gpu_model']/GiB:.2f} {real['gpu_context']/GiB:.2f} {real['gpu_compute']/GiB:.2f} | "
          f"{(real['host_model']+real['host_context']+real['host_compute'])/GiB:.2f}{flag}")
print(f"{under} under-estimates (out of memory), {over} over by more than 10% or 0.5 GiB.\n")
if plans:
    print(f"What the planner does with the GPU memory free now ({plans[0]['plan']['free']/GiB:.2f} GiB):")
    for p in plans:
        q = p['plan']
        if q['ngl'] >= 999 and q['n_overrides'] == 0:
            where = 'all on the GPU'
        else:
            gpu_layers = q['layers'] if q['ngl'] >= 999 else q['ngl']
            where = f"split: {gpu_layers}/{q['layers']} layers on the GPU, {q['n_overrides']} tensor groups in RAM"
        ctx = f"{q['ctx']//1024}k" + (f" (asked {p['ctx']//1024}k)" if q['ctx'] < p['ctx'] else '')
        need = f", needs {q['need']/GiB:.2f}" if q['need'] else ''
        print(f"  {p['model'][:40]:40} {ctx:>16}  {where}, batches {q['batch']}/{q['ubatch']}{need}")
PY

if [ -n "${UPDATE_FIXTURE:-}" ]; then
  # Paths relative to the home directory: the test finds the models there
  # and skips the ones this machine doesn't have.
  grep -v '"error"' "$out" | jq -c --arg home "$HOME/" \
    'select(.real_gpu) | {path: (.path | ltrimstr($home)), ctx, batch, ubatch, real_gpu, gpu: "cuda"}' \
    > "$here/src/fixtures/estimator.jsonl"
  echo "wrote src/fixtures/estimator.jsonl" >&2
fi
echo "raw results: $out" >&2
