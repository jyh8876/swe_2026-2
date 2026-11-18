import 'package:flutter/material.dart' hide Route;
import 'package:flutter/services.dart';

import '../app/app_model.dart';
import '../app/i18n.dart';
import '../app/platform_services.dart';
import '../app/theme.dart';
import '../core/llm.dart';
import '../core/lyrics.dart';
import '../core/models.dart';
import 'components.dart';

/// FG-03 노래 추가 (Figma / GitHub cover-select-prototype): title, artist, lyrics with a
/// "싱크 가사" switch, the translation language, then "커버 이미지 선택하기" (RQ-6).
class AddSongView extends StatefulWidget {
  final AddSongDraft draft;
  const AddSongView({super.key, required this.draft});
  @override
  State<AddSongView> createState() => _AddSongViewState();
}

class _AddSongViewState extends State<AddSongView> {
  late final _title = TextEditingController(text: widget.draft.title);
  late final _artist = TextEditingController(text: widget.draft.artist);
  late final _lyrics = TextEditingController(text: widget.draft.lyrics);

  /// Keep the time tags of synced lyrics (on by default when the text has them).
  bool _keepSync = true;

  /// Translation language for this song; null = the app setting ("기본").
  late String? _target = widget.draft.targetLanguage;

  @override
  void dispose() {
    _title.dispose();
    _artist.dispose();
    _lyrics.dispose();
    super.dispose();
  }

  bool get _canContinue => _title.text.trim().isNotEmpty && _artist.text.trim().isNotEmpty && _lyrics.text.trim().isNotEmpty;

  @override
  Widget build(BuildContext context) {
    final t = context.theme;
    final model = context.model;
    final synced = _lyrics.text.isNotEmpty && LRCParser.parse(_lyrics.text).type == LyricsType.synced;
    final appTarget = model.target;
    return Scaffold(
      appBar: AppBar(title: Text(tr('노래 추가')), centerTitle: true),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          SectionLabel(tr('제목')),
          const SizedBox(height: 8),
          OutlinedField(controller: _title, hint: '제목을 입력해주세요.', onChanged: (_) => setState(() {})),
          const SizedBox(height: 18),
          SectionLabel(tr('아티스트')),
          const SizedBox(height: 8),
          OutlinedField(controller: _artist, hint: '아티스트명을 입력해주세요.', onChanged: (_) => setState(() {})),
          const SizedBox(height: 18),
          Row(
            children: [
              SectionLabel(tr('가사')),
              const Spacer(),
              Text(tr('싱크 가사'), style: TextStyle(fontSize: 12, color: synced ? t.textSecondary : t.textTertiary)),
              const SizedBox(width: 4),
              Transform.scale(
                scale: 0.8,
                child: Switch(value: synced && _keepSync, onChanged: synced ? (v) => setState(() => _keepSync = v) : null),
              ),
            ],
          ),
          // The app fetches no lyrics: find an LRC on the web, copy, come back and paste.
          Wrap(
            spacing: 4,
            children: [
              _lyricsAction(Icons.travel_explore, tr('인터넷에서 가사 찾기'), _title.text.trim().isEmpty ? null : _searchWeb),
              _lyricsAction(Icons.content_paste, tr('붙여넣기'), _paste),
            ],
          ),
          const SizedBox(height: 4),
          OutlinedField(
            controller: _lyrics,
            hint: tr('이곳에 가사를 붙여넣어 주세요.\n[00:12.34] 형식의 LRC 가사도 인식해요'),
            minLines: 10,
            maxLines: null,
            style: TextStyle(color: t.textPrimary, fontSize: 13, fontFamily: 'monospace', height: 1.4),
            onChanged: (_) => setState(() {}),
          ),
          if (synced && !_keepSync)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(tr('시간 정보를 빼고 일반 가사로 저장해요'), style: TextStyle(fontSize: 12, color: t.textTertiary)),
            ),
          const SizedBox(height: 18),
          SectionLabel(tr('번역 언어')),
          const SizedBox(height: 8),
          DropdownButtonFormField<String?>(
            initialValue: _target,
            isExpanded: true,
            dropdownColor: t.surfaceRaised,
            style: TextStyle(color: t.textPrimary, fontSize: 16),
            decoration: InputDecoration(
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
                borderSide: BorderSide(color: t.stroke),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
                borderSide: BorderSide(color: t.textSecondary),
              ),
              contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            ),
            items: [
              DropdownMenuItem<String?>(value: null, child: Text(tr('{0}(기본)', [appTarget.nativeName]))),
              for (final l in Language.supported.where((l) => l.code != appTarget.code)) DropdownMenuItem<String?>(value: l.code, child: Text(l.nativeName)),
            ],
            onChanged: (v) => setState(() => _target = v),
          ),
        ],
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 12),
          child: PrimaryButton(tr('커버 이미지 선택하기'), onPressed: _canContinue ? _toCover : null),
        ),
      ),
    );
  }

  void _toCover() {
    FocusScope.of(context).unfocus();
    final synced = LRCParser.parse(_lyrics.text).type == LyricsType.synced;
    widget.draft
      ..title = _title.text.trim()
      ..artist = _artist.text.trim()
      ..lyrics = synced && !_keepSync ? LRCParser.parse(_lyrics.text).lines.map((l) => l.text).join('\n') : _lyrics.text
      ..targetLanguage = _target;
    context.readModel.push(CoverSelectRoute(widget.draft));
  }

  Widget _lyricsAction(IconData icon, String label, VoidCallback? onPressed) {
    final t = context.theme;
    final color = onPressed == null ? t.textTertiary : t.textPrimary;
    return TextButton.icon(
      onPressed: onPressed,
      style: TextButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 8), visualDensity: VisualDensity.compact),
      icon: Icon(icon, size: 18, color: color),
      label: Text(
        label,
        style: TextStyle(fontSize: 13, color: color, fontWeight: FontWeight.w600),
      ),
    );
  }

  Future<void> _searchWeb() => openLyricsWebSearch(context, title: _title.text, artist: _artist.text);

  /// Replaces the lyrics with the clipboard, as copied from a lyrics page.
  Future<void> _paste() async {
    final text = (await Clipboard.getData(Clipboard.kTextPlain))?.text?.trim() ?? '';
    if (!mounted) return;
    if (text.isEmpty) {
      showMessage(context, tr('클립보드가 비어 있어요.'));
      return;
    }
    setState(() => _lyrics.text = text);
  }
}

/// Opens the browser on a web search for the song's LRC lyrics ("artist title .lrc").
Future<void> openLyricsWebSearch(BuildContext context, {required String title, String artist = ''}) async {
  try {
    await Links.open(LyricsWebSearch.url(title: title, artist: artist));
  } catch (_) {
    if (context.mounted) showMessage(context, tr('브라우저를 열지 못했어요.'));
  }
}

/// Saves the drafted song with its cover and opens the translating screen. Shared by the cover
/// screen; checks the engine, duplicates and the one-time cloud notice first.
Future<void> addToCollection(BuildContext context, AddSongDraft draft, {String? coverPath}) async {
  final model = context.readModel;
  // The chosen engine cannot translate yet (e.g. the on-device model is not downloaded).
  if (!model.currentEngine().isAvailable) {
    final choice = await showActionSheet<String>(
      context,
      title: tr('번역 엔진을 먼저 준비해 주세요'),
      message: tr('온디바이스 모델을 내려받거나, 마이페이지에서 다른 번역 엔진을 설정하면 번역이 시작돼요.'),
      actions: [
        SheetAction(tr('번역 엔진 설정'), 'settings', icon: Icons.tune),
        SheetAction(tr('지금은 저장만 하기'), 'save', icon: Icons.save_outlined),
        SheetAction(tr('취소'), 'cancel'),
      ],
    );
    if (!context.mounted || choice == null || choice == 'cancel') return;
    if (choice == 'settings') {
      model.openSettings();
      return;
    }
  }
  final key = TrackKey(title: draft.title, artist: draft.artist, duration: draft.duration);
  final existing = model.collection.existingSong(key);
  if (existing != null) {
    final choice = await showActionSheet<String>(
      context,
      title: tr('이미 컬렉션에 있는 노래예요'),
      actions: [SheetAction(tr('기존 LP 열기'), 'open'), SheetAction(tr('그래도 추가'), 'add'), SheetAction(tr('취소'), 'cancel')],
    );
    if (!context.mounted) return;
    if (choice == 'open') model.setPath([PlayerRoute(existing.id)]);
    if (choice != 'add') return;
  }
  final engine = model.settings.engine;
  if (engine.isCloud && !model.settings.cloudNoticeAccepted) {
    final ok = await confirmDialog(
      context,
      title: tr('가사가 선택한 AI 서비스로 전송돼요'),
      message: switch (engine) {
        EngineKind.gateway => tr('LLM 게이트웨이로 가사를 보내 번역하고, 사용량은 게이트웨이 계정에 청구돼요.'),
        _ => tr('{0} API로 가사를 보내 번역하고, 사용량은 내 API 계정에 청구돼요. 노래 한 곡에 약 \$0.01 미만이에요.', [engine.badgeLabel]),
      },
      confirm: tr('계속'),
    );
    if (!ok || !context.mounted) return;
    model.updateSettings((s) => s.cloudNoticeAccepted = true);
  }
  if (model.settings.engine.isCloud && !model.currentEngine().isAvailable) {
    model.showBanner(AppBanner(LLMError.missingAPIKey.userMessage, actionTitle: tr('설정')));
  }
  final id = model.addSong(draft, coverSourcePath: coverPath);
  // Replace the add flow with the translating screen (linear flow, SSRD 4.1.2).
  model.setPath([TranslatingRoute(id)]);
}
