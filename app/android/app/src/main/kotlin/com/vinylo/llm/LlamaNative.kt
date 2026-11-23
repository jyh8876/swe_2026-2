package com.vinylo.llm

/** JNI entry points in libvinylo_llm.so (src/main/cpp/vinylo_llm.cpp over the shared core, llama.cpp b11913). */
object LlamaNative {
    val loaded: Boolean = runCatching { System.loadLibrary("vinylo_llm") }.isSuccess

    fun interface TokenCallback { fun onToken(bytes: ByteArray) }

    external fun load(libDir: String, path: String, nCtx: Int): Boolean
    external fun unload()
    external fun cancel()
    external fun systemInfo(): String
    /** [closeDepth] > 0 stops once the model closes that many open JSON objects/arrays. */
    external fun generate(prompt: String, maxTokens: Int, closeDepth: Int, callback: TokenCallback): Int
}
