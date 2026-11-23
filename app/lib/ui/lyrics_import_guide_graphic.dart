import 'package:flutter/material.dart';

/// 가사 불러오는 법 안내 그래픽 (api_key_guide_graphic.dart와 같은 스타일의 일러스트형 목업).
///
/// 글로만 된 가이드가 어렵다는 피드백에 따라, 캡처 대신 같은 기기 실루엣 안에서 4단계를 움직여 보여줘요.
/// - 디자인 좌표: 375 × 248 영역. 폭에 맞춰 비율 그대로 늘거나 줄어요.
/// - 15.5초 반복(장면당 3초, 마지막 붙여넣은 결과는 3.5초): 1단계 가사 검색(0–3s) → 2단계 LRC 결과 고르기(3–6s) → 3단계 가사 복사(6–12s: 방법 1 드래그 6–9s, 방법 2 복사 아이콘 9–12s) → 4단계 붙여넣기(12–15.5s)
/// - 모든 상태는 시간 t(초)만으로 계산해요. 타이머를 쓰지 않아서 어느 시점이든 같은 화면이 나와요.
/// - 시스템 '동작 줄이기'가 켜져 있으면 확대 없이 장면만 바뀌어요.
/// - 외부 사이트 로고나 캡처를 쓰지 않고 스켈레톤으로 그려서, 사이트 UI가 바뀌어도 그림은 그대로예요.
///
/// 앱으로 옮길 때 바꿀 것: 아래 [_Palette]의 색을 앱 테마 토큰으로, [fontFamily]를 앱 폰트로.
/// 안에 쓰인 글자(노래 제목, 버튼 이름 등)는 앱의 tr()로 감싸서 번역해요. 에셋은 필요 없어요.
class LyricsImportGuideGraphic extends StatefulWidget {
  const LyricsImportGuideGraphic({
    super.key,
    this.background,
    this.brightness,
    this.fontFamily = 'SUIT',
    this.speed = 1.0,
    this.playing = true,
    this.seekTo,
    this.translate,
  });

  /// 그래픽 영역 바탕색. 비우면 bg/layer/basement. 아래 40px이 이 색으로 사라져요.
  final Color? background;

  /// 라이트/다크. 비우면 앱 테마(Theme.of(context).brightness)를 따라요.
  final Brightness? brightness;

  /// 서체. 기본은 디자인 토큰의 SUIT. 앱에 SUIT가 없으면 앱 서체 이름으로 바꿔요.
  final String? fontFamily;

  /// 재생 속도 배율 (1.0 = 원래 속도, 0.5 = 느리게).
  final double speed;
  final bool playing;

  /// 값이 바뀌면 그 시점(초)으로 이동해요. 미리보기에서 단계 이동용.
  final double? seekTo;

  /// 그림 속 글자 번역 함수. 앱에서는 `translate: tr`로 넘겨요. 비우면 한국어 그대로.
  final String Function(String)? translate;

  /// 장면 설계 기준 한 바퀴(초). 아래 시점들(stepStarts 등)은 모두 이 기준이에요.
  static const double _storyboardSeconds = 15.5;

  /// 재생 속도 보정 배수. 1.0 = 설계 그대로(장면당 3초).
  static const double slowdown = 1.0;

  /// 실제 한 바퀴 길이(초)
  static const double loopSeconds = _storyboardSeconds * slowdown;

  /// 각 단계가 시작하는 시점(초). 미리보기·단계 표시와 맞출 때 써요.
  static const List<double> stepStarts = [0.0, 3.0, 6.0, 12.0];

  /// 3단계의 두 번째 방법(복사 아이콘 누르기)이 시작하는 시점(초).
  static const double copyIconStart = 9.0;

  @override
  State<LyricsImportGuideGraphic> createState() => _LyricsImportGuideGraphicState();
}

/// 피그마 Color 토큰. api_key_guide_graphic.dart와 같은 값이고, 같은 값이에요.
class _Palette {
  const _Palette({
    required this.gray00,
    required this.gray200,
    required this.gray300,
    required this.gray400,
    required this.gray500,
    required this.gray600,
    required this.gray700,
    required this.gray800,
    required this.gray900,
    required this.gray1000,
    required this.blue700,
    required this.onSolid,
  });

  final Color gray00; // bg/layer/basement
  final Color gray200; // bg/layer/default
  final Color gray300; // bg/neutral/weak
  final Color gray400; // stroke/neutral/weak
  final Color gray500;
  final Color gray600; // fg/neutral/placeholder
  final Color gray700; // fg/neutral/subtle
  final Color gray800; // fg/neutral/muted, bg/neutral/muted
  final Color gray900;
  final Color gray1000; // fg/neutral/base, bg/neutral/solid
  final Color blue700; // fg/informative/base
  final Color onSolid; // bg/neutral/solid 위 글자

  static const light = _Palette(
    gray00: Color(0xFFFFFFFF),
    gray200: Color(0xFFF3F4F5),
    gray300: Color(0xFFEEEFF1),
    gray400: Color(0xFFDCDEE3),
    gray500: Color(0xFFD1D3D8),
    gray600: Color(0xFFB0B3BA),
    gray700: Color(0xFF868B94),
    gray800: Color(0xFF555D6D),
    gray900: Color(0xFF2A3038),
    gray1000: Color(0xFF1A1C20),
    blue700: Color(0xFF217CF9),
    onSolid: Color(0xFFFFFFFF),
  );

  static const dark = _Palette(
    gray00: Color(0xFF16171B),
    gray200: Color(0xFF1D2025),
    gray300: Color(0xFF2B2E35),
    gray400: Color(0xFF393D46),
    gray500: Color(0xFF5B606A),
    gray600: Color(0xFF868B94),
    gray700: Color(0xFFB0B3BA),
    gray800: Color(0xFFDCDEE3),
    gray900: Color(0xFFE9EAEC),
    gray1000: Color(0xFFF3F4F5),
    blue700: Color(0xFF41A2F9),
    onSolid: Color(0xFF16171B),
  );
}

/// 모션 이징
const _easeOut = Cubic(.22, 1, .36, 1);
const _easeInOut = Cubic(.65, 0, .35, 1);

class _LyricsImportGuideGraphicState extends State<LyricsImportGuideGraphic> with SingleTickerProviderStateMixin {
  late final AnimationController _c;
  double _t = 0; // 현재 시점(초)
  _Palette _p = _Palette.light;
  Duration? _last;

  @override
  void initState() {
    super.initState();
    _t = widget.seekTo ?? 0;
    _c = AnimationController(vsync: this, duration: const Duration(days: 1))
      ..addListener(_tick)
      ..forward();
  }

  void _tick() {
    final now = _c.lastElapsedDuration ?? Duration.zero;
    final dt = _last == null ? 0.0 : (now - _last!).inMicroseconds / 1e6;
    _last = now;
    if (!widget.playing) return;
    setState(() => _t = (_t + dt * widget.speed / LyricsImportGuideGraphic.slowdown) % LyricsImportGuideGraphic._storyboardSeconds);
  }

  @override
  void didUpdateWidget(LyricsImportGuideGraphic old) {
    super.didUpdateWidget(old);
    if (widget.seekTo != null && widget.seekTo != old.seekTo) _t = widget.seekTo!;
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  String _tr(String s) => widget.translate?.call(s) ?? s;

  // ── 시간 → 값 도우미 ─────────────────────────────
  /// start부터 dur초 동안 0→1 (이징 적용)
  double _ramp(double start, double dur, [Curve curve = _easeOut]) =>
      curve.transform(((_t - start) / dur).clamp(0.0, 1.0));

  /// start에 켜져서 hold초 유지 후 꺼지는 값 (켜짐·꺼짐 각각 dur초)
  double _pulse(double start, double hold, double dur) => _ramp(start, dur) * (1 - _ramp(start + hold, dur));

  /// 장면 k의 불투명도. 장면 전환은 300ms 교차 페이드.
  static const _starts = [0.0, 3.0, 6.0, 9.0, 12.0];
  static const _ends = [3.0, 6.0, 9.0, 12.0, 15.5]; // 마지막 장면(붙여넣은 결과)만 0.5초 더
  double _scene(int k) {
    if (k == 4 && _t < 0.3) return 1 - _ramp(0, 0.3); // 반복 시작 때 마지막 장면이 사라짐
    return _ramp(_starts[k], 0.3) * (1 - _ramp(_ends[k], 0.3));
  }

  TextStyle _text(double size, double height, FontWeight w, Color color, {double? ls}) => TextStyle(
        fontFamily: widget.fontFamily,
        fontSize: size,
        height: height / size,
        fontWeight: w,
        color: color,
        letterSpacing: ls ?? size * -0.02,
      );

  /// 복사 단계(6~12초)에서 이미지 영역 맨 아래에 두 방법을 한 줄로 보여줘요 (폰 화면 안 UI처럼 보이지 않게 폰 밖 바탕 위에).
  /// 지금 보여주는 방법은 진하게, 나머지는 연하게.
  Widget _copyGuide() {
    final drag = _scene(2), icon = _scene(3);
    final show = drag > icon ? drag : icon;
    // 번호 없이 "드래그해서 복사 또는 복사 버튼 누르기". 지금 보여주는 방법만 진하게.
    Widget label(String text, double on) =>
        Text(text, style: _text(11, 15, FontWeight.w700, Color.lerp(_p.gray600, _p.gray1000, on)!, ls: 11 * -0.02));

    return Opacity(
      opacity: show,
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        label(_tr('드래그해서 복사'), drag),
        const SizedBox(width: 8),
        Text(_tr('또는'), style: _text(11, 15, FontWeight.w700, _p.gray600, ls: 11 * -0.02)),
        const SizedBox(width: 8),
        label(_tr('복사 버튼 누르기'), icon),
      ]),
    );
  }

  @override
  Widget build(BuildContext context) => _graphic(context);

  Widget _graphic(BuildContext context) {
    final dark = (widget.brightness ?? Theme.of(context).brightness) == Brightness.dark;
    _p = dark ? _Palette.dark : _Palette.light;
    final bg = widget.background ?? _p.gray00;

    // 실루엣 변환: 1.3배 (폰은 가운데에 고정)
    const base = 1.3;
    const dl = 99.0, dt = 10.0;
    const bx = (375 - 176 * base) / 2 - dl, by = 0.0;
    const s = base;
    const tx = bx, ty = by;

    return Semantics(
      label: _tr('앱에서 가사 검색을 누르고, 검색 결과에서 .LRC 사이트를 골라 드래그하거나 복사 아이콘을 눌러 가사를 복사한 뒤, 앱에 붙여넣는 과정을 보여주는 그래픽'),
      image: true,
      child: ExcludeSemantics(
        // 그림 속 글자라 시스템 글자 크기 설정에 따라 커지지 않게 고정
        child: MediaQuery.withNoTextScaling(
          child: AspectRatio(
            aspectRatio: 375 / 248,
            child: FittedBox(
              fit: BoxFit.contain,
              child: SizedBox(
                width: 375,
                height: 248,
                child: ClipRect(
                  child: ColoredBox(
                    color: bg,
                    child: Stack(
                      children: [
                        Positioned(
                          left: dl,
                          top: dt,
                          child: Transform(
                            transform: Matrix4.translationValues(tx, ty, 0)..scaleByDouble(s, s, 1, 1),
                            child: _device(),
                          ),
                        ),
                        // 아래 40px은 바탕색으로 사라짐
                        Positioned(
                          left: 0,
                          right: 0,
                          bottom: 0,
                          height: 40,
                          child: IgnorePointer(
                            child: DecoratedBox(
                              decoration: BoxDecoration(
                                gradient: LinearGradient(
                                  begin: Alignment.topCenter,
                                  end: Alignment.bottomCenter,
                                  stops: const [0, .85],
                                  colors: [bg.withValues(alpha: 0), bg],
                                ),
                              ),
                            ),
                          ),
                        ),
                        // 복사 단계 안내: 이미지 영역 안 맨 아래, 폰이 바탕으로 사라지는 자리
                        Positioned(left: 0, right: 0, bottom: 8, child: Center(child: _copyGuide())),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// 기기 실루엣 176 × 300: 테두리 4 gray/500, 모서리 30, 흰색, 다이나믹 아일랜드
  Widget _device() => Container(
        width: 176,
        height: 300,
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          color: _p.gray00,
          borderRadius: BorderRadius.circular(30),
          border: Border.all(color: _p.gray500, width: 4),
        ),
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            Positioned(
              left: 84 - 20,
              top: 10,
              child: Container(width: 40, height: 10, decoration: BoxDecoration(color: _p.gray400, borderRadius: BorderRadius.circular(6))),
            ),
            _fade(0, _sceneAddSong(pressSearch: _pulse(1.9, 0.26, 0.15))),
            _fade(1, _sceneResults()),
            _fade(2, _sceneLrcPage()),
            _fade(3, _sceneCopyIcon()),
            _fade(4, _sceneAddSong(pasteShown: _ramp(12.45, 0.3), pressPaste: _pulse(12.8, 0.26, 0.15), filled: _ramp(13.2, 0.25), recognized: _ramp(13.6, 0.3))),
          ],
        ),
      );

  Widget _fade(int k, Widget child) {
    final o = _scene(k);
    if (o <= 0) return const SizedBox.shrink();
    return Positioned.fill(child: Opacity(opacity: o, child: Stack(clipBehavior: Clip.none, children: [child])));
  }

  // ── 1단계 · 4단계: 노래 추가 화면 ────────────────────────
  // 피그마 시안(2026-2 소웨공 · 노래 추가)의 '가사' 영역을 0.448배(168/375)로 옮겼어요.
  // 1단계는 '가사 검색' 버튼이, 4단계는 '클립보드에서 붙여넣기' 버튼이 눌려요. 같은 화면이라 이어져 보여요.
  // 위쪽 제목·아티스트 칸은 스크롤로 올라간 것으로 보고 생략했고, 입력 칸 높이는 보이는 영역에 맞춰 줄였어요.
  Widget _sceneAddSong({double pressSearch = 0, double pasteShown = 0, double pressPaste = 0, double filled = 0, double recognized = 0}) {
    const lines = ['[00:13.04] You can count on me', "[00:16.52] I'll be there", '[00:18.11] And I know when I need it'];
    const boxTop = 82.0, boxH = 52.0;

    return Stack(clipBehavior: Clip.none, children: [
      // 헤더: 뒤로가기 + 가운데 제목
      Positioned(left: 10, top: 25, child: Icon(Icons.chevron_left, size: 10, color: _p.gray1000)),
      Positioned(left: 0, right: 0, top: 26, child: Text(_tr('노래 추가'), textAlign: TextAlign.center, style: _text(8, 11, FontWeight.w600, _p.gray1000))),
      // '가사' 라벨
      Positioned(left: 9, top: 45, child: Text(_tr('가사'), style: _text(5.5, 8, FontWeight.w500, _p.gray700, ls: 0))),
      // 가사 검색 버튼: 회색 알약, '곡명 – 아티스트 가사 검색 ↗'
      Positioned(
        left: 9,
        top: 58,
        child: Transform.scale(
          scale: 1 - .04 * pressSearch,
          alignment: Alignment.centerLeft,
          child: Container(
            height: 16,
            // 시안처럼 내용 폭에 맞추고 좌우 패딩(12 → 5.4)을 똑같이 둬요
            padding: const EdgeInsets.symmetric(horizontal: 6),
            decoration: BoxDecoration(color: Color.lerp(_p.gray200, _p.gray400, pressSearch), borderRadius: BorderRadius.circular(999)),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Text.rich(
                TextSpan(children: [
                  TextSpan(text: 'Count on Me – Bruno Mars ', style: _text(5.6, 8, FontWeight.w500, _p.gray800, ls: 0)),
                  TextSpan(text: _tr('가사 검색'), style: _text(5.6, 8, FontWeight.w700, _p.gray1000, ls: 0)),
                ]),
                maxLines: 1,
                softWrap: false,
              ),
              const SizedBox(width: 3),
              Icon(Icons.north_east, size: 6, color: _p.gray1000),
            ]),
          ),
        ),
      ),
      // 가사 입력 칸 (안쪽 아래에 구분선 + 클립보드에서 붙여넣기)
      Positioned(
        left: 9,
        right: 9,
        top: boxTop,
        height: boxH,
        child: Container(
          decoration: BoxDecoration(color: _p.gray00, borderRadius: BorderRadius.circular(5), border: Border.all(color: _p.gray400)),
          child: Stack(children: [
            Positioned(
              left: 5,
              right: 5,
              top: 5,
              child: Stack(children: [
                Opacity(opacity: 1 - filled, child: Text(_tr('이곳에 가사를 붙여넣어 주세요.'), style: _text(5.5, 8, FontWeight.w400, _p.gray600, ls: 0))),
                Opacity(
                  opacity: filled,
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    for (final l in lines) Text(l, maxLines: 1, softWrap: false, overflow: TextOverflow.clip, style: _text(5.4, 8, FontWeight.w400, _p.gray1000, ls: 0)),
                  ]),
                ),
              ]),
            ),
            // 붙여넣기 버튼: 가사 검색에서 돌아온 뒤(4단계)에만 나타나고, 가사가 채워지면 사라져요
            Positioned(
              left: 4,
              right: 4,
              bottom: 0,
              height: 17,
              child: Opacity(
                opacity: pasteShown * (1 - filled),
                child: Column(children: [
                  ColoredBox(color: _p.gray300, child: const SizedBox(height: 1, width: double.infinity)),
                  Expanded(
                    // 눌림은 배경색만 바뀌어요 (크기가 움직이면 흔들려 보여서)
                    child: DecoratedBox(
                      decoration: BoxDecoration(color: Color.lerp(_p.gray00, _p.gray200, pressPaste), borderRadius: BorderRadius.circular(4)),
                      child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                        Icon(Icons.content_paste, size: 6.5, color: _p.gray1000),
                        const SizedBox(width: 2.5),
                        Text(_tr('클립보드에서 붙여넣기'), style: _text(5.8, 8, FontWeight.w700, _p.gray1000, ls: 0)),
                      ]),
                    ),
                  ),
                ]),
              ),
            ),
          ]),
        ),
      ),
      // 확인 메시지: 입력 칸 아래 왼쪽, 파란 체크 + 문구
      Positioned(
        left: 9,
        top: boxTop + boxH + 5,
        child: Opacity(
          opacity: recognized,
          child: Transform.translate(
            offset: Offset(0, 2 * (1 - recognized)),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Icon(Icons.check_rounded, size: 7, color: _p.blue700),
              const SizedBox(width: 2),
              Text(_tr('싱크 가사를 인식했어요'), style: _text(5.6, 8, FontWeight.w500, _p.blue700, ls: 0)),
            ]),
          ),
        ),
      ),
    ]);
  }

  // ── 2단계: 검색 결과에서 (.LRC)가 붙은 결과 고르기 ─────────
  Widget _sceneResults() {
    final tip = _ramp(3.7, 0.25) * (1 - _ramp(5.3, 0.2));
    final press = _pulse(5.0, 0.3, 0.15);

    Widget skeletonResult(double top) => Positioned(
          left: 12,
          right: 12,
          top: top,
          child: Opacity(
            opacity: .55,
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Container(width: 7, height: 7, decoration: BoxDecoration(color: _p.gray400, shape: BoxShape.circle)),
                const SizedBox(width: 4),
                _bar(34, 4, _p.gray300),
              ]),
              const SizedBox(height: 4),
              _bar(100, 6, _p.gray400),
              const SizedBox(height: 4),
              _bar(124, 4, _p.gray300),
            ]),
          ),
        );

    return Stack(clipBehavior: Clip.none, children: [
      // 검색창: 앱이 만들어 준 검색어
      Positioned(
        left: 10,
        right: 10,
        top: 30,
        height: 16,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 6),
          decoration: BoxDecoration(color: _p.gray200, borderRadius: BorderRadius.circular(999)),
          child: Row(children: [
            Icon(Icons.search_rounded, size: 8, color: _p.gray700),
            const SizedBox(width: 4),
            Flexible(
              child: Text('Count on Me Bruno Mars .lrc',
                  maxLines: 1, softWrap: false, overflow: TextOverflow.clip, style: _text(6.5, 9, FontWeight.w500, _p.gray1000, ls: 0)),
            ),
          ]),
        ),
      ),
      // 첫 번째 결과 (눌림)
      Positioned(
        left: 6,
        right: 6,
        top: 52,
        height: 44,
        child: Transform.scale(
          scale: 1 - .03 * press,
          child: Container(
            padding: const EdgeInsets.fromLTRB(6, 5, 6, 0),
            decoration: BoxDecoration(color: Color.lerp(_p.gray00, _p.gray200, press), borderRadius: BorderRadius.circular(8)),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Container(width: 7, height: 7, decoration: BoxDecoration(color: _p.gray400, shape: BoxShape.circle)),
                const SizedBox(width: 4),
                _bar(34, 4, _p.gray400),
              ]),
              const SizedBox(height: 4),
              Row(children: [
                Flexible(
                  child: Text('Bruno Mars - Count On Me',
                      maxLines: 1, softWrap: false, overflow: TextOverflow.clip, style: _text(7.5, 10, FontWeight.w700, _p.blue700, ls: 0)),
                ),
                const SizedBox(width: 3),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 1),
                  decoration: BoxDecoration(color: _p.blue700.withValues(alpha: .14), borderRadius: BorderRadius.circular(3)),
                  child: Text('(.LRC)', style: _text(6, 8, FontWeight.w700, _p.blue700, ls: 0)),
                ),
              ]),
              const SizedBox(height: 4),
              _bar(124, 4, _p.gray300),
              const SizedBox(height: 3),
              _bar(90, 4, _p.gray300),
            ]),
          ),
        ),
      ),
      skeletonResult(104),
      skeletonResult(137),
      // 말풍선: 결과 아래에서 살짝 커지며 등장
      if (tip > 0)
        Positioned(
          left: 12,
          top: 92,
          child: Opacity(
            opacity: tip,
            child: Transform.translate(
              offset: Offset(0, -2 * (1 - tip)),
              child: Transform.scale(
                scale: .92 + .08 * tip,
                alignment: Alignment.topLeft,
                child: _tooltip(_tr('(.LRC)가 붙은 결과 누르기')),
              ),
            ),
          ),
        ),
    ]);
  }

  // ── 3단계: 시간이 붙은 가사를 처음부터 끝까지 선택해 복사 ─────
  Widget _sceneLrcPage() {
    final sel = _ramp(6.9, 0.8, _easeInOut);
    final bubble = _ramp(7.7, 0.18) * (1 - _ramp(8.5, 0.18));
    final bubblePress = _pulse(8.2, 0.15, 0.15);
    final toast = _ramp(8.35, 0.2) * (1 - _ramp(8.9, 0.1));
    const lines = ['[00:13.04] You can count on me', "[00:16.52] I'll be there", '[00:18.11] And I know when I need it'];
    const lineH = 12.0, top0 = 64.0;

    return Stack(clipBehavior: Clip.none, children: [
      Positioned(left: 12, top: 30, child: Text('Count On Me', style: _text(9, 12, FontWeight.w700, _p.gray1000))),
      Positioned(left: 12, top: 46, child: _bar(70, 4, _p.gray300)),
      // 선택 영역: 첫 줄에서 마지막 줄까지 위에서 아래로 차올라요
      Positioned(
        left: 8,
        right: 8,
        top: top0 - 1,
        height: (lineH * lines.length + 2) * sel,
        child: DecoratedBox(
          decoration: BoxDecoration(color: _p.blue700.withValues(alpha: .18), borderRadius: BorderRadius.circular(3)),
        ),
      ),
      for (var i = 0; i < lines.length; i++)
        Positioned(
          left: 12,
          top: top0 + i * lineH,
          height: lineH,
          child: Align(
            alignment: Alignment.centerLeft,
            child: Text(lines[i], maxLines: 1, softWrap: false, overflow: TextOverflow.clip, style: _text(6, 8.5, FontWeight.w500, _p.gray1000, ls: 0)),
          ),
        ),
      // 선택 핸들 두 개
      if (sel > 0) ...[
        Positioned(left: 5, top: top0 - 4, child: _handle()),
        Positioned(left: 8 + 152, top: top0 + lineH * lines.length * sel - 2, child: _handle()),
      ],
      Positioned(left: 12, top: 108, child: _bar(120, 4, _p.gray300)),
      Positioned(left: 12, top: 117, child: _bar(88, 4, _p.gray300)),
      // '복사' 말풍선
      if (bubble > 0)
        Positioned(
          left: 68,
          top: top0 - 24,
          child: Opacity(
            opacity: bubble,
            child: Transform.translate(
              offset: Offset(0, 3 * (1 - bubble)),
              child: Stack(clipBehavior: Clip.none, children: [
                // 꼬리는 말풍선 가운데 아래에 달려요
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: -3,
                  child: Center(
                    child: Transform.rotate(
                      angle: .785398,
                      child: Container(width: 6, height: 6, color: Color.lerp(_p.gray800, _p.gray900, bubblePress)),
                    ),
                  ),
                ),
                Container(
                  height: 16,
                  padding: const EdgeInsets.symmetric(horizontal: 5),
                  alignment: Alignment.center,
                  decoration: BoxDecoration(color: Color.lerp(_p.gray800, _p.gray900, bubblePress), borderRadius: BorderRadius.circular(6)),
                  child: Text(_tr('복사'), style: _text(7, 9, FontWeight.w700, _p.onSolid)),
                ),
              ]),
            ),
          ),
        ),
      // 복사 완료 토스트
      if (toast > 0)
        // 다른 요소와 같은 좌우 여백(9)을 두고 그 안을 꽉 채워요. 바탕색은 한 단계 낮춤(gray900 → gray800)
        Positioned(
          left: 9,
          right: 9,
          top: 106,
          child: Opacity(
            opacity: toast,
            child: Container(
              height: 16,
              alignment: Alignment.center,
              decoration: BoxDecoration(color: _p.gray800, borderRadius: BorderRadius.circular(999)),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                Icon(Icons.check_rounded, size: 8, color: _p.onSolid),
                const SizedBox(width: 3),
                Text(_tr('복사했어요'), style: _text(6.5, 9, FontWeight.w600, _p.onSolid, ls: 0)),
              ]),
            ),
          ),
        ),
    ]);
  }

  // ── 3단계 방법 2: 복사 아이콘 누르기 ───────────────────────
  Widget _sceneCopyIcon() {
    final tip = _ramp(9.8, 0.25) * (1 - _ramp(10.6, 0.2));
    final press = _pulse(10.3, 0.3, 0.2);
    final done = _ramp(10.55, 0.25);
    final toast = _ramp(10.75, 0.2) * (1 - _ramp(11.6, 0.1));
    const lines = ['[00:13.04] You can count on me', "[00:16.52] I'll be there", '[00:18.11] And I know when I need it'];
    const lineH = 12.0, top0 = 64.0;

    return Stack(clipBehavior: Clip.none, children: [
      Positioned(left: 12, top: 30, child: Text('Count On Me', style: _text(9, 12, FontWeight.w700, _p.gray1000))),
      Positioned(left: 12, top: 46, child: _bar(70, 4, _p.gray300)),
      for (var i = 0; i < lines.length; i++)
        Positioned(
          left: 12,
          top: top0 + i * lineH,
          height: lineH,
          child: Align(
            alignment: Alignment.centerLeft,
            child: Text(lines[i], maxLines: 1, softWrap: false, overflow: TextOverflow.clip, style: _text(6, 8.5, FontWeight.w500, _p.gray1000, ls: 0)),
          ),
        ),
      Positioned(left: 12, top: 108, child: _bar(120, 4, _p.gray300)),
      Positioned(left: 12, top: 117, child: _bar(88, 4, _p.gray300)),
      // 복사 아이콘 버튼: 눌리면 체크로 바뀌어요
      Positioned(
        right: 9,
        top: 40,
        child: Transform.scale(
          scale: 1 - .1 * press,
          child: Container(
            width: 14,
            height: 14,
            decoration: BoxDecoration(color: Color.lerp(_p.gray200, _p.gray400, press), shape: BoxShape.circle),
            child: Stack(alignment: Alignment.center, children: [
              Opacity(opacity: 1 - done, child: CustomPaint(size: const Size(9, 9), painter: _CopyIconPainter(_p.gray800))),
              Opacity(opacity: done, child: Icon(Icons.check_rounded, size: 9, color: _p.gray800)),
            ]),
          ),
        ),
      ),
      // '복사' 툴팁: 아이콘 아래 가운데
      if (tip > 0)
        Positioned(
          right: 9 + 7,
          top: 58,
          child: FractionalTranslation(
            translation: const Offset(.5, 0),
            child: Opacity(
              opacity: tip,
              child: Transform.translate(offset: Offset(0, -2 * (1 - tip)), child: _tooltip(_tr('복사'))),
            ),
          ),
        ),
      if (toast > 0)
        // 다른 요소와 같은 좌우 여백(9)을 두고 그 안을 꽉 채워요. 바탕색은 한 단계 낮춤(gray900 → gray800)
        Positioned(
          left: 9,
          right: 9,
          top: 106,
          child: Opacity(
            opacity: toast,
            child: Container(
              height: 16,
              alignment: Alignment.center,
              decoration: BoxDecoration(color: _p.gray800, borderRadius: BorderRadius.circular(999)),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                Icon(Icons.check_rounded, size: 8, color: _p.onSolid),
                const SizedBox(width: 3),
                Text(_tr('복사했어요'), style: _text(6.5, 9, FontWeight.w600, _p.onSolid, ls: 0)),
              ]),
            ),
          ),
        ),
    ]);
  }

  Widget _handle() => Container(
        width: 6,
        height: 6,
        decoration: BoxDecoration(color: _p.blue700, shape: BoxShape.circle),
      );

  Widget _tooltip(String text) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
        decoration: BoxDecoration(
          color: _p.gray900,
          borderRadius: BorderRadius.circular(4),
          boxShadow: const [BoxShadow(color: Color(0x29000000), blurRadius: 6, offset: Offset(0, 2))],
        ),
        child: Text(text, style: _text(6.5, 9, FontWeight.w600, _p.onSolid, ls: 0)),
      );

  Widget _bar(double w, double h, Color color) =>
      Container(width: w, height: h, decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(h / 2)));
}

/// 복사 아이콘: 겹친 두 사각형을 얇은 선으로 (api_key_guide_graphic.dart와 같은 모양)
class _CopyIconPainter extends CustomPainter {
  const _CopyIconPainter(this.color);

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final u = size.width / 24;
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.6 * u
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    canvas.drawRRect(RRect.fromLTRBR(8 * u, 3 * u, 19 * u, 18 * u, Radius.circular(2 * u)), paint);
    final back = Path()
      ..moveTo(5 * u, 7 * u)
      ..lineTo(5 * u, 19 * u)
      ..arcToPoint(Offset(7 * u, 21 * u), radius: Radius.circular(2 * u), clockwise: false)
      ..lineTo(16 * u, 21 * u);
    canvas.drawPath(back, paint);
  }

  @override
  bool shouldRepaint(_CopyIconPainter old) => old.color != color;
}
