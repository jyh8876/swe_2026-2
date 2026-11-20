import Flutter
import MediaPlayer
import MusicKit
import UIKit

/// iOS side of the Dart `vinylo/media_session` channels (see lib/app/platform_services.dart,
/// classes MusicApp and MusicAppSource). Android answers the same channels with media sessions
/// (MediaSessionBridge.kt); here Apple Music is followed and controlled through MusicKit.
///
/// Methods:
/// - `hasAccess`: Apple Music (MusicKit) authorization is granted.
/// - `openAccessSettings`: shows the system permission prompt the first time, then Settings.
/// - `start` / `stop`: begin / end reporting the playing track on the event channel.
/// - `play`, `pause`, `next`, `previous`, `seek` {positionMs}, `artwork`, `playFromSearch` {query}.
///
/// Events (`vinylo/media_session/state`): title, artist, album, durationMs, positionMs, ageMs,
/// playing, speed, mediaId, app ("Apple Music"), canSeek, canSkip; or {none: true} when idle.
final class AppleMusicBridge: NSObject, FlutterStreamHandler {
  private static var instance: AppleMusicBridge?

  static func attach(messenger: FlutterBinaryMessenger) {
    let bridge = AppleMusicBridge()
    instance = bridge
    let methods = FlutterMethodChannel(name: "vinylo/media_session", binaryMessenger: messenger)
    methods.setMethodCallHandler { call, result in bridge.handle(call, result) }
    FlutterEventChannel(name: "vinylo/media_session/state", binaryMessenger: messenger).setStreamHandler(bridge)
  }

  private var sink: FlutterEventSink?
  private var timer: Timer?
  private var following = false

  /// What was last sent, to report only changes and drift, plus a slow heartbeat.
  private var lastKey = ""
  private var lastPlaying = false
  private var lastPosition = 0.0
  private var lastSent = Date.distantPast
  private var wasIdle = false

  private var player: SystemMusicPlayer { SystemMusicPlayer.shared }
  private var authorized: Bool { MusicAuthorization.currentStatus == .authorized }

  // MARK: Method channel

  private func handle(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) {
    switch call.method {
    case "hasAccess":
      result(authorized)
    case "openAccessSettings":
      Task { @MainActor in
        if MusicAuthorization.currentStatus == .notDetermined {
          _ = await MusicAuthorization.request()
        } else if let url = URL(string: UIApplication.openSettingsURLString) {
          await UIApplication.shared.open(url)
        }
        result(nil)
      }
    case "start":
      guard authorized else {
        result(FlutterError(code: "no_access", message: "Apple Music access is not granted", details: nil))
        return
      }
      following = true
      startTimer()
      result(nil)
    case "stop":
      following = false
      stopTimer()
      result(nil)
    case "play":
      guard requireAccess(result) else { return }
      Task { @MainActor in await self.run(result) { try await self.player.play() } }
    case "pause":
      guard requireAccess(result) else { return }
      player.pause()
      result(nil)
    case "next":
      guard requireAccess(result) else { return }
      Task { @MainActor in await self.run(result) { try await self.player.skipToNextEntry() } }
    case "previous":
      guard requireAccess(result) else { return }
      Task { @MainActor in await self.run(result) { try await self.player.skipToPreviousEntry() } }
    case "seek":
      guard requireAccess(result) else { return }
      let ms = (call.arguments as? [String: Any])?["positionMs"] as? NSNumber
      player.playbackTime = max(0, (ms?.doubleValue ?? 0) / 1000)
      result(nil)
    case "artwork":
      result(artworkData())
    case "playFromSearch":
      guard requireAccess(result) else { return }
      let query = ((call.arguments as? [String: Any])?["query"] as? String ?? "").trimmingCharacters(in: .whitespaces)
      Task { @MainActor in await self.playFromSearch(query, result) }
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func requireAccess(_ result: FlutterResult) -> Bool {
    if authorized { return true }
    result(FlutterError(code: "no_access", message: "Apple Music access is not granted", details: nil))
    return false
  }

  private func run(_ result: FlutterResult, _ body: () async throws -> Void) async {
    do {
      try await body()
      result(nil)
    } catch {
      result(FlutterError(code: "player_error", message: "\(error)", details: nil))
    }
  }

  /// Finds the first Apple Music catalog match and plays it in the system Music player.
  @MainActor
  private func playFromSearch(_ query: String, _ result: FlutterResult) async {
    guard !query.isEmpty else {
      result(FlutterError(code: "empty_query", message: "Empty query", details: nil))
      return
    }
    do {
      var request = MusicCatalogSearchRequest(term: query, types: [Song.self])
      request.limit = 1
      let response = try await request.response()
      guard let song = response.songs.first else {
        result(FlutterError(code: "not_found", message: "No Apple Music match", details: nil))
        return
      }
      player.queue = [song]
      try await player.play()
      result(nil)
    } catch {
      result(FlutterError(code: "player_error", message: "\(error)", details: nil))
    }
  }

  // MARK: Event channel

  func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
    sink = events
    if following { startTimer() }
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    sink = nil
    stopTimer()
    return nil
  }

  private func startTimer() {
    guard timer == nil else { return }
    lastKey = ""
    let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.poll() }
    RunLoop.main.add(t, forMode: .common)
    timer = t
    poll()
  }

  private func stopTimer() {
    timer?.invalidate()
    timer = nil
  }

  private struct Track {
    var title = ""
    var artist = ""
    var album: String?
    var duration: TimeInterval = 0
    var id = ""
  }

  /// The current queue entry: MusicKit first, the system media library for what it lacks
  /// (songs from the user's own library often have no catalog item).
  private func currentTrack() -> Track? {
    guard let entry = player.queue.currentEntry else { return nil }
    var track = Track(title: entry.title, artist: entry.subtitle ?? "", id: "\(entry.id)")
    switch entry.item {
    case .song(let song):
      track.artist = song.artistName
      track.album = song.albumTitle
      track.duration = song.duration ?? 0
      track.id = song.id.rawValue
    case .musicVideo(let video):
      track.artist = video.artistName
      track.duration = video.duration ?? 0
      track.id = video.id.rawValue
    default:
      break
    }
    if let item = MPMusicPlayerController.systemMusicPlayer.nowPlayingItem {
      if track.title.isEmpty { track.title = item.title ?? "" }
      if track.artist.isEmpty { track.artist = item.artist ?? "" }
      if track.album == nil { track.album = item.albumTitle }
      if track.duration <= 0 { track.duration = item.playbackDuration }
    }
    return track.title.isEmpty ? nil : track
  }

  private func poll() {
    guard following, let sink = sink else { return }
    guard authorized, let track = currentTrack() else {
      if !wasIdle {
        wasIdle = true
        lastKey = ""
        sink(["none": true])
      }
      return
    }
    wasIdle = false
    let status = player.state.playbackStatus
    let playing = status == .playing || status == .seekingForward || status == .seekingBackward
    let rate = Double(player.state.playbackRate)
    let position = player.playbackTime
    let now = Date()

    // Where the playhead should be if nothing changed since the last report.
    let expected = lastPlaying ? lastPosition + now.timeIntervalSince(lastSent) * (lastRate == 0 ? 1 : lastRate) : lastPosition
    let key = "\(track.id)|\(track.title)|\(track.artist)"
    let changed = key != lastKey || playing != lastPlaying
    let drifted = abs(position - expected) > 0.8
    guard changed || drifted || now.timeIntervalSince(lastSent) >= 5 else { return }

    lastKey = key
    lastPlaying = playing
    lastRate = rate
    lastPosition = position
    lastSent = now
    sink([
      "title": track.title,
      "artist": track.artist,
      "album": track.album as Any,
      "durationMs": Int(track.duration * 1000),
      "positionMs": Int(position * 1000),
      "ageMs": 0,
      "playing": playing,
      "speed": playing ? (rate > 0 ? rate : 1) : 0,
      "mediaId": track.id,
      "app": "Apple Music",
      "canSeek": true,
      "canSkip": true,
    ])
  }

  private var lastRate = 1.0

  /// The playing track's cover as JPEG. MusicKit artwork URLs are not plain http for library
  /// songs, so this reads it from the media library item.
  private func artworkData() -> Any? {
    guard let art = MPMusicPlayerController.systemMusicPlayer.nowPlayingItem?.artwork,
          let image = art.image(at: CGSize(width: 800, height: 800)),
          let data = image.jpegData(compressionQuality: 0.9) else { return nil }
    return FlutterStandardTypedData(bytes: data)
  }
}
