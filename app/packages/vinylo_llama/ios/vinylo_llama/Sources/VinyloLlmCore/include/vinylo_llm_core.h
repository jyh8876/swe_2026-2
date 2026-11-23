// On-device llama.cpp core shared by Android (JNI, android/app/src/main/cpp) and iOS (this Swift package).
// One model and one context at a time; every call is made from a single worker thread.
#pragma once

#ifdef __cplusplus
extern "C" {
#endif

/// Receives the bytes of each generated token (a piece may end inside a UTF-8 character).
typedef void (*vl_piece_fn)(const char *bytes, int len, void *user);

/// Loads a GGUF model. [backend_dir] is where ggml CPU variants live (Android) or NULL.
/// [n_gpu_layers]: 0 = CPU only (Android), 99 = everything on Metal (iOS).
int vl_load(const char *path, int n_ctx, int n_gpu_layers, const char *backend_dir);
void vl_unload(void);
void vl_cancel(void);
const char *vl_system_info(void);

/// Greedy completion of [prompt], reusing the cached prefix of the previous prompt.
/// [close_depth] > 0: the prompt ends inside that many open JSON objects/arrays, and generation
/// stops as soon as the model closes them (so a forced `{"i":` prefix stops after one entry).
/// Returns the number of generated tokens, -1 on error, -2 when the prompt does not fit.
int vl_generate(const char *prompt, int max_tokens, int close_depth, vl_piece_fn on_piece, void *user);

#ifdef __cplusplus
}
#endif
