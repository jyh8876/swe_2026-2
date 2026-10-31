import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../app/app_model.dart';
import '../app/i18n.dart';
import '../app/platform_services.dart';
import '../app/theme.dart';
import 'components.dart';
import 'covers.dart';

/// "내 노래 자랑" card for social media (Notion idea g): the newest covers, counts and a saved line,
/// rendered to a PNG and handed to the share sheet.
Future<void> showShareCard(BuildContext context) {
  final t = context.theme;
  return showModalBottomSheet<void>(
    context: context,
    useRootNavigator: true,
    isScrollControlled: true,
    backgroundColor: t.background,
    showDragHandle: true,
    builder: (_) => const _ShareSheet(),
  );
}

class _ShareSheet extends StatefulWidget {
  const _ShareSheet();
  @override
  State<_ShareSheet> createState() => _ShareSheetState();
}

class _ShareSheetState extends State<_ShareSheet> {
  final _key = GlobalKey();
  bool _busy = false;

  @override
  Widget build(BuildContext context) {
    final t = context.theme;
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Text(tr('내 컬렉션 자랑하기'), style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700, color: t.textPrimary)),
          const SizedBox(height: 16),
          RepaintBoundary(key: _key, child: const CollectionPoster()),
          const SizedBox(height: 20),
          PrimaryButton(_busy ? tr('이미지 만드는 중…') : tr('이미지로 공유하기'), icon: Icons.ios_share_rounded, onPressed: _busy ? null : _share),
        ]),
      ),
    );
  }

  Future<void> _share() async {
    setState(() => _busy = true);
    try {
      final boundary = _key.currentContext!.findRenderObject() as RenderRepaintBoundary;
      final img = await boundary.toImage(pixelRatio: 3);
      final data = await img.toByteData(format: ui.ImageByteFormat.png);
      img.dispose();
      final dir = await getTemporaryDirectory();
      final f = File('${dir.path}/vynilo-collection.png');
      await f.writeAsBytes(data!.buffer.asUint8List());
      await SharePlus.instance.share(ShareParams(files: [XFile(f.path, mimeType: 'image/png')], text: tr('내 Vynilo 컬렉션')));
    } catch (_) {
      if (mounted) showMessage(context, tr('이미지를 만들지 못했어요.'));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }
}

/// The poster itself. Always dark so it looks the same whatever the app theme.
class CollectionPoster extends StatelessWidget {
  const CollectionPoster({super.key});

  @override
  Widget build(BuildContext context) {
    final model = context.model;
    final t = context.theme;
    final songs = model.collection.songsNewestFirst;
    final conquered = songs.where((s) => s.isConquered).length;
    final phrases = model.collection.phrases.length;
    final shown = songs.take(9).toList();
    final quote = songs.map((s) => model.featuredLine(s.id)).whereType<(String, String?)>().firstOrNull;
    const fg = Color(0xFFF3F4F5), sub = Color(0xFFB0B3BA);

    Widget stat(String n, String label) => Expanded(
          child: Column(children: [
            Text(n, style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w800, color: fg)),
            Text(label, style: const TextStyle(fontSize: 11, color: sub)),
          ]),
        );

    return Container(
      width: 320,
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [const Color(0xFF16171B), Color.alphaBlend(t.brand.withValues(alpha: 0.22), const Color(0xFF16171B))],
        ),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          const Text('Vynilo', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800, color: fg, letterSpacing: 0.5)),
          const Spacer(),
          Text(QuizProgress.dayKey(DateTime.now()).replaceAll('-', '.'), style: const TextStyle(fontSize: 11, color: sub)),
        ]),
        const SizedBox(height: 4),
        Text(tr('나의 가사 컬렉션'), style: TextStyle(fontSize: 12, color: sub)),
        const SizedBox(height: 16),
        GridView.count(
          crossAxisCount: 3,
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          mainAxisSpacing: 6,
          crossAxisSpacing: 6,
          children: [
            for (final s in shown)
              Container(
                decoration: BoxDecoration(border: s.isConquered ? Border.all(color: t.gold, width: 2) : null),
                child: s.coverPath != null ? CoverArt(path: s.coverPath, radius: 0) : GeneratedCover(seed: s.id, label: s.title, radius: 0),
              ),
          ],
        ),
        if (quote != null) ...[
          const SizedBox(height: 16),
          Text('“${quote.$1}”', maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 14, fontStyle: FontStyle.italic, color: fg)),
          if (quote.$2 != null) Text(quote.$2!, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12, color: t.brand)),
        ],
        const SizedBox(height: 16),
        Row(children: [stat('${songs.length}', tr('모은 노래')), stat('$conquered', tr('정복한 노래')), stat('$phrases', tr('저장한 문장'))]),
      ]),
    );
  }
}
