package com.vinylo.llm

/** JNI entry points in libvinylo_llm.so (src/main/cpp/vinylo_llm.cpp, llama.cpp b11913). */
object LlamaNative {
    val loaded: Boolean = runCatching { System.loadLibrary("vinylo_llm") }.isSuccess

    fun interface TokenCallback { fun onToken(bytes: ByteArray) }

    external fun load(libDir: String, path: String, nCtx: Int): Boolean
    external fun unload()
    external fun cancel()
    external fun systemInfo(): String
    external fun generate(prompt: String, maxTokens: Int, callback: TokenCallback): Int
}
