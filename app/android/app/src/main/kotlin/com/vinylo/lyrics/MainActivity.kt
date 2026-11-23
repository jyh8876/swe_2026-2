package com.vinylo.lyrics

import android.content.Intent
import android.net.Uri
import com.vinylo.llm.LlamaNative
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream
import java.util.concurrent.Executors

class MainActivity : FlutterActivity() {
    private val llmThread = Executors.newSingleThreadExecutor()
    private var loadedPath: String? = null
    private var links: MethodChannel? = null
    private var pendingLink: String? = null
    private var spotifyRemote: SpotifyRemoteBridge? = null
    private var mediaSessions: MediaSessionBridge? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val messenger = flutterEngine.dartExecutor.binaryMessenger

        // Spotify App Remote SDK: plays through the installed Spotify app in the background.
        spotifyRemote = SpotifyRemoteBridge(this, messenger)

        // Spotify (or any music app) through the system media sessions; needs notification access.
        mediaSessions = MediaSessionBridge(applicationContext, messenger)

        // On-device llama.cpp (Gemma 4 E2B). All calls run on one background thread.
        val llama = MethodChannel(messenger, "vinylo/llama")
        llama.setMethodCallHandler { call, result ->
            when (call.method) {
                "available" -> result.success(LlamaNative.loaded)
                "cancel" -> { if (LlamaNative.loaded) LlamaNative.cancel(); result.success(null) }
                "unload" -> llmThread.execute {
                    if (LlamaNative.loaded) LlamaNative.unload()
                    loadedPath = null
                    runOnUiThread { result.success(null) }
                }
                "complete" -> {
                    val path = call.argument<String>("path")!!
                    val prompt = call.argument<String>("prompt")!!
                    val maxTokens = call.argument<Int>("maxTokens") ?: 1024
                    val nCtx = call.argument<Int>("nCtx") ?: 4096
                    // With a stream id, the text is also sent as it is generated ("partial"), so lines can
                    // be shown one by one instead of after the whole chunk.
                    val streamId = call.argument<Int>("streamId")
                    llmThread.execute {
                        try {
                            if (!LlamaNative.loaded) throw IllegalStateException("llama.cpp is not available on this device")
                            if (loadedPath != path) {
                                if (!LlamaNative.load(applicationInfo.nativeLibraryDir, path, nCtx)) {
                                    throw IllegalStateException("model load failed (not enough free memory?)")
                                }
                                loadedPath = path
                            }
                            val out = ByteArrayOutputStream()
                            var sent = 0
                            var lastSend = 0L
                            val rc = LlamaNative.generate(prompt, maxTokens) {
                                out.write(it)
                                val now = System.currentTimeMillis()
                                if (streamId != null && now - lastSend >= 200) {
                                    lastSend = now
                                    val text = utf8Prefix(out.toByteArray())
                                    if (text.length > sent) {
                                        val piece = text.substring(sent)
                                        sent = text.length
                                        runOnUiThread { llama.invokeMethod("partial", mapOf("id" to streamId, "text" to piece)) }
                                    }
                                }
                            }
                            val text = out.toString(Charsets.UTF_8.name())
                            runOnUiThread {
                                when {
                                    rc == -2 -> result.error("too_long", "prompt too long", null)
                                    rc < 0 -> result.error("failed", "generation failed", null)
                                    else -> result.success(text)
                                }
                            }
                        } catch (e: Throwable) {
                            runOnUiThread { result.error("failed", e.message, null) }
                        }
                    }
                }
                else -> result.notImplemented()
            }
        }

        // Browser launch and OAuth redirects (Spotify PKCE: vinylo://spotify-callback).
        links = MethodChannel(messenger, "vinylo/links").apply {
            setMethodCallHandler { call, result ->
                when (call.method) {
                    "open" -> {
                        // No app for the link (e.g. spotify: without Spotify installed) is an error, not a crash.
                        try {
                            startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(call.argument<String>("url"))).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
                            result.success(null)
                        } catch (e: android.content.ActivityNotFoundException) {
                            result.error("no_app", e.message, null)
                        }
                    }
                    "initialLink" -> { result.success(pendingLink); pendingLink = null }
                    else -> result.notImplemented()
                }
            }
        }
        intent?.data?.let { pendingLink = it.toString() }
    }

    override fun onDestroy() {
        spotifyRemote?.dispose()
        mediaSessions?.stop()
        super.onDestroy()
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        intent.data?.let { uri -> links?.invokeMethod("link", uri.toString()) ?: run { pendingLink = uri.toString() } }
    }

    /** The bytes decoded as UTF-8 up to the last complete character (a token can end mid-character). */
    private fun utf8Prefix(bytes: ByteArray): String {
        var end = bytes.size
        var back = 0
        // Step back over continuation bytes (10xxxxxx) to the lead byte of the last character.
        while (back < 4 && end - back - 1 >= 0 && (bytes[end - back - 1].toInt() and 0xC0) == 0x80) back++
        if (end - back - 1 >= 0) {
            val lead = bytes[end - back - 1].toInt() and 0xFF
            val need = when {
                lead >= 0xF0 -> 4
                lead >= 0xE0 -> 3
                lead >= 0xC0 -> 2
                else -> 1
            }
            if (back + 1 < need) end -= back + 1
        }
        return String(bytes, 0, end, Charsets.UTF_8)
    }
}
