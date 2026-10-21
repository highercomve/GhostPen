#!/usr/bin/env bash
set -euo pipefail

# Keep release builds and default-branch cache warming on the same key.
: "${GITHUB_ENV:?GITHUB_ENV must name the Actions environment file}"
: "${CUDA_ARCHS:?CUDA_ARCHS must list the compiled GPU architectures}"
zig build --fetch >/dev/null
oriel_hash=$(sed -n 's/.*\.hash = "oriel-\([^"]*\)".*/\1/p' build.zig.zon)
oriel_dir="zig-pkg/oriel-$oriel_hash"
test -d "$oriel_dir"
cuda_parts='/^pub const CudaOptions/,/^};/{print} /^fn cudaArchArgs/,/^}/{print} /^fn isComputeCapability/,/^}/{print} /^fn addCudaBackend/,/^}/{print} /^const cuda_sources/,/^};/{print}'
ggml_key=$( { grep -A2 '\.llama = ' "$oriel_dir/build.zig.zon"; awk "$cuda_parts" "$oriel_dir/build/ggml.zig" | grep -v -E '^\s*//|buildFail|panic\('; } | sha256sum | cut -c1-16)
archs_key=${CUDA_ARCHS//,/_}
cuda_version=$(pacman -Si cuda | sed -n 's/^Version *: *//p')
test -n "$cuda_version"
{
    printf 'GGML_KEY=%s\n' "$ggml_key"
    printf 'CUDA_ARCHS_KEY=%s\n' "$archs_key"
    printf 'CUDA_VERSION=%s\n' "$cuda_version"
    printf 'CUDA_CACHE_KEY=ggml-cuda-%s-%s-cuda-%s\n' "$ggml_key" "$archs_key" "$cuda_version"
} >> "$GITHUB_ENV"
