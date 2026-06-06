import 'package:flutter/foundation.dart';

/// What the rest of the app needs to know about who's signed in. Built from
/// the current Supabase auth user joined with the optional `profiles.display_name`.
@immutable
class Account {
  const Account({
    required this.userId,
    required this.isAnonymous,
    this.email,
    this.displayName,
  });

  final String userId;
  final bool isAnonymous;
  final String? email;
  final String? displayName;

  bool get isSignedIn => !isAnonymous;

  /// Best human-readable label for greetings, profile headers, etc.
  /// Falls back through display name → email-local-part → "Guest learner" → "Learner".
  String get friendlyName {
    if (displayName != null && displayName!.trim().isNotEmpty) {
      return displayName!.trim();
    }
    if (email != null && email!.contains('@')) {
      final String local = email!.split('@').first;
      if (local.isNotEmpty) return local;
    }
    return isAnonymous ? 'Guest learner' : 'Learner';
  }

  /// Short subtitle for the Profile card — surfaces auth state honestly.
  String get statusLine {
    if (isAnonymous) {
      return 'Anonymous device account · sign in to keep your work safe';
    }
    return email ?? 'Signed in';
  }

  // Value equality so Riverpod's StreamProvider doesn't treat every
  // re-emit as a fresh value — otherwise every Supabase auth tick
  // (TOKEN_REFRESHED, USER_UPDATED, etc.) rebuilds every consumer of
  // accountProvider, which in turn clobbers any focused TextField with
  // a controller backed by an Account-derived prop.
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is Account &&
          runtimeType == other.runtimeType &&
          userId == other.userId &&
          isAnonymous == other.isAnonymous &&
          email == other.email &&
          displayName == other.displayName;

  @override
  int get hashCode => Object.hash(userId, isAnonymous, email, displayName);
}
