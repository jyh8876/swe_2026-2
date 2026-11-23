import 'package:flutter/material.dart';

/// Design tokens from the Figma file "2026-2 소웨공" (dark frames) and the earlier light prototype.
/// The base (dark grey or white) and the accent colour are chosen in My page → 테마 (Notion "컬러 테마").
enum ThemeBase {
  dark('다크 그레이'),
  light('화이트');

  final String label;
  const ThemeBase(this.label);
}

/// Accent colours offered in settings. [ink] is the readable variant on a white background.
enum AccentColor {
  mint('민트', Color(0xFF08F0C4), Color(0xFF00A284)),
  yellow('노랑', Color(0xFFFFD43B), Color(0xFFB08800)),
  green('초록', Color(0xFF51CF66), Color(0xFF2B8A3E)),
  red('빨강', Color(0xFFFF6B6B), Color(0xFFE03131)),
  blue('파랑', Color(0xFF4DABF7), Color(0xFF1971C2));

  final String label;
  final Color color;
  final Color ink;
  const AccentColor(this.label, this.color, this.ink);
}

class AppTheme {
  final bool isDark;
  final Color background; // --bg-basement
  final Color surface; // --bg-disabled
  final Color surfaceRaised; // --page
  final Color stroke; // --fg-weak
  final Color textPrimary; // --fg
  final Color textSecondary; // --fg-muted
  final Color textTertiary; // --fg-subtle
  final Color disabled; // --fg-disabled
  final Color accent; // --bg-solid
  final Color onAccent;
  final Color brand; // accent colour used for saved lines
  final Color brandInk; // accent text on the background
  final Color marker; // expression highlight background
  final Color gold;

  const AppTheme({
    this.isDark = false,
    required this.background,
    required this.surface,
    required this.surfaceRaised,
    required this.stroke,
    required this.textPrimary,
    required this.textSecondary,
    required this.textTertiary,
    required this.disabled,
    required this.accent,
    required this.onAccent,
    required this.brand,
    required this.brandInk,
    required this.marker,
    required this.gold,
  });

  static const light = AppTheme(
    background: Color(0xFFFFFFFF),
    surface: Color(0xFFF7F8F9),
    surfaceRaised: Color(0xFFEEEFF1),
    stroke: Color(0xFFDCDEE3),
    textPrimary: Color(0xFF1A1C20),
    textSecondary: Color(0xFF555D6D),
    textTertiary: Color(0xFF868B94),
    disabled: Color(0xFFD1D3D8),
    accent: Color(0xFF1A1C20),
    onAccent: Color(0xFFFFFFFF),
    brand: Color(0xFF08F0C4),
    brandInk: Color(0xFF00A284),
    marker: Color(0xFFDBFFF8),
    gold: Color(0xFFE3B341),
  );

  /// Figma dark frames: #16171B page, #1D2025 cards, #2B2E35 raised, #393D46 lines, white buttons.
  static const dark = AppTheme(
    isDark: true,
    background: Color(0xFF16171B),
    surface: Color(0xFF1D2025),
    surfaceRaised: Color(0xFF2B2E35),
    stroke: Color(0xFF393D46),
    textPrimary: Color(0xFFF3F4F5),
    textSecondary: Color(0xFFB0B3BA),
    textTertiary: Color(0xFF868B94),
    disabled: Color(0xFF4D4E52),
    accent: Color(0xFFF3F4F5),
    onAccent: Color(0xFF16171B),
    brand: Color(0xFF08F0C4),
    brandInk: Color(0xFF08F0C4),
    marker: Color(0xFF173B36),
    gold: Color(0xFFE3B341),
  );

  static final Map<(ThemeBase, AccentColor), AppTheme> _cache = {};

  /// One shared instance per combination, so identical themes compare equal.
  static AppTheme of(ThemeBase base, AccentColor accent) => _cache.putIfAbsent((base, accent), () {
        final b = base == ThemeBase.dark ? dark : light;
        return AppTheme(
          isDark: b.isDark,
          background: b.background,
          surface: b.surface,
          surfaceRaised: b.surfaceRaised,
          stroke: b.stroke,
          textPrimary: b.textPrimary,
          textSecondary: b.textSecondary,
          textTertiary: b.textTertiary,
          disabled: b.disabled,
          accent: b.accent,
          onAccent: b.onAccent,
          brand: accent.color,
          brandInk: b.isDark ? accent.color : accent.ink,
          marker: Color.alphaBlend(accent.color.withValues(alpha: b.isDark ? 0.18 : 0.16), b.background),
          gold: b.gold,
        );
      });

  /// Screenshot tests load a real font under this family; null in the app (platform font).
  static String? fontFamilyOverride;

  /// Kept for the vinyl painter: the record colour on light backgrounds.
  Color get vinyl => textPrimary;

  ThemeData get material {
    final scheme = (isDark ? const ColorScheme.dark() : const ColorScheme.light()).copyWith(
      primary: accent,
      onPrimary: onAccent,
      secondary: textSecondary,
      surface: background,
      onSurface: textPrimary,
      error: const Color(0xFFE5484D),
      outline: stroke,
    );
    TextStyle s(double size, FontWeight w, double ls) =>
        TextStyle(fontFamily: fontFamilyOverride, fontSize: size, fontWeight: w, letterSpacing: ls, color: textPrimary);
    return ThemeData(
      useMaterial3: true,
      fontFamily: fontFamilyOverride,
      brightness: isDark ? Brightness.dark : Brightness.light,
      colorScheme: scheme,
      scaffoldBackgroundColor: background,
      canvasColor: background,
      dividerColor: stroke,
      // A plain ripple; Material 3's shimmering InkSparkle felt noisy on taps.
      splashFactory: InkRipple.splashFactory,
      textTheme: TextTheme(
        titleLarge: s(18, FontWeight.w700, -0.36),
        titleMedium: s(16, FontWeight.w700, -0.24),
        bodyLarge: s(16, FontWeight.w400, -0.24),
        bodyMedium: s(14, FontWeight.w400, -0.21),
        labelMedium: s(12, FontWeight.w500, -0.24),
      ),
      appBarTheme: AppBarTheme(
        backgroundColor: background,
        foregroundColor: textPrimary,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: true,
        titleTextStyle: s(18, FontWeight.w700, -0.36),
      ),
      bottomSheetTheme: BottomSheetThemeData(backgroundColor: background, modalBackgroundColor: background),
      dialogTheme: DialogThemeData(backgroundColor: background),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: accent,
        contentTextStyle: TextStyle(color: onAccent),
        actionTextColor: brand,
        behavior: SnackBarBehavior.floating,
      ),
      sliderTheme: SliderThemeData(activeTrackColor: textPrimary, thumbColor: textPrimary, inactiveTrackColor: stroke),
      progressIndicatorTheme: ProgressIndicatorThemeData(color: textPrimary, linearTrackColor: stroke),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith((st) => st.contains(WidgetState.selected) ? onAccent : textTertiary),
        trackColor: WidgetStateProperty.resolveWith((st) => st.contains(WidgetState.selected) ? brandInk : surfaceRaised),
        trackOutlineColor: const WidgetStatePropertyAll(Colors.transparent),
      ),
      textSelectionTheme: TextSelectionThemeData(cursorColor: textPrimary, selectionColor: marker),
    );
  }
}

/// Dark palette of the player screen (Figma 06 플레이어 · 가사 v2).
class PlayerPalette {
  static const background = Color(0xFF1D1D1D);
  static const fg = Color(0xFFF3F4F5);
  static const subtle = Color(0xFFB0B3BA);
  static const placeholder = Color(0xFF868B94);
  static const weak = Color(0xFF2B2E35);
  static const line = Color(0xFF393D46);
  /// Follows the accent colour chosen in settings.
  static Color brand = const Color(0xFF08F0C4);
}

/// Provides the theme chosen in settings. Widgets outside it (tests) get the Figma dark theme.
class AppThemeScope extends InheritedWidget {
  final AppTheme theme;
  const AppThemeScope({super.key, required this.theme, required super.child});

  @override
  bool updateShouldNotify(AppThemeScope old) => old.theme != theme;
}

extension ThemeContext on BuildContext {
  AppTheme get theme => dependOnInheritedWidgetOfExactType<AppThemeScope>()?.theme ?? AppTheme.dark;
}
