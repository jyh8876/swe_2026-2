// Minimal JNI bridge: load one GGUF model and stream a greedy completion for a prompt.
#include <jni.h>
#include <android/log.h>
#include <atomic>
#include <mutex>
#include <string>
#include <vector>
#include <thread>
#include <algorithm>

#include "llama.h"
#include "ggml-backend.h"

#define TAG "vynilo-llm"
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO, TAG, __VA_ARGS__)
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, TAG, __VA_ARGS__)

static std::mutex g_mu;
static llama_model *g_model = nullptr;
static llama_context *g_ctx = nullptr;
static std::atomic<bool> g_cancel{false};
static bool g_backends = false;

static void log_cb(ggml_log_level level, const char *text, void *) {
    if (level >= GGML_LOG_LEVEL_WARN) __android_log_print(ANDROID_LOG_WARN, TAG, "%s", text);
}

static int n_threads() {
    // Use the big cores only: half the cores, at least 2, at most 6.
    int n = (int) std::thread::hardware_concurrency() / 2;
    return std::clamp(n, 2, 6);
}

static void unload_locked() {
    if (g_ctx) { llama_free(g_ctx); g_ctx = nullptr; }
    if (g_model) { llama_model_free(g_model); g_model = nullptr; }
}

extern "C" JNIEXPORT jboolean JNICALL
Java_com_vynilo_llm_LlamaNative_load(JNIEnv *env, jobject, jstring libDir, jstring path, jint nCtx) {
    std::lock_guard<std::mutex> lock(g_mu);
    if (!g_backends) {
        llama_log_set(log_cb, nullptr);
        const char *dir = env->GetStringUTFChars(libDir, nullptr);
        ggml_backend_load_all_from_path(dir);
        env->ReleaseStringUTFChars(libDir, dir);
        llama_backend_init();
        g_backends = true;
    }
    unload_locked();
    const char *p = env->GetStringUTFChars(path, nullptr);
    auto mp = llama_model_default_params();
    g_model = llama_model_load_from_file(p, mp);
    env->ReleaseStringUTFChars(path, p);
    if (!g_model) { LOGE("model load failed"); return JNI_FALSE; }

    auto cp = llama_context_default_params();
    cp.n_ctx = nCtx;
    cp.n_batch = 512;
    cp.n_ubatch = 512;
    cp.n_threads = n_threads();
    cp.n_threads_batch = n_threads();
    g_ctx = llama_init_from_model(g_model, cp);
    if (!g_ctx) { LOGE("context init failed"); unload_locked(); return JNI_FALSE; }
    LOGI("loaded, threads=%d %s", n_threads(), llama_print_system_info());
    return JNI_TRUE;
}

extern "C" JNIEXPORT void JNICALL
Java_com_vynilo_llm_LlamaNative_unload(JNIEnv *, jobject) {
    std::lock_guard<std::mutex> lock(g_mu);
    unload_locked();
}

extern "C" JNIEXPORT void JNICALL
Java_com_vynilo_llm_LlamaNative_cancel(JNIEnv *, jobject) { g_cancel = true; }

extern "C" JNIEXPORT jstring JNICALL
Java_com_vynilo_llm_LlamaNative_systemInfo(JNIEnv *env, jobject) {
    return env->NewStringUTF(llama_print_system_info());
}

// Streams token pieces to callback.onToken(String); returns the number of generated tokens, or -1 on error.
extern "C" JNIEXPORT jint JNICALL
Java_com_vynilo_llm_LlamaNative_generate(JNIEnv *env, jobject, jstring jprompt, jint maxTokens, jobject callback) {
    std::lock_guard<std::mutex> lock(g_mu);
    if (!g_ctx) return -1;
    g_cancel = false;

    jclass cls = env->GetObjectClass(callback);
    jmethodID onToken = env->GetMethodID(cls, "onToken", "([B)V");

    const char *cp = env->GetStringUTFChars(jprompt, nullptr);
    std::string prompt(cp);
    env->ReleaseStringUTFChars(jprompt, cp);

    const llama_vocab *vocab = llama_model_get_vocab(g_model);
    int n = -llama_tokenize(vocab, prompt.c_str(), (int) prompt.size(), nullptr, 0, true, true);
    std::vector<llama_token> toks(n);
    if (llama_tokenize(vocab, prompt.c_str(), (int) prompt.size(), toks.data(), n, true, true) < 0) return -1;

    const int n_ctx = (int) llama_n_ctx(g_ctx);
    if ((int) toks.size() + 8 >= n_ctx) { LOGE("prompt too long: %d", (int) toks.size()); return -2; }
    maxTokens = std::min<int>(maxTokens, n_ctx - (int) toks.size() - 1);

    llama_memory_clear(llama_get_memory(g_ctx), true);

    // Prompt in n_batch-sized chunks.
    for (size_t i = 0; i < toks.size(); i += 512) {
        int len = (int) std::min<size_t>(512, toks.size() - i);
        if (llama_decode(g_ctx, llama_batch_get_one(toks.data() + i, len)) != 0) return -1;
        if (g_cancel) return 0;
    }

    auto sp = llama_sampler_chain_default_params();
    llama_sampler *smpl = llama_sampler_chain_init(sp);
    llama_sampler_chain_add(smpl, llama_sampler_init_greedy());

    int produced = 0;
    char buf[256];
    while (produced < maxTokens && !g_cancel) {
        llama_token t = llama_sampler_sample(smpl, g_ctx, -1);
        if (llama_vocab_is_eog(vocab, t)) break;
        int len = llama_token_to_piece(vocab, t, buf, sizeof(buf), 0, false);
        if (len > 0) {
            jbyteArray arr = env->NewByteArray(len);
            env->SetByteArrayRegion(arr, 0, len, reinterpret_cast<const jbyte *>(buf));
            env->CallVoidMethod(callback, onToken, arr);
            env->DeleteLocalRef(arr);
        }
        produced++;
        if (llama_decode(g_ctx, llama_batch_get_one(&t, 1)) != 0) break;
    }
    llama_sampler_free(smpl);
    return produced;
}
