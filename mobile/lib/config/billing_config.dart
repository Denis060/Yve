import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;

/// App Store compliance gate for paid-upgrade surfaces.
///
/// Apple (App Store Review Guideline 3.1.1) bars apps from sending users
/// to an external (Stripe) checkout for digital subscriptions unless the
/// app either uses Apple In-App Purchase or holds the External Link
/// Account entitlement. Until that entitlement is granted, every
/// paid-upgrade entry point is hidden on iOS only. Android and web are
/// untouched and keep the full Stripe Checkout + Customer Portal flow.
///
/// ROLLBACK: once Apple grants the External Link Account entitlement (or
/// an Apple IAP layer ships), set [_iosUpgradeEnabled] to `true` to
/// restore the upgrade surfaces on iPhone. This single flag is the only
/// change required — every surface reads [upgradeEnabled].
class BillingConfig {
  BillingConfig._();

  /// Flip to `true` once Apple approves external-link billing (or IAP
  /// lands). Kept `false` so the first App Store submission ships with no
  /// external-purchase calls to action.
  static const bool _iosUpgradeEnabled = false;

  /// Whether paid-upgrade surfaces (pricing screen, upgrade tiles,
  /// quota-card upgrade CTA, Stripe checkout + customer portal) should be
  /// shown and reachable.
  ///
  /// Account-creation flows (e.g. the anonymous "save my work" prompt)
  /// are intentionally NOT gated by this — they involve no payment and
  /// are allowed on iOS.
  static bool get upgradeEnabled {
    if (kIsWeb) return true; // web keeps Stripe
    return Platform.isIOS ? _iosUpgradeEnabled : true; // Android keeps Stripe
  }
}
