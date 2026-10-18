import 'package:flutter/material.dart' hide Route;

import '../app/app_model.dart';
import '../app/theme.dart';
import 'components.dart';

/// FG-05 Saved (RQ-8). Signature motion #2: LP drops onto the shelf. ≤ 1.2 s, reduced-motion aware.
class SavedView extends StatefulWidget {
  final String songID;
  const SavedView({super.key, required this.songID});
  @override
  State<SavedView> createState() => _SavedViewState();
}

class _SavedViewState extends State<SavedView> with SingleTickerProviderStateMixin {
  late final _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 700));
  late final _drop = CurvedAnimation(parent: _c, curve: Curves.easeOutBack);

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.of(context).disableAnimations) {
      _c.value = 1;
    } else if (_c.status == AnimationStatus.dismissed) {
      Future.delayed(const Duration(milliseconds: 150), () {
        if (mounted) _c.forward();
      });
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final model = context.model;
    final t = context.theme;
    final song = model.collection.song(widget.songID);
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) model.setPath([]);
      },
      child: Scaffold(
        appBar: AppBar(automaticallyImplyLeading: false),
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Column(children: [
              const Spacer(),
              SizedBox(height: 160, child: _shelf(song?.coverPath)),
              const SizedBox(height: 20),
              Text('컬렉션에 추가됐어요!', style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: t.textPrimary)),
              const SizedBox(height: 8),
              Text('${song?.title ?? ''} · ${song?.artist ?? ''}', style: TextStyle(fontSize: 15, color: t.textSecondary)),
              const SizedBox(height: 8),
              Text('가사 ${model.collection.translatedCount(widget.songID, model.target.code)}줄 번역 완료',
                  style: TextStyle(fontSize: 12, color: t.textSecondary)),
              const SizedBox(height: 32),
              PrimaryButton('바로 공부하기', onPressed: () => model.setPath([PlayerRoute(widget.songID)])),
              const SizedBox(height: 12),
              SecondaryButton('라이브러리로', onPressed: () => model.setPath([])),
              const Spacer(flex: 2),
            ]),
          ),
        ),
      ),
    );
  }

  Widget _shelf(String? cover) {
    final t = context.theme;
    Widget spine() => Container(
        width: 10, height: 120, margin: const EdgeInsets.symmetric(horizontal: 3), decoration: BoxDecoration(color: t.stroke, borderRadius: BorderRadius.circular(2)));
    return Column(mainAxisAlignment: MainAxisAlignment.end, children: [
      Row(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.end, children: [
        spine(),
        spine(),
        spine(),
        AnimatedBuilder(
          animation: _drop,
          builder: (_, child) => Opacity(
            opacity: _c.value.clamp(0, 1),
            child: Transform.translate(offset: Offset(0, -220 * (1 - _drop.value)), child: child),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 3),
            child: SizedBox(width: 140, height: 140, child: CoverArt(path: cover, radius: 4)),
          ),
        ),
        spine(),
        spine(),
      ]),
      Container(height: 3, color: t.textPrimary),
    ]);
  }
}
