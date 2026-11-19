import 'package:flutter/material.dart';

/// API 키 발급 안내 그래픽 (00-2 온보딩 · 키 발급 안내).
///
/// 디자인 시안(HTML 프로토타입)을 그대로 옮긴 위젯이에요. 앱의 00-2 화면에서 제목과 단계 목록 사이에 둬요.
/// - 디자인 좌표: 375 × 248 영역. 폭에 맞춰 비율 그대로 늘거나 줄어요.
/// - 10초 반복: 1단계 로그인(0–3.6s) → 2단계 키 복사(3.6–7.2s) → 3단계 붙여넣기(7.2–10s)
/// - 모든 상태는 시간 t(초)만으로 계산해요. 타이머를 쓰지 않아서 어느 시점이든 같은 화면이 나와요.
/// - 시스템 '동작 줄이기'가 켜져 있으면 확대 없이 장면만 바뀌어요.
///
/// 사용 예:
/// ```dart
/// ApiKeyGuideGraphic(background: context.theme.background, fontFamily: AppTheme.fontFamilyOverride)
/// ```
/// 색은 [_Palette]에 피그마 Color 토큰(라이트/다크) 값으로 들어 있어요.
class ApiKeyGuideGraphic extends StatefulWidget {
  const ApiKeyGuideGraphic({super.key, this.background, this.brightness, this.fontFamily, this.speed = 1.0, this.playing = true, this.seekTo});

  /// 그래픽 영역 바탕색. 비우면 bg/layer/basement. 아래 40px이 이 색으로 사라져요.
  final Color? background;

  /// 라이트/다크. 비우면 앱 테마(Theme.of(context).brightness)를 따라요.
  final Brightness? brightness;

  /// 서체. 비우면 기기 기본 서체예요. 앱에서는 AppTheme.fontFamilyOverride를 넘겨요.
  final String? fontFamily;

  /// 재생 속도 배율 (1.0 = 원래 속도, 0.5 = 느리게).
  final double speed;
  final bool playing;

  /// 값이 바뀌면 그 시점(초)으로 이동해요. 미리보기에서 단계 이동용.
  final double? seekTo;

  /// 한 바퀴 길이(초)
  static const double loopSeconds = 10.0;

  @override
  State<ApiKeyGuideGraphic> createState() => _ApiKeyGuideGraphicState();
}

/// 피그마 Color 토큰. 라이트/다크 두 벌이고, 다크는 피그마 Color 컬렉션 Dark 모드 값이에요.
/// 회색 단계를 그대로 뒤집어 대응시켜요 (gray/200→bg/layer/default, gray/1000→fg/neutral/base 등).
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

class _ApiKeyGuideGraphicState extends State<ApiKeyGuideGraphic> with SingleTickerProviderStateMixin {
  late final AnimationController _c;
  double _t = 0; // 현재 시점(초)
  _Palette _p = _Palette.light;
  Duration? _last;

  @override
  void initState() {
    super.initState();
    _t = widget.seekTo ?? 0;
    // 실제 시간은 Ticker로 받고, 속도 배율을 곱해 t를 직접 진행시켜요.
    _c = AnimationController(vsync: this, duration: const Duration(days: 1))
      ..addListener(_tick)
      ..forward();
  }

  void _tick() {
    final now = _c.lastElapsedDuration ?? Duration.zero;
    final dt = _last == null ? 0.0 : (now - _last!).inMicroseconds / 1e6;
    _last = now;
    if (!widget.playing) return;
    setState(() => _t = (_t + dt * widget.speed) % ApiKeyGuideGraphic.loopSeconds);
  }

  @override
  void didUpdateWidget(ApiKeyGuideGraphic old) {
    super.didUpdateWidget(old);
    if (widget.seekTo != null && widget.seekTo != old.seekTo) _t = widget.seekTo!;
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  // ── 시간 → 값 도우미 ─────────────────────────────
  /// start부터 dur초 동안 0→1 (이징 적용)
  double _ramp(double start, double dur, [Curve curve = _easeOut]) => curve.transform(((_t - start) / dur).clamp(0.0, 1.0));

  /// start에 켜져서 hold초 유지 후 꺼지는 값 (켜짐·꺼짐 각각 dur초)
  double _pulse(double start, double hold, double dur) => _ramp(start, dur) * (1 - _ramp(start + hold, dur));

  /// 장면 k의 불투명도. 장면 전환은 300ms 교차 페이드.
  static const _starts = [0.0, 1.8, 3.6, 7.2];
  static const _ends = [1.8, 3.6, 7.2, 10.0];
  double _scene(int k) {
    if (k == 3 && _t < 0.3) return 1 - _ramp(0, 0.3); // 반복 시작 때 마지막 장면이 사라짐
    return _ramp(_starts[k], 0.3) * (1 - _ramp(_ends[k], 0.3));
  }

  TextStyle _text(double size, double height, FontWeight w, Color color, {double? ls}) =>
      TextStyle(fontFamily: widget.fontFamily, fontSize: size, height: height / size, fontWeight: w, color: color, letterSpacing: ls ?? size * -0.02);

  @override
  Widget build(BuildContext context) {
    final reduceMotion = MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    final dark = (widget.brightness ?? Theme.of(context).brightness) == Brightness.dark;
    _p = dark ? _Palette.dark : _Palette.light;
    final bg = widget.background ?? _p.gray00;

    // 실루엣 변환: 평소 1.4배, 2단계에서 복사 버튼 줄로 2.2배 확대 (전체에서 한 번)
    const base = 1.4, zoomS = 2.2;
    const dl = 99.0, dt = 10.0, cx = 187.5, cy = 104.0;
    const bx = (375 - 176 * base) / 2 - dl, by = 0.0;
    const zx = cx - dl - zoomS * 88, zy = cy - dt - zoomS * 94;
    final z = reduceMotion ? 0.0 : _ramp(4.2, 0.7, _easeInOut) * (1 - _ramp(6.4, 0.7, _easeInOut));
    final s = base + (zoomS - base) * z;
    final tx = bx + (zx - bx) * z, ty = by + (zy - by) * z;

    return Semantics(
      label: 'Google AI Studio에 로그인하고, API 키 목록에서 복사 버튼을 누른 뒤, 앱에서 붙여넣는 과정을 보여주는 그래픽',
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
                          child: Transform(transform: Matrix4.translationValues(tx, ty, 0)..scaleByDouble(s, s, 1, 1), child: _device()),
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
          child: Container(
            width: 40,
            height: 10,
            decoration: BoxDecoration(color: _p.gray400, borderRadius: BorderRadius.circular(6)),
          ),
        ),
        _fade(0, _sceneLanding()),
        _fade(1, _sceneAccount()),
        _fade(2, _sceneKeys()),
        _fade(3, _scenePaste()),
      ],
    ),
  );

  Widget _fade(int k, Widget child) {
    final o = _scene(k);
    if (o <= 0) return const SizedBox.shrink();
    return Positioned.fill(
      child: Opacity(
        opacity: o,
        child: Stack(clipBehavior: Clip.none, children: [child]),
      ),
    );
  }

  // ── 1단계-a: AI Studio 첫 화면, 'Get started' 눌림 ─────────
  Widget _sceneLanding() {
    final p = _pulse(0.9, 0.26, 0.15);
    return Stack(
      clipBehavior: Clip.none,
      children: [
        Positioned(left: 10, top: 32, child: Image.asset('assets/onboarding/ai_studio_lockup.png', width: 62, color: _p.gray1000)),
        Positioned(
          right: 10,
          top: 30,
          child: Transform.scale(
            scale: 1 - .1 * p,
            child: Container(
              height: 16,
              padding: const EdgeInsets.symmetric(horizontal: 7),
              decoration: BoxDecoration(color: Color.lerp(_p.gray1000, _p.gray800, p), borderRadius: BorderRadius.circular(999)),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.login_rounded, size: 6, color: _p.onSolid),
                  const SizedBox(width: 3),
                  Text('Get started', style: _text(7, 9, FontWeight.w700, _p.onSolid, ls: 0)),
                ],
              ),
            ),
          ),
        ),
        Positioned(
          left: 0,
          right: 0,
          top: 62,
          child: Text(
            'Build with\nGoogle AI Studio',
            textAlign: TextAlign.center,
            style: _text(12, 15, FontWeight.w700, _p.gray1000, ls: 12 * -0.03),
          ),
        ),
        Positioned(left: 34, top: 104, child: _bar(100, 6, _p.gray300)),
      ],
    );
  }

  // ── 1단계-b: 구글 계정 선택, 첫 계정 눌림 ─────────────────
  Widget _sceneAccount() {
    final p = _pulse(2.7, 0.26, 0.15);
    return Stack(
      clipBehavior: Clip.none,
      children: [
        Positioned(left: 12, top: 32, child: Image.asset('assets/onboarding/google_g.png', width: 16, height: 16)),
        Positioned(left: 12, top: 52, child: Text('계정을 선택하세요.', style: _text(11, 14, FontWeight.w700, _p.gray1000))),
        Positioned(
          left: 8,
          right: 8,
          top: 74,
          height: 30,
          child: Stack(
            children: [
              Positioned.fill(
                child: Transform.scale(
                  scale: 1 - .03 * p,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 6),
                    decoration: BoxDecoration(color: Color.lerp(_p.gray00, _p.gray200, p), borderRadius: BorderRadius.circular(8)),
                    child: Row(
                      children: [
                        Container(
                          width: 16,
                          height: 16,
                          decoration: BoxDecoration(color: _p.gray400, shape: BoxShape.circle),
                        ),
                        const SizedBox(width: 8),
                        Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [_bar(48, 6, _p.gray400), const SizedBox(height: 4), _bar(70, 5, _p.gray300)],
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              // 구분선은 둥근 모서리를 따라 휘지 않도록 따로 그린 직선
              Positioned(left: 4, right: 4, bottom: 0, height: 1, child: ColoredBox(color: _p.gray300)),
            ],
          ),
        ),
        Positioned(
          left: 14,
          top: 106,
          height: 30,
          child: Row(
            children: [
              Icon(Icons.account_circle_outlined, size: 12, color: _p.gray700),
              const SizedBox(width: 8),
              Text('다른 계정 사용', style: _text(6.5, 9, FontWeight.w600, _p.gray800)),
            ],
          ),
        ),
      ],
    );
  }

  // ── 2단계: API 키 목록, 첫 키의 복사 버튼 ─────────────────
  Widget _sceneKeys() {
    final press = _pulse(5.4, 0.35, 0.25);
    final done = _ramp(5.65, 0.3);
    final tip = _ramp(4.9, 0.25) * (1 - _ramp(6.3, 0.2));
    const rowW = 176.0 - 8 - 20; // 실루엣 안쪽 폭 - 좌우 여백
    const actsW = 14.0 + 4 * 12 + 4 * 3; // 복사 버튼 + 아이콘 4개 + 간격
    const copyCenterX = rowW - actsW + 7;

    Widget keyRow({required double top, required String key, required String name, required bool live}) => Positioned(
      left: 10,
      top: top,
      width: rowW,
      height: 30,
      child: Opacity(
        opacity: live ? 1 : .4,
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            Positioned(left: 0, right: 0, top: 0, height: 1, child: ColoredBox(color: _p.gray300)),
            Positioned.fill(
              child: Row(
                children: [
                  Flexible(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(key, maxLines: 1, softWrap: false, overflow: TextOverflow.clip, style: _text(8, 11, FontWeight.w700, _p.blue700, ls: 0)),
                        Text(name, maxLines: 1, softWrap: false, overflow: TextOverflow.clip, style: _text(6.5, 9, FontWeight.w400, _p.gray700)),
                      ],
                    ),
                  ),
                  const Spacer(),
                  if (live) ...[
                    // 실제 사이트처럼 아이콘 5개 중 첫 번째가 복사
                    Transform.scale(
                      scale: 1 - .1 * press,
                      child: Container(
                        width: 14,
                        height: 14,
                        decoration: BoxDecoration(color: Color.lerp(_p.gray00, _p.gray300, press), shape: BoxShape.circle),
                        child: Stack(
                          alignment: Alignment.center,
                          children: [
                            Opacity(
                              opacity: 1 - done,
                              child: Transform.scale(
                                scale: 1 - .4 * done,
                                child: CustomPaint(size: const Size(9, 9), painter: _CopyIconPainter(_p.gray800)),
                              ),
                            ),
                            Opacity(
                              opacity: done,
                              child: Transform.scale(
                                scale: .6 + .4 * done,
                                child: Icon(Icons.check_rounded, size: 9, color: _p.gray800),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    // 나머지 아이콘 4개 자리는 연한 선 하나로
                    const SizedBox(width: 6),
                    SizedBox(
                      width: actsW - 14 - 6,
                      height: 12,
                      child: Center(child: _bar(actsW - 14 - 6, 3, _p.gray200)),
                    ),
                  ] else
                    const SizedBox(width: actsW),
                ],
              ),
            ),
            // 'API 키 복사' 툴팁: 아이콘 아래 4px, 위에서 살짝 커지며 등장
            if (live && tip > 0)
              Positioned(
                left: copyCenterX,
                top: 8 + 14 + 4,
                child: FractionalTranslation(
                  translation: const Offset(-.5, 0),
                  child: Opacity(
                    opacity: tip,
                    child: Transform.translate(
                      offset: Offset(0, -2 * (1 - tip)),
                      child: Transform.scale(
                        scale: .92 + .08 * tip,
                        alignment: Alignment.topCenter,
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
                          decoration: BoxDecoration(
                            color: _p.gray900,
                            borderRadius: BorderRadius.circular(4),
                            boxShadow: const [BoxShadow(color: Color(0x29000000), blurRadius: 6, offset: Offset(0, 2))],
                          ),
                          child: Text('API 키 복사', style: _text(6.5, 9, FontWeight.w600, _p.onSolid, ls: 0)),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );

    return Stack(
      clipBehavior: Clip.none,
      children: [
        Positioned(left: 12, top: 28, child: Image.asset('assets/onboarding/ai_studio_lockup.png', width: 72, color: _p.gray1000)),
        Positioned(
          left: 12,
          right: 12,
          top: 53,
          child: Row(
            children: [
              Text('API 키', style: _text(7, 10, FontWeight.w600, _p.gray1000)),
              const Spacer(),
              // 'API 키 만들기' 버튼도 스켈레톤으로
              _bar(40, 11, _p.gray300),
            ],
          ),
        ),
        keyRow(top: 108, key: '…m2Lp', name: 'Default Gemini API Key', live: false),
        keyRow(top: 68, key: '…x7Qa', name: 'Gemini API Key', live: true),
      ],
    );
  }

  // ── 3단계: 앱의 키 입력 화면(피그마 00-3), 붙여넣기 ───────
  Widget _scenePaste() {
    final bubble = _ramp(7.9, 0.18) * (1 - _ramp(8.5, 0.18));
    final bubblePress = _pulse(8.4, 0.15, 0.15);
    final filled = _ramp(8.5, 0.2);
    final active = _ramp(8.5, 0.25);
    return Stack(
      clipBehavior: Clip.none,
      children: [
        Positioned(left: 12, top: 32, child: Text('복사한 API 키를\n붙여넣어 주세요', style: _text(11, 14, FontWeight.w700, _p.gray1000))),
        Positioned(left: 12, top: 74, child: Text('Gemini API 키', style: _text(6.5, 9, FontWeight.w600, _p.gray800))),
        Positioned(
          left: 12,
          right: 12,
          top: 87,
          height: 26,
          child: Container(
            padding: const EdgeInsets.only(left: 8, right: 6),
            decoration: BoxDecoration(
              color: _p.gray00,
              borderRadius: BorderRadius.circular(6),
              border: Border.all(color: Color.lerp(_p.gray400, _p.gray1000, filled)!, width: 1),
            ),
            child: Stack(
              alignment: Alignment.centerLeft,
              children: [
                Opacity(
                  opacity: 1 - (filled > 0 ? 1 : 0),
                  child: Text('API 키 입력', style: _text(7, 9, FontWeight.w400, _p.gray600, ls: 0)),
                ),
                // 키는 한 번에 들어와요 (타이핑 없음)
                Opacity(
                  opacity: filled,
                  child: Row(
                    children: [
                      Text('••••••••••••••', style: _text(7, 9, FontWeight.w700, _p.gray1000, ls: 1)),
                      const Spacer(),
                      Container(
                        width: 9,
                        height: 9,
                        decoration: BoxDecoration(color: _p.gray700, shape: BoxShape.circle),
                        child: Icon(Icons.close_rounded, size: 6, color: _p.gray00),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
        Positioned(
          left: 12,
          right: 12,
          top: 119,
          height: 22,
          child: Container(
            alignment: Alignment.center,
            decoration: BoxDecoration(color: Color.lerp(_p.gray200, _p.gray1000, active), borderRadius: BorderRadius.circular(7)),
            child: Text('API 키 연결하기', style: _text(7, 9, FontWeight.w700, Color.lerp(_p.gray500, _p.onSolid, active)!)),
          ),
        ),
        // iOS '붙여넣기' 말풍선: 바탕은 bg/neutral/muted(gray/800), 눌리면 gray/900
        if (bubble > 0)
          Positioned(
            left: 20,
            top: 65,
            child: Opacity(
              opacity: bubble,
              child: Transform.translate(
                offset: Offset(0, 3 * (1 - bubble)),
                child: Stack(
                  clipBehavior: Clip.none,
                  children: [
                    Positioned(
                      left: 12,
                      bottom: -3,
                      child: Transform.rotate(
                        angle: .785398,
                        child: Container(width: 6, height: 6, color: Color.lerp(_p.gray800, _p.gray900, bubblePress)),
                      ),
                    ),
                    Container(
                      height: 16,
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      alignment: Alignment.center,
                      decoration: BoxDecoration(color: Color.lerp(_p.gray800, _p.gray900, bubblePress), borderRadius: BorderRadius.circular(6)),
                      child: Text('붙여넣기', style: _text(7, 9, FontWeight.w700, _p.onSolid)),
                    ),
                  ],
                ),
              ),
            ),
          ),
      ],
    );
  }

  Widget _bar(double w, double h, Color color) => Container(
    width: w,
    height: h,
    decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(h / 2)),
  );
}

/// 복사 아이콘: 겹친 두 사각형을 얇은 선(gray/800)으로. 머티리얼 아이콘보다 가볍게 보이도록 직접 그려요.
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
