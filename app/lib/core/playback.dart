import 'dart:async';
import 'dart:math';

import 'models.dart';

enum SourceID { spotify, appleMusic, simulator }

enum SourceCapability { read, playPause, skip, seek }

/// A position report from a playback source.
class PlaybackSnapshot {
  final TrackKey track;

  /// Playback position in seconds at `reportedAt`.
  final double position;
  final DateTime reportedAt;
  final double rate;
  final bool isPlaying;

  PlaybackSnapshot({required this.track, required this.position, DateTime? reportedAt, this.rate = 1, required this.isPlaying})
      : reportedAt = reportedAt ?? DateTime.now();
}

enum SourceError { unsupported, notConnected, notInstalled, premiumRequired, permissionDenied }

extension SourceErrorMessage on SourceError {
  String get userMessage => switch (this) {
        SourceError.unsupported => '음악 앱이 이 기능을 지원하지 않아요.',
        SourceError.notConnected => '음악 앱과 연결이 끊겼어요. 다시 연결해 주세요.',
        SourceError.notInstalled => 'Spotify 앱이 설치되어 있지 않아요.',
        SourceError.premiumRequired => 'Spotify 재생 제어는 Premium 계정이 필요해요.',
        SourceError.permissionDenied => '음악 접근 권한이 없어요. 설정에서 허용해 주세요.',
      };
}

/// SSRD A.III `NowPlayingSource`. One adapter per source, each declaring its capabilities.
abstract class NowPlayingSource {
  SourceID get id;
  Set<SourceCapability> get capabilities;
  Stream<PlaybackSnapshot> get snapshots;

  Future<void> play();
  Future<void> pause();
  Future<void> next();
  Future<void> previous();
  Future<void> seek(double position);
  void dispose() {}
}

/// A fake source that "plays" a track on a timer. Stands in for Spotify / Apple Music
/// while their SDKs are not integrated, so every connected-state screen can be tried.
class SimulatedSource implements NowPlayingSource {
  @override
  final SourceID id;
  @override
  final Set<SourceCapability> capabilities = SourceCapability.values.toSet();

  TrackKey _track;
  double _anchorPosition = 0;
  DateTime _anchorDate = DateTime.now();
  bool _isPlaying = false;
  final _controller = StreamController<PlaybackSnapshot>.broadcast();

  SimulatedSource(this._track, {this.id = SourceID.simulator});

  @override
  Stream<PlaybackSnapshot> get snapshots async* {
    yield _current();
    yield* _controller.stream;
  }

  void load(TrackKey track, {bool autoplay = true}) {
    _track = track;
    _anchorPosition = 0;
    _anchorDate = DateTime.now();
    _isPlaying = autoplay;
    _broadcast();
  }

  @override
  Future<void> play() async {
    _anchorDate = DateTime.now();
    _isPlaying = true;
    _broadcast();
  }

  @override
  Future<void> pause() async {
    _anchorPosition = _position();
    _anchorDate = DateTime.now();
    _isPlaying = false;
    _broadcast();
  }

  @override
  Future<void> next() => seek(0);
  @override
  Future<void> previous() => seek(0);

  @override
  Future<void> seek(double position) async {
    _anchorPosition = max(0, position);
    _anchorDate = DateTime.now();
    _broadcast();
  }

  double _position() {
    final p = _isPlaying ? _anchorPosition + DateTime.now().difference(_anchorDate).inMicroseconds / 1e6 : _anchorPosition;
    final d = _track.duration;
    return d != null ? min(p, d) : p;
  }

  PlaybackSnapshot _current() => PlaybackSnapshot(track: _track, position: _position(), isPlaying: _isPlaying);

  void _broadcast() => _controller.add(_current());

  @override
  void dispose() => _controller.close();
}

/// Turns sparse position reports into a smooth playhead and decides which line is current (LOS-1).
/// position(now) = anchor.position + (now − anchor.reportedAt) × rate, re-anchored on every report.
class SyncEngine {
  PlaybackSnapshot? anchor;

  /// Per-song offset in seconds (RQ-10). Positive = lyrics appear later.
  double offset;

  SyncEngine({this.offset = 0});

  void update(PlaybackSnapshot snapshot) => anchor = snapshot;

  double? position([DateTime? now]) {
    final a = anchor;
    if (a == null) return null;
    if (!a.isPlaying) return a.position;
    final elapsed = max(0, (now ?? DateTime.now()).difference(a.reportedAt).inMicroseconds / 1e6);
    var p = a.position + elapsed * a.rate;
    final d = a.track.duration;
    if (d != null) p = min(p, d);
    return p;
  }

  /// Index of the line whose start ≤ (position − offset), or null before the first line or for plain lyrics.
  int? currentLineIndex(List<LyricLine> lines, [DateTime? now]) {
    final p = position(now);
    if (p == null) return null;
    return lineIndex(p - offset, lines);
  }

  /// Binary search over line starts. Lines must be sorted by start.
  static int? lineIndex(double position, List<LyricLine> lines) {
    final first = lines.isEmpty ? null : lines.first.start;
    if (first == null || position < first) return null;
    var lo = 0;
    var hi = lines.length - 1;
    while (lo < hi) {
      final mid = (lo + hi + 1) ~/ 2;
      final s = lines[mid].start;
      if (s != null && s <= position) {
        lo = mid;
      } else {
        hi = mid - 1;
      }
    }
    return lo;
  }

  /// Where to seek to land on a line, taking the per-song offset into account (RQ-4).
  double? seekTarget(LyricLine line) => line.start == null ? null : max(0, line.start! + offset);

  /// Offset step used by the player's timing control (RQ-10).
  static const offsetStep = 0.5;
}
