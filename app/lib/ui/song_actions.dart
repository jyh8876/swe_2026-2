import 'package:flutter/material.dart';

import '../app/account.dart';
import '../app/app_model.dart';
import '../app/i18n.dart';
import '../app/theme.dart';
import '../core/models.dart';
import '../core/quiz.dart';
import 'components.dart';
import 'covers.dart';
import 'quiz.dart';

// Song settings shared by the library's long-press menu and the player's menu (Notion 11/19):
// edit song, change cover, retranslate, report the AI translation, sync, quiz this song.

/// Opens the quiz at the next level not yet passed (the last level once all are passed).
void openSongQuiz(BuildContext context, Song song) {
  final level = context.readModel.quiz.level(song.id);
  openQuiz(context, song.id, level >= QuizBuilder.levels ? QuizBuilder.levels : level + 1);
}

/// Picks a new album cover for [song].
Future<void> showCoverPicker(BuildContext context, Song song) {
  final t = context.theme;
  return showModalBottomSheet<void>(
    context: context,
    useRootNavigator: true,
    backgroundColor: t.background,
    showDragHandle: true,
    builder: (_) => SafeArea(child: Padding(padding: const EdgeInsets.fromLTRB(20, 0, 20, 20), child: CoverPicker(songID: song.id))),
  );
}

/// Title and artist of a song. Lyrics stay as they are, so translations and saved phrases keep
/// their lines.
Future<void> showEditSong(BuildContext context, Song song) {
  final t = context.theme;
  return showModalBottomSheet<void>(
    context: context,
    useRootNavigator: true,
    isScrollControlled: true,
    backgroundColor: t.surfaceRaised,
    shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
    builder: (_) => _EditSongSheet(song: song),
  );
}

class _EditSongSheet extends StatefulWidget {
  final Song song;
  const _EditSongSheet({required this.song});
  @override
  State<_EditSongSheet> createState() => _EditSongSheetState();
}

class _EditSongSheetState extends State<_EditSongSheet> {
  late final _title = TextEditingController(text: widget.song.title);
  late final _artist = TextEditingController(text: widget.song.artist);

  @override
  void dispose() {
    _title.dispose();
    _artist.dispose();
    super.dispose();
  }

  bool get _valid => _title.text.trim().isNotEmpty && _artist.text.trim().isNotEmpty;

  @override
  Widget build(BuildContext context) {
    final t = context.theme;
    return Padding(
      padding: EdgeInsets.fromLTRB(20, 16, 20, 20 + MediaQuery.of(context).viewInsets.bottom),
      child: SafeArea(
        top: false,
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(tr('노래 수정'), style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700, color: t.textPrimary)),
          const SizedBox(height: 16),
          Text(tr('제목'), style: TextStyle(fontSize: 12, color: t.textTertiary)),
          const SizedBox(height: 6),
          OutlinedField(controller: _title, hint: tr('제목'), onChanged: (_) => setState(() {})),
          const SizedBox(height: 12),
          Text(tr('아티스트'), style: TextStyle(fontSize: 12, color: t.textTertiary)),
          const SizedBox(height: 6),
          OutlinedField(controller: _artist, hint: tr('아티스트'), onChanged: (_) => setState(() {})),
          const SizedBox(height: 20),
          PrimaryButton(tr('저장'), onPressed: _valid ? _save : null),
        ]),
      ),
    );
  }

  void _save() {
    context.readModel.editSong(widget.song.id, title: _title.text, artist: _artist.text);
    Navigator.pop(context);
  }
}

/// AI translation report (required, 원준). [lineIndex] reports one line; null reports the song.
/// Only the title, artist, line number, reason and engine are sent, never the lyrics.
Future<void> showReportTranslation(BuildContext context, String songID, {int? lineIndex}) {
  final t = context.theme;
  return showModalBottomSheet<void>(
    context: context,
    useRootNavigator: true,
    isScrollControlled: true,
    backgroundColor: t.surfaceRaised,
    shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
    builder: (_) => _ReportSheet(songID: songID, lineIndex: lineIndex),
  );
}

String reportReasonLabel(ReportReason r) => switch (r) {
      ReportReason.wrong => tr('뜻이 틀려요'),
      ReportReason.awkward => tr('어색해요'),
      ReportReason.offensive => tr('비속어·불쾌한 표현이 있어요'),
      ReportReason.reading => tr('독음이 틀려요'),
      ReportReason.other => tr('기타'),
    };

class _ReportSheet extends StatefulWidget {
  final String songID;
  final int? lineIndex;
  const _ReportSheet({required this.songID, this.lineIndex});
  @override
  State<_ReportSheet> createState() => _ReportSheetState();
}

class _ReportSheetState extends State<_ReportSheet> {
  ReportReason? _reason;
  final _comment = TextEditingController();
  bool _sending = false;

  @override
  void dispose() {
    _comment.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = context.theme;
    final model = context.model;
    final song = model.collection.song(widget.songID);
    return Padding(
      padding: EdgeInsets.fromLTRB(20, 16, 20, 20 + MediaQuery.of(context).viewInsets.bottom),
      child: SafeArea(
        top: false,
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(tr('AI 번역 신고하기'), style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700, color: t.textPrimary)),
            const SizedBox(height: 4),
            Text(
              widget.lineIndex == null
                  ? tr('{0} · 노래 전체', [song?.title ?? ''])
                  : tr('{0} · {1}번째 줄', [song?.title ?? '', '${widget.lineIndex! + 1}']),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 13, color: t.textSecondary),
            ),
            const SizedBox(height: 12),
            RadioGroup<ReportReason>(
              groupValue: _reason,
              onChanged: (v) => setState(() => _reason = v),
              child: Column(children: [
                for (final r in ReportReason.values)
                  RadioListTile<ReportReason>(
                    value: r,
                    contentPadding: EdgeInsets.zero,
                    dense: true,
                    activeColor: t.brand,
                    title: Text(reportReasonLabel(r), style: TextStyle(fontSize: 15, color: t.textPrimary)),
                  ),
              ]),
            ),
            const SizedBox(height: 8),
            OutlinedField(controller: _comment, hint: tr('자세한 내용 (선택)'), minLines: 2, maxLines: 4),
            const SizedBox(height: 8),
            Text(tr('노래 제목·아티스트, 줄 번호, 사용한 번역 엔진만 보내요. 가사와 번역문은 보내지 않아요.'),
                style: TextStyle(fontSize: 12, color: t.textTertiary)),
            const SizedBox(height: 16),
            PrimaryButton(_sending ? tr('보내는 중…') : tr('신고 보내기'), onPressed: _reason == null || _sending ? null : _send),
          ]),
        ),
      ),
    );
  }

  Future<void> _send() async {
    setState(() => _sending = true);
    final model = context.readModel;
    try {
      await model.reportTranslation(widget.songID, reason: _reason!, lineIndex: widget.lineIndex, comment: _comment.text);
      if (!mounted) return;
      Navigator.pop(context);
      showMessage(context, tr('신고를 보냈어요. 고마워요!'));
    } on AccountApiException catch (e) {
      if (!mounted) return;
      setState(() => _sending = false);
      showMessage(
        context,
        e.message == 'not configured'
            ? tr('이 버전은 신고 서버에 연결되어 있지 않아요.')
            : e.status == 401
                ? tr('신고하려면 먼저 마이페이지에서 로그인해 주세요.')
                : e.message == 'network'
                    ? tr('인터넷 연결을 확인해 주세요.')
                    : tr('신고를 보내지 못했어요. 잠시 후 다시 시도해 주세요.'),
      );
    }
  }
}
