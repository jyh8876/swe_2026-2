import 'package:flutter_test/flutter_test.dart';
import 'package:lyrics_translator/core/lyrics.dart';

void main() {
  test('finds the LRC block in page text and drops the page around it', () {
    final page = '''Menu  Home  Login
Song lyrics for Day Off
[ti:Day Off]
[ar:Band]
[00:01.00]one
[00:02.50]two

[00:04.00]three
[00:05.00]four
[00:06.00]five
Share this page
Related: [00:01.00]x
''';
    expect(PageLyrics.lrc(page), '[ti:Day Off]\n[ar:Band]\n[00:01.00]one\n[00:02.50]two\n[00:04.00]three\n[00:05.00]four\n[00:06.00]five');
  });

  test('pages with only a few timestamps are not LRC', () {
    expect(PageLyrics.lrc('intro\n[00:01.00]a\n[00:02.00]b\noutro'), isNull);
    expect(PageLyrics.lrc('plain lyrics\nno times'), isNull);
  });

  test('takes the longest LRC when a page shows several', () {
    final short = List.generate(5, (i) => '[00:0$i.00]s$i').join('\n');
    final long = List.generate(8, (i) => '[01:0$i.00]l$i').join('\n');
    expect(PageLyrics.lrc('$short\ntext between\n$long'), long);
  });

  test('the browser bar opens addresses and searches everything else', () {
    expect(LyricsWebSearch.urlFor('megalobiz.com/lrc').toString(), 'https://megalobiz.com/lrc');
    expect(LyricsWebSearch.urlFor('https://a.b/c?d=1').toString(), 'https://a.b/c?d=1');
    expect(LyricsWebSearch.urlFor('IU 밤편지 .lrc').host, 'www.google.com');
  });
}
