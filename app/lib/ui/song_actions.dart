import 'package:flutter/material.dart';

import '../app/account.dart';
import '../app/app_model.dart';
import '../app/i18n.dart';
import '../app/platform_services.dart';
import '../app/theme.dart';
import '../core/lyrics.dart';
import '../core/models.dart';
import '../core/quiz.dart';
import 'components.dart';
import 'cover_select.dart';
import 'quiz.dart';

// Song settings shared by the library's long-press menu and the player's menu (Notion 11/19):
// edit song, change cover, retranslate, report the AI translation, sync, quiz this song.

/// Opens the quiz at the next level not yet passed (the last level once all are passed).
void openSongQuiz(BuildContext context, Song song) {
  final level = context.readModel.quiz.level(song.id);
  openQuiz(context, song.id, level >= QuizBuilder.levels ? QuizBuilder.levels : level + 1);
}

/// "앨범 커버 수정": the same "커버 이미지 추가" screen as when adding a song (album cover,
/// gallery, Pinterest, default covers), saved with "저장".
Future<void> showCoverPicker(BuildContext context, Song song) => Navigator.of(context, rootNavigator: true).push(MaterialPageRoute(
    builder: (_) => CoverSelectView(
        draft: AddSongDraft()
          ..title = song.title
          ..artist = song.artist
          ..album = song.album,
        songID: song.id)));

/// Song edit (Figma "가사 수정", 249:2145): title, artist, lyrics and translation language on one
/// screen, saved with "수정 완료". Unchanged lines keep their translations and saved state.
Future<void> showEditSong(BuildContext context, Song song) =>
    Navigator.of(context, rootNavigator: true).push(MaterialPageRoute(builder: (_) => EditSongView(song: song)));

class EditSongView extends StatefulWidget {
  final Song song;
  const EditSongView({super.key, required this.song});
  @override
  State<EditSongView> createState() => _EditSongViewState();
}

class _EditSongViewState extends State<EditSongView> {
  late final _title = TextEditingController(text: widget.song.title);
  late final _artist = TextEditingController(text: widget.song.artist);
  late final _lyrics = TextEditingController(text: LRCParser.format(context.readModel.collection.linesFor(widget.song.id)));
  late String? _target = widget.song.targetLanguage;

  @override
  void dispose() {
    _title.dispose();
    _artist.dispose();
    _lyrics.dispose();
    super.dispose();
  }

  bool get _valid => _title.text.trim().isNotEmpty && _artist.text.trim().isNotEmpty && _lyrics.text.trim().isNotEmpty;

  @override
  Widget build(BuildContext context) {
    final t = context.theme;
    final model = context.model;
    return Scaffold(
      appBar: AppBar(title: Text(tr('노래·가사 수정')), centerTitle: true),
      body: ListView(padding: const EdgeInsets.all(20), children: [
        SectionLabel(tr('제목')),
        const SizedBox(height: 8),
        OutlinedField(controller: _title, hint: tr('제목'), onChanged: (_) => setState(() {})),
        const SizedBox(height: 18),
        SectionLabel(tr('아티스트')),
        const SizedBox(height: 8),
        OutlinedField(controller: _artist, hint: tr('아티스트'), onChanged: (_) => setState(() {})),
        const SizedBox(height: 18),
        SectionLabel(tr('가사')),
        const SizedBox(height: 8),
        OutlinedField(
          controller: _lyrics,
          hint: tr('이곳에 가사를 붙여넣어 주세요.'),
          minLines: 10,
          maxLines: 14,
          style: TextStyle(color: t.textPrimary, fontSize: 13, fontFamily: 'monospace', height: 1.4),
          onChanged: (_) => setState(() {}),
        ),
        const SizedBox(height: 6),
        Text(tr('바꾼 줄만 다시 번역해요. 바꾼 줄에 담아 둔 문장은 빠져요.'), style: TextStyle(fontSize: 12, color: t.textTertiary)),
        const SizedBox(height: 18),
        SectionLabel(tr('번역 언어')),
        const SizedBox(height: 8),
        LanguageSelectField(value: _target, appTarget: model.target, onChanged: (v) => setState(() => _target = v)),
      ]),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 12),
          child: PrimaryButton(tr('수정 완료'), onPressed: _valid ? _save : null),
        ),
      ),
    );
  }

  Future<void> _save() async {
    FocusScope.of(context).unfocus();
    final model = context.readModel;
    final id = widget.song.id;
    final lyricsChanged = _lyrics.text.trim() != LRCParser.format(model.collection.linesFor(id)).trim();
    var all = false;
    if (lyricsChanged) {
      // Changed lines are translated again anyway; the whole song only when the user wants it.
      final choice = await showActionSheet<String>(
        context,
        title: tr('가사를 바꿨어요. 현재 엔진으로 다시 번역할까요?'),
        message: tr('엔진: {0}', [EngineFactory.label(model.settings.engine)]),
        actions: [
          SheetAction(tr('노래 전체 다시 번역'), 'all', icon: Icons.translate),
          SheetAction(tr('바꾼 줄만 번역'), 'changed', icon: Icons.edit_note),
          SheetAction(tr('취소'), 'cancel'),
        ],
      );
      if (!mounted || choice == null || choice == 'cancel') return;
      all = choice == 'all';
    }
    model.editSong(id, title: _title.text, artist: _artist.text, lyrics: _lyrics.text, targetLanguage: _target, setTarget: true);
    if (all) model.retranslate(id);
    if (mounted) Navigator.pop(context);
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
