import 'package:flutter/material.dart';

/// Yve color tokens — see Product Vision & Design System §3.1.
///
/// These are the source of truth for every color in the app. Screens should
/// reference these tokens rather than hard-coded hex values so future palette
/// tweaks land everywhere at once.
class YveColors {
  YveColors._();

  // Brand
  static const Color primary = Color(0xFF1B4332);
  static const Color primaryLight = Color(0xFF2D6A4F);
  static const Color primarySurface = Color(0xFFD8F3DC);
  static const Color accent = Color(0xFF52B788);

  // Surfaces
  static const Color background = Color(0xFFF8F9FA);
  static const Color surface = Color(0xFFFFFFFF);
  static const Color surface2 = Color(0xFFF1F3F5);

  // Text
  static const Color textPrimary = Color(0xFF1A1A2E);
  static const Color textSecondary = Color(0xFF6B7280);
  static const Color textTertiary = Color(0xFF9CA3AF);
  static const Color textInverse = Color(0xFFFFFFFF);
  static const Color textOnGradient = Color(0xFFA8D5B5);

  // State
  static const Color error = Color(0xFFDC2626);
  static const Color warning = Color(0xFFF59E0B);

  // Borders / dividers
  static const Color border = Color(0xFFE5E7EB);
  static const Color borderSubtle = Color(0xFFF1F3F5);

  // Subject palette — used to color-code subject cards / dots.
  static const List<Color> subjectPalette = <Color>[
    Color(0xFF52B788), // green
    Color(0xFF3B82F6), // blue
    Color(0xFF8B5CF6), // purple
    Color(0xFFF59E0B), // amber
    Color(0xFFEC4899), // rose
    Color(0xFF14B8A6), // teal
  ];

  // Soft pastel tints used behind material/tool icons.
  static const Color tintGreen = Color(0xFFD8F3DC);
  static const Color tintBlue = Color(0xFFDBEAFE);
  static const Color tintPurple = Color(0xFFEDE9FE);
  static const Color tintAmber = Color(0xFFFEF3C7);
  static const Color tintRose = Color(0xFFFFE4E6);
  static const Color tintRed = Color(0xFFFEE2E2);

  static const LinearGradient brandGradient = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: <Color>[primary, primaryLight],
  );

  static Color subjectColor(int seed) =>
      subjectPalette[seed.abs() % subjectPalette.length];
}
