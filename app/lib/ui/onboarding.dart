import 'package:flutter/material.dart' hide Route;
import 'package:flutter/services.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:sign_in_with_apple/sign_in_with_apple.dart';

import '../app/account.dart';
import '../app/app_model.dart';
import '../app/i18n.dart';
import '../app/platform_services.dart';
import '../app/theme.dart';
import '../core/llm.dart';
import 'components.dart';

// Figma "00 온보딩" (런처 아이콘 section) and "온보딩 - API 키 연결" (00-1 to 00-4):
// start → sign in → what the AI does → how to get a Gemini key → paste it → connected.

/// The first-run flow. Finishing or skipping it sets [AppSettings.hasOnboarded].
class OnboardingFlow extends StatefulWidget {
  const OnboardingFlow({super.key});
  @override
  State<OnboardingFlow> createState() => _OnboardingFlowState();
}

class _OnboardingFlowState extends State<OnboardingFlow> {
  final _nav = GlobalKey<NavigatorState>();

  void _push(Widget page) => _nav.currentState!.push(MaterialPageRoute(builder: (_) => page));

  void _finish() => context.readModel.updateSettings((s) => s.hasOnboarded = true);

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && (_nav.currentState?.canPop() ?? false)) _nav.currentState!.pop();
      },
      child: Navigator(
        key: _nav,
        onGenerateRoute: (_) => MaterialPageRoute(
          builder: (_) => OnboardingStart(onSignedIn: () => _push(_aiIntro()), onSkip: () => _push(_aiIntro())),
        ),
      ),
    );
  }

  Widget _aiIntro() => OnboardingAIIntro(onConnect: () => _push(_keyGuide()), onLater: _finish);

  Widget _keyGuide() => OnboardingKeyGuide(onHaveKey: () => _push(_keyEntry()));

  Widget _keyEntry() => OnboardingKeyEntry(onConnected: () => _push(OnboardingConnected(onStart: _finish)));
}

// ─────────────── 00 시작 ───────────────

class OnboardingStart extends StatefulWidget {
  final VoidCallback onSignedIn;
  final VoidCallback onSkip;
  const OnboardingStart({super.key, required this.onSignedIn, required this.onSkip});
  @override
  State<OnboardingStart> createState() => _OnboardingStartState();
}

class _OnboardingStartState extends State<OnboardingStart> {
  bool _busy = false;

  Future<void> _signIn(Future<void> Function() signIn) async {
    setState(() => _busy = true);
    final model = context.readModel;
    try {
      await signIn();
      if (mounted && model.account != null) widget.onSignedIn();
    } on GoogleSignInException catch (e) {
      if (mounted) showMessage(context, tr('Google 로그인에 실패했어요: {0}', [e.description ?? e.code.name]));
    } on SignInWithAppleException catch (e) {
      if (mounted) showMessage(context, tr('Apple 로그인에 실패했어요: {0}', ['$e']));
    } on AccountApiException catch (e) {
      if (mounted) showMessage(context, tr('로그인하지 못했어요: {0}', ['$e']));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = context.theme;
    final model = context.model;
    final dark = t.isDark;
    // Figma: the first button is filled (black on light, white on dark), the second outlined.
    final filled = ButtonStyle(
      backgroundColor: WidgetStatePropertyAll(dark ? Colors.white : const Color(0xFF1B1C1F)),
      foregroundColor: WidgetStatePropertyAll(dark ? Colors.black : Colors.white),
      shape: const WidgetStatePropertyAll(StadiumBorder()),
      minimumSize: const WidgetStatePropertyAll(Size.fromHeight(48)),
      textStyle: const WidgetStatePropertyAll(TextStyle(fontSize: 15, fontWeight: FontWeight.w500)),
    );
    final outlined = ButtonStyle(
      foregroundColor: WidgetStatePropertyAll(t.textPrimary),
      side: WidgetStatePropertyAll(BorderSide(color: t.textPrimary)),
      shape: const WidgetStatePropertyAll(StadiumBorder()),
      minimumSize: const WidgetStatePropertyAll(Size.fromHeight(48)),
      textStyle: const WidgetStatePropertyAll(TextStyle(fontSize: 15, fontWeight: FontWeight.w500)),
    );
    final buttons = <Widget>[
      if (model.appleAvailable)
        FilledButton.icon(
          onPressed: _busy ? null : () => _signIn(model.signInApple),
          style: filled,
          icon: const Icon(Icons.apple, size: 22),
          label: Text(tr('Apple로 시작하기')),
        ),
      if (model.googleAvailable)
        (model.appleAvailable ? OutlinedButton.icon : FilledButton.icon)(
          onPressed: _busy ? null : () => _signIn(model.signInGoogle),
          style: model.appleAvailable ? outlined : filled,
          icon: const _GoogleMark(),
          label: Text(tr('Google로 시작하기')),
        ),
    ];
    return Scaffold(
      backgroundColor: dark ? Colors.black : Colors.white,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: SizedBox(
            width: double.infinity,
            child: Column(children: [
            const Spacer(flex: 3),
            ClipRRect(
              borderRadius: BorderRadius.circular(22),
              child: Image.asset('assets/brand/app_icon.png', width: 96, height: 96, semanticLabel: 'Vinylo'),
            ),
            const SizedBox(height: 28),
            Text('Vinylo', style: TextStyle(fontSize: 28, fontWeight: FontWeight.w500, letterSpacing: -0.4, color: t.textPrimary)),
            const SizedBox(height: 10),
            Text('SPIN IT. READ IT. KEEP IT.', style: TextStyle(fontSize: 12, letterSpacing: 0.2, color: t.textSecondary)),
            const Spacer(flex: 4),
            for (final b in buttons) ...[b, const SizedBox(height: 10)],
            // Without a sign-in option in this build (no client ID yet), or for users who want to
            // look around first: everything except the account works without signing in.
            if (buttons.isEmpty)
              FilledButton(onPressed: widget.onSkip, style: filled, child: Text(tr('시작하기')))
            else
              TextButton(
                onPressed: _busy ? null : widget.onSkip,
                style: TextButton.styleFrom(foregroundColor: t.textSecondary),
                child: Text(tr('로그인 없이 둘러보기')),
              ),
            const SizedBox(height: 24),
            ]),
          ),
        ),
      ),
    );
  }
}

/// The Google "G" in its four colours.
class _GoogleMark extends StatelessWidget {
  const _GoogleMark();
  @override
  Widget build(BuildContext context) => SizedBox(width: 20, height: 20, child: CustomPaint(painter: _GooglePainter()));
}

class _GooglePainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final s = size.width;
    final stroke = s * 0.2;
    final rect = Rect.fromCircle(center: Offset(s / 2, s / 2), radius: s / 2 - stroke / 2);
    Paint p(Color c) => Paint()
      ..color = c
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke;
    const deg = 3.14159265 / 180;
    canvas.drawArc(rect, -40 * deg, -100 * deg, false, p(const Color(0xFFEA4335)));
    canvas.drawArc(rect, -140 * deg, -90 * deg, false, p(const Color(0xFFFBBC05)));
    canvas.drawArc(rect, 130 * deg, -90 * deg, false, p(const Color(0xFF34A853)));
    canvas.drawArc(rect, 40 * deg, -40 * deg, false, p(const Color(0xFF4285F4)));
    canvas.drawRect(Rect.fromLTWH(s / 2, s / 2 - stroke / 2, s / 2, stroke), Paint()..color = const Color(0xFF4285F4));
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

// ─────────────── shared layout ───────────────

class _Step extends StatelessWidget {
  final String title;
  final String? subtitle;
  final List<Widget> body;
  final Widget? primary;
  final Widget? secondary;
  const _Step({required this.title, this.subtitle, this.body = const [], this.primary, this.secondary});

  @override
  Widget build(BuildContext context) {
    final t = context.theme;
    return Scaffold(
      backgroundColor: t.background,
      appBar: AppBar(
        backgroundColor: t.background,
        elevation: 0,
        automaticallyImplyLeading: false,
        leading: Navigator.of(context).canPop()
            ? IconButton(tooltip: tr('뒤로'), icon: const Icon(Icons.chevron_left, size: 30), onPressed: () => Navigator.pop(context))
            : null,
      ),
      body: SafeArea(
        top: false,
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Expanded(
            child: ListView(padding: const EdgeInsets.fromLTRB(16, 8, 16, 16), children: [
              Text(title, style: TextStyle(fontSize: 24, height: 32 / 24, fontWeight: FontWeight.w600, letterSpacing: -0.5, color: t.textPrimary)),
              if (subtitle != null) ...[
                const SizedBox(height: 6),
                Text(subtitle!, style: TextStyle(fontSize: 14, color: t.textTertiary)),
              ],
              const SizedBox(height: 28),
              ...body,
            ]),
          ),
          if (primary != null) Padding(padding: const EdgeInsets.fromLTRB(16, 0, 16, 4), child: primary),
          if (secondary != null) Padding(padding: const EdgeInsets.symmetric(horizontal: 16), child: secondary),
          const SizedBox(height: 12),
        ]),
      ),
    );
  }
}

Widget _textAction(BuildContext context, String label, VoidCallback onPressed) {
  final t = context.theme;
  return SizedBox(
    height: 44,
    child: TextButton(
      onPressed: onPressed,
      style: TextButton.styleFrom(foregroundColor: t.textSecondary, textStyle: const TextStyle(fontSize: 15)),
      child: Text(label),
    ),
  );
}

// ─────────────── 00-1 가사 속 표현을 AI가 알려줘요 ───────────────

class OnboardingAIIntro extends StatelessWidget {
  final VoidCallback onConnect;
  final VoidCallback onLater;
  const OnboardingAIIntro({super.key, required this.onConnect, required this.onLater});

  @override
  Widget build(BuildContext context) {
    final t = context.theme;
    return _Step(
      title: tr('가사 속 표현을\nAI가 알려줘요'),
      subtitle: tr('Google 무료 API 키를 연결해보세요'),
      body: [
        // The example card from Figma: a lyric line, its translation, and one explained expression.
        Container(
          padding: const EdgeInsets.fromLTRB(16, 18, 16, 18),
          decoration: BoxDecoration(
            color: t.surfaceRaised,
            borderRadius: BorderRadius.circular(12),
            boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.08), blurRadius: 16, offset: const Offset(0, 4))],
          ),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Expanded(
                child: Text("We're running late,\nbut that's on brand",
                    style: TextStyle(fontSize: 15, height: 1.35, fontWeight: FontWeight.w500, color: t.textPrimary)),
              ),
              Icon(Icons.star_rounded, color: t.brand, size: 22),
            ]),
            const SizedBox(height: 8),
            Text(tr('늦었지만, 원래 우리 스타일이잖아'), style: TextStyle(fontSize: 12, color: t.textSecondary)),
            Padding(padding: const EdgeInsets.symmetric(vertical: 14), child: Divider(height: 1, color: t.stroke)),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(color: t.marker, borderRadius: BorderRadius.circular(4)),
              child: Text('on brand', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w500, color: t.brandInk)),
            ),
            const SizedBox(height: 8),
            Text(tr("'딱 나답다'는 뜻이에요. 나다운 행동을 가볍게 말할 때 써요."), style: TextStyle(fontSize: 13, height: 1.45, color: t.textSecondary)),
          ]),
        ),
      ],
      primary: PrimaryButton(tr('API 키 연결하기'), onPressed: onConnect),
      secondary: _textAction(context, tr('나중에 할게요'), onLater),
    );
  }
}

// ─────────────── 00-2 API 키를 복사해 주세요 ───────────────

class OnboardingKeyGuide extends StatelessWidget {
  final VoidCallback onHaveKey;
  const OnboardingKeyGuide({super.key, required this.onHaveKey});

  static final studio = Uri.parse('https://aistudio.google.com/app/apikey');

  @override
  Widget build(BuildContext context) {
    final t = context.theme;
    Widget step(int n, String title, String sub) => Padding(
          padding: const EdgeInsets.only(bottom: 20),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Container(
              width: 20,
              height: 20,
              alignment: Alignment.center,
              decoration: BoxDecoration(color: t.surface, shape: BoxShape.circle),
              child: Text('$n', style: TextStyle(fontSize: 11, color: t.textSecondary)),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(title, style: TextStyle(fontSize: 15, fontWeight: FontWeight.w500, color: t.textPrimary)),
                const SizedBox(height: 4),
                Text(sub, style: TextStyle(fontSize: 12, color: t.textTertiary)),
              ]),
            ),
          ]),
        );
    return _Step(
      title: tr('API 키를\n복사해 주세요'),
      body: [
        step(1, tr('Google AI Studio에 로그인해요'), tr('이미 있는 Google 계정으로 사용할 수 있어요')),
        step(2, tr('목록에서 API 키를 복사해요'), tr("키가 없다면 'API 키 만들기'를 눌러요")),
        step(3, tr('키를 복사해서 돌아와요'), tr('다음 화면에서 붙여넣기만 하면 끝나요')),
        const SizedBox(height: 4),
        Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(color: t.surface, borderRadius: BorderRadius.circular(10)),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(tr('무료로 쓸 수 있나요?'), style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: t.textPrimary)),
            const SizedBox(height: 6),
            Text(tr('결제 정보를 등록하지 않으면 요금이 나가지 않아요.\n하루 사용량은 Google 정책에 따라 달라질 수 있어요.'),
                style: TextStyle(fontSize: 12, height: 1.5, color: t.textSecondary)),
          ]),
        ),
      ],
      primary: PrimaryButton(tr('Google AI Studio 열기'), icon: Icons.north_east, onPressed: () => _openStudio(context)),
      secondary: _textAction(context, tr('이미 키가 있어요'), onHaveKey),
    );
  }

  /// Google blocks its sign-in inside embedded web views, so AI Studio opens in the browser. On
  /// return the user goes on to paste the key.
  Future<void> _openStudio(BuildContext context) async {
    try {
      await Links.open(studio);
    } catch (_) {
      if (context.mounted) showMessage(context, tr('브라우저를 열지 못했어요.'));
      return;
    }
    if (context.mounted) onHaveKey();
  }
}

// ─────────────── 00-3 복사한 API 키를 붙여넣어 주세요 ───────────────

class OnboardingKeyEntry extends StatefulWidget {
  final VoidCallback onConnected;
  const OnboardingKeyEntry({super.key, required this.onConnected});
  @override
  State<OnboardingKeyEntry> createState() => _OnboardingKeyEntryState();
}

class _OnboardingKeyEntryState extends State<OnboardingKeyEntry> {
  final _key = TextEditingController();
  bool _checking = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _pasteIfKey();
  }

  @override
  void dispose() {
    _key.dispose();
    super.dispose();
  }

  /// Coming back from AI Studio with a key on the clipboard fills the field (Figma "붙여넣음").
  Future<void> _pasteIfKey() async {
    final text = (await Clipboard.getData(Clipboard.kTextPlain))?.text?.trim() ?? '';
    if (mounted && _key.text.isEmpty && RegExp(r'^AIza[0-9A-Za-z_\-]{30,}$').hasMatch(text)) {
      setState(() => _key.text = text);
    }
  }

  Future<void> _connect() async {
    final key = _key.text.trim();
    setState(() {
      _checking = true;
      _error = null;
    });
    final model = context.readModel;
    try {
      await GeminiEngine(key).verifyKey();
      await model.secureStore.set(key, SecretKey.geminiAPIKey);
      model.updateSettings((s) => s.engine = EngineKind.gemini);
      if (mounted) widget.onConnected();
    } on LLMError catch (e) {
      if (mounted) setState(() => _error = e.userMessage);
    } catch (_) {
      if (mounted) setState(() => _error = tr('API 키가 올바르지 않아요. 다시 붙여넣어 주세요.'));
    } finally {
      if (mounted) setState(() => _checking = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = context.theme;
    final error = _error;
    const red = Color(0xFFE5484D);
    return _Step(
      title: tr('복사한 API 키를\n붙여넣어 주세요'),
      subtitle: tr('API 키는 이 기기에만 저장돼요'),
      body: [
        Text(tr('Gemini API 키'), style: TextStyle(fontSize: 12, color: t.textSecondary)),
        const SizedBox(height: 6),
        TextField(
          controller: _key,
          obscureText: true,
          autocorrect: false,
          enableSuggestions: false,
          onChanged: (_) => setState(() => _error = null),
          style: TextStyle(fontSize: 15, color: t.textPrimary),
          decoration: InputDecoration(
            hintText: tr('API 키 입력'),
            hintStyle: TextStyle(color: t.textTertiary),
            isDense: true,
            contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
            enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide(color: error == null ? t.stroke : red)),
            focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide(color: error == null ? t.textSecondary : red)),
            suffixIcon: _key.text.isEmpty
                ? IconButton(
                    tooltip: tr('붙여넣기'),
                    icon: Icon(Icons.content_paste, size: 20, color: t.textTertiary),
                    onPressed: () async {
                      final text = (await Clipboard.getData(Clipboard.kTextPlain))?.text?.trim() ?? '';
                      if (mounted) setState(() => _key.text = text);
                    },
                  )
                : null,
          ),
        ),
        if (error != null) ...[
          const SizedBox(height: 6),
          Text(error, style: const TextStyle(fontSize: 12, color: red)),
        ],
        if (_checking) const Padding(padding: EdgeInsets.only(top: 20), child: Center(child: CircularProgressIndicator())),
      ],
      primary: PrimaryButton(tr('API 키 연결하기'), onPressed: _key.text.trim().isEmpty || _checking ? null : _connect),
    );
  }
}

// ─────────────── 00-4 Vinylo에 AI를 연결했어요 ───────────────

class OnboardingConnected extends StatelessWidget {
  final VoidCallback onStart;
  const OnboardingConnected({super.key, required this.onStart});

  @override
  Widget build(BuildContext context) {
    final t = context.theme;
    return Scaffold(
      backgroundColor: t.background,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            const Spacer(flex: 3),
            Center(child: Image.asset('assets/brand/vinylo_logo.png', width: 64, height: 64)),
            const SizedBox(height: 24),
            Text(tr('Vinylo에 AI를 연결했어요'), textAlign: TextAlign.center, style: TextStyle(fontSize: 22, fontWeight: FontWeight.w600, color: t.textPrimary)),
            const SizedBox(height: 10),
            Text(tr('이제 좋아하는 노래를 추가하고\n노래 가사와 함께 공부해요'),
                textAlign: TextAlign.center, style: TextStyle(fontSize: 14, height: 1.5, color: t.textSecondary)),
            const Spacer(flex: 4),
            PrimaryButton(tr('Vinylo 시작하기'), onPressed: onStart),
            const SizedBox(height: 16),
          ]),
        ),
      ),
    );
  }
}
