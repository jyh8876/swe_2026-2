import 'dart:io';

import 'package:flutter/material.dart' hide Route;
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';

import '../app/app_model.dart';
import '../app/i18n.dart';
import '../app/spotify_library.dart';
import '../app/theme.dart';
import '../core/llm.dart';
import '../core/lyrics.dart';
import '../core/models.dart';
import 'components.dart';

/// FG-03 Add to collection (RQ-6). Coming from search, saving needs exactly one tap.
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
  String? _coverPath;

  @override
  void dispose() {
    _title.dispose();
    _artist.dispose();
    _lyrics.dispose();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    // Spotify album art becomes the cover; the user can still tap to replace it.
    final url = widget.draft.coverURL;
    if (url != null) {
      getTemporaryDirectory().then((d) => SpotifyLibrary.downloadToTemp(url, d)).then((f) {
        if (f != null && mounted && _coverPath == null) setState(() => _coverPath = f.path);
      }, onError: (_) {});
    }
  }

  bool get _canSave => _title.text.trim().isNotEmpty && _lyrics.text.trim().isNotEmpty;

  @override
  Widget build(BuildContext context) {
    final t = context.theme;
    final type = _lyrics.text.isEmpty ? null : LRCParser.parse(_lyrics.text).type;
    return Scaffold(
      appBar: AppBar(title: Text(tr('컬렉션에 추가'))),
      body: ListView(padding: const EdgeInsets.all(20), children: [
        Center(child: _coverPicker()),
        const SizedBox(height: 18),
        SectionLabel(tr('제목')),
        const SizedBox(height: 8),
        OutlinedField(controller: _title, hint: 'Song Title', onChanged: (_) => setState(() {})),
        const SizedBox(height: 18),
        SectionLabel(tr('아티스트')),
        const SizedBox(height: 8),
        OutlinedField(controller: _artist, hint: 'Artist'),
        const SizedBox(height: 18),
        Row(children: [
          SectionLabel(tr('가사')),
          const Spacer(),
          if (type != null)
            Text(type == LyricsType.synced ? tr('싱크 가사') : tr('일반 가사'), style: TextStyle(fontSize: 11, color: t.textTertiary)),
        ]),
        const SizedBox(height: 8),
        OutlinedField(
          controller: _lyrics,
          hint: tr('가사를 불러오지 못하면 여기에 직접 붙여넣기\n[00:12.34] 형식의 LRC 가사도 인식해요'),
          minLines: 12,
          maxLines: null,
          style: TextStyle(color: t.textPrimary, fontSize: 13, fontFamily: 'monospace', height: 1.4),
          onChanged: (_) => setState(() {}),
        ),
      ]),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 12),
          child: PrimaryButton(tr('저장'), onPressed: _canSave ? _attemptSave : null),
        ),
      ),
    );
  }

  Widget _coverPicker() {
    final t = context.theme;
    return Column(children: [
      Semantics(
        label: tr('앨범 커버 선택'),
        button: true,
        child: InkWell(
          onTap: _pickCover,
          borderRadius: BorderRadius.circular(12),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: Container(
              width: 150,
              height: 150,
              color: t.surfaceRaised,
              child: _coverPath != null
                  ? Image.file(File(_coverPath!), fit: BoxFit.cover)
                  : Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                      Icon(Icons.add, size: 28, color: t.textSecondary),
                      const SizedBox(height: 6),
                      Text(tr('앨범 커버'), style: TextStyle(fontSize: 12, color: t.textSecondary)),
                    ]),
            ),
          ),
        ),
      ),
      const SizedBox(height: 8),
      Text(tr('탭해서 나만의 커버로'), style: TextStyle(fontSize: 12, color: t.textSecondary)),
    ]);
  }

  /// Covers are downscaled to ≤1024×1024 and stay on the device (RQ-6).
  Future<void> _pickCover() async {
    try {
      final x = await ImagePicker().pickImage(source: ImageSource.gallery, maxWidth: 1024, maxHeight: 1024, imageQuality: 85);
      if (x != null && mounted) setState(() => _coverPath = x.path);
    } catch (_) {
      if (mounted) showMessage(context, tr('사진을 불러오지 못했어요.'));
    }
  }

  Future<void> _attemptSave() async {
    final model = context.readModel;
    // The chosen engine cannot translate yet (e.g. the on-device model is not downloaded).
    if (!model.currentEngine().isAvailable) {
      final choice = await showActionSheet<String>(context,
          title: tr('번역 엔진을 먼저 준비해 주세요'),
          message: tr('온디바이스 모델을 내려받거나, 마이페이지에서 다른 번역 엔진을 설정하면 번역이 시작돼요.'),
          actions: [
            SheetAction(tr('번역 엔진 설정'), 'settings', icon: Icons.tune),
            SheetAction(tr('지금은 저장만 하기'), 'save', icon: Icons.save_outlined),
            SheetAction(tr('취소'), 'cancel'),
          ]);
      if (!mounted || choice == null || choice == 'cancel') return;
      if (choice == 'settings') {
        model.openSettings();
        return;
      }
    }
    final key = TrackKey(title: _title.text, artist: _artist.text, duration: widget.draft.duration);
    final existing = model.collection.existingSong(key);
    if (existing != null) {
      final choice = await showActionSheet<String>(context, title: tr('이미 컬렉션에 있는 노래예요'), actions: [
        SheetAction(tr('기존 LP 열기'), 'open'),
        SheetAction(tr('그래도 추가'), 'add'),
        SheetAction(tr('취소'), 'cancel'),
      ]);
      if (!mounted) return;
      if (choice == 'open') model.setPath([PlayerRoute(existing.id)]);
      if (choice != 'add') return;
    }
    final engine = model.settings.engine;
    if (engine.isCloud && !model.settings.cloudNoticeAccepted) {
      final ok = await confirmDialog(
        context,
        title: engine == EngineKind.vynilo ? tr('가사가 내 Vynilo 서버로 전송돼요') : tr('가사가 선택한 AI 서비스로 전송돼요'),
        message: switch (engine) {
          EngineKind.vynilo => tr('Tailscale로 연결된 내 서버에서 번역해요. 외부 AI 서비스로는 보내지 않아요.'),
          EngineKind.gateway => tr('LLM 게이트웨이로 가사를 보내 번역하고, 사용량은 게이트웨이 계정에 청구돼요.'),
          _ => tr('{0} API로 가사를 보내 번역하고, 사용량은 내 API 계정에 청구돼요. 노래 한 곡에 약 \$0.01 미만이에요.', [engine.badgeLabel]),
        },
        confirm: tr('계속'),
      );
      if (!ok || !mounted) return;
      model.updateSettings((s) => s.cloudNoticeAccepted = true);
    }
    _save();
  }

  void _save() {
    final model = context.readModel;
    if (model.settings.engine.isCloud && !model.currentEngine().isAvailable) {
      model.showBanner(AppBanner(LLMError.missingAPIKey.userMessage, actionTitle: tr('설정')));
    }
    final draft = widget.draft
      ..title = _title.text
      ..artist = _artist.text
      ..lyrics = _lyrics.text;
    final id = model.addSong(draft, coverSourcePath: _coverPath);
    // Replace the add flow with the translating screen (linear flow, SSRD 4.1.2).
    model.setPath([TranslatingRoute(id)]);
  }
}
