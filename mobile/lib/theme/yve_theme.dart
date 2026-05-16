import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import 'yve_colors.dart';
import 'yve_spacing.dart';

/// Builds the Yve [ThemeData]. Typography uses Inter via [GoogleFonts] and
/// follows the scale from the design system spec (§3.2): 28–32 display,
/// 18–20 heading, 14–16 body, 12 caption, 14–15 button.
ThemeData buildYveTheme() {
  const ColorScheme scheme = ColorScheme(
    brightness: Brightness.light,
    primary: YveColors.primary,
    onPrimary: YveColors.textInverse,
    primaryContainer: YveColors.primarySurface,
    onPrimaryContainer: YveColors.primary,
    secondary: YveColors.accent,
    onSecondary: YveColors.textInverse,
    secondaryContainer: YveColors.primarySurface,
    onSecondaryContainer: YveColors.primary,
    tertiary: YveColors.primaryLight,
    onTertiary: YveColors.textInverse,
    error: YveColors.error,
    onError: YveColors.textInverse,
    surface: YveColors.surface,
    onSurface: YveColors.textPrimary,
    surfaceContainerHighest: YveColors.surface2,
    outline: YveColors.border,
    outlineVariant: YveColors.borderSubtle,
  );

  final TextTheme baseText = GoogleFonts.interTextTheme().apply(
    bodyColor: YveColors.textPrimary,
    displayColor: YveColors.textPrimary,
  );

  final TextTheme textTheme = baseText.copyWith(
    displayLarge: baseText.displayLarge?.copyWith(
      fontSize: 32,
      fontWeight: FontWeight.w700,
      height: 1.2,
    ),
    displayMedium: baseText.displayMedium?.copyWith(
      fontSize: 28,
      fontWeight: FontWeight.w700,
      height: 1.2,
    ),
    headlineLarge: baseText.headlineLarge?.copyWith(
      fontSize: 24,
      fontWeight: FontWeight.w700,
    ),
    headlineMedium: baseText.headlineMedium?.copyWith(
      fontSize: 22,
      fontWeight: FontWeight.w700,
    ),
    titleLarge: baseText.titleLarge?.copyWith(
      fontSize: 20,
      fontWeight: FontWeight.w600,
    ),
    titleMedium: baseText.titleMedium?.copyWith(
      fontSize: 18,
      fontWeight: FontWeight.w600,
    ),
    titleSmall: baseText.titleSmall?.copyWith(
      fontSize: 15,
      fontWeight: FontWeight.w600,
    ),
    bodyLarge: baseText.bodyLarge?.copyWith(
      fontSize: 16,
      fontWeight: FontWeight.w400,
      height: 1.5,
    ),
    bodyMedium: baseText.bodyMedium?.copyWith(
      fontSize: 14,
      fontWeight: FontWeight.w400,
      height: 1.5,
    ),
    bodySmall: baseText.bodySmall?.copyWith(
      fontSize: 13,
      fontWeight: FontWeight.w400,
      color: YveColors.textSecondary,
      height: 1.4,
    ),
    labelLarge: baseText.labelLarge?.copyWith(
      fontSize: 15,
      fontWeight: FontWeight.w600,
    ),
    labelMedium: baseText.labelMedium?.copyWith(
      fontSize: 13,
      fontWeight: FontWeight.w600,
    ),
    labelSmall: baseText.labelSmall?.copyWith(
      fontSize: 12,
      fontWeight: FontWeight.w400,
      color: YveColors.textSecondary,
    ),
  );

  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: YveColors.background,
    textTheme: textTheme,
    splashFactory: InkSparkle.splashFactory,
    appBarTheme: AppBarTheme(
      backgroundColor: YveColors.surface,
      foregroundColor: YveColors.textPrimary,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: false,
      titleTextStyle: textTheme.titleMedium,
      iconTheme: const IconThemeData(color: YveColors.primary),
    ),
    cardTheme: const CardThemeData(
      color: YveColors.surface,
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(borderRadius: YveSpacing.cardRadius),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: YveColors.surface2,
      contentPadding: const EdgeInsets.symmetric(
        horizontal: YveSpacing.lg,
        vertical: 14,
      ),
      border: OutlineInputBorder(
        borderRadius: YveSpacing.inputRadius,
        borderSide: BorderSide.none,
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: YveSpacing.inputRadius,
        borderSide: BorderSide.none,
      ),
      focusedBorder: const OutlineInputBorder(
        borderRadius: YveSpacing.inputRadius,
        borderSide: BorderSide(color: YveColors.primary, width: 1.5),
      ),
      labelStyle: textTheme.bodyMedium?.copyWith(
        color: YveColors.textSecondary,
      ),
      hintStyle: textTheme.bodyMedium?.copyWith(
        color: YveColors.textTertiary,
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: YveColors.primary,
        foregroundColor: YveColors.textInverse,
        minimumSize: const Size.fromHeight(YveSpacing.inputHeight),
        shape: const RoundedRectangleBorder(
          borderRadius: YveSpacing.pillRadius,
        ),
        textStyle: textTheme.labelLarge,
        padding: const EdgeInsets.symmetric(horizontal: YveSpacing.xxl),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: YveColors.primary,
        side: const BorderSide(color: YveColors.primary, width: 1.5),
        minimumSize: const Size.fromHeight(YveSpacing.inputHeight),
        shape: const RoundedRectangleBorder(
          borderRadius: YveSpacing.pillRadius,
        ),
        textStyle: textTheme.labelLarge,
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: YveColors.primary,
        textStyle: textTheme.labelLarge,
      ),
    ),
    chipTheme: ChipThemeData(
      backgroundColor: YveColors.surface,
      side: const BorderSide(color: YveColors.border, width: 1.5),
      labelStyle: textTheme.labelMedium,
      padding: const EdgeInsets.symmetric(horizontal: YveSpacing.md),
      shape: const RoundedRectangleBorder(
        borderRadius: YveSpacing.pillRadius,
      ),
    ),
    dividerTheme: const DividerThemeData(
      color: YveColors.borderSubtle,
      thickness: 1,
      space: 1,
    ),
    bottomSheetTheme: const BottomSheetThemeData(
      backgroundColor: YveColors.surface,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: YveSpacing.sheetRadius),
    ),
    snackBarTheme: SnackBarThemeData(
      backgroundColor: YveColors.textPrimary,
      contentTextStyle: textTheme.bodyMedium?.copyWith(
        color: YveColors.textInverse,
      ),
      behavior: SnackBarBehavior.floating,
      shape: const RoundedRectangleBorder(borderRadius: YveSpacing.cardRadius),
    ),
  );
}
