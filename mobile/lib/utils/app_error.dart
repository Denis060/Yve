// Centralized user-facing error model.
//
// Rules of engagement:
//   1. Never render a caught exception directly in the UI. Always go
//      through AppError.from(e).userMessage.
//   2. The raw exception is logged via developer.log so console/devtools
//      still have everything you need to debug.
//   3. Known cases (auth required, already subscribed, trial used,
//      offline, validation, etc.) get a specific kind that the UI can
//      switch on to render the right surface — not always a generic
//      error banner. The anonymous_user case in particular should
//      *never* render as an error; the UI shows the AuthContinuationPanel.
//   4. Unknown errors fall back to "Something went wrong. Please try
//      again." — calm, actionable, never technical.

import 'dart:async';
import 'dart:developer' as developer;
import 'dart:io' show SocketException;

import 'package:flutter/services.dart';
import 'package:supabase_flutter/supabase_flutter.dart' as sb;

/// What kind of error this is — drives whether the UI shows a generic
/// banner, an auth panel, an upgrade prompt, or a custom surface.
enum AppErrorKind {
  /// "Something went wrong" — no specific category matched.
  unknown,

  /// Offline / DNS / fetch couldn't complete. UI offers retry.
  network,

  /// The action requires an account. UI shows AuthContinuationPanel,
  /// NOT an error banner.
  authRequired,

  /// User has no Supabase session at all (shouldn't happen post-app-
  /// open since we ensureSession() on launch). Treated like authRequired
  /// in most UIs.
  notAuthenticated,

  /// User already has an active subscription. UI surfaces "Manage
  /// billing" instead of trial CTA.
  alreadySubscribed,

  /// User already used their 3-day trial. UI offers direct subscribe.
  trialUsed,

  /// Server rejected on bad input (missing plan_code, bad email, etc.).
  validation,

  /// File too big for the platform body-size cap.
  fileTooLarge,

  /// Permission denied — camera, microphone, photo library, etc.
  permissionDenied,

  /// 5xx — backend is temporarily sick. UI offers retry.
  serverError,
}

/// Sanitized error surface the rest of the app deals with. Never carry
/// the original exception into the UI — only [userMessage] and [kind]
/// are safe to render. [cause] is for logging and debug screens only.
class AppError implements Exception {
  const AppError({
    required this.kind,
    required this.userMessage,
    this.code,
    this.cause,
    this.retryable = false,
  });

  final AppErrorKind kind;
  final String userMessage;

  /// Backend code (e.g., 'anonymous_user', 'already_subscribed'). Used
  /// for switch-on-kind UI variants when kind alone isn't specific
  /// enough. NEVER show this in UI directly.
  final String? code;

  /// Original throwable. Only used for logging. NEVER show in UI.
  final Object? cause;

  /// Whether a retry button is meaningful. Network + 5xx are retryable;
  /// validation + auth-required are not.
  final bool retryable;

  @override
  String toString() => 'AppError(${kind.name}: $userMessage)';

  /// Map any caught error into an AppError. Logs the raw error to
  /// developer.log for the dev console — UI only ever sees the
  /// sanitized fields on the returned object.
  factory AppError.from(Object e, {String? actionContext}) {
    _logRaw(e, actionContext);

    if (e is AppError) return e;

    // Supabase Edge Function error envelope: { error, code, detail }.
    if (e is sb.FunctionException) {
      return _fromFunctionException(e);
    }

    // Supabase Auth errors.
    if (e is sb.AuthApiException) {
      return _fromAuthApi(e);
    }
    if (e is sb.AuthException) {
      return AppError(
        kind: AppErrorKind.unknown,
        userMessage: _sanitizeAuthMessage(e.message),
        cause: e,
      );
    }

    // Supabase Postgrest (DB) errors.
    if (e is sb.PostgrestException) {
      return AppError(
        kind: AppErrorKind.serverError,
        userMessage:
            "We couldn't reach your data right now. Please try again.",
        cause: e,
        retryable: true,
      );
    }

    // Platform channel errors (image_picker, file_picker, etc.).
    if (e is PlatformException) {
      return _fromPlatform(e);
    }

    // Networking primitives.
    if (e is SocketException) {
      return const AppError(
        kind: AppErrorKind.network,
        userMessage:
            "You're offline. Check your connection and try again.",
        retryable: true,
      );
    }
    if (e is TimeoutException) {
      return const AppError(
        kind: AppErrorKind.network,
        userMessage: 'That took longer than expected. Please try again.',
        retryable: true,
      );
    }

    // String "errors" — sometimes thrown by lower-level code.
    if (e is String && e.toLowerCase().contains('socket')) {
      return const AppError(
        kind: AppErrorKind.network,
        userMessage:
            "You're offline. Check your connection and try again.",
        retryable: true,
      );
    }

    // Fallback. The userMessage is intentionally generic — anything
    // specific belongs in a typed branch above.
    return AppError(
      kind: AppErrorKind.unknown,
      userMessage: 'Something went wrong. Please try again.',
      cause: e,
      retryable: true,
    );
  }
}

// ─────────────────────────────────────────────────────────────────────
// FunctionException — our backend's { error, code, detail } envelope
// ─────────────────────────────────────────────────────────────────────

AppError _fromFunctionException(sb.FunctionException e) {
  // Supabase wraps the JSON body in `details`. Sometimes it's a
  // Map<String, dynamic>; sometimes a String we need to read.
  final Map<String, dynamic> details = _normalizeDetails(e.details);
  final String? code = details['code'] as String?;
  final String? backendError = details['error'] as String?;
  final String? backendDetail = details['detail'] as String?;

  // Known backend codes — map to specific UX.
  switch (code) {
    case 'anonymous_user':
      return AppError(
        kind: AppErrorKind.authRequired,
        userMessage:
            'Pro attaches to your account so it works on every device you study from.',
        code: code,
        cause: e,
      );
    case 'anonymous_subject_limit':
      // Guest preview cap on subjects. UI should open the
      // AnonymousContinuationPanel ("Keep going with Yve") rather
      // than show a banner.
      return AppError(
        kind: AppErrorKind.authRequired,
        userMessage:
            "You've started one subject as a guest. Save your account to keep going.",
        code: code,
        cause: e,
      );
    case 'subject_limit':
      return AppError(
        kind: AppErrorKind.alreadySubscribed,
        userMessage: backendError ??
            "You're at the subjects limit for your plan. Upgrade to add more.",
        code: code,
        cause: e,
      );
    case 'already_subscribed':
      return AppError(
        kind: AppErrorKind.alreadySubscribed,
        userMessage: backendDetail ??
            'You already have an active subscription. Use billing to change plans.',
        code: code,
        cause: e,
      );
  }

  // Fallback by status code — never reflect the backend's raw message
  // unless we explicitly trust it.
  switch (e.status) {
    case 400:
      return AppError(
        kind: AppErrorKind.validation,
        userMessage: 'Something about that request didn\'t add up. Please try again.',
        code: code,
        cause: e,
      );
    case 401:
    case 403:
      return AppError(
        kind: AppErrorKind.notAuthenticated,
        userMessage: 'Your session expired. Please sign in again.',
        code: code,
        cause: e,
      );
    case 404:
      return AppError(
        kind: AppErrorKind.unknown,
        userMessage: backendError != null && backendError.length < 80
            ? backendError
            : 'We couldn\'t find what you were looking for.',
        code: code,
        cause: e,
      );
    case 409:
      return AppError(
        kind: AppErrorKind.alreadySubscribed,
        userMessage: backendDetail ??
            'That action conflicts with your current state — refresh and try again.',
        code: code,
        cause: e,
      );
    case 429:
      return AppError(
        kind: AppErrorKind.serverError,
        userMessage: 'Too many requests just now. Take a breath and try again.',
        code: code,
        cause: e,
        retryable: true,
      );
    case 500:
    case 502:
    case 503:
    case 504:
      return AppError(
        kind: AppErrorKind.serverError,
        userMessage: 'Yve is having a brief moment. Try again in a few seconds.',
        code: code,
        cause: e,
        retryable: true,
      );
  }

  return AppError(
    kind: AppErrorKind.unknown,
    userMessage: 'Something went wrong. Please try again.',
    code: code,
    cause: e,
    retryable: true,
  );
}

/// Supabase's `details` is typed as `dynamic`. Normalize it so we can
/// switch on `code` whether the body arrived as a Map or a JSON string.
Map<String, dynamic> _normalizeDetails(dynamic raw) {
  if (raw is Map) {
    return raw.map((k, v) => MapEntry(k.toString(), v));
  }
  if (raw is String) {
    // We don't decode JSON here — keeping the dependency surface narrow
    // and the failure mode safe. If we ever need it, parse with
    // jsonDecode(raw) — but in practice FunctionException details
    // arrives as a Map already.
  }
  return const <String, dynamic>{};
}

// ─────────────────────────────────────────────────────────────────────
// Supabase AuthApiException
// ─────────────────────────────────────────────────────────────────────

AppError _fromAuthApi(sb.AuthApiException e) {
  final String msg = e.message.toLowerCase();

  if (msg.contains('already') &&
      (msg.contains('registered') || msg.contains('exists'))) {
    return AppError(
      kind: AppErrorKind.validation,
      userMessage: 'That email is already linked to another account.',
      cause: e,
    );
  }
  if (msg.contains('invalid') && msg.contains('token')) {
    return AppError(
      kind: AppErrorKind.validation,
      userMessage:
          "That code didn't match. Double-check it or request a new one.",
      cause: e,
    );
  }
  if (msg.contains('rate') || msg.contains('too many')) {
    return AppError(
      kind: AppErrorKind.serverError,
      userMessage:
          'Too many tries — wait a minute before requesting another code.',
      cause: e,
      retryable: false,
    );
  }
  if (msg.contains('network') || msg.contains('failed to fetch')) {
    return AppError(
      kind: AppErrorKind.network,
      userMessage: "You're offline. Check your connection and try again.",
      cause: e,
      retryable: true,
    );
  }
  return AppError(
    kind: AppErrorKind.unknown,
    userMessage: 'We couldn\'t complete that just now. Please try again.',
    cause: e,
    retryable: true,
  );
}

String _sanitizeAuthMessage(String raw) {
  // Strip URLs and JSON-y noise that sometimes leaks into AuthException
  // messages from Supabase. If nothing readable survives, fall back to
  // the generic line.
  final String stripped = raw
      .replaceAll(RegExp(r'https?://\S+'), '')
      .replaceAll(RegExp(r'\{[^}]*\}'), '')
      .trim();
  if (stripped.isEmpty || stripped.length > 140) {
    return 'We couldn\'t complete that just now. Please try again.';
  }
  return stripped;
}

// ─────────────────────────────────────────────────────────────────────
// PlatformException — image_picker / file_picker / camera / mic
// ─────────────────────────────────────────────────────────────────────

AppError _fromPlatform(PlatformException e) {
  final String code = (e.code).toLowerCase();
  if (code.contains('permission') || code.contains('denied')) {
    return AppError(
      kind: AppErrorKind.permissionDenied,
      userMessage:
          "We don't have permission to do that. Allow access in your device settings and try again.",
      code: code,
      cause: e,
    );
  }
  if (code.contains('camera_access') || code.contains('photo_access')) {
    return AppError(
      kind: AppErrorKind.permissionDenied,
      userMessage:
          'Allow camera and photo access in Settings, then try again.',
      code: code,
      cause: e,
    );
  }
  if (code.contains('user_cancel') || code.contains('canceled')) {
    // User canceled — not an error. Use a neutral message; UI should
    // typically not display this at all.
    return AppError(
      kind: AppErrorKind.unknown,
      userMessage: 'Canceled.',
      code: code,
      cause: e,
    );
  }
  if (code.contains('file_size') || (e.message ?? '').toLowerCase().contains('too large')) {
    return AppError(
      kind: AppErrorKind.fileTooLarge,
      userMessage:
          'That file is too large. Try a smaller one (under 25 MB).',
      code: code,
      cause: e,
    );
  }
  return AppError(
    kind: AppErrorKind.unknown,
    userMessage: 'Something went wrong on your device. Please try again.',
    code: code,
    cause: e,
    retryable: true,
  );
}

// ─────────────────────────────────────────────────────────────────────
// Logging
// ─────────────────────────────────────────────────────────────────────

void _logRaw(Object e, String? actionContext) {
  final String name = actionContext == null ? 'yve.error' : 'yve.error.$actionContext';
  developer.log(
    e.toString(),
    name: name,
    error: e,
    level: 1000, // SEVERE in dart:developer ranking
  );
}
