import 'dart:math';

// Core data model — SSRD Appendix A.III "Core data model".
// Field names match the iOS LyricsCore models so export files (RQ-18) move between platforms.

/// Uppercase RFC 4122 v4 UUID, the same form Swift's `UUID` encodes to.
String newUUID() {
  final r = Random.secure();
  final b = List<int>.generate(16, (_) => r.nextInt(256));
  b[6] = (b[6] & 0x0f) | 0x40;
  b[8] = (b[8] & 0x3f) | 0x80;
  final h = b.map((x) => x.toRadixString(16).padLeft(2, '0')).join().toUpperCase();
  return '${h.substring(0, 8)}-${h.substring(8, 12)}-${h.substring(12, 16)}-${h.substring(16, 20)}-${h.substring(20)}';
}

/// Adds `value` under `key` only when it is non-null (Swift's encodeIfPresent).
void _put(Map<String, dynamic> m, String key, Object? value) {
  if (value != null) m[key] = value;
}

double? _toDouble(Object? v) => v == null ? null : (v as num).toDouble();

enum LyricsType { synced, plain }

enum SongStatus { translating, done, failed }

T _enumByName<T extends Enum>(List<T> values, Object? name, T fallback) =>
    values.firstWhere((v) => v.name == name, orElse: () => fallback);

/// Encodes dates. The local store and the portable export use different codecs.
typedef DateEncoder = Object Function(DateTime);
typedef DateDecoder = DateTime Function(Object);

class DateCodec {
  final DateEncoder encode;
  final DateDecoder decode;
  const DateCodec(this.encode, this.decode);

  /// Local store: lossless epoch milliseconds.
  static final local = DateCodec(
    (d) => d.microsecondsSinceEpoch / 1000.0,
    (v) => DateTime.fromMicrosecondsSinceEpoch(((v as num) * 1000).round()),
  );

  /// Portable export: ISO-8601 with milliseconds, readable by iOS and web.
  static final portable = DateCodec(
    (d) => d.toUtc().toIso8601String().replaceFirstMapped(
        RegExp(r'\.(\d{3})\d*Z$'), (m) => '.${m[1]}Z'),
    (v) => DateTime.parse(v as String),
  );
}

class TrackKey {
  final String title;
  final String artist;
  final String? album;
  final double? duration;

  const TrackKey({required this.title, required this.artist, this.album, this.duration});

  @override
  bool operator ==(Object other) =>
      other is TrackKey && other.title == title && other.artist == artist && other.album == album && other.duration == duration;

  @override
  int get hashCode => Object.hash(title, artist, album, duration);
}

class Song {
  final String id;
  String title;
  String artist;
  String? album;

  /// Track duration in seconds.
  double? duration;

  /// File name inside the app's covers directory. Covers are never uploaded (RQ-6).
  String? coverPath;
  LyricsType lyricsType;

  /// Where the lyrics came from, for example "lrclib" or "manual".
  String sourceProvider;

  /// Per-song timing offset in seconds (RQ-10). Positive = lyrics shown later.
  double offset;
  SongStatus status;
  DateTime? conqueredAt;
  DateTime addedAt;
  String? curatedShelfID;

  Song({
    String? id,
    required this.title,
    required this.artist,
    this.album,
    this.duration,
    this.coverPath,
    required this.lyricsType,
    required this.sourceProvider,
    this.offset = 0,
    this.status = SongStatus.translating,
    this.conqueredAt,
    DateTime? addedAt,
    this.curatedShelfID,
  })  : id = id ?? newUUID(),
        addedAt = addedAt ?? DateTime.now();

  bool get isConquered => conqueredAt != null;
  TrackKey get trackKey => TrackKey(title: title, artist: artist, album: album, duration: duration);

  Map<String, dynamic> toJson(DateCodec c) {
    final m = <String, dynamic>{
      'id': id,
      'title': title,
      'artist': artist,
      'lyricsType': lyricsType.name,
      'sourceProvider': sourceProvider,
      'offset': offset,
      'status': status.name,
      'addedAt': c.encode(addedAt),
    };
    _put(m, 'album', album);
    _put(m, 'duration', duration);
    _put(m, 'coverPath', coverPath);
    _put(m, 'conqueredAt', conqueredAt == null ? null : c.encode(conqueredAt!));
    _put(m, 'curatedShelfID', curatedShelfID);
    return m;
  }

  factory Song.fromJson(Map<String, dynamic> j, DateCodec c) => Song(
        id: j['id'] as String,
        title: j['title'] as String,
        artist: j['artist'] as String,
        album: j['album'] as String?,
        duration: _toDouble(j['duration']),
        coverPath: j['coverPath'] as String?,
        lyricsType: _enumByName(LyricsType.values, j['lyricsType'], LyricsType.plain),
        sourceProvider: j['sourceProvider'] as String? ?? 'manual',
        offset: _toDouble(j['offset']) ?? 0,
        status: _enumByName(SongStatus.values, j['status'], SongStatus.failed),
        conqueredAt: j['conqueredAt'] == null ? null : c.decode(j['conqueredAt']),
        addedAt: c.decode(j['addedAt']),
        curatedShelfID: j['curatedShelfID'] as String?,
      );
}

class LyricLine {
  final String songID;
  final int index;

  /// Start time in seconds; null for plain lyrics.
  final double? start;
  final double? end;
  final String text;

  /// BCP-47 code detected on the device (RQ-15), null until detected.
  String? detectedLanguage;

  LyricLine({required this.songID, required this.index, this.start, this.end, required this.text, this.detectedLanguage});

  String get id => '$songID#$index';

  Map<String, dynamic> toJson() {
    final m = <String, dynamic>{'songID': songID, 'index': index, 'text': text};
    _put(m, 'start', start);
    _put(m, 'end', end);
    _put(m, 'detectedLanguage', detectedLanguage);
    return m;
  }

  factory LyricLine.fromJson(Map<String, dynamic> j) => LyricLine(
        songID: j['songID'] as String,
        index: j['index'] as int,
        start: _toDouble(j['start']),
        end: _toDouble(j['end']),
        text: j['text'] as String,
        detectedLanguage: j['detectedLanguage'] as String?,
      );
}

enum Outcome { translated, copied, failed }

class Translation {
  final String songID;
  final int index;
  final String targetLanguage;
  final String engineID;
  final String promptVersion;

  /// Translated text. Null when the line was copied (already in the target language) or failed.
  final String? text;
  final Outcome outcome;
  final DateTime createdAt;

  Translation({
    required this.songID,
    required this.index,
    required this.targetLanguage,
    required this.engineID,
    required this.promptVersion,
    this.text,
    required this.outcome,
    DateTime? createdAt,
  }) : createdAt = createdAt ?? DateTime.now();

  Map<String, dynamic> toJson(DateCodec c) {
    final m = <String, dynamic>{
      'songID': songID,
      'index': index,
      'targetLanguage': targetLanguage,
      'engineID': engineID,
      'promptVersion': promptVersion,
      'outcome': outcome.name,
      'createdAt': c.encode(createdAt),
    };
    _put(m, 'text', text);
    return m;
  }

  factory Translation.fromJson(Map<String, dynamic> j, DateCodec c) => Translation(
        songID: j['songID'] as String,
        index: j['index'] as int,
        targetLanguage: j['targetLanguage'] as String,
        engineID: j['engineID'] as String,
        promptVersion: j['promptVersion'] as String,
        text: j['text'] as String?,
        outcome: _enumByName(Outcome.values, j['outcome'], Outcome.failed),
        createdAt: c.decode(j['createdAt']),
      );
}

class Expression {
  final String phrase;
  final String meaning;
  const Expression({required this.phrase, required this.meaning});

  Map<String, dynamic> toJson() => {'phrase': phrase, 'meaning': meaning};
  factory Expression.fromJson(Map<String, dynamic> j) =>
      Expression(phrase: '${j['phrase'] ?? ''}', meaning: '${j['meaning'] ?? ''}');
}

/// Structured line explanation (RQ-11). At most 3 expressions (Win-AGRE-7).
class Explanation {
  static const maxExpressions = 3;

  final List<Expression> expressions;
  final String structure;
  final String usage;
  final String example;

  Explanation({required List<Expression> expressions, required this.structure, required this.usage, required this.example})
      : expressions = expressions.take(maxExpressions).toList();

  Map<String, dynamic> toJson() => {
        'expressions': expressions.map((e) => e.toJson()).toList(),
        'structure': structure,
        'usage': usage,
        'example': example,
      };

  factory Explanation.fromJson(Map<String, dynamic> j) => Explanation(
        expressions: ((j['expressions'] as List?) ?? const [])
            .map((e) => Expression.fromJson(Map<String, dynamic>.from(e as Map)))
            .toList(),
        structure: '${j['structure'] ?? ''}',
        usage: '${j['usage'] ?? ''}',
        example: '${j['example'] ?? ''}',
      );
}

class ExplanationRecord {
  final String songID;
  final int index;
  final String targetLanguage;
  final String engineID;
  final String promptVersion;
  final Explanation explanation;
  final DateTime createdAt;

  ExplanationRecord({
    required this.songID,
    required this.index,
    required this.targetLanguage,
    required this.engineID,
    required this.promptVersion,
    required this.explanation,
    DateTime? createdAt,
  }) : createdAt = createdAt ?? DateTime.now();

  Map<String, dynamic> toJson(DateCodec c) => {
        'songID': songID,
        'index': index,
        'targetLanguage': targetLanguage,
        'engineID': engineID,
        'promptVersion': promptVersion,
        'explanation': explanation.toJson(),
        'createdAt': c.encode(createdAt),
      };

  factory ExplanationRecord.fromJson(Map<String, dynamic> j, DateCodec c) => ExplanationRecord(
        songID: j['songID'] as String,
        index: j['index'] as int,
        targetLanguage: j['targetLanguage'] as String,
        engineID: j['engineID'] as String,
        promptVersion: j['promptVersion'] as String,
        explanation: Explanation.fromJson(Map<String, dynamic>.from(j['explanation'] as Map)),
        createdAt: c.decode(j['createdAt']),
      );
}

class Phrase {
  final String id;
  final String songID;
  final int index;
  final DateTime savedAt;

  Phrase({String? id, required this.songID, required this.index, DateTime? savedAt})
      : id = id ?? newUUID(),
        savedAt = savedAt ?? DateTime.now();

  Map<String, dynamic> toJson(DateCodec c) =>
      {'id': id, 'songID': songID, 'index': index, 'savedAt': c.encode(savedAt)};

  factory Phrase.fromJson(Map<String, dynamic> j, DateCodec c) => Phrase(
        id: j['id'] as String,
        songID: j['songID'] as String,
        index: j['index'] as int,
        savedAt: c.decode(j['savedAt']),
      );
}

/// One study session with the lyrics open; drives the mastery suggestion (RQ-13).
class ListenSession {
  final String songID;
  final DateTime startedAt;
  final Set<int> linesReached;
  final Set<int> explanationsOpened;

  ListenSession({required this.songID, DateTime? startedAt, Set<int>? linesReached, Set<int>? explanationsOpened})
      : startedAt = startedAt ?? DateTime.now(),
        linesReached = linesReached ?? <int>{},
        explanationsOpened = explanationsOpened ?? <int>{};

  Map<String, dynamic> toJson(DateCodec c) => {
        'songID': songID,
        'startedAt': c.encode(startedAt),
        'linesReached': (linesReached.toList()..sort()),
        'explanationsOpened': (explanationsOpened.toList()..sort()),
      };

  factory ListenSession.fromJson(Map<String, dynamic> j, DateCodec c) => ListenSession(
        songID: j['songID'] as String,
        startedAt: c.decode(j['startedAt']),
        linesReached: ((j['linesReached'] as List?) ?? const []).map((e) => e as int).toSet(),
        explanationsOpened: ((j['explanationsOpened'] as List?) ?? const []).map((e) => e as int).toSet(),
      );
}

/// A target or source language. Adding a language is a configuration entry (LOS-14).
class Language {
  final String code;
  final String englishName;
  final String nativeName;

  const Language(this.code, this.englishName, this.nativeName);

  static const korean = Language('ko', 'Korean', '한국어');
  static const english = Language('en', 'English', 'English');
  static const japanese = Language('ja', 'Japanese', '日本語');
  static const spanish = Language('es', 'Spanish', 'Español');

  static const supported = [korean, english, japanese, spanish];

  static Language named(String code) =>
      supported.firstWhere((l) => l.code == code, orElse: () => Language(code, code, code));
}
