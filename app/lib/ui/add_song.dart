import 'package:flutter/material.dart' hide Route;
import 'package:flutter/services.dart';

import '../app/app_model.dart';
import '../app/i18n.dart';
import '../app/theme.dart';
import '../core/llm.dart';
import '../core/lyrics.dart';
import '../core/models.dart';
import 'components.dart';
import 'lyrics_browser.dart';

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

  static const _info = Color(0xFF217CF9); // bg/informative/solid
  static const _placeholder = Color(0xFFB0B3BA); // fg/placeholder

  TextStyle _s(double size, FontWeight w, Color c, double ls, double h) =>
      TextStyle(fontSize: size, fontWeight: w, color: c, letterSpacing: ls, height: h / size);

  Widget _input(TextEditingController c, String hint) {
    final t = context.theme;
    final border = OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide(color: t.stroke));
    return TextField(
      controller: c,
      onChanged: (_) => setState(() {}),
      autocorrect: false,
      style: _s(14, FontWeight.w400, t.textPrimary, -0.21, 18),
      decoration: InputDecoration(
        isDense: true,
        contentPadding: const EdgeInsets.all(12),
        hintText: tr(hint),
        hintStyle: _s(14, FontWeight.w400, _placeholder, -0.21, 18),
        enabledBorder: border,
        focusedBorder: border.copyWith(borderSide: BorderSide(color: t.textPrimary)),
      ),
    );
  }

  /// Figma "클립보드에서 붙여넣기": the bar at the bottom of the empty lyrics box.
  Future<void> _paste() async {
    final text = (await Clipboard.getData(Clipboard.kTextPlain))?.text?.trim() ?? '';
    if (!mounted || text.isEmpty) return;
    setState(() => _lyrics.text = PageLyrics.lrc(text) ?? text);
  }

  @override
  Widget build(BuildContext context) {
    final t = context.theme;
    final model = context.model;
    final base = Theme.of(context);
    final label = _s(12, FontWeight.w700, t.textTertiary, -0.24, 16);
    final hasLyrics = _lyrics.text.trim().isNotEmpty;
    final type = hasLyrics ? LRCParser.parse(_lyrics.text).type : null;
    final showChip = _title.text.trim().isNotEmpty || _artist.text.trim().isNotEmpty;
    // Figma 노래 추가 (SUIT, 12/14px text styles). The font applies to this screen only.
    return Theme(
      data: base.copyWith(
        textTheme: base.textTheme.apply(fontFamily: 'SUIT'),
        appBarTheme: base.appBarTheme.copyWith(
          titleTextStyle: (base.appBarTheme.titleTextStyle ?? base.textTheme.titleLarge)?.copyWith(fontFamily: 'SUIT'),
        ),
      ),
      child: Scaffold(
        appBar: AppBar(title: Text(tr('노래 추가')), centerTitle: true),
        body: ListView(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
          children: [
            Text(tr('제목'), style: label),
            const SizedBox(height: 6),
            _input(_title, '제목을 입력해주세요.'),
            const SizedBox(height: 16),
            Text(tr('아티스트'), style: label),
            const SizedBox(height: 6),
            _input(_artist, '아티스트명을 입력해주세요.'),
            const SizedBox(height: 16),
            // "가사" + the how-to link, the lyrics search chip once a title or artist is in,
            // then the 226px lyrics box with the clipboard bar inside.
            Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
              Text(tr('가사'), style: label),
              InkWell(
                onTap: () => showLyricsGuide(context),
                child: Text(tr('가사는 어떻게 불러오나요?'),
                    style: _s(12, FontWeight.w700, t.textPrimary, -0.24, 16).copyWith(decoration: TextDecoration.underline)),
              ),
            ]),
            const SizedBox(height: 6),
            if (showChip) ...[
              LyricsSearchChip(title: _title.text, artist: _artist.text, onTap: _searchWeb),
              const SizedBox(height: 6),
            ],
            Container(
              height: 226,
              decoration: BoxDecoration(border: Border.all(color: t.stroke), borderRadius: BorderRadius.circular(10)),
              child: Column(children: [
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: TextField(
                      controller: _lyrics,
                      expands: true,
                      maxLines: null,
                      minLines: null,
                      textAlignVertical: TextAlignVertical.top,
                      autocorrect: false,
                      onChanged: (_) => setState(() {}),
                      style: _s(14, FontWeight.w400, t.textPrimary, -0.21, 18),
                      decoration: InputDecoration(
                        isDense: true,
                        filled: false,
                        contentPadding: EdgeInsets.zero,
                        border: InputBorder.none,
                        enabledBorder: InputBorder.none,
                        focusedBorder: InputBorder.none,
                        hintText: tr('이곳에 가사를 붙여넣어 주세요.'),
                        hintStyle: _s(14, FontWeight.w400, _placeholder, -0.21, 18),
                      ),
                    ),
                  ),
                ),
                if (!hasLyrics)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(8, 0, 8, 4),
                    child: InkWell(
                      onTap: _paste,
                      child: Container(
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(border: Border(top: BorderSide(color: t.stroke))),
                        child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                          Icon(Icons.content_paste_rounded, size: 18, color: t.textPrimary),
                          const SizedBox(width: 4),
                          Text(tr('클립보드에서 붙여넣기'), style: _s(14, FontWeight.w700, t.textPrimary, -0.28, 18)),
                        ]),
                      ),
                    ),
                  ),
              ]),
            ),
            // Timestamps such as [00:13.04] are recognised by themselves; no switch to set.
            if (type != null) ...[
              const SizedBox(height: 6),
              Row(children: [
                const Icon(Icons.check, size: 16, color: _info),
                const SizedBox(width: 2),
                Text(type == LyricsType.synced ? tr('싱크 가사를 인식했어요') : tr('가사를 인식했어요'),
                    style: _s(12, FontWeight.w700, _info, -0.24, 16)),
              ]),
            ],
            const SizedBox(height: 16),
            Text(tr('번역 언어'), style: label),
            const SizedBox(height: 6),
            LanguageSelectField(
              value: _target,
              appTarget: model.target,
              onChanged: (v) => setState(() => _target = v),
            ),
          ],
        ),
        bottomNavigationBar: SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 10, 20, 12),
            child: SizedBox(
              width: double.infinity,
              height: 52,
              child: FilledButton(
                onPressed: _canContinue ? _toCover : null,
                style: FilledButton.styleFrom(
                  backgroundColor: t.accent,
                  foregroundColor: t.onAccent,
                  disabledBackgroundColor: t.surface,
                  disabledForegroundColor: t.disabled,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                ),
                child: Text(tr('커버 이미지 선택하기'), style: _s(16, FontWeight.w700, _canContinue ? t.onAccent : t.disabled, -0.24, 22)),
              ),
            ),
          ),
        ),
      ),
    );
  }

  void _toCover() {
    FocusScope.of(context).unfocus();
    widget.draft
      ..title = _title.text.trim()
      ..artist = _artist.text.trim()
      ..lyrics = _lyrics.text
      ..targetLanguage = _target;
    context.readModel.push(CoverSelectRoute(widget.draft));
  }

  /// In-app browser on the LRC search; the lyrics taken there fill the field.
  Future<void> _searchWeb() async {
    final lyrics = await openLyricsBrowser(context, title: _title.text, artist: _artist.text);
    if (!mounted || lyrics == null || lyrics.trim().isEmpty) return;
    setState(() => _lyrics.text = lyrics.trim());
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
