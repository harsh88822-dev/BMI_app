import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

/// Clockwork BMI — brand palette plus **Plus Jakarta Sans ONLY** (single family;
/// hierarchy via weight and size).
class AppTheme {
  AppTheme._();

  static const Color parchment = Color(0xFFFAF8F5);
  static const Color ink = Color(0xFF1C1B19);
  static const Color inkMuted = Color(0xFF5C5955);
  static const Color divider = Color(0xFFE5E0D8);
  // Approximated from the provided logo for visual brand consistency.
  static const Color deepBlue = Color(0xFF1243A8);
  static const Color champagne = Color(0xFFFF6A00);
  static const Color brandBlueMuted = Color(0xFF2D5FC0);

  static ThemeData light() {
    final baseScheme = ColorScheme.fromSeed(
      seedColor: deepBlue,
      brightness: Brightness.light,
      surface: parchment,
      onSurface: ink,
      primary: deepBlue,
      onPrimary: Colors.white,
      secondary: brandBlueMuted,
      onSecondary: Colors.white,
      tertiary: champagne,
      onTertiary: ink,
      error: const Color(0xFF8B3A3A),
      onError: Colors.white,
      outline: const Color(0xFFE1DCD3),
      outlineVariant: const Color(0xFFEEEAE2),
      surfaceContainerHighest: const Color(0xFFF3EEE7),
    );

    final baseText = Typography.material2021(platform: TargetPlatform.iOS).black;

    final jakartaBase = GoogleFonts.plusJakartaSansTextTheme(baseText);

    // Single font family app-wide: Plus Jakarta Sans (weight/size hierarchy only).
    final textTheme = jakartaBase.copyWith(
      displayLarge: GoogleFonts.plusJakartaSans(
        textStyle: jakartaBase.displayLarge,
        fontWeight: FontWeight.w700,
        letterSpacing: -0.6,
        color: ink,
      ),
      displayMedium: GoogleFonts.plusJakartaSans(
        textStyle: jakartaBase.displayMedium,
        fontWeight: FontWeight.w700,
        letterSpacing: -0.45,
        color: ink,
      ),
      displaySmall: GoogleFonts.plusJakartaSans(
        textStyle: jakartaBase.displaySmall,
        fontWeight: FontWeight.w600,
        letterSpacing: -0.35,
        color: ink,
      ),
      headlineLarge: GoogleFonts.plusJakartaSans(
        textStyle: jakartaBase.headlineLarge,
        fontWeight: FontWeight.w600,
        letterSpacing: -0.3,
        color: ink,
      ),
      headlineMedium: GoogleFonts.plusJakartaSans(
        textStyle: jakartaBase.headlineMedium,
        fontWeight: FontWeight.w600,
        letterSpacing: -0.22,
        color: ink,
      ),
      headlineSmall: GoogleFonts.plusJakartaSans(
        textStyle: jakartaBase.headlineSmall,
        fontWeight: FontWeight.w600,
        letterSpacing: -0.15,
        height: 1.15,
        color: ink,
      ),
      titleLarge: GoogleFonts.plusJakartaSans(
        textStyle: jakartaBase.titleLarge,
        fontWeight: FontWeight.w600,
        letterSpacing: -0.08,
        color: ink,
      ),
      titleMedium: GoogleFonts.plusJakartaSans(
        textStyle: jakartaBase.titleMedium,
        fontWeight: FontWeight.w600,
        letterSpacing: 0.1,
        color: ink,
      ),
      titleSmall: GoogleFonts.plusJakartaSans(
        textStyle: jakartaBase.titleSmall,
        fontWeight: FontWeight.w600,
        letterSpacing: 0.15,
        color: ink,
      ),
      bodyLarge: GoogleFonts.plusJakartaSans(
        textStyle: jakartaBase.bodyLarge,
        fontWeight: FontWeight.w400,
        height: 1.45,
        color: ink,
      ),
      bodyMedium: GoogleFonts.plusJakartaSans(
        textStyle: jakartaBase.bodyMedium,
        fontWeight: FontWeight.w400,
        height: 1.45,
        color: inkMuted,
      ),
      bodySmall: GoogleFonts.plusJakartaSans(
        textStyle: jakartaBase.bodySmall,
        fontWeight: FontWeight.w400,
        color: inkMuted,
      ),
      labelLarge: GoogleFonts.plusJakartaSans(
        textStyle: jakartaBase.labelLarge,
        fontWeight: FontWeight.w600,
        letterSpacing: 0.4,
      ),
      labelMedium: GoogleFonts.plusJakartaSans(
        textStyle: jakartaBase.labelMedium,
        fontWeight: FontWeight.w600,
        letterSpacing: 0.35,
      ),
    );

    final softShape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(20),
    );

    return ThemeData(
      useMaterial3: true,
      colorScheme: baseScheme,
      fontFamily: GoogleFonts.plusJakartaSans().fontFamily,
      scaffoldBackgroundColor: parchment,
      textTheme: textTheme,
      splashFactory: InkSparkle.constantTurbulenceSeedSplashFactory,
      appBarTheme: AppBarTheme(
        centerTitle: false,
        elevation: 0,
        scrolledUnderElevation: 0.5,
        backgroundColor: parchment.withValues(alpha: 0.92),
        surfaceTintColor: Colors.transparent,
        foregroundColor: ink,
        titleTextStyle: GoogleFonts.plusJakartaSans(
          fontSize: 22,
          fontWeight: FontWeight.w600,
          letterSpacing: -0.08,
          color: ink,
        ),
      ),
      cardTheme: CardThemeData(
        elevation: 0,
        color: Colors.white,
        surfaceTintColor: Colors.transparent,
        shape: softShape,
        shadowColor: ink.withValues(alpha: 0.06),
        margin: EdgeInsets.zero,
      ),
      dividerTheme: DividerThemeData(
        color: divider,
        thickness: 1,
        space: 1,
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: Colors.white,
        labelStyle: TextStyle(color: inkMuted, fontSize: 14),
        floatingLabelStyle: TextStyle(
          color: deepBlue.withValues(alpha: 0.85),
          fontWeight: FontWeight.w500,
        ),
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: const BorderSide(color: divider),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: const BorderSide(color: divider),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: BorderSide(color: deepBlue.withValues(alpha: 0.85), width: 1.6),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: BorderSide(color: baseScheme.error.withValues(alpha: 0.85)),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: const Size.fromHeight(52),
          elevation: 0,
          shadowColor: Colors.transparent,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
          backgroundColor: deepBlue,
          foregroundColor: Colors.white,
          textStyle: GoogleFonts.plusJakartaSans(
            fontWeight: FontWeight.w600,
            letterSpacing: 0.35,
            fontSize: 15,
          ),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          minimumSize: const Size.fromHeight(50),
          side: BorderSide(color: deepBlue.withValues(alpha: 0.35)),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
          foregroundColor: deepBlue,
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: deepBlue,
          textStyle: GoogleFonts.plusJakartaSans(
            fontWeight: FontWeight.w600,
            letterSpacing: 0.2,
          ),
        ),
      ),
      navigationBarTheme: NavigationBarThemeData(
        height: 72,
        elevation: 0,
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.transparent,
        shadowColor: ink.withValues(alpha: 0.08),
        indicatorColor: deepBlue.withValues(alpha: 0.10),
        labelTextStyle: WidgetStateProperty.resolveWith((states) {
          final selected = states.contains(WidgetState.selected);
          return GoogleFonts.plusJakartaSans(
            fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
            fontSize: 11,
            letterSpacing: 0.15,
            color: selected ? deepBlue : inkMuted,
          );
        }),
        iconTheme: WidgetStateProperty.resolveWith((states) {
          final selected = states.contains(WidgetState.selected);
          return IconThemeData(
            size: 24,
            color: selected ? deepBlue : inkMuted,
          );
        }),
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        elevation: 4,
        backgroundColor: ink,
        contentTextStyle: GoogleFonts.plusJakartaSans(
          color: Colors.white,
          fontWeight: FontWeight.w500,
        ),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
        ),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(22),
        ),
        titleTextStyle: GoogleFonts.plusJakartaSans(
          fontSize: 22,
          fontWeight: FontWeight.w600,
          letterSpacing: -0.08,
          color: ink,
        ),
      ),
      checkboxTheme: CheckboxThemeData(
        fillColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) {
            return deepBlue;
          }
          return null;
        }),
        side: const BorderSide(color: divider, width: 1.5),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(5)),
      ),
    );
  }
}
