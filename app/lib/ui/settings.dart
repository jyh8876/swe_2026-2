import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:sign_in_with_apple/sign_in_with_apple.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../app/account.dart';
import '../app/app_model.dart';
import '../app/i18n.dart';
import '../app/platform_services.dart';
import '../app/theme.dart';
import '../core/collection.dart';
import '../core/llm.dart';
import '../core/models.dart';
import '../core/playback.dart';
import 'calendar.dart';
import 'components.dart';
import 'engine_settings.dart';
import 'onboarding.dart';
import 'share_card.dart';

/// FG-09 Settings (RQ-14, RQ-15, RQ-18, PR-10).
class SettingsView extends StatefulWidget {
  /// Shown as the "My page" tab (no close button) or pushed as a full-screen page.
  final bool asTab;
  const SettingsView({super.key, this.asTab = false});
  @override
  State<SettingsView> createState() => _SettingsViewState();
}

class _SettingsViewState extends State<SettingsView> {
  double? downloadProgress;

  @override
  Widget build(BuildContext context) {
    final model = context.model;
    final t = context.theme;
    final s = model.settings;
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.asTab ? tr('마이페이지') : tr('설정')),
        automaticallyImplyLeading: false,
        actions: [
          if (!widget.asTab)
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text(
                tr('완료'),
                style: TextStyle(
                  color: t.textPrimary,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 32),
        children: [
          if (widget.asTab) ...[
            if (model.account case final a?) _ProfileHeader(account: a),
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 12, 16, 0),
              child: MyStats(),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: EdgeInsets.fromLTRB(16, 0, 16, 8),
                    child: SectionLabel(tr('내 컬렉션 달력')),
                  ),
                  const CollectionCalendar(),
                ],
              ),
            ),
            if (model.collection.songs.isNotEmpty)
              _section(null, [
                _nav(tr('내 컬렉션 자랑하기'), () => showShareCard(context)),
              ]),
          ],
          // Home layout, two variants for the survey: B picks the layout here, C on the home with
          // one folding button next to "노래 추가". Album slide is the default layout either way.
          _section(tr('보기 방식'), [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: SizedBox(
                width: double.infinity,
                child: SegmentedButton<LayoutControl>(
                  showSelectedIcon: false,
                  style: SegmentedButton.styleFrom(
                    selectedBackgroundColor: t.accent,
                    selectedForegroundColor: t.onAccent,
                    foregroundColor: t.textSecondary,
                    side: BorderSide(color: t.stroke),
                    padding: const EdgeInsets.symmetric(vertical: 10),
                  ),
                  segments: [
                    for (final c in LayoutControl.values)
                      ButtonSegment(value: c, label: Text(tr(c.label), style: const TextStyle(fontSize: 13))),
                  ],
                  selected: {s.layoutControl},
                  onSelectionChanged: (v) => model.updateSettings((x) => x.layoutControl = v.first),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: Text(
                s.layoutControl == LayoutControl.myPage ? tr('여기서 홈 화면 보기 방식을 골라요') : tr('홈 화면 "노래 추가" 왼쪽 버튼을 눌러 골라요'),
                style: TextStyle(fontSize: 12, color: t.textTertiary),
              ),
            ),
            if (s.layoutControl == LayoutControl.myPage)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
                child: SizedBox(
                  width: double.infinity,
                  child: SegmentedButton<LibraryLayout>(
                    showSelectedIcon: false,
                    style: SegmentedButton.styleFrom(
                      selectedBackgroundColor: t.accent,
                      selectedForegroundColor: t.onAccent,
                      foregroundColor: t.textSecondary,
                      side: BorderSide(color: t.stroke),
                      padding: const EdgeInsets.symmetric(vertical: 10),
                    ),
                    segments: [
                      for (final (l, icon) in [
                        (LibraryLayout.carousel, Icons.view_carousel_outlined),
                        (LibraryLayout.stack, Icons.layers_outlined),
                        (LibraryLayout.grid, Icons.grid_view_outlined),
                        (LibraryLayout.list, Icons.view_list_outlined),
                      ])
                        // Icon above the name, so "슬라이드" fits on one line in a quarter of the row.
                        ButtonSegment(
                          value: l,
                          label: Column(mainAxisSize: MainAxisSize.min, children: [
                            Icon(icon, size: 20),
                            const SizedBox(height: 2),
                            Text(tr(l.label), maxLines: 1, softWrap: false, overflow: TextOverflow.fade, style: const TextStyle(fontSize: 12)),
                          ]),
                        ),
                    ],
                    selected: {s.libraryLayout},
                    onSelectionChanged: (v) => model.updateSettings((x) => x.libraryLayout = v.first),
                  ),
                ),
              )
            else
              const SizedBox(height: 16),
          ]),
          _section(tr('테마'), [
            ListTile(
              title: Text(tr('배경'), style: TextStyle(color: t.textPrimary)),
              trailing: SegmentedButton<ThemeBase>(
                showSelectedIcon: false,
                style: SegmentedButton.styleFrom(
                  selectedBackgroundColor: t.accent,
                  selectedForegroundColor: t.onAccent,
                  foregroundColor: t.textSecondary,
                  side: BorderSide(color: t.stroke),
                  visualDensity: VisualDensity.compact,
                ),
                segments: [
                  for (final b in ThemeBase.values)
                    ButtonSegment(
                      value: b,
                      label: Text(
                        tr(b.label),
                        style: const TextStyle(fontSize: 13),
                      ),
                    ),
                ],
                selected: {s.themeBase},
                onSelectionChanged: (v) =>
                    model.updateSettings((x) => x.themeBase = v.first),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    tr('포인트 색'),
                    style: TextStyle(fontSize: 16, color: t.textPrimary),
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      for (final a in AccentColor.values)
                        Padding(
                          padding: const EdgeInsets.only(right: 14),
                          child: Semantics(
                            button: true,
                            selected: s.accent == a,
                            label: tr('포인트 색 {0}', [a.label]),
                            excludeSemantics: true,
                            child: GestureDetector(
                              onTap: () =>
                                  model.updateSettings((x) => x.accent = a),
                              child: Column(
                                children: [
                                  AnimatedContainer(
                                    duration: const Duration(milliseconds: 180),
                                    width: 36,
                                    height: 36,
                                    decoration: BoxDecoration(
                                      color: a.color,
                                      shape: BoxShape.circle,
                                      border: Border.all(
                                        color: s.accent == a
                                            ? t.textPrimary
                                            : Colors.transparent,
                                        width: 2.5,
                                      ),
                                    ),
                                    child: s.accent == a
                                        ? const Icon(
                                            Icons.check,
                                            size: 18,
                                            color: Color(0xFF16171B),
                                          )
                                        : null,
                                  ),
                                  const SizedBox(height: 4),
                                  Text(
                                    tr(a.label),
                                    style: TextStyle(
                                      fontSize: 11,
                                      color: t.textTertiary,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ]),
          _section(tr('번역 엔진'), [
            for (final (kind, label) in [
              (EngineKind.onDevice, tr('온디바이스 (기본)')),
              (EngineKind.gemini, 'Gemini API'),
              (EngineKind.gateway, tr('LLM 게이트웨이')),
            ])
              _radio(
                label,
                s.engine == kind,
                () => model.updateSettings((x) => x.engine = kind),
              ),
            if (s.engine == EngineKind.onDevice) ...[
              _row(
                tr('사용 중'),
                trailing: EngineFactory.label(EngineKind.onDevice),
              ),
              _modelDownloadRow(model),
            ] else if (s.engine == EngineKind.gateway) ...[
              _row(tr('사용 중'), trailing: _endpointSummary(model)),
              _nav(
                tr('게이트웨이 설정'),
                () => Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => EndpointSettingsView(kind: s.engine),
                  ),
                ),
              ),
            ] else
              _nav(
                tr('API 키 입력'),
                () => Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => const APIKeyEntryView()),
                ),
              ),
          ]),
          _section(tr('언어'), [
            ListTile(
              leading: Icon(Icons.language, color: t.textSecondary),
              // The English word stays visible so a user can always find the way back.
              title: Text(
                I18n.lang == 'en'
                    ? 'App language'
                    : '${tr('앱 언어')} · App language',
                style: TextStyle(color: t.textPrimary),
              ),
              trailing: _languageMenu(
                s.uiLanguage,
                Language.uiLanguages,
                (v) => model.updateSettings((x) => x.uiLanguage = v),
              ),
            ),
            ListTile(
              leading: Icon(Icons.translate, color: t.textSecondary),
              title: Text(tr('번역할 언어'), style: TextStyle(color: t.textPrimary)),
              subtitle: Text(
                tr('가사를 이 언어로 번역해요'),
                style: TextStyle(fontSize: 12, color: t.textTertiary),
              ),
              trailing: _languageMenu(
                s.targetLanguage,
                Language.supported,
                (v) => model.updateSettings((x) => x.targetLanguage = v),
              ),
            ),
          ]),
          _section(tr('가사 기본 설정'), [
            // 해석 is always shown; 발음 is toggled per song in the player, this is its default.
            SwitchListTile(
              title: Text(tr('발음 표시'), style: TextStyle(color: t.textPrimary)),
              value: s.showReading,
              onChanged: (v) => model.updateSettings((x) => x.showReading = v),
            ),
          ]),
          // On iOS this is the Apple Music connection (MusicKit), in the place the Spotify row had
          // (feedback 11/22 #4, #24); Android follows any music app through media sessions.
          if (MusicApp.supported)
            _section(isIOS ? 'Apple Music' : tr('음악 앱'), [
              ListTile(
                leading: Icon(
                  model.musicAppAccess
                      ? Icons.check_circle_rounded
                      : Icons.music_note_outlined,
                  color: model.musicAppAccess ? t.brand : t.textSecondary,
                ),
                title: Text(
                  isIOS ? tr('Apple Music 연결') : tr('듣는 곡 따라가기'),
                  style: TextStyle(color: t.textPrimary),
                ),
                subtitle: Text(
                  model.musicAppAccess
                      ? (model.activeSourceID == SourceID.musicApp &&
                                model.nowPlaying?.appName != null
                            ? tr('연결됨 · 지금 {0}', [model.nowPlaying!.appName!])
                            : tr('연결됨'))
                      : isIOS
                      ? tr('연결하면 Apple Music으로 듣는 곡의 가사가 따라오고, Vinylo에서 재생을 제어할 수 있어요')
                      : tr('연결 안 됨'),
                  style: TextStyle(fontSize: 12, color: t.textTertiary),
                ),
                trailing: model.musicAppAccess
                    ? null
                    : TextButton(
                        onPressed: () => _connectMusicApp(model),
                        child: Text(
                          tr('연결하기'),
                          style: TextStyle(
                            color: t.textPrimary,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
              ),
            ]),
          if (model.googleAvailable ||
              model.appleAvailable ||
              model.account != null)
            _section(tr('계정'), [
              if (model.account case final a?) ...[
                ListTile(
                  leading: Icon(
                    a.isApple ? Icons.apple : Icons.account_circle_outlined,
                    color: t.textPrimary,
                    size: 28,
                  ),
                  title: Text(
                    a.isApple ? tr('Apple 계정') : tr('Google 계정'),
                    style: TextStyle(color: t.textPrimary),
                  ),
                  subtitle: Text(
                    a.email ?? a.name ?? tr('이메일 비공개'),
                    style: TextStyle(fontSize: 12, color: t.textTertiary),
                  ),
                  trailing: TextButton(
                    onPressed: () => _signOut(model),
                    child: Text(
                      tr('로그아웃'),
                      style: TextStyle(color: t.textSecondary),
                    ),
                  ),
                ),
                ListTile(
                  title: Text(
                    tr('계정 삭제'),
                    style: const TextStyle(color: Color(0xFFE5484D)),
                  ),
                  onTap: () => _deleteAccount(model),
                ),
              ] else ...[
                if (model.appleAvailable)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                    child: SignInWithAppleButton(
                      text: tr('Apple로 로그인'),
                      height: 44,
                      style: t.isDark
                          ? SignInWithAppleButtonStyle.white
                          : SignInWithAppleButtonStyle.black,
                      onPressed: () => _signInApple(model),
                    ),
                  ),
                if (model.googleAvailable)
                  ListTile(
                    leading: Icon(
                      Icons.account_circle_outlined,
                      color: t.textPrimary,
                      size: 28,
                    ),
                    title: Text(
                      tr('Google 계정'),
                      style: TextStyle(color: t.textPrimary),
                    ),
                    trailing: TextButton(
                      onPressed: () => _signInGoogle(model),
                      child: Text(
                        tr('로그인'),
                        style: TextStyle(
                          color: t.textPrimary,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
                  child: Text(
                    model.accountApi.isConfigured
                        ? tr('선택 사항 · 계정 정보(이메일, 이름)만 저장하고 가사는 저장하지 않아요')
                        : tr('선택 사항 · 계정 정보만 이 기기에 저장해요'),
                    style: TextStyle(fontSize: 12, color: t.textTertiary),
                  ),
                ),
              ],
            ]),
          if (SpotifyAuth.available)
            _section('Spotify', [
              ListTile(
                leading: Image.asset(
                  'assets/brand/spotify_icon_green.png',
                  width: 28,
                  height: 28,
                ),
                title: Text(
                  tr('Spotify 계정'),
                  style: TextStyle(color: t.textPrimary),
                ),
                subtitle: Text(
                  model.spotifyConnected ? tr('로그인됨') : tr('연결 안 됨'),
                  style: TextStyle(fontSize: 12, color: t.textTertiary),
                ),
                trailing: model.spotifyConnected
                    ? TextButton(
                        onPressed: () => _logout(model),
                        child: Text(
                          tr('로그아웃'),
                          style: TextStyle(color: t.textSecondary),
                        ),
                      )
                    : model.spotifyAuth.isConfigured
                    ? TextButton(
                        onPressed: () => model.connect(SourceID.spotify),
                        child: Text(
                          tr('연결하기'),
                          style: TextStyle(
                            color: t.textPrimary,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      )
                    : null,
              ),
              if (model.spotifyConnected) ...[
                ListTile(
                  leading: Icon(
                    model.usingSpotifyApp
                        ? Icons.check_circle_rounded
                        : Icons.info_outline_rounded,
                    color: model.usingSpotifyApp ? t.brand : t.textTertiary,
                  ),
                  title: Text(tr('재생'), style: TextStyle(color: t.textPrimary)),
                  subtitle: Text(
                    model.usingSpotifyApp
                        ? tr('Spotify 앱으로 재생 · 앱 전환 없이 백그라운드에서 재생해요')
                        : (model.spotifyRemoteIssue ??
                              tr('Spotify 앱에 연결하는 중…')),
                    style: TextStyle(fontSize: 12, color: t.textTertiary),
                  ),
                  trailing: model.usingSpotifyApp
                      ? null
                      : TextButton(
                          onPressed: () =>
                              model.attachSpotify(retryRemote: true),
                          child: Text(
                            tr('다시 연결'),
                            style: TextStyle(
                              color: t.textPrimary,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
                  child: Text(
                    tr(
                      '노래는 휴대폰의 Spotify 앱으로 재생돼요 (Spotify Premium 필요). 지금 듣는 곡의 가사가 자동으로 따라와요.',
                    ),
                    style: TextStyle(fontSize: 12, color: t.textTertiary),
                  ),
                ),
              ],
            ]),
          _section(tr('데이터'), [
            _row(
              tr('저장 공간 사용량'),
              trailing: StorageMeter.format(model.storageUsedBytes),
            ),
            _nav(tr('컬렉션 내보내기'), _export),
            _nav(tr('컬렉션 가져오기'), _import),
            if (ModelManager.isInstalled)
              _destructive(tr('온디바이스 모델 삭제'), () {
                ModelManager.deleteModel();
                setState(() {});
              }),
            _destructive(tr('전체 삭제'), _deleteAll),
          ]),
          _section(null, [
            _row(
              tr('버전'),
              trailing: '0.18.4 (${Platform.isIOS ? 'iOS' : 'Android'})',
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
              child: Text(
                tr(
                  '가사는 앱 안의 브라우저에서 찾아 가져오거나 붙여넣어요. 가사와 번역은 이 기기에만 저장되고, 가사는 선택한 번역 엔진으로만 전송돼요. 로그인하면 노래 제목·아티스트와 학습 기록만 서버에 저장돼요.',
                ),
                style: TextStyle(fontSize: 12, color: t.textTertiary),
              ),
            ),
          ]),
        ],
      ),
    );
  }

  /// A dropdown of languages by their own names. A saved value that is no longer offered stays listed.
  Widget _languageMenu(
    String value,
    List<Language> options,
    ValueChanged<String> onChanged,
  ) {
    final t = context.theme;
    final items = [
      ...options,
      if (!options.any((l) => l.code == value)) Language.named(value),
    ];
    return DropdownButton<String>(
      value: value,
      underline: const SizedBox(),
      dropdownColor: t.surfaceRaised,
      style: TextStyle(color: t.textSecondary, fontSize: 15),
      items: [
        for (final l in items)
          DropdownMenuItem(value: l.code, child: Text(l.nativeName)),
      ],
      onChanged: (v) => v == null ? null : onChanged(v),
    );
  }

  Widget _section(String? title, List<Widget> children) {
    final t = context.theme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (title != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: SectionLabel(title),
            ),
          Container(
            decoration: BoxDecoration(
              color: t.surface,
              borderRadius: BorderRadius.circular(12),
            ),
            clipBehavior: Clip.antiAlias,
            child: Material(
              color: Colors.transparent,
              child: Column(children: children),
            ),
          ),
        ],
      ),
    );
  }

  Widget _radio(String label, bool selected, VoidCallback onTap) {
    final t = context.theme;
    return ListTile(
      title: Text(label, style: TextStyle(color: t.textPrimary)),
      trailing: selected ? Icon(Icons.check, color: t.textPrimary) : null,
      onTap: onTap,
    );
  }

  Widget _row(String label, {required String trailing}) {
    final t = context.theme;
    return ListTile(
      title: Text(label, style: TextStyle(color: t.textPrimary)),
      trailing: Text(
        trailing,
        style: TextStyle(color: t.textSecondary, fontSize: 14),
      ),
    );
  }

  Widget _nav(String label, VoidCallback onTap) {
    final t = context.theme;
    return ListTile(
      title: Text(label, style: TextStyle(color: t.textPrimary)),
      trailing: Icon(Icons.chevron_right, color: t.textTertiary),
      onTap: onTap,
    );
  }

  Widget _destructive(String label, VoidCallback onTap) => ListTile(
    title: Text(label, style: const TextStyle(color: Color(0xFFE57373))),
    onTap: onTap,
  );

  /// PR-9 / ONRQ-14: progress is shown inline.
  Widget _modelDownloadRow(AppModel model) {
    final t = context.theme;
    if (downloadProgress case final p?) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    tr('번역 모델 다운로드 중… {0} / {1}', [
                      StorageMeter.format(
                        (p * ModelManager.approximateBytes).round(),
                      ),
                      StorageMeter.format(ModelManager.approximateBytes),
                    ]),
                    style: TextStyle(color: t.textPrimary),
                  ),
                ),
                TextButton(
                  onPressed: ModelManager.cancelDownload,
                  child: Text(
                    tr('취소'),
                    style: TextStyle(color: t.textSecondary),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            LinearProgressIndicator(value: p),
            const SizedBox(height: 6),
            Text(
              tr('Wi-Fi에서 받는 걸 권장해요. 중간에 멈춰도 이어서 받아요.'),
              style: TextStyle(fontSize: 12, color: t.textTertiary),
            ),
          ],
        ),
      );
    }
    if (!ModelManager.isSupported) {
      return _row(tr('온디바이스 모델'), trailing: tr('이 기기에서는 지원하지 않아요'));
    }
    if (ModelManager.isInstalled) {
      return _row(tr('온디바이스 모델'), trailing: tr('번역 모델 설치됨'));
    }
    return ListTile(
      title: Text(
        tr('번역 모델 내려받기 ({0})', [
          StorageMeter.format(ModelManager.approximateBytes),
        ]),
        style: TextStyle(color: t.accent),
      ),
      onTap: () async {
        setState(() => downloadProgress = 0);
        try {
          await ModelManager.download((p) {
            if (mounted) setState(() => downloadProgress = p);
          });
          if (mounted) showMessage(context, tr('번역 모델을 설치했어요.'));
        } on CancelledException {
          if (mounted) showMessage(context, tr('다운로드를 멈췄어요. 다시 누르면 이어서 받아요.'));
        } catch (_) {
          if (mounted) {
            showMessage(context, tr('모델을 내려받지 못했어요. 다시 시도하면 이어서 받아요.'));
          }
        }
        if (mounted) setState(() => downloadProgress = null);
      },
    );
  }

  String _endpointSummary(AppModel model) {
    final s = model.settings;
    final hasKey = (model.apiKey(s.engine) ?? '').isNotEmpty;
    if (!hasKey) return tr('설정 필요');
    return s.gatewayModel.isEmpty ? tr('모델 선택 필요') : s.gatewayModel;
  }

  Future<void> _signInGoogle(AppModel model) async {
    try {
      await model.signInGoogle();
    } on GoogleSignInException catch (e) {
      if (mounted) {
        showMessage(
          context,
          tr('Google 로그인에 실패했어요: {0}', [e.description ?? e.code.name]),
        );
      }
    } on AccountApiException catch (e) {
      if (mounted) showMessage(context, tr('로그인하지 못했어요: {0}', ['$e']));
    }
  }

  Future<void> _signInApple(AppModel model) async {
    try {
      await model.signInApple();
    } on SignInWithAppleException catch (e) {
      if (mounted) showMessage(context, tr('Apple 로그인에 실패했어요: {0}', ['$e']));
    } on AccountApiException catch (e) {
      if (mounted) showMessage(context, tr('로그인하지 못했어요: {0}', ['$e']));
    }
  }

  Future<void> _signOut(AppModel model) async {
    final ok = await confirmDialog(
      context,
      title: tr('계정에서 로그아웃할까요?'),
      message: tr('이 기기에서 계정 정보를 지워요. 계정은 그대로 남아 있어요.'),
      confirm: tr('로그아웃'),
      destructive: true,
    );
    if (ok) await model.signOut();
  }

  /// Account deletion (App Store guideline 5.1.1(v)): asks once, then re-authenticates.
  Future<void> _deleteAccount(AppModel model) async {
    final ok = await confirmDialog(
      context,
      title: tr('계정을 삭제할까요?'),
      message: tr(
        '본인 확인을 위해 한 번 더 로그인해요. 서버의 계정 정보가 지워지고 로그아웃돼요. 이 기기의 노래와 가사는 그대로예요.',
      ),
      confirm: tr('삭제'),
      destructive: true,
    );
    if (!ok) return;
    try {
      if (await model.deleteAccount() && mounted) {
        showMessage(context, tr('계정을 삭제했어요.'));
      }
    } catch (e) {
      if (mounted) showMessage(context, tr('계정을 삭제하지 못했어요: {0}', ['$e']));
    }
  }

  Future<void> _logout(AppModel model) async {
    final ok = await confirmDialog(
      context,
      title: tr('Spotify에서 로그아웃할까요?'),
      message: tr('내 플레이리스트를 더 불러올 수 없어요. 다른 음악 앱으로 듣는 곡의 가사는 계속 따라와요.'),
      confirm: tr('로그아웃'),
      destructive: true,
    );
    if (ok) await model.disconnect(SourceID.spotify);
  }

  Future<void> _connectMusicApp(AppModel model) async {
    if (await confirmMusicAppAccess(context)) {
      await model.requestMusicAppAccess();
    }
  }

  Future<void> _export() async {
    final model = context.readModel;
    try {
      final dir = await getTemporaryDirectory();
      final f = File('${dir.path}/Vinylo-collection.json');
      await f.writeAsString(model.exportData(), flush: true);
      await SharePlus.instance.share(
        ShareParams(
          files: [XFile(f.path, mimeType: 'application/json')],
          subject: tr('Vinylo 컬렉션'),
        ),
      );
    } catch (_) {
      if (mounted) showMessage(context, tr('내보내지 못했어요.'));
    }
  }

  Future<void> _import() async {
    final model = context.readModel;
    String message;
    try {
      final files = await FilePicker.pickFiles(type: FileType.any);
      final path = files.isEmpty ? null : files.single.path;
      if (path == null) return;
      final report = model.importData(
        utf8.decode(await File(path).readAsBytes()),
      );
      message = tr('노래 {0}곡, 문장 {1}개를 가져왔어요.', [
        report.songsAdded,
        report.phrasesAdded,
      ]);
    } on ImportError catch (e) {
      message = e.newerSchema != null
          ? tr('더 새로운 버전의 앱에서 만든 파일이에요. 앱을 업데이트해 주세요.')
          : tr('파일을 읽을 수 없어요. 아무것도 변경되지 않았어요.');
    } catch (_) {
      message = tr('파일을 읽을 수 없어요. 아무것도 변경되지 않았어요.');
    }
    if (mounted) showMessage(context, message);
  }

  Future<void> _deleteAll() async {
    final ok = await confirmDialog(
      context,
      title: tr('모든 데이터를 삭제할까요?'),
      message: tr('컬렉션, 번역, 저장한 문장, 커버, 모델 파일, API 키가 모두 삭제돼요. 되돌릴 수 없어요.'),
      confirm: tr('전체 삭제'),
      destructive: true,
    );
    if (!ok || !mounted) return;
    final model = context.readModel;
    if (!widget.asTab) Navigator.pop(context);
    await model.deleteAll();
  }
}

/// API key entry with "Verify key" (RQ-14, ONRQ-10). Keys are masked after saving and stored
/// only in secure storage.
class APIKeyEntryView extends StatefulWidget {
  final bool showDone;
  const APIKeyEntryView({super.key, this.showDone = false});
  @override
  State<APIKeyEntryView> createState() => _APIKeyEntryViewState();
}

class _APIKeyEntryViewState extends State<APIKeyEntryView> {
  // Gemini is the only engine that takes a personal API key now.
  final EngineKind provider = EngineKind.gemini;
  final _key = TextEditingController();
  String status = 'idle';
  String? failure;

  @override
  void dispose() {
    _key.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final model = context.model;
    final t = context.theme;
    final saved = model.apiKey(provider);
    return Scaffold(
      appBar: AppBar(
        title: Text(tr('API 키')),
        actions: [
          if (widget.showDone)
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text(
                tr('완료'),
                style: TextStyle(
                  color: t.textPrimary,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Text(
            'Gemini API',
            style: TextStyle(
              fontSize: 17,
              fontWeight: FontWeight.w600,
              color: t.textPrimary,
            ),
          ),
          const SizedBox(height: 20),
          if (saved != null && _key.text.isEmpty) ...[
            Row(
              children: [
                Text(tr('저장된 키'), style: TextStyle(color: t.textSecondary)),
                const Spacer(),
                Text(
                  maskSecret(saved),
                  style: TextStyle(
                    color: t.textPrimary,
                    fontFamily: 'monospace',
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
          ],
          OutlinedField(
            controller: _key,
            hint: tr('API 키 입력'),
            obscure: true,
            onChanged: (_) => setState(() {}),
            // Same paste button as onboarding.
            suffix: IconButton(
              tooltip: tr('붙여넣기'),
              icon: Icon(Icons.content_paste, size: 20, color: t.textTertiary),
              onPressed: () async {
                final text =
                    (await Clipboard.getData(Clipboard.kTextPlain))?.text
                        ?.trim() ??
                    '';
                if (mounted && text.isNotEmpty) {
                  setState(() => _key.text = text);
                }
              },
            ),
          ),
          const SizedBox(height: 4),
          // Feedback 11/19 #11: the same help as onboarding, under the field.
          _helpRow(
            Icons.north_east,
            tr('Google AI Studio 열기'),
            tr('API 키 페이지로 바로 가요'),
            () async {
              try {
                await Links.open(OnboardingKeyGuide.studio);
              } catch (_) {
                if (context.mounted) showMessage(context, tr('브라우저를 열지 못했어요.'));
              }
            },
          ),
          _helpRow(
            Icons.menu_book_outlined,
            tr('가져오기 가이드'),
            tr('API 키를 복사하는 3단계'),
            () {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (c) =>
                      OnboardingKeyGuide(onHaveKey: () => Navigator.pop(c)),
                ),
              );
            },
          ),
          const SizedBox(height: 12),
          PrimaryButton(
            tr('키 확인'),
            onPressed: _key.text.isEmpty || status == 'verifying'
                ? null
                : _verify,
          ),
          const SizedBox(height: 12),
          if (status == 'verifying')
            const Center(child: CircularProgressIndicator()),
          if (status == 'ok')
            Row(
              children: [
                Icon(Icons.check_circle_outline, color: Colors.green),
                SizedBox(width: 8),
                Text(tr('키가 확인됐어요'), style: TextStyle(color: Colors.green)),
              ],
            ),
          if (status == 'failed')
            Row(
              children: [
                const Icon(Icons.highlight_off, color: Color(0xFFE57373)),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    failure ?? '',
                    style: const TextStyle(color: Color(0xFFE57373)),
                  ),
                ),
              ],
            ),
        ],
      ),
    );
  }

  Widget _helpRow(
    IconData icon,
    String title,
    String subtitle,
    VoidCallback onTap,
  ) {
    final t = context.theme;
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: Icon(icon, size: 20, color: t.textSecondary),
      title: Text(title, style: TextStyle(fontSize: 15, color: t.textPrimary)),
      subtitle: Text(
        subtitle,
        style: TextStyle(fontSize: 12, color: t.textTertiary),
      ),
      trailing: Icon(Icons.chevron_right, color: t.textTertiary),
      onTap: onTap,
    );
  }

  Future<void> _verify() async {
    final model = context.readModel;
    setState(() => status = 'verifying');
    final key = _key.text.trim();
    try {
      final CloudChatEngine engine = GeminiEngine(key);
      await engine.verifyKey();
      await model.secureStore.set(key, SecretKey.apiKeyFor(provider)!);
      model.updateSettings((s) => s.engine = provider);
      _key.clear();
      if (mounted) setState(() => status = 'ok');
    } on LLMError catch (e) {
      if (mounted) {
        setState(() {
          status = 'failed';
          failure = e.userMessage;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          status = 'failed';
          failure = tr('키를 저장하지 못했어요.');
        });
      }
    }
  }
}

/// Who is signed in, at the top of the My page: initial in a circle, the name, and the e-mail or
/// the sign-in provider underneath. Apple may share no name (only the first time) and may hide the
/// e-mail, so the name falls back to the e-mail's local part, then to the provider.
class _ProfileHeader extends StatelessWidget {
  final AccountInfo account;
  const _ProfileHeader({required this.account});

  @override
  Widget build(BuildContext context) {
    final t = context.theme;
    final provider = account.isApple ? tr('Apple 계정') : tr('Google 계정');
    final email = (account.email ?? '').trim();
    final name = (account.name ?? '').trim();
    final title = name.isNotEmpty
        ? name
        : (email.isNotEmpty ? email.split('@').first : provider);
    final sub = title == provider
        ? null
        : (email.isNotEmpty && email != title ? email : provider);
    final initial = title == provider
        ? null
        : String.fromCharCode(title.runes.first).toUpperCase();
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 4),
      child: Row(
        children: [
          Container(
            width: 52,
            height: 52,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: t.surfaceRaised,
              shape: BoxShape.circle,
              border: Border.all(color: t.stroke.withValues(alpha: 0.6)),
            ),
            child: initial == null
                ? Icon(Icons.person_rounded, color: t.textSecondary)
                : Text(
                    initial,
                    style: TextStyle(
                      fontSize: 22,
                      fontWeight: FontWeight.w700,
                      color: t.textPrimary,
                    ),
                  ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                    letterSpacing: -0.3,
                    color: t.textPrimary,
                  ),
                ),
                if (sub != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(
                      sub,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 13, color: t.textSecondary),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
