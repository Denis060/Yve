import 'package:flutter/material.dart';

import '../config/billing_config.dart';
import '../screens/pricing_screen.dart';

/// Entry point preserved from the v1 upgrade flow — callers still write
/// `showUpgradeSheet(context)` and get the right thing. As of Phase 4
/// "the right thing" is the full PricingScreen (three tiers, intent-
/// first framing, Stripe Checkout per tier), not the old single-plan
/// bottom sheet.
///
/// [audience] is forwarded to PricingScreen so deep-link variants
/// (/for-nursing-students etc.) can pre-select the right tier when
/// they're wired through URL routing.
Future<void> showUpgradeSheet(
  BuildContext context, {
  PricingAudience audience = PricingAudience.general,
}) {
  // App Store compliance: no paid-upgrade surface on iOS until the
  // External Link entitlement is granted (see BillingConfig).
  if (!BillingConfig.upgradeEnabled) return Future<void>.value();
  return Navigator.of(context, rootNavigator: true).push<void>(
    MaterialPageRoute<void>(
      builder: (_) => PricingScreen(audience: audience),
      fullscreenDialog: true,
    ),
  );
}
