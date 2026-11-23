// Shared on-device llama.cpp core (llama.cpp b11913). Android builds it with CMake against the
// source tree; iOS links the official b11913 llama.xcframework (Metal).
#include "vinylo_llm_core.h"

#include <algorithm>
#include <atomic>
#include <cstring>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

#if __has_include(<llama/llama.h>)
#include <llama/llama.h>
#else
#include "llama.h"
#include "ggml-backend.h"
#define VL_LOAD_BACKENDS 1
#endif

#ifdef __ANDROID__
#include <android/log.h>
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO, "vinylo-llm", __VA_ARGS__)
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, "vinylo-llm", __VA_ARGS__)
#else
#include <cstdio>
#define LOGI(...) (fprintf(stderr, "vinylo-llm: " __VA_ARGS__), fputc('\n', stderr))
#define LOGE(...) LOGI(__VA_ARGS__)
#endif

static std::mutex g_mu;
static llama_model *g_model = nullptr;
static llama_context *g_ctx = nullptr;
static std::atomic<bool> g_cancel{false};
static bool g_backends = false;

// Tokens now held in the KV cache (prompt + generated). The next prompt reuses the longest common
// prefix: every line of a song starts with the same system prompt, so only the line is decoded.
static std::vector<llama_token> g_cached;

static void log_cb(ggml_log_level level, const char *text, void *) {
    if (level >= GGML_LOG_LEVEL_WARN) LOGE("%s", text);
}

static int n_threads() {
    // Decoding is memory-bound: the big cores only (half the cores, 2 to 6).
    int n = (int) std::thread::hardware_concurrency() / 2;
    return std::clamp(n, 2, 6);
}

static void unload_locked() {
    g_cached.clear();
    if (g_ctx) { llama_free(g_ctx); g_ctx = nullptr; }
    if (g_model) { llama_model_free(g_model); g_model = nullptr; }
}

extern "C" int vl_load(const char *path, int n_ctx, int n_gpu_layers, const char *backend_dir) {
    std::lock_guard<std::mutex> lock(g_mu);
    if (!g_backends) {
        llama_log_set(log_cb, nullptr);
#ifdef VL_LOAD_BACKENDS
        if (backend_dir) ggml_backend_load_all_from_path(backend_dir);
#else
        (void) backend_dir;
#endif
        llama_backend_init();
        g_backends = true;
    }
    unload_locked();
    auto mp = llama_model_default_params();
    mp.n_gpu_layers = n_gpu_layers;
    g_model = llama_model_load_from_file(path, mp);
    if (!g_model) { LOGE("model load failed"); return 0; }

    auto cp = llama_context_default_params();
    cp.n_ctx = n_ctx;
    cp.n_batch = 512;
    cp.n_ubatch = 512;
    cp.n_threads = n_threads();
    cp.n_threads_batch = n_threads();
    // Gemma's sliding-window layers keep a cache that cannot be cut back to the shared prefix, so
    // every request would decode the whole system prompt again. A full-size SWA cache can be cut
    // (a few MB at this context size); per line, 11-31 new tokens instead of ~240 (CPU test, 2026-11-23).
    cp.swa_full = true;
    g_ctx = llama_init_from_model(g_model, cp);
    if (!g_ctx) { LOGE("context init failed"); unload_locked(); return 0; }
    LOGI("loaded, threads=%d gpu_layers=%d %s", n_threads(), n_gpu_layers, llama_print_system_info());
    return 1;
}

extern "C" void vl_unload(void) {
    std::lock_guard<std::mutex> lock(g_mu);
    unload_locked();
}

extern "C" void vl_cancel(void) { g_cancel = true; }

extern "C" const char *vl_system_info(void) { return llama_print_system_info(); }

// Tracks JSON nesting in generated text, outside string literals.
struct JsonDepth {
    int depth;
    bool in_str = false, esc = false;
    explicit JsonDepth(int d) : depth(d) {}
    // Returns true once every open object/array is closed.
    bool feed(const char *s, int n) {
        for (int i = 0; i < n; i++) {
            char c = s[i];
            if (in_str) {
                if (esc) esc = false;
                else if (c == '\\') esc = true;
                else if (c == '"') in_str = false;
            } else if (c == '"') in_str = true;
            else if (c == '{' || c == '[') depth++;
            else if ((c == '}' || c == ']') && --depth <= 0) return true;
        }
        return false;
    }
};

extern "C" int vl_generate(const char *prompt, int max_tokens, int close_depth, vl_piece_fn on_piece, void *user) {
    std::lock_guard<std::mutex> lock(g_mu);
    if (!g_ctx) return -1;
    g_cancel = false;

    const llama_vocab *vocab = llama_model_get_vocab(g_model);
    const int plen = (int) strlen(prompt);
    int n = -llama_tokenize(vocab, prompt, plen, nullptr, 0, true, true);
    std::vector<llama_token> toks(n);
    if (llama_tokenize(vocab, prompt, plen, toks.data(), n, true, true) < 0) return -1;

    const int n_ctx = (int) llama_n_ctx(g_ctx);
    if ((int) toks.size() + 8 >= n_ctx) { LOGE("prompt too long: %d", (int) toks.size()); return -2; }
    max_tokens = std::min<int>(max_tokens, n_ctx - (int) toks.size() - 1);

    // Keep the common prefix (at least one prompt token is decoded, for the first logits).
    llama_memory_t mem = llama_get_memory(g_ctx);
    size_t keep = 0;
    while (keep < g_cached.size() && keep < toks.size() && g_cached[keep] == toks[keep]) keep++;
    if (keep >= toks.size()) keep = toks.size() - 1;
    // Models whose memory cannot be cut part-way (recurrent layers) start over.
    if (keep == 0 || !llama_memory_seq_rm(mem, 0, (llama_pos) keep, -1)) {
        llama_memory_clear(mem, true);
        keep = 0;
    }
    g_cached.assign(toks.begin(), toks.begin() + keep);

    for (size_t i = keep; i < toks.size(); i += 512) {
        int len = (int) std::min<size_t>(512, toks.size() - i);
        if (llama_decode(g_ctx, llama_batch_get_one(toks.data() + i, len)) != 0) {
            g_cached.clear();
            llama_memory_clear(mem, true);
            return -1;
        }
        g_cached.insert(g_cached.end(), toks.begin() + i, toks.begin() + i + len);
        if (g_cancel) return 0;
    }

    llama_sampler *smpl = llama_sampler_chain_init(llama_sampler_chain_default_params());
    llama_sampler_chain_add(smpl, llama_sampler_init_greedy());

    JsonDepth json(close_depth);
    int produced = 0;
    char buf[256];
    while (produced < max_tokens && !g_cancel) {
        llama_token t = llama_sampler_sample(smpl, g_ctx, -1);
        if (llama_vocab_is_eog(vocab, t)) break;
        int len = llama_token_to_piece(vocab, t, buf, sizeof(buf), 0, false);
        produced++;
        if (len > 0) on_piece(buf, len, user);
        // The answer is complete: stop without decoding the token (it is not needed for a next one).
        if (close_depth > 0 && len > 0 && json.feed(buf, len)) break;
        if (llama_decode(g_ctx, llama_batch_get_one(&t, 1)) != 0) break;
        g_cached.push_back(t);
    }
    llama_sampler_free(smpl);
    LOGI("prompt %d tokens (%d reused), %d generated", (int) toks.size(), (int) keep, produced);
    return produced;
}
