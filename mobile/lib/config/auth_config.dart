import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;

/// Auth surface gating for App Store compliance.
///
/// App Store Review Guideline 4.8 requires that any third-party / social
/// login (e.g. "Continue with Google") be offered alongside an equivalent
/// privacy-preserving option such as Sign in with Apple. Yve's Apple
/// sign-in isn't configured yet, so on iOS we hide social login entirely
/// and offer in-app email-code sign-in only.
///
/// Email-code sign-in is first-party and stays inside the app (no external
/// browser), so this also satisfies Guideline 4's requirement that account
/// sign-in/registration happen in-app rather than in Safari.
///
/// Web + Android keep "Continue with Google" unchanged.
///
/// ROLLBACK: once Sign in with Apple is wired up (Service ID + key +
/// Supabase Apple provider + Xcode capability), restore the Apple button
/// in the auth panels and set [socialLoginEnabled] to true on iOS.
class AuthConfig {
  AuthConfig._();

  /// Whether third-party/social login buttons (Google) should be shown.
  static bool get socialLoginEnabled {
    if (kIsWeb) return true; // web keeps Google
    return !Platform.isIOS; // Android keeps Google; iOS = email only
  }
}
