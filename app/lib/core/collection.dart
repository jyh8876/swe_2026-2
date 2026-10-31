import 'dart:convert';
import 'dart:io';

import 'llm.dart';
import 'lyrics.dart';
import 'models.dart';

class Stats {
  final int songs;
  final int conquered;
  final int phrases;
  const Stats(this.songs, this.conquered, this.phrases);
}

/// The whole local collection as one value. The app holds one of these, mutates it, and
/// persists through a `CollectionRepository` after every change (per-line commits, LOS-3).
class CollectionSnapshot {
  List<Song> songs;
  List<LyricLine> lines;
  List<Translation> translations;
  List<ExplanationRecord> explanations;
  List<Phrase> phrases;
  List<ListenSession> sessions;

  CollectionSnapshot({
    List<Song>? songs,
    List<LyricLine>? lines,
    List<Translation>? translations,
    List<ExplanationRecord>? explanations,
    List<Phrase>? phrases,
    List<ListenSession>? sessions,
  })  : songs = songs ?? [],
        lines = lines ?? [],
        translations = translations ?? [],
        explanations = explanations ?? [],
        phrases = phrases ?? [],
        sessions = sessions ?? [];

  // ── Indexes ──
  // Lookups used for every lyric row (translation, saved state, lines of a song) go through maps
  // built once per change instead of scanning every list. The mutation methods below mark the
  // collection changed; code that edits the lists directly calls [touch]. The list lengths are part
  // of the check as a safety net.

  int _version = 0;
  _Index? _index;
  Object? _indexKey;

  /// Increases whenever the collection changes; use it to cache derived values.
  int get version => _version;

  void touch() => _version++;

  _Index get _idx {
    final key = (_version, songs.length, lines.length, translations.length, phrases.length, explanations.length);
    if (_index == null || _indexKey != key) {
      _index = _Index(this);
      _indexKey = key;
    }
    return _index!;
  }

  // ── Queries ──

  /// Newest first (RQ-9).
  List<Song> get songsNewestFirst => [...songs]..sort((a, b) => b.addedAt.compareTo(a.addedAt));

  Song? song(String id) => _idx.songs[id];

  /// The song's lines in order. The list is shared and read-only.
  List<LyricLine> linesFor(String songID) => _idx.lines[songID] ?? const [];

  LyricLine? line(String songID, int index) => _idx.line['$songID\u0000$index'];

  /// Latest translation of a line for a target language, any engine.
  Translation? translation(String songID, int index, String target) => _idx.translation['$songID\u0000$index\u0000$target'];

  /// Display text for a line's translation: copied lines show a dash (RQ-15).
  String? translationText(String songID, int index, String target) {
    final t = translation(songID, index, target);
    if (t == null) return null;
    return switch (t.outcome) {
      Outcome.translated => t.text,
      Outcome.copied => '—',
      Outcome.failed => null,
    };
  }

  int translatedCount(String songID, String target) => _idx.translated['$songID\u0000$target']?.length ?? 0;

  ExplanationRecord? explanation(String songID, int index, String target) => _idx.explanation['$songID\u0000$index\u0000$target'];

  bool isSaved(String songID, int index) => _idx.saved.contains('$songID\u0000$index');

  Stats get stats => Stats(songs.length, songs.where((s) => s.isConquered).length, phrases.length);

  /// Duplicate check: same normalised title, artist and duration ±2 s (RQ-6).
  Song? existingSong(TrackKey key) {
    for (final s in songs) {
      if (TrackMatcher.matches(s.trackKey, key)) return s;
    }
    return null;
  }

  // ── Mutations ──

  void addSong(Song song, LyricsDocument document) {
    songs.add(song);
    lines.addAll(document.lyricLines(song.id));
    touch();
  }

  void updateSong(String id, void Function(Song) change) {
    final s = song(id);
    if (s != null) change(s);
  }

  /// Deleting a song asks whether to keep its saved phrases (default: keep, RQ-12).
  /// Kept phrases keep their line and translation data so they still render.
  void deleteSong(String id, {bool keepPhrases = true}) {
    final kept = phrases.where((p) => p.songID == id).map((p) => p.index).toSet();
    if (keepPhrases && kept.isNotEmpty) {
      lines.removeWhere((l) => l.songID == id && !kept.contains(l.index));
      translations.removeWhere((t) => t.songID == id && !kept.contains(t.index));
    } else {
      lines.removeWhere((l) => l.songID == id);
      translations.removeWhere((t) => t.songID == id);
      phrases.removeWhere((p) => p.songID == id);
    }
    songs.removeWhere((s) => s.id == id);
    explanations.removeWhere((e) => e.songID == id && !(keepPhrases && kept.contains(e.index)));
    sessions.removeWhere((s) => s.songID == id);
    touch();
  }

  /// Commits one line result immediately (ONRQ-9, LOS-3).
  void commit(LineResult result, {required String songID, required String target, required String engineID}) {
    translations.add(Translation(
      songID: songID,
      index: result.index,
      targetLanguage: target,
      engineID: engineID,
      promptVersion: Prompts.version,
      text: result is Translated ? result.text : null,
      outcome: switch (result) {
        Translated() => Outcome.translated,
        Copied() => Outcome.copied,
        Failed() => Outcome.failed,
      },
    ));
    touch();
  }

  /// Star toggle (RQ-10/RQ-12). Returns the new saved state.
  bool toggleSaved(String songID, int index) {
    final i = phrases.indexWhere((p) => p.songID == songID && p.index == index);
    touch();
    if (i >= 0) {
      phrases.removeAt(i);
      return false;
    }
    phrases.add(Phrase(songID: songID, index: index));
    return true;
  }

  void cacheExplanation(ExplanationRecord r) {
    explanations.add(r);
    touch();
  }

  // ── Coding ──

  Map<String, dynamic> toJson(DateCodec c) => {
        'explanations': explanations.map((e) => e.toJson(c)).toList(),
        'lines': lines.map((l) => l.toJson()).toList(),
        'phrases': phrases.map((p) => p.toJson(c)).toList(),
        'sessions': sessions.map((s) => s.toJson(c)).toList(),
        'songs': songs.map((s) => s.toJson(c)).toList(),
        'translations': translations.map((t) => t.toJson(c)).toList(),
      };

  factory CollectionSnapshot.fromJson(Map<String, dynamic> j, DateCodec c) {
    List<Map<String, dynamic>> list(String k) =>
        ((j[k] as List?) ?? const []).map((e) => Map<String, dynamic>.from(e as Map)).toList();
    return CollectionSnapshot(
      songs: list('songs').map((e) => Song.fromJson(e, c)).toList(),
      lines: list('lines').map(LyricLine.fromJson).toList(),
      translations: list('translations').map((e) => Translation.fromJson(e, c)).toList(),
      explanations: list('explanations').map((e) => ExplanationRecord.fromJson(e, c)).toList(),
      phrases: list('phrases').map((e) => Phrase.fromJson(e, c)).toList(),
      sessions: list('sessions').map((e) => ListenSession.fromJson(e, c)).toList(),
    );
  }
}

/// Lookup maps for one version of a [CollectionSnapshot]. Ties keep the record that comes later,
/// as the old linear scans did.
class _Index {
  final songs = <String, Song>{};
  final lines = <String, List<LyricLine>>{};
  final line = <String, LyricLine>{};
  final translation = <String, Translation>{};
  final translated = <String, Set<int>>{};
  final explanation = <String, ExplanationRecord>{};
  final saved = <String>{};

  _Index(CollectionSnapshot c) {
    for (final s in c.songs) {
      songs[s.id] = s;
    }
    final grouped = <String, List<LyricLine>>{};
    for (final l in c.lines) {
      (grouped[l.songID] ??= []).add(l);
      line['${l.songID}\u0000${l.index}'] = l;
    }
    grouped.forEach((k, v) => lines[k] = List.unmodifiable(v..sort((a, b) => a.index.compareTo(b.index))));
    for (final t in c.translations) {
      final k = '${t.songID}\u0000${t.index}\u0000${t.targetLanguage}';
      final best = translation[k];
      if (best == null || !t.createdAt.isBefore(best.createdAt)) translation[k] = t;
      if (t.outcome != Outcome.failed) (translated['${t.songID}\u0000${t.targetLanguage}'] ??= <int>{}).add(t.index);
    }
    for (final e in c.explanations) {
      final k = '${e.songID}\u0000${e.index}\u0000${e.targetLanguage}';
      final best = explanation[k];
      if (best == null || !e.createdAt.isBefore(best.createdAt)) explanation[k] = e;
    }
    for (final p in c.phrases) {
      saved.add('${p.songID}\u0000${p.index}');
    }
  }
}

// ─────────────────────────────── Persistence ───────────────────────────────

abstract class CollectionRepository {
  CollectionSnapshot load();
  void save(CollectionSnapshot snapshot);
  void deleteAll();
}

/// Atomically written JSON file (write temp, then rename). The SSRD target is SQLite in WAL
/// mode with versioned migrations; swap the repository without touching callers.
class JSONFileRepository implements CollectionRepository {
  final File file;
  JSONFileRepository(this.file);

  @override
  CollectionSnapshot load() {
    if (!file.existsSync()) return CollectionSnapshot();
    final j = jsonDecode(file.readAsStringSync()) as Map;
    return CollectionSnapshot.fromJson(Map<String, dynamic>.from(j), DateCodec.local);
  }

  @override
  void save(CollectionSnapshot snapshot) {
    file.parent.createSync(recursive: true);
    final tmp = File('${file.path}.tmp');
    tmp.writeAsStringSync(jsonEncode(snapshot.toJson(DateCodec.local)), flush: true);
    tmp.renameSync(file.path);
  }

  @override
  void deleteAll() {
    if (file.existsSync()) file.deleteSync();
  }
}

class InMemoryRepository implements CollectionRepository {
  CollectionSnapshot _stored;
  InMemoryRepository([CollectionSnapshot? s]) : _stored = s ?? CollectionSnapshot();

  @override
  CollectionSnapshot load() => _stored;
  @override
  void save(CollectionSnapshot snapshot) => _stored = snapshot;
  @override
  void deleteAll() => _stored = CollectionSnapshot();
}

// ─────────────────────────────── Export / import (RQ-18) ───────────────────────────────

class ImportReport {
  int songsAdded = 0;
  int songsUpdated = 0;
  int phrasesAdded = 0;
}

class ImportError implements Exception {
  final int? newerSchema;
  const ImportError.invalidFile() : newerSchema = null;
  const ImportError.newer(int v) : newerSchema = v;
}

class CollectionMerger {
  static const currentSchemaVersion = 1;

  /// Same portable schema as the iOS app, so a collection moves between phones.
  static String export(CollectionSnapshot snapshot, {DateTime? now}) {
    final doc = {
      'app': 'LyricsTranslator',
      'collection': snapshot.toJson(DateCodec.portable),
      'exportedAt': DateCodec.portable.encode(now ?? DateTime.now()),
      'schemaVersion': currentSchemaVersion,
    };
    return const JsonEncoder.withIndent('  ').convert(doc);
  }

  /// Validates the schema version first; an invalid or newer file changes nothing (ONRQ-16).
  static CollectionSnapshot decode(String data) {
    Map j;
    try {
      j = jsonDecode(data) as Map;
    } catch (_) {
      throw const ImportError.invalidFile();
    }
    final v = j['schemaVersion'];
    if (v is! int) throw const ImportError.invalidFile();
    if (v > currentSchemaVersion) throw ImportError.newer(v);
    try {
      return CollectionSnapshot.fromJson(Map<String, dynamic>.from(j['collection'] as Map), DateCodec.portable);
    } catch (_) {
      throw const ImportError.invalidFile();
    }
  }

  /// Merge rule (ONRQ-16): union of songs and phrases; for the same record the most recent
  /// change wins; nothing is deleted by a merge.
  static ImportReport merge(CollectionSnapshot incoming, CollectionSnapshot base) {
    final report = ImportReport();
    final past = DateTime.fromMillisecondsSinceEpoch(0);

    for (final song in incoming.songs) {
      final i = base.songs.indexWhere((s) => s.id == song.id);
      if (i >= 0) {
        final cur = base.songs[i];
        if ((song.conqueredAt ?? past).isAfter(cur.conqueredAt ?? past) ||
            (song.status == SongStatus.done && cur.status != SongStatus.done)) {
          base.songs[i] = song;
          report.songsUpdated += 1;
        }
      } else {
        base.songs.add(song);
        report.songsAdded += 1;
      }
    }

    final existingLines = base.lines.map((l) => l.id).toSet();
    base.lines.addAll(incoming.lines.where((l) => !existingLines.contains(l.id)));

    String tKey(Translation t) =>
        '${t.songID}#${t.index}#${t.targetLanguage}#${t.engineID}#${t.promptVersion}#${t.createdAt.millisecondsSinceEpoch}';
    final existingT = base.translations.map(tKey).toSet();
    base.translations.addAll(incoming.translations.where((t) => !existingT.contains(tKey(t))));

    String eKey(ExplanationRecord e) => '${e.songID}#${e.index}#${e.targetLanguage}#${e.engineID}#${e.promptVersion}';
    final existingE = base.explanations.map(eKey).toSet();
    base.explanations.addAll(incoming.explanations.where((e) => !existingE.contains(eKey(e))));

    for (final p in incoming.phrases) {
      if (!base.phrases.any((q) => q.songID == p.songID && q.index == p.index)) {
        base.phrases.add(p);
        report.phrasesAdded += 1;
      }
    }

    base.sessions.addAll(incoming.sessions.where((s) => !base.sessions.any(
        (b) => b.songID == s.songID && (b.startedAt.difference(s.startedAt).inMicroseconds).abs() < 1000)));
    return report;
  }
}

// ─────────────────────────────── Mastery (RQ-13) ───────────────────────────────

/// "Conquered" rules. Thresholds are configuration values, tuned after user testing (OI-3).
class MasteryRules {
  /// A play-through counts when this share of the song's lines was reached with lyrics open.
  final double playThroughShare = 0.9;

  /// Suggest "Conquered" after this many play-throughs…
  final int suggestAfterPlayThroughs = 3;

  /// …and when explanations were opened for at least this share of distinct lines.
  final double suggestExplanationShare = 0.3;

  const MasteryRules();

  bool isPlayThrough(ListenSession s, int lineCount) => lineCount > 0 && s.linesReached.length / lineCount >= playThroughShare;

  int playThroughs(String songID, CollectionSnapshot snap) {
    final count = snap.linesFor(songID).length;
    return snap.sessions.where((s) => s.songID == songID && isPlayThrough(s, count)).length;
  }

  /// The action is available after at least one full listen with the lyrics open.
  bool canMarkConquered(String songID, CollectionSnapshot snap) => playThroughs(songID, snap) >= 1;

  bool shouldSuggest(String songID, CollectionSnapshot snap) {
    final song = snap.song(songID);
    if (song == null || song.isConquered) return false;
    final lineCount = snap.linesFor(songID).length;
    if (lineCount == 0 || playThroughs(songID, snap) < suggestAfterPlayThroughs) return false;
    final opened = <int>{};
    for (final s in snap.sessions.where((s) => s.songID == songID)) {
      opened.addAll(s.explanationsOpened);
    }
    return opened.length / lineCount >= suggestExplanationShare;
  }
}

// ─────────────────────────────── Curation (RQ-17) ───────────────────────────────

class ShelfEntry {
  final String title;
  final String artist;
  final double? duration;
  const ShelfEntry(this.title, this.artist, this.duration);

  String get id => '$artist—$title';
  TrackKey get trackKey => TrackKey(title: title, artist: artist, duration: duration);
}

class CuratedShelf {
  final String id;
  final String title;
  final String subtitle;
  final List<ShelfEntry> songs;
  const CuratedShelf(this.id, this.title, this.subtitle, this.songs);

  /// Reads the versioned shelf file shared with the iOS app.
  static List<CuratedShelf> parseFile(String json) {
    try {
      final j = jsonDecode(json) as Map;
      return (j['shelves'] as List).map((s) {
        final songs = (s['songs'] as List)
            .map((e) => ShelfEntry(e['title'] as String, e['artist'] as String, (e['duration'] as num?)?.toDouble()))
            .toList();
        return CuratedShelf(s['id'] as String, s['title'] as String, s['subtitle'] as String, songs);
      }).toList();
    } catch (_) {
      return [];
    }
  }
}
