import 'package:flutter/material.dart';

/// Yve spacing + shape tokens — see Product Vision & Design System §3.3.
///
/// 4px base grid. Card radii are 16, inputs 12, bottom sheets 24, pills 999.
class YveSpacing {
  YveSpacing._();

  static const double xs = 4;
  static const double sm = 8;
  static const double md = 12;
  static const double lg = 16;
  static const double xl = 20;
  static const double xxl = 24;
  static const double xxxl = 32;

  // Touch targets
  static const double bottomNavHeight = 64;
  static const double inputHeight = 52;

  // Radii
  static const double radiusInput = 12;
  static const double radiusCard = 16;
  static const double radiusSheet = 24;
  static const double radiusPill = 999;

  static const BorderRadius cardRadius =
      BorderRadius.all(Radius.circular(radiusCard));
  static const BorderRadius inputRadius =
      BorderRadius.all(Radius.circular(radiusInput));
  static const BorderRadius pillRadius =
      BorderRadius.all(Radius.circular(radiusPill));
  static const BorderRadius sheetRadius = BorderRadius.only(
    topLeft: Radius.circular(radiusSheet),
    topRight: Radius.circular(radiusSheet),
  );

  // Shadows
  static const List<BoxShadow> cardShadow = <BoxShadow>[
    BoxShadow(
      color: Color(0x14000000), // rgba(0,0,0,0.08)
      blurRadius: 4,
      offset: Offset(0, 1),
    ),
  ];

  // Primary-tinted glow under the elevated Scan button (spec: rgba(27,67,50,0.35)).
  static const List<BoxShadow> fabShadow = <BoxShadow>[
    BoxShadow(
      color: Color(0x591B4332),
      blurRadius: 16,
      offset: Offset(0, 4),
    ),
  ];
}
