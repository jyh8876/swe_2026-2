import 'package:flutter/material.dart';

/// Design tokens from the UI prototype (swe-2026_2_UI "player prototype.html", Figma variables).
/// The app uses one light look; the player screen uses its own dark palette ([PlayerPalette]).
class AppTheme {
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
  final Color brand; // mint used for saved lines
  final Color brandInk; // text on mint
  final Color marker; // expression highlight background
  final Color gold;

  const AppTheme({
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

  /// Screenshot tests load a real font under this family; null in the app (platform font).
  static String? fontFamilyOverride;

  /// Kept for the vinyl painter: the record colour on light backgrounds.
  Color get vinyl => textPrimary;

  ThemeData get material {
    final scheme = ColorScheme.light(
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
      brightness: Brightness.light,
      colorScheme: scheme,
      scaffoldBackgroundColor: background,
      canvasColor: background,
      dividerColor: stroke,
      splashFactory: InkSparkle.splashFactory,
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
  static const brand = Color(0xFF08F0C4);
}

extension ThemeContext on BuildContext {
  AppTheme get theme => AppTheme.light;
}
