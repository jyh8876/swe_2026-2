package com.vynilo.lyrics

import android.app.Activity
import com.spotify.android.appremote.api.ConnectionParams
import com.spotify.android.appremote.api.Connector
import com.spotify.android.appremote.api.SpotifyAppRemote
import com.spotify.protocol.client.Subscription
import com.spotify.protocol.types.PlayerState
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

/**
 * Spotify App Remote SDK bridge. Plays and follows Spotify through the installed Spotify app in the
 * background, so the Spotify app is never brought to the front, and player state is pushed the
 * moment it changes instead of polled from the Web API every 3 s.
 *
 * Channels: "vynilo/spotify_remote" (installed, connect, disconnect, play, pause, resume, seek, next,
 * previous, state) and "vynilo/spotify_remote/state" (player state events).
 */
class SpotifyRemoteBridge(private val activity: Activity, messenger: BinaryMessenger) {
    private var remote: SpotifyAppRemote? = null
    private var subscription: Subscription<PlayerState>? = null
    private var sink: EventChannel.EventSink? = null

    init {
        MethodChannel(messenger, "vynilo/spotify_remote").setMethodCallHandler { call, result ->
            when (call.method) {
                "installed" -> result.success(SpotifyAppRemote.isSpotifyInstalled(activity))
                "connected" -> result.success(remote?.isConnected == true)
                "connect" -> connect(call.argument<String>("clientId")!!, call.argument<String>("redirectUri")!!, result)
                "disconnect" -> { dispose(); result.success(null) }
                "play" -> {
                    val player = remote?.playerApi ?: return@setMethodCallHandler result.error("NotConnected", "Spotify App Remote is not connected", null)
                    val position = (call.argument<Number>("positionMs") ?: 0).toLong()
                    player.play(call.argument<String>("uri")!!)
                        .setResultCallback {
                            if (position > 0) player.seekTo(position)
                            reply { result.success(null) }
                        }
                        .setErrorCallback { e -> reply { result.error(e.javaClass.simpleName, e.message, null) } }
                }
                "pause", "resume", "next", "previous", "seek" -> {
                    val player = remote?.playerApi ?: return@setMethodCallHandler result.error("NotConnected", "Spotify App Remote is not connected", null)
                    val call0 = when (call.method) {
                        "pause" -> player.pause()
                        "resume" -> player.resume()
                        "next" -> player.skipNext()
                        "previous" -> player.skipPrevious()
                        else -> player.seekTo((call.argument<Number>("positionMs") ?: 0).toLong())
                    }
                    call0.setResultCallback { reply { result.success(null) } }
                        .setErrorCallback { e -> reply { result.error(e.javaClass.simpleName, e.message, null) } }
                }
                "state" -> {
                    val player = remote?.playerApi ?: return@setMethodCallHandler result.success(null)
                    player.playerState
                        .setResultCallback { s -> reply { result.success(toMap(s)) } }
                        .setErrorCallback { _ -> reply { result.success(null) } }
                }
                else -> result.notImplemented()
            }
        }
        EventChannel(messenger, "vynilo/spotify_remote/state").setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
                sink = events
                remote?.let { subscribe(it) }
            }

            override fun onCancel(arguments: Any?) {
                sink = null
            }
        })
    }

    private fun reply(block: () -> Unit) = activity.runOnUiThread(block)

    /** Connects once; the Spotify app asks the user to approve "app-remote-control" the first time. */
    private fun connect(clientId: String, redirectUri: String, result: MethodChannel.Result) {
        if (remote?.isConnected == true) return result.success(true)
        var replied = false
        val params = ConnectionParams.Builder(clientId).setRedirectUri(redirectUri).showAuthView(true).build()
        SpotifyAppRemote.connect(activity, params, object : Connector.ConnectionListener {
            override fun onConnected(appRemote: SpotifyAppRemote) {
                remote = appRemote
                subscribe(appRemote)
                if (!replied) { replied = true; reply { result.success(true) } }
            }

            // Also called later when an established connection drops; only the first call replies.
            override fun onFailure(error: Throwable) {
                remote = null
                subscription = null
                if (!replied) {
                    replied = true
                    reply { result.error(error.javaClass.simpleName, error.message, null) }
                } else {
                    reply { sink?.success(mapOf("disconnected" to true, "reason" to error.javaClass.simpleName)) }
                }
            }
        })
    }

    private fun subscribe(appRemote: SpotifyAppRemote) {
        subscription?.cancel()
        subscription = appRemote.playerApi.subscribeToPlayerState().setEventCallback { s ->
            val map = toMap(s)
            reply { sink?.success(map) }
        }
    }

    private fun toMap(s: PlayerState): Map<String, Any?>? {
        val t = s.track ?: return null
        return mapOf(
            "title" to t.name,
            "artist" to (t.artists?.mapNotNull { it.name }?.joinToString(", ") ?: t.artist?.name ?: ""),
            "album" to t.album?.name,
            "durationMs" to t.duration,
            "uri" to t.uri,
            "positionMs" to s.playbackPosition,
            "paused" to s.isPaused,
            "speed" to s.playbackSpeed.toDouble(),
            "isEpisode" to t.isEpisode,
        )
    }

    fun dispose() {
        subscription?.cancel()
        subscription = null
        remote?.let { SpotifyAppRemote.disconnect(it) }
        remote = null
    }
}
