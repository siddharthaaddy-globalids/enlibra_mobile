import 'package:flutter/material.dart';

/// Colour tokens and themes.
///
/// The palette is warm-neutral rather than the blue-grey Material default:
/// paper-toned backgrounds, a terracotta accent, and near-black text that
/// is never pure #000. Dark mode is a warm charcoal for the same reason —
/// pure black against white text is high-glare and, on a long reading
/// surface like a chat transcript, tiring.
///
/// Nothing outside this file hardcodes a colour. Widgets read
/// `context.tokens`, so a palette change is a change here only.
class AppColors {
  const AppColors._();

  // Light
  static const lightBackground = Color(0xFFF0EEE6);
  static const lightSurface = Color(0xFFFAF9F5);
  static const lightSurfaceRaised = Color(0xFFFFFFFF);
  static const lightText = Color(0xFF1F1E1D);
  static const lightTextMuted = Color(0xFF73716B);
  static const lightTextFaint = Color(0xFF9B9890);
  static const lightBorder = Color(0xFFDEDBD1);
  static const lightUserMessage = Color(0xFFFFFFFF);

  // Dark
  static const darkBackground = Color(0xFF262624);
  static const darkSurface = Color(0xFF30302E);
  static const darkSurfaceRaised = Color(0xFF3A3A37);
  static const darkText = Color(0xFFF5F4EE);
  static const darkTextMuted = Color(0xFFA5A29A);
  static const darkTextFaint = Color(0xFF7C7A73);
  static const darkBorder = Color(0xFF403F3C);
  static const darkUserMessage = Color(0xFF3A3A37);

  // Accent, taken from the logo artwork. The two are not the same hue by
  // accident: a saturated orange glows against a dark field, so the
  // dark-theme mark uses a softer #f69446 where the light one uses #f67711.
  // The UI accent follows the same split, otherwise buttons drift away from
  // the logo sitting directly above them.
  static const accentLight = Color(0xFFF67711);
  static const accentDark = Color(0xFFF69446);
  static const accentPressedLight = Color(0xFFD96407);
  static const accentPressedDark = Color(0xFFE07F30);
  static const accentSubtle = Color(0x1FF67711);

  static const danger = Color(0xFFBF4722);
}

/// Semantic colours the Material [ColorScheme] has no slot for.
@immutable
class AppTokens extends ThemeExtension<AppTokens> {
  const AppTokens({
    required this.background,
    required this.surface,
    required this.surfaceRaised,
    required this.text,
    required this.textMuted,
    required this.textFaint,
    required this.border,
    required this.userMessage,
    required this.accent,
  });

  final Color background;
  final Color surface;
  final Color surfaceRaised;
  final Color text;
  final Color textMuted;
  final Color textFaint;
  final Color border;
  final Color userMessage;
  final Color accent;

  static const light = AppTokens(
    background: AppColors.lightBackground,
    surface: AppColors.lightSurface,
    surfaceRaised: AppColors.lightSurfaceRaised,
    text: AppColors.lightText,
    textMuted: AppColors.lightTextMuted,
    textFaint: AppColors.lightTextFaint,
    border: AppColors.lightBorder,
    userMessage: AppColors.lightUserMessage,
    accent: AppColors.accentLight,
  );

  static const dark = AppTokens(
    background: AppColors.darkBackground,
    surface: AppColors.darkSurface,
    surfaceRaised: AppColors.darkSurfaceRaised,
    text: AppColors.darkText,
    textMuted: AppColors.darkTextMuted,
    textFaint: AppColors.darkTextFaint,
    border: AppColors.darkBorder,
    userMessage: AppColors.darkUserMessage,
    accent: AppColors.accentDark,
  );

  @override
  AppTokens copyWith({
    Color? background,
    Color? surface,
    Color? surfaceRaised,
    Color? text,
    Color? textMuted,
    Color? textFaint,
    Color? border,
    Color? userMessage,
    Color? accent,
  }) {
    return AppTokens(
      background: background ?? this.background,
      surface: surface ?? this.surface,
      surfaceRaised: surfaceRaised ?? this.surfaceRaised,
      text: text ?? this.text,
      textMuted: textMuted ?? this.textMuted,
      textFaint: textFaint ?? this.textFaint,
      border: border ?? this.border,
      userMessage: userMessage ?? this.userMessage,
      accent: accent ?? this.accent,
    );
  }

  @override
  AppTokens lerp(AppTokens? other, double t) {
    if (other == null) return this;
    return AppTokens(
      background: Color.lerp(background, other.background, t)!,
      surface: Color.lerp(surface, other.surface, t)!,
      surfaceRaised: Color.lerp(surfaceRaised, other.surfaceRaised, t)!,
      text: Color.lerp(text, other.text, t)!,
      textMuted: Color.lerp(textMuted, other.textMuted, t)!,
      textFaint: Color.lerp(textFaint, other.textFaint, t)!,
      border: Color.lerp(border, other.border, t)!,
      userMessage: Color.lerp(userMessage, other.userMessage, t)!,
      accent: Color.lerp(accent, other.accent, t)!,
    );
  }
}

extension AppTokensAccess on BuildContext {
  AppTokens get tokens => Theme.of(this).extension<AppTokens>()!;
}

class AppTheme {
  const AppTheme._();

  /// Comfortable reading measure. Chat transcripts are prose, and prose set
  /// across the full width of a tablet or desktop window is hard to track
  /// line-to-line.
  static const double maxContentWidth = 720;

  static ThemeData light() => _build(Brightness.light, AppTokens.light);
  static ThemeData dark() => _build(Brightness.dark, AppTokens.dark);

  static ThemeData _build(Brightness brightness, AppTokens t) {
    final isDark = brightness == Brightness.dark;

    final scheme = ColorScheme(
      brightness: brightness,
      primary: t.accent,
      onPrimary: Colors.white,
      secondary: t.accent,
      onSecondary: Colors.white,
      error: AppColors.danger,
      onError: Colors.white,
      surface: t.surface,
      onSurface: t.text,
      surfaceContainerLowest: t.background,
      surfaceContainer: t.surface,
      surfaceContainerHigh: t.surfaceRaised,
      surfaceContainerHighest: t.surfaceRaised,
      outline: t.border,
      outlineVariant: t.border,
    );

    final base = isDark ? ThemeData.dark() : ThemeData.light();

    return base.copyWith(
      colorScheme: scheme,
      scaffoldBackgroundColor: t.background,
      canvasColor: t.background,
      dividerColor: t.border,
      extensions: [t],

      textTheme: _textTheme(base.textTheme, t),

      appBarTheme: AppBarTheme(
        backgroundColor: t.background,
        foregroundColor: t.text,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        titleTextStyle: TextStyle(
          color: t.text,
          fontSize: 16,
          fontWeight: FontWeight.w500,
          letterSpacing: -0.1,
        ),
      ),

      cardTheme: CardThemeData(
        color: t.surface,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(color: t.border),
        ),
      ),

      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: t.accent,
          foregroundColor: Colors.white,
          disabledBackgroundColor: t.border,
          disabledForegroundColor: t.textFaint,
          elevation: 0,
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
          textStyle: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
        ),
      ),

      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: t.textMuted,
          textStyle: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
        ),
      ),

      iconTheme: IconThemeData(color: t.textMuted, size: 20),

      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: t.surface,
        hintStyle: TextStyle(color: t.textFaint, fontSize: 15),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 16,
          vertical: 14,
        ),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: t.border),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: t.border),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: t.accent, width: 1.5),
        ),
      ),

      chipTheme: ChipThemeData(
        backgroundColor: t.surfaceRaised,
        side: BorderSide(color: t.border),
        labelStyle: TextStyle(
          color: t.textMuted,
          fontSize: 12,
          fontWeight: FontWeight.w500,
        ),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
      ),

      progressIndicatorTheme: ProgressIndicatorThemeData(
        color: t.accent,
        linearTrackColor: t.border,
        circularTrackColor: Colors.transparent,
      ),

      snackBarTheme: SnackBarThemeData(
        backgroundColor: t.surfaceRaised,
        contentTextStyle: TextStyle(color: t.text, fontSize: 14),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),

      dividerTheme: DividerThemeData(color: t.border, thickness: 1, space: 1),
    );
  }

  /// Slightly larger body text and a generous line height. Message text is
  /// read continuously rather than scanned, so it wants more leading than
  /// Material's defaults give.
  static TextTheme _textTheme(TextTheme base, AppTokens t) {
    return base.copyWith(
      bodyLarge: TextStyle(
        color: t.text,
        fontSize: 15.5,
        height: 1.65,
        letterSpacing: -0.05,
      ),
      bodyMedium: TextStyle(
        color: t.text,
        fontSize: 15,
        height: 1.6,
        letterSpacing: -0.05,
      ),
      bodySmall: TextStyle(color: t.textMuted, fontSize: 13, height: 1.45),
      titleMedium: TextStyle(
        color: t.text,
        fontSize: 15,
        fontWeight: FontWeight.w600,
        letterSpacing: -0.1,
      ),
      titleSmall: TextStyle(
        color: t.text,
        fontSize: 13,
        fontWeight: FontWeight.w600,
      ),
      labelLarge: TextStyle(
        color: t.text,
        fontSize: 14,
        fontWeight: FontWeight.w500,
      ),
      labelSmall: TextStyle(
        color: t.textFaint,
        fontSize: 11,
        fontWeight: FontWeight.w500,
        letterSpacing: 0.3,
      ),
    );
  }
}
