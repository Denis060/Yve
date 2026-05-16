import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Errors emitted by [AuthService] when the auth flow runs into a known
/// edge case the UI needs to react to specifically.
class AuthException implements Exception {
  AuthException(this.kind, this.message);
  final AuthFailureKind kind;
  final String message;
  @override
  String toString() => message;
}

enum AuthFailureKind {
  emailAlreadyInUse,
  invalidCode,
  rateLimited,
  network,
  unknown,
}

/// Owns the device's Supabase session lifecycle. Always keeps *some* session
/// active so RLS-protected reads/writes never see a null uid — sign-out
/// immediately re-establishes an anonymous session.
class AuthService {
  AuthService(this._client);

  final SupabaseClient _client;

  String? get currentUserId => _client.auth.currentUser?.id;
  User? get currentUser => _client.auth.currentUser;

  Future<void> ensureSession() async {
    if (_client.auth.currentSession != null) return;
    await _client.auth.signInAnonymously();
  }

  /// Anonymous → real account. Adds the email to the existing user row so
  /// every subject / session / observation stays attached. The learner
  /// receives a 6-digit code to verify ownership.
  ///
  /// Throws [AuthException] with [AuthFailureKind.emailAlreadyInUse] when
  /// the email is bound to a different account — the caller should fall
  /// back to [sendSignInCode] (with the data-loss warning the UI surfaces).
  Future<void> sendLinkCode(String email) async {
    try {
      await _client.auth.updateUser(UserAttributes(email: email));
    } on AuthApiException catch (e) {
      throw _mapAuthError(e);
    } catch (e) {
      throw AuthException(AuthFailureKind.unknown, e.toString());
    }
  }

  /// Existing-account sign-in path. The current anonymous user is dropped
  /// once the new session is established — local data tied to that
  /// anonymous user_id remains in Postgres but becomes invisible to this
  /// device (which is why the UI warns before going down this path).
  Future<void> sendSignInCode(String email) async {
    try {
      await _client.auth.signInWithOtp(
        email: email,
        shouldCreateUser: true,
      );
    } on AuthApiException catch (e) {
      throw _mapAuthError(e);
    } catch (e) {
      throw AuthException(AuthFailureKind.unknown, e.toString());
    }
  }

  /// Verifies the 6-digit code. Pass [isLink]=true for the upgrade flow
  /// (uses [OtpType.emailChange]); false for plain sign-in ([OtpType.email]).
  Future<void> verifyCode({
    required String email,
    required String code,
    required bool isLink,
  }) async {
    try {
      await _client.auth.verifyOTP(
        email: email,
        token: code,
        type: isLink ? OtpType.emailChange : OtpType.email,
      );
    } on AuthApiException catch (e) {
      throw _mapAuthError(e);
    } catch (e) {
      throw AuthException(AuthFailureKind.unknown, e.toString());
    }
  }

  /// Anonymous → real account via OAuth (Apple / Google). Uses
  /// linkIdentity when there's an active anonymous session so the
  /// existing user_id is preserved — anonymous subjects, sessions,
  /// scans, and concept history all stay attached. For an already-
  /// named user (rare in this flow), falls back to signInWithOAuth.
  ///
  /// On web Supabase navigates automatically; on mobile the caller may
  /// need to handle the deep-link callback.
  Future<void> continueWithOAuth(OAuthProvider provider) async {
    try {
      final User? user = _client.auth.currentUser;
      if (user != null && user.isAnonymous == true) {
        await _client.auth.linkIdentity(provider);
      } else {
        await _client.auth.signInWithOAuth(provider);
      }
    } on AuthApiException catch (e) {
      throw _mapAuthError(e);
    } catch (e) {
      throw AuthException(AuthFailureKind.unknown, e.toString());
    }
  }

  /// Signs out and immediately re-establishes an anonymous session so the
  /// app always has a uid for RLS.
  Future<void> signOut() async {
    await _client.auth.signOut();
    await _client.auth.signInAnonymously();
  }

  AuthException _mapAuthError(AuthApiException e) {
    final String msg = e.message.toLowerCase();
    if (msg.contains('already') &&
        (msg.contains('registered') || msg.contains('exists'))) {
      return AuthException(
        AuthFailureKind.emailAlreadyInUse,
        'That email is already linked to another account.',
      );
    }
    if (msg.contains('invalid') && msg.contains('token')) {
      return AuthException(
        AuthFailureKind.invalidCode,
        'That code didn\'t match. Double-check it or request a new one.',
      );
    }
    if (msg.contains('rate') || msg.contains('too many')) {
      return AuthException(
        AuthFailureKind.rateLimited,
        'Too many tries — wait a minute before requesting another code.',
      );
    }
    return AuthException(AuthFailureKind.unknown, e.message);
  }
}

final authServiceProvider = Provider<AuthService>((_) {
  return AuthService(Supabase.instance.client);
});

/// Resolves once the device has a valid auth session. Gates the rest of the
/// app behind successful sign-in so RLS-protected queries always have a uid.
final authReadyProvider = FutureProvider<void>((ref) async {
  await ref.read(authServiceProvider).ensureSession();
});
