import 'collection.dart';
import 'lyrics.dart';
import 'models.dart';

/// Song suggestions from the curated shelves (Notion/meeting notes: "추천하는 곡들이 쉽게 뜨게끔",
/// "노래 추가했다고 추천", "검색 전에 추천창 — 쉬운 곡, 인기있는 곡").
class Recommender {
  /// Shelf songs not yet in the collection. With [after], songs from the same shelf and by the same
  /// artist come first; otherwise the shelves are interleaved so every kind shows up early.
  static List<ShelfEntry> pick(List<CuratedShelf> shelves, CollectionSnapshot collection, {Song? after, int limit = 10}) {
    bool owned(ShelfEntry e) =>
        collection.songs.any((s) => TrackMatcher.matches(TrackKey(title: s.title, artist: s.artist), TrackKey(title: e.title, artist: e.artist)));

    final ordered = <ShelfEntry>[];
    if (after != null) {
      final artist = TrackNormalizer.normalize(TrackNormalizer.primaryArtist(after.artist));
      for (final s in shelves) {
        ordered.addAll(s.songs.where((e) => TrackNormalizer.normalize(e.artist) == artist));
      }
      for (final s in shelves.where((s) => s.id == after.curatedShelfID)) {
        ordered.addAll(s.songs);
      }
    }
    final longest = shelves.fold(0, (m, s) => s.songs.length > m ? s.songs.length : m);
    for (var i = 0; i < longest; i++) {
      for (final s in shelves) {
        if (i < s.songs.length) ordered.add(s.songs[i]);
      }
    }

    final seen = <String>{};
    final out = <ShelfEntry>[];
    for (final e in ordered) {
      if (out.length >= limit) break;
      if (!seen.add(e.id) || owned(e)) continue;
      if (after != null && TrackMatcher.matches(TrackKey(title: after.title, artist: after.artist), TrackKey(title: e.title, artist: e.artist))) {
        continue;
      }
      out.add(e);
    }
    return out;
  }
}

/// Search result clean-up (meeting notes: "같은 노래가사가 너무 많이 뜸", "가사가 너무 많이 뜸").
class SearchResults {
  static const maxResults = 20;

  /// Keeps one result per song (same normalised title and main artist), preferring synced lyrics,
  /// then plain lyrics. Results keep the order of each song's first appearance.
  static List<LyricsCandidate> dedupe(List<LyricsCandidate> found, {int limit = maxResults}) {
    int score(LyricsCandidate c) => c.hasSynced ? 2 : (c.hasPlain ? 1 : 0);
    final best = <String, LyricsCandidate>{};
    final order = <String>[];
    for (final c in found) {
      final key = '${TrackNormalizer.normalize(c.trackName)}|${TrackNormalizer.normalize(TrackNormalizer.primaryArtist(c.artistName))}';
      final prev = best[key];
      if (prev == null) {
        order.add(key);
        best[key] = c;
      } else if (score(c) > score(prev)) {
        best[key] = c;
      }
    }
    final list = [for (final k in order) best[k]!];
    // Instrumental results with no lyrics go last.
    return [
      ...list.where((c) => !c.instrumental || c.hasSynced || c.hasPlain),
      ...list.where((c) => c.instrumental && !c.hasSynced && !c.hasPlain),
    ].take(limit).toList();
  }
}
