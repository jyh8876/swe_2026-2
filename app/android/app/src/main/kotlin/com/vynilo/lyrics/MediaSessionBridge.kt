package com.vynilo.lyrics

import android.app.SearchManager
import android.content.ActivityNotFoundException
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.media.MediaMetadata
import android.media.session.MediaController
import android.media.session.MediaSessionManager
import android.media.session.PlaybackState
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.provider.MediaStore
import android.provider.Settings
import android.service.notification.NotificationListenerService
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream

/**
 * Exists only so the user can grant notification access, which is what lets the app read other
 * apps' media sessions. Notifications themselves are ignored.
 */
class MediaListenerService : NotificationListenerService()

/**
 * Follows whatever music app is playing through the system media sessions, and controls it.
 * Spotify is preferred when several apps have a session and none is playing, and is the app
 * asked first to play a song. Channels: `vynilo/media_session` (methods) and
 * `vynilo/media_session/state` (one map per change, or `{none: true}` when nothing plays).
 */
class MediaSessionBridge(private val context: Context, messenger: BinaryMessenger) {
    private val main = Handler(Looper.getMainLooper())
    private val manager = context.getSystemService(MediaSessionManager::class.java)
    private val component = ComponentName(context, MediaListenerService::class.java)
    private var sink: EventChannel.EventSink? = null
    private var listening = false
    private val callbacks = mutableMapOf<MediaController, MediaController.Callback>()
    private var current: MediaController? = null
    private val sessionsListener = MediaSessionManager.OnActiveSessionsChangedListener { update(it ?: emptyList()) }

    init {
        MethodChannel(messenger, "vynilo/media_session").setMethodCallHandler { call, result ->
            when (call.method) {
                "hasAccess" -> result.success(hasAccess())
                "openAccessSettings" -> { openAccessSettings(); result.success(null) }
                "start" -> try {
                    start()
                    result.success(null)
                } catch (e: SecurityException) {
                    result.error("no_access", e.message, null)
                }
                "stop" -> { stop(); result.success(null) }
                "play", "pause", "next", "previous", "seek" -> {
                    val c = current ?: return@setMethodCallHandler result.error("no_session", "nothing is playing", null)
                    val controls = c.transportControls
                    when (call.method) {
                        "play" -> controls.play()
                        "pause" -> controls.pause()
                        "next" -> controls.skipToNext()
                        "previous" -> controls.skipToPrevious()
                        "seek" -> controls.seekTo((call.argument<Number>("positionMs") ?: 0).toLong())
                    }
                    result.success(null)
                }
                "playFromSearch" -> playFromSearch(call.argument<String>("query") ?: "", call.argument<String>("package"), result)
                "artwork" -> result.success(artwork())
                else -> result.notImplemented()
            }
        }
        EventChannel(messenger, "vynilo/media_session/state").setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
                sink = events
                emit()
            }

            override fun onCancel(arguments: Any?) {
                sink = null
            }
        })
    }

    private fun hasAccess(): Boolean {
        val enabled = Settings.Secure.getString(context.contentResolver, "enabled_notification_listeners") ?: return false
        return enabled.split(':').any { ComponentName.unflattenFromString(it)?.packageName == context.packageName }
    }

    private fun openAccessSettings() {
        val detail = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            Intent(Settings.ACTION_NOTIFICATION_LISTENER_DETAIL_SETTINGS)
                .putExtra(Settings.EXTRA_NOTIFICATION_LISTENER_COMPONENT_NAME, component.flattenToString())
        } else null
        for (intent in listOfNotNull(detail, Intent(Settings.ACTION_NOTIFICATION_LISTENER_SETTINGS))) {
            try {
                context.startActivity(intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
                return
            } catch (_: ActivityNotFoundException) {
            }
        }
    }

    private fun start() {
        if (listening) return
        update(manager.getActiveSessions(component))
        manager.addOnActiveSessionsChangedListener(sessionsListener, component, main)
        listening = true
    }

    fun stop() {
        if (listening) manager.removeOnActiveSessionsChangedListener(sessionsListener)
        listening = false
        callbacks.forEach { (c, cb) -> c.unregisterCallback(cb) }
        callbacks.clear()
        current = null
    }

    /** Keeps a callback on every session (except this app's) and re-picks the one to follow. */
    private fun update(sessions: List<MediaController>) {
        val others = sessions.filter { it.packageName != context.packageName }
        val gone = callbacks.keys.filter { old -> others.none { it.sessionToken == old.sessionToken } }
        gone.forEach { callbacks.remove(it)?.let(it::unregisterCallback) }
        for (c in others) {
            if (callbacks.keys.any { it.sessionToken == c.sessionToken }) continue
            val cb = object : MediaController.Callback() {
                override fun onPlaybackStateChanged(state: PlaybackState?) = changed()
                override fun onMetadataChanged(metadata: MediaMetadata?) = changed()
                override fun onSessionDestroyed() = changed()
            }
            c.registerCallback(cb, main)
            callbacks[c] = cb
        }
        changed()
    }

    /**
     * Follows the app that is playing (Spotify when several are); otherwise stays with the last one
     * while it has a session, then prefers Spotify's session.
     */
    private fun changed() {
        val sessions = callbacks.keys.sortedByDescending { it.packageName == SPOTIFY }
        val playing = sessions.firstOrNull { it.playbackState?.state == PlaybackState.STATE_PLAYING }
        val stillThere = current?.let { c -> sessions.firstOrNull { it.sessionToken == c.sessionToken } }
        current = playing ?: stillThere ?: sessions.firstOrNull { it.metadata != null }
        emit()
    }

    private fun emit() {
        val s = sink ?: return
        val c = current
        val md = c?.metadata
        val title = md?.getString(MediaMetadata.METADATA_KEY_TITLE) ?: md?.getString(MediaMetadata.METADATA_KEY_DISPLAY_TITLE)
        if (c == null || md == null || title.isNullOrBlank()) {
            s.success(mapOf("none" to true))
            return
        }
        val st = c.playbackState
        val actions = st?.actions ?: 0L
        val updated = st?.lastPositionUpdateTime ?: 0L
        s.success(mapOf(
            "package" to c.packageName,
            "app" to appLabel(c.packageName),
            "title" to title,
            "artist" to (md.getString(MediaMetadata.METADATA_KEY_ARTIST)
                ?: md.getString(MediaMetadata.METADATA_KEY_ALBUM_ARTIST)
                ?: md.getString(MediaMetadata.METADATA_KEY_DISPLAY_SUBTITLE) ?: ""),
            "album" to md.getString(MediaMetadata.METADATA_KEY_ALBUM),
            "durationMs" to md.getLong(MediaMetadata.METADATA_KEY_DURATION),
            "positionMs" to (st?.position ?: 0L),
            // How long ago the position was measured, so Dart can extrapolate from the right moment.
            "ageMs" to (if (updated > 0) SystemClock.elapsedRealtime() - updated else 0L),
            "speed" to (st?.playbackSpeed ?: 1f).toDouble(),
            "playing" to (st?.state == PlaybackState.STATE_PLAYING),
            "canSeek" to (actions and PlaybackState.ACTION_SEEK_TO != 0L),
            "canSkip" to (actions and (PlaybackState.ACTION_SKIP_TO_NEXT or PlaybackState.ACTION_SKIP_TO_PREVIOUS) != 0L),
            "hasArt" to (md.getBitmap(MediaMetadata.METADATA_KEY_ALBUM_ART) != null || md.getBitmap(MediaMetadata.METADATA_KEY_ART) != null),
        ))
    }

    private fun appLabel(pkg: String): String = try {
        val pm = context.packageManager
        pm.getApplicationLabel(pm.getApplicationInfo(pkg, 0)).toString()
    } catch (_: Exception) {
        pkg
    }

    /** The current album art as JPEG, at most 640 px, or null. */
    private fun artwork(): ByteArray? {
        val md = current?.metadata ?: return null
        val art = md.getBitmap(MediaMetadata.METADATA_KEY_ALBUM_ART) ?: md.getBitmap(MediaMetadata.METADATA_KEY_ART) ?: return null
        val scale = minOf(1f, 640f / maxOf(art.width, art.height))
        val bmp = if (scale < 1f) Bitmap.createScaledBitmap(art, (art.width * scale).toInt(), (art.height * scale).toInt(), true) else art
        return ByteArrayOutputStream().use { out ->
            bmp.compress(Bitmap.CompressFormat.JPEG, 88, out)
            out.toByteArray()
        }
    }

    /**
     * Asks a music app to find and play [query] ("artist title"), the request voice assistants use.
     * The followed session is asked first; otherwise the app [pkg] (the last one used), then
     * Spotify, then any app.
     */
    private companion object {
        const val SPOTIFY = "com.spotify.music"
    }

    private fun playFromSearch(query: String, pkg: String?, result: MethodChannel.Result) {
        val c = current
        if (c != null && (pkg == null || c.packageName == pkg) &&
            (c.playbackState?.actions ?: 0L) and PlaybackState.ACTION_PLAY_FROM_SEARCH != 0L) {
            c.transportControls.playFromSearch(query, Bundle())
            return result.success("session")
        }
        val target = pkg ?: c?.packageName
        for (p in listOf(target, SPOTIFY, null).distinct()) {
            val intent = Intent(MediaStore.INTENT_ACTION_MEDIA_PLAY_FROM_SEARCH)
                .putExtra(MediaStore.EXTRA_MEDIA_FOCUS, "vnd.android.cursor.item/*")
                .putExtra(SearchManager.QUERY, query)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            if (p != null) intent.setPackage(p)
            try {
                context.startActivity(intent)
                return result.success("intent")
            } catch (_: ActivityNotFoundException) {
            }
        }
        result.error("no_app", "no music app can play from search", null)
    }
}
