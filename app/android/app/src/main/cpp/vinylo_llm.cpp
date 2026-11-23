// JNI wrapper over the shared core (packages/vinylo_llama/ios/vinylo_llama/Sources/VinyloLlmCore, also used by iOS).
#include <jni.h>
#include "vinylo_llm_core.h"

extern "C" JNIEXPORT jboolean JNICALL
Java_com_vinylo_llm_LlamaNative_load(JNIEnv *env, jobject, jstring libDir, jstring path, jint nCtx) {
    const char *dir = env->GetStringUTFChars(libDir, nullptr);
    const char *p = env->GetStringUTFChars(path, nullptr);
    int ok = vl_load(p, nCtx, 0, dir);
    env->ReleaseStringUTFChars(path, p);
    env->ReleaseStringUTFChars(libDir, dir);
    return ok ? JNI_TRUE : JNI_FALSE;
}

extern "C" JNIEXPORT void JNICALL
Java_com_vinylo_llm_LlamaNative_unload(JNIEnv *, jobject) { vl_unload(); }

extern "C" JNIEXPORT void JNICALL
Java_com_vinylo_llm_LlamaNative_cancel(JNIEnv *, jobject) { vl_cancel(); }

extern "C" JNIEXPORT jstring JNICALL
Java_com_vinylo_llm_LlamaNative_systemInfo(JNIEnv *env, jobject) { return env->NewStringUTF(vl_system_info()); }

struct PieceSink { JNIEnv *env; jobject callback; jmethodID onToken; };

static void on_piece(const char *bytes, int len, void *user) {
    auto *s = static_cast<PieceSink *>(user);
    jbyteArray arr = s->env->NewByteArray(len);
    s->env->SetByteArrayRegion(arr, 0, len, reinterpret_cast<const jbyte *>(bytes));
    s->env->CallVoidMethod(s->callback, s->onToken, arr);
    s->env->DeleteLocalRef(arr);
}

// Hands token bytes to callback.onToken(ByteArray); returns generated tokens, -1 error, -2 too long.
extern "C" JNIEXPORT jint JNICALL
Java_com_vinylo_llm_LlamaNative_generate(JNIEnv *env, jobject, jstring jprompt, jint maxTokens, jint closeDepth, jobject callback) {
    PieceSink sink{env, callback, env->GetMethodID(env->GetObjectClass(callback), "onToken", "([B)V")};
    const char *prompt = env->GetStringUTFChars(jprompt, nullptr);
    int rc = vl_generate(prompt, maxTokens, closeDepth, on_piece, &sink);
    env->ReleaseStringUTFChars(jprompt, prompt);
    return rc;
}
