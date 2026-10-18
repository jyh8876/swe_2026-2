import 'dart:async';
import 'dart:ui';

import 'package:flutter/material.dart' hide Route;

import '../app/app_model.dart';
import '../app/theme.dart';
import '../core/lyrics.dart';
import '../core/playback.dart';
import 'components.dart';

/// Figma "mini player": a frosted card above the tab bar while something is playing.
/// Tap → player (or search when the track is not in the collection); the round button toggles play.
class MiniPlayer extends StatefulWidget {
  const MiniPlayer({super.key});
  @override
  State<MiniPlayer> createState() => _MiniPlayerState();
}

class _MiniPlayerState extends State<MiniPlayer> {
  late final Timer _tick = Timer.periodic(const Duration(milliseconds: 250), (_) {
    if (mounted) setState(() {});
  });

  @override
  void dispose() {
    _tick.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final model = context.model;
    final t = context.theme;
    final snap = model.nowPlaying;
    if (snap == null) return const SizedBox.shrink();
    final song = model.nowPlayingSong;
    final engine = SyncEngine()..update(snap);
    final duration = snap.track.duration ?? song?.duration ?? 0;
    final p = duration > 0 ? ((engine.position() ?? 0) / duration).clamp(0.0, 1.0) : 0.0;

    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
        child: Container(
          height: 72,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.7),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: Colors.white.withValues(alpha: 0.6)),
            boxShadow: const [
              BoxShadow(color: Color(0x0F000000), blurRadius: 1),
              BoxShadow(color: Color(0x1A000000), blurRadius: 24, offset: Offset(0, 8)),
            ],
          ),
          child: Row(children: [
            Expanded(
              child: Semantics(
                button: true,
                label: '재생 화면 열기',
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () => model.push(song != null
                      ? PlayerRoute(song.id)
                      : SearchRoute('${TrackNormalizer.normalize(snap.track.title)} ${TrackNormalizer.primaryArtist(snap.track.artist)}')),
                  child: Row(children: [
                    SizedBox(
                      width: 46,
                      height: 46,
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(12),
                        child: song?.coverPath != null
                            ? CoverArt(path: song!.coverPath, radius: 0)
                            : Container(color: t.stroke, child: Icon(Icons.music_note_rounded, color: t.textTertiary)),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text(snap.track.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(fontSize: 14, height: 18 / 14, fontWeight: FontWeight.w500, letterSpacing: -0.28, color: t.textPrimary)),
                        const SizedBox(height: 2),
                        Text(song == null ? '${snap.track.artist} · 컬렉션에 없는 노래' : snap.track.artist,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(fontSize: 12, height: 16 / 12, letterSpacing: -0.18, color: t.textTertiary)),
                        const SizedBox(height: 6),
                        ClipRRect(
                          borderRadius: BorderRadius.circular(2),
                          child: LinearProgressIndicator(value: p, minHeight: 4, color: t.textSecondary, backgroundColor: t.stroke),
                        ),
                      ]),
                    ),
                  ]),
                ),
              ),
            ),
            const SizedBox(width: 16),
            Semantics(
              button: true,
              label: snap.isPlaying ? '일시정지' : '재생',
              excludeSemantics: true,
              child: InkWell(
                customBorder: const CircleBorder(),
                onTap: () => snap.isPlaying ? model.source?.pause() : model.source?.play(),
                child: Container(
                  width: 40,
                  height: 40,
                  decoration: const BoxDecoration(color: Color(0xFF2A3038), shape: BoxShape.circle),
                  child: Icon(snap.isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded, color: Colors.white, size: snap.isPlaying ? 20 : 24),
                ),
              ),
            ),
          ]),
        ),
      ),
    );
  }
}
