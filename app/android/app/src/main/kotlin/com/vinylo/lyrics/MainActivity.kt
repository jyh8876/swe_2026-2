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

        // On-device llama.cpp (vinylo-e2b-lyrics). All calls run on one background thread.
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
                    val closeDepth = call.argument<Int>("closeDepth") ?: 0
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
                            val rc = LlamaNative.generate(prompt, maxTokens, closeDepth) { out.write(it) }
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
    }}
