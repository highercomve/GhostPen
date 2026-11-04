// llama.cpp's memory accounting and fitting for llm_helper.zig's GPU
// planner, through C entry points (both are C++ only upstream):
//
// - what a model and context take, by where it lives
//   (llama_get_memory_breakdown, what llama-server's --fit reads). With a
//   model loaded `no_alloc` nothing is allocated: the sizes are what a real
//   load would take, whatever memory is free.
// - llama-server's --fit (common_fit_params): the GPU layers, and the
//   tensors kept in system RAM, that fit the free memory.

#include "llama.h"
#include "llama-ext.h"
#include "ggml-backend.h"
#include "fit.h"

#include <cstdint>
#include <vector>

extern "C" {

struct ghostpen_llm_memory {
    // On the GPU devices (every non-host buffer type).
    uint64_t gpu_model;
    uint64_t gpu_context;
    uint64_t gpu_compute;
    // In system RAM (host and pinned host buffers).
    uint64_t host_model;
    uint64_t host_context;
    uint64_t host_compute;
};

bool ghostpen_llm_memory_breakdown(const llama_context * ctx, ghostpen_llm_memory * out) {
    if (ctx == nullptr || out == nullptr) return false;
    *out = {};
    try {
        for (const auto & [buft, mb] : llama_get_memory_breakdown(ctx)) {
            if (buft == nullptr || ggml_backend_buft_is_host(buft)) {
                out->host_model += mb.model;
                out->host_context += mb.context;
                out->host_compute += mb.compute;
            } else {
                out->gpu_model += mb.model;
                out->gpu_context += mb.context;
                out->gpu_compute += mb.compute;
            }
        }
    } catch (...) {
        return false;
    }
    return true;
}

// Fit `mparams` (GPU layers, tensor overrides into `overrides`, which holds
// llama_max_tensor_buft_overrides() entries) to the free GPU memory, leaving
// `margin` bytes free on each device, at the context and batches in
// `cparams` (kept: a context set there is never changed). 0: fits, 1: no
// split fits, 2: error.
int ghostpen_llm_fit(const char * path, llama_model_params * mparams, llama_context_params * cparams,
                     llama_model_tensor_buft_override * overrides, uint64_t margin) {
    // Read by the load as long as the model lives: one plan at a time.
    static std::vector<float> tensor_split;
    tensor_split.assign(llama_max_devices(), 0.0f);
    std::vector<size_t> margins(llama_max_devices(), margin);
    try {
        return common_fit_params(path, mparams, cparams, tensor_split.data(), overrides, margins.data(),
                                 cparams->n_ctx, nullptr, GGML_LOG_LEVEL_ERROR);
    } catch (...) {
        return 2;
    }
}

} // extern "C"
