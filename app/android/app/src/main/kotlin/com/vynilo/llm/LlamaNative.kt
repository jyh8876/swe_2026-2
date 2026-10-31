package com.vynilo.llm

/** JNI entry points in libvynilo_llm.so (src/main/cpp/vynilo_llm.cpp, llama.cpp b11913). */
object LlamaNative {
    val loaded: Boolean = runCatching { System.loadLibrary("vynilo_llm") }.isSuccess

    fun interface TokenCallback { fun onToken(bytes: ByteArray) }

    external fun load(libDir: String, path: String, nCtx: Int): Boolean
    external fun unload()
    external fun cancel()
    external fun systemInfo(): String
    external fun generate(prompt: String, maxTokens: Int, callback: TokenCallback): Int
}
