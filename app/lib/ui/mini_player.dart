import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart' hide Route;

import '../app/app_model.dart';
import '../app/i18n.dart';
import '../app/theme.dart';
import '../core/lyrics.dart';
import '../core/models.dart';
import '../core/playback.dart';
import 'components.dart';
import 'covers.dart';

/// Mini player docked on top of the tab bar: one full-width box in the theme colours with a
/// progress line in the accent colour along its top edge. Tap → player (or search when the track is
/// not in the collection); the round button toggles play.
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
    final position = song != null ? (model.positionOf(song) ?? 0) : ((SyncEngine()..update(snap)).position() ?? 0);
    final playing = song != null ? model.isPlayingSong(song) : snap.isPlaying;
    final duration = snap.track.duration ?? song?.duration ?? 0;
    final p = duration > 0 ? (position / duration).clamp(0.0, 1.0) : 0.0;

    return SizedBox(
      height: 64,
      child: Stack(children: [
        // Progress along the top edge.
        Positioned(
          left: 0,
          right: 0,
          top: 0,
          height: 2,
          child: Align(alignment: Alignment.centerLeft, child: FractionallySizedBox(widthFactor: p, child: ColoredBox(color: t.brand))),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 12, 8),
          child: Row(children: [
            Expanded(
              child: Semantics(
                button: true,
                label: tr('재생 화면 열기'),
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () {
                    model.selectTab(AppTab.library);
                    model.push(song != null
                        ? PlayerRoute(song.id)
                        : SearchRoute('${TrackNormalizer.normalize(snap.track.title)} ${TrackNormalizer.primaryArtist(snap.track.artist)}', snap.track));
                  },
                  child: Row(children: [
                    SizedBox(
                      width: 44,
                      height: 44,
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(6),
                        child: song?.coverPath != null
                            ? CoverArt(path: song!.coverPath, radius: 0)
                            : (song != null ? GeneratedCover(seed: song.id, radius: 0) : Container(color: t.surfaceRaised, child: Icon(Icons.music_note_rounded, color: t.textTertiary))),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text(song?.title ?? snap.track.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(fontSize: 14, height: 18 / 14, fontWeight: FontWeight.w600, letterSpacing: -0.28, color: t.textPrimary)),
                        const SizedBox(height: 2),
                        Text(song == null ? tr('{0} · 컬렉션에 없는 노래', [snap.track.artist]) : song.artist,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(fontSize: 12, height: 16 / 12, letterSpacing: -0.18, color: t.textTertiary)),
                      ]),
                    ),
                  ]),
                ),
              ),
            ),
            const SizedBox(width: 4),
            _skip(t, Icons.replay_5_rounded, tr('5초 뒤로'), () => _jump(model, song, position, -5)),
            Semantics(
              button: true,
              label: playing ? tr('일시정지') : tr('재생'),
              excludeSemantics: true,
              child: Material(
                color: t.brand,
                shape: const CircleBorder(),
                child: InkWell(
                  customBorder: const CircleBorder(),
                  onTap: () {
                    if (song != null) {
                      model.togglePlaySong(song);
                    } else {
                      playing ? model.source?.pause() : model.source?.play();
                    }
                  },
                  child: SizedBox(
                    width: 40,
                    height: 40,
                    child: Icon(playing ? Icons.pause_rounded : Icons.play_arrow_rounded, color: const Color(0xFF16171B), size: 24),
                  ),
                ),
              ),
            ),
            _skip(t, Icons.forward_5_rounded, tr('5초 앞으로'), () => _jump(model, song, position, 5)),
          ]),
        ),
      ]),
    );
  }

  void _jump(AppModel model, Song? song, double position, double delta) {
    if (song != null) {
      model.seekSong(song, position + delta);
    } else {
      model.source?.seek(max(0, position + delta));
    }
  }

  Widget _skip(AppTheme t, IconData icon, String label, VoidCallback onTap) => IconButton(
        tooltip: label,
        onPressed: onTap,
        iconSize: 24,
        visualDensity: VisualDensity.compact,
        color: t.textSecondary,
        icon: Icon(icon),
      );
}
