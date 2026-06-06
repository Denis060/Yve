import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io' show Platform;
import 'dart:math' show Random;

import 'package:crypto/crypto.dart' show sha256;
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sign_in_with_apple/sign_in_with_apple.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../screens/oauth_webview_screen.dart';
import 'entitlement_service.dart';
import 'profile_service.dart';
import 'retention_service.dart';
import 'sessions_service.dart';
import 'subjects_service.dart';

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
  /// The requested OAuth provider isn't enabled in this Supabase
  /// project (or the credentials are bad). Surface a "Google sign-in
  /// isn't available yet" message rather than a raw exception.
  providerNotEnabled,
  unknown,
}

/// Whether we're sending the OTP as part of upgrading an anonymous
/// session (email_change template) or signing in to an existing
/// account (magic_link template). Both arrive in the user's inbox as
/// a 6-digit code — the [OtpType] only matters when verifying.
enum OtpPurpose { upgradeAnonymous, signInExisting }

/// SharedPreferences key holding the anonymous user_id we should claim
/// rows for once a real sign-in finishes. We persist it (rather than
/// keeping it in-memory) because the OAuth round-trip on mobile sends
/// the process to background — Android can kill+restart Yve while
/// Chrome is open, and we'd lose the anon UID otherwise.
const String _kPendingAnonClaim = 'pending_anon_claim_uid';

/// Owns the device's Supabase session lifecycle. Always keeps *some* session
/// active so RLS-protected reads/writes never see a null uid — sign-out
/// immediately re-establishes an anonymous session.
class AuthService {
  AuthService(this._client);

  final SupabaseClient _client;

  String? get currentUserId => _client.auth.currentUser?.id;
  User? get currentUser => _client.auth.currentUser;

  /// HTTPS App Link Supabase redirects back to after a third-party
  /// OAuth round-trip on mobile. Android verifies ownership of
  /// app.getyve.com against the signing cert via the
  /// `/.well-known/assetlinks.json` file we host there, then routes
  /// every browser navigation to this URL straight into the app —
  /// works on Samsung Internet, Firefox, etc., not just Chrome.
  ///
  /// The intent-filter in AndroidManifest also keeps the legacy
  /// `io.getyve.yve://login-callback` custom-scheme as a fallback for
  /// environments where App Link verification hasn't kicked in yet.
  static const String _mobileAuthCallback =
      'https://app.getyve.com/auth/callback';

  Future<void> ensureSession() async {
    if (_client.auth.currentSession != null) return;
    await _client.auth.signInAnonymously();
  }

  /// Sends a 6-digit OTP code via email. The flavor of email sent
  /// (and the OtpType used for verification) depends on [purpose]:
  ///
  ///   - [OtpPurpose.upgradeAnonymous] → updateUser(email) triggers the
  ///     `Change email` template. Adds the email to the existing
  ///     anonymous user_id so every subject / session / observation
  ///     stays attached automatically. Verified with [OtpType.emailChange].
  ///   - [OtpPurpose.signInExisting] → signInWithOtp(email) triggers the
  ///     `Magic link` template (which we configured to send the
  ///     `{{ .Token }}` code, not a link). Establishes a fresh session
  ///     on the existing account; if the caller was anonymous they
  ///     should call [claimAnonymousData] afterward to transfer guest
  ///     data into the now-authenticated account. Verified with
  ///     [OtpType.email].
  ///
  /// Throws [AuthException] with [AuthFailureKind.emailAlreadyInUse]
  /// when an upgrade-mode email belongs to a different account — the
  /// caller MUST then prompt the user with an explicit "sign in to that
  /// account instead?" confirmation. NEVER silently fall through to
  /// signInExisting without consent — see the comment block above
  /// `claimAnonymousData` for why.
  Future<void> sendOtp(String email, {required OtpPurpose purpose}) async {
    try {
      switch (purpose) {
        case OtpPurpose.upgradeAnonymous:
          // Stash the anon UID *before* the upgrade — if updateUser
          // succeeds the in-place upgrade preserves the UID and the
          // claim becomes a no-op; if the caller falls back to
          // signInExisting (separate code path) we'll still have it.
          await _stashAnonUid();
          await _client.auth.updateUser(UserAttributes(email: email));
        case OtpPurpose.signInExisting:
          // Existing-account flow always produces a fresh session, so
          // we need the claim to migrate guest data over afterward.
          await _stashAnonUid();
          await _client.auth.signInWithOtp(
            email: email,
            shouldCreateUser: true,
          );
      }
    } on AuthApiException catch (e) {
      throw _mapAuthError(e);
    } catch (e) {
      throw AuthException(AuthFailureKind.unknown, e.toString());
    }
  }

  /// Verifies a 6-digit OTP from the email Yve sent. The [purpose]
  /// must match the [sendOtp] purpose for the same email — they map
  /// to different Supabase OtpType values internally.
  ///
  /// After a successful verify this auto-runs [claimAnonymousData] if
  /// the device had a stashed anon UID — so all guest work flows into
  /// the now-authenticated account without the caller having to remember.
  Future<void> verifyOtp({
    required String email,
    required String code,
    required OtpPurpose purpose,
  }) async {
    try {
      final OtpType type = switch (purpose) {
        OtpPurpose.upgradeAnonymous => OtpType.emailChange,
        OtpPurpose.signInExisting => OtpType.email,
      };
      await _client.auth.verifyOTP(
        email: email,
        token: code,
        type: type,
      );
      // Fire-and-forget — a failed claim shouldn't fail the verify.
      // We log the error inside the claim helper.
      unawaited(_runPendingClaim());
    } on AuthApiException catch (e) {
      throw _mapAuthError(e);
    } catch (e) {
      throw AuthException(AuthFailureKind.unknown, e.toString());
    }
  }

  /// Anonymous → real account via OAuth (Apple / Google).
  ///
  /// We use [signInWithOAuth] (NOT [linkIdentity]) even from an anonymous
  /// session, because linkIdentity's callback URL doesn't auto-finalize
  /// on Android with `supabase_flutter` 2.5 — the browser tab hangs after
  /// account selection. signInWithOAuth uses the standard `/authorize`
  /// endpoint which the SDK's deep link handler routes correctly.
  ///
  /// To preserve guest work across the platform-change, we:
  ///   1. Stash the anon user_id in SharedPreferences *before* opening
  ///      the OAuth browser (the process may be killed during the OAuth
  ///      hop on Android).
  ///   2. Listen for `AuthChangeEvent.signedIn` (in the provider below).
  ///   3. On signed-in, POST the stashed UID to `claim-anonymous-data`
  ///      which UPDATEs every user_id-bearing row from anon → authed.
  /// Returns `true` if the OAuth flow actually finished and a real
  /// session landed, `false` if the user dismissed the in-app WebView
  /// or otherwise bailed out before sign-in completed. Callers that
  /// dismiss UI on success (the continuation panel, the auth gate)
  /// MUST check this so a cancelled flow doesn't fall through as if
  /// the user signed in successfully (which would let gated actions
  /// like Word export run for users who never authed).
  ///
  /// On web we can't introspect the redirect cleanly — `signInWithOAuth`
  /// returns before the OAuth round-trip completes — so we return
  /// `true` optimistically and let the auth-state listener drive the
  /// real state transition.
  Future<bool> continueWithOAuth(
    OAuthProvider provider, {
    BuildContext? context,
  }) async {
    try {
      final String? redirectTo = kIsWeb ? Uri.base.origin : _mobileAuthCallback;
      await _stashAnonUid();

      // On Android we run the OAuth flow in an embedded WebView. The
      // alternatives all have proven failure modes:
      //   - Custom Tabs: don't trigger App Link intents on the callback
      //     redirect, so user lands on a 404 / bridge page
      //   - External browser: Samsung Internet silently swallows the
      //     deep-link intent from the bridge page, leaving the user
      //     stranded with no way back to Yve
      //   - signInWithOAuth's auto-launch: forces external browser for
      //     Google on Android, hitting the Samsung Internet bug above
      //
      // The WebView path owns navigation end-to-end: we get the auth
      // URL via getOAuthSignInUrl(), load it, intercept the callback
      // before WebView even fetches our hosting, and finish the PKCE
      // exchange via getSessionFromUrl(). Works on every Android device
      // regardless of default browser. Requires a BuildContext to push
      // the WebView screen; callers that don't have one (legacy) fall
      // back to signInWithOAuth's external launch.
      final bool useWebView =
          !kIsWeb && Platform.isAndroid && context != null;
      if (useWebView) {
        final OAuthResponse res = await _client.auth.getOAuthSignInUrl(
          provider: provider,
          redirectTo: redirectTo,
        );
        if (!context.mounted) return false;
        final bool? ok = await Navigator.of(context).push<bool>(
          MaterialPageRoute<bool>(
            fullscreenDialog: true,
            builder: (_) => OAuthWebViewScreen(
              authUrl: res.url,
              callbackHost: 'app.getyve.com',
              callbackPathPrefix: '/auth/callback',
            ),
          ),
        );
        if (ok == true) {
          unawaited(_runPendingClaim());
          return true;
        }
        return false;
      }

      await _client.auth.signInWithOAuth(
        provider,
        redirectTo: redirectTo,
        authScreenLaunchMode: kIsWeb
            ? LaunchMode.platformDefault
            : LaunchMode.externalApplication,
      );
      // External-browser flow on mobile or new-tab on web: the result
      // arrives async via the SDK's deep-link listener. We can't await
      // a definitive yes/no here, so return true optimistically — the
      // auth state watcher invalidates UI providers on real sign-in.
      return true;
    } on AuthApiException catch (e) {
      throw _mapAuthError(e);
    } catch (e) {
      final String msg = e.toString().toLowerCase();
      if (msg.contains('not enabled') || msg.contains('provider is not')) {
        throw AuthException(
          AuthFailureKind.providerNotEnabled,
          '${_providerName(provider)} sign-in isn\'t available yet. Use email instead.',
        );
      }
      throw AuthException(AuthFailureKind.unknown, e.toString());
    }
  }

  String _providerName(OAuthProvider provider) {
    switch (provider) {
      case OAuthProvider.google: return 'Google';
      case OAuthProvider.apple:  return 'Apple';
      default: return 'That';
    }
  }

  /// Sign in with Apple via the native iOS sheet (or the web flow on
  /// non-Apple platforms). Apple's App Store rules (Guideline 4.8)
  /// require us to offer Apple Sign In whenever we offer any other
  /// social login — so this path is mandatory once we add Google.
  ///
  /// Flow:
  ///   1. Generate a random nonce + its SHA-256 hash.
  ///   2. Ask Apple for an ID token, sending the hash as the nonce.
  ///   3. Hand the ID token + raw nonce to Supabase's
  ///      `signInWithIdToken`. Supabase verifies the JWT signature
  ///      against Apple's published public keys and confirms the
  ///      nonce-hash inside the token matches our raw nonce — proves
  ///      the token isn't a replay from another session.
  ///   4. Auth state changes; the watcher fires the claim function.
  ///
  /// Returns true on success, false if the user dismissed Apple's
  /// sheet without completing.
  Future<bool> continueWithApple({BuildContext? context}) async {
    try {
      await _stashAnonUid();

      // Nonce hardening — Apple signs the *hash* of our nonce into
      // the ID token; Supabase checks our raw nonce against that
      // hash. Anyone replaying a stolen token would need to also
      // present the raw nonce, which only this device generated.
      final String rawNonce = _generateNonce();
      final String hashedNonce = sha256.convert(utf8.encode(rawNonce)).toString();

      final AuthorizationCredentialAppleID cred =
          await SignInWithApple.getAppleIDCredential(
        scopes: <AppleIDAuthorizationScopes>[
          AppleIDAuthorizationScopes.email,
          AppleIDAuthorizationScopes.fullName,
        ],
        nonce: hashedNonce,
        // Web fallback config — required for non-iOS Apple sign-in.
        // Service ID and redirect URI come from Apple Developer portal
        // setup (documented in docs/IOS_BUILD.md).
        webAuthenticationOptions: kIsWeb || !Platform.isIOS
            ? WebAuthenticationOptions(
                clientId: 'io.getyve.yve.web',
                redirectUri: Uri.parse(
                  'https://ftekdhcomxxhbihvsyyw.supabase.co/auth/v1/callback',
                ),
              )
            : null,
      );

      final String? idToken = cred.identityToken;
      if (idToken == null || idToken.isEmpty) {
        throw AuthException(
          AuthFailureKind.unknown,
          'Apple didn\'t return an identity token.',
        );
      }
      await _client.auth.signInWithIdToken(
        provider: OAuthProvider.apple,
        idToken: idToken,
        nonce: rawNonce,
      );
      // Auth state listener will run the claim. Return true so the
      // caller can dismiss whatever UI prompted sign-in.
      return true;
    } on SignInWithAppleAuthorizationException catch (e) {
      // User cancelled the Apple sheet — explicit signal to bail out.
      if (e.code == AuthorizationErrorCode.canceled) return false;
      throw AuthException(AuthFailureKind.unknown, e.message);
    } on AuthApiException catch (e) {
      throw _mapAuthError(e);
    } catch (e) {
      throw AuthException(AuthFailureKind.unknown, e.toString());
    }
  }

  /// Cryptographically-random 32-character nonce.
  static String _generateNonce([int length = 32]) {
    const String charset =
        'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._';
    final Random random = Random.secure();
    return List<int>.generate(length, (_) => random.nextInt(charset.length))
        .map((int i) => charset[i])
        .join();
  }

  /// Signs out and immediately re-establishes an anonymous session so the
  /// app always has a uid for RLS.
  Future<void> signOut() async {
    await _client.auth.signOut();
    // Drop any stale claim pointer — once the user signs out we're not
    // mid-upgrade anymore.
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.remove(_kPendingAnonClaim);
    await _client.auth.signInAnonymously();
  }

  // ── Anonymous-data claim ──────────────────────────────────────────

  /// Stash the current anon user_id so we can transfer their rows
  /// after the sign-in lands. No-op for already-named users.
  Future<void> _stashAnonUid() async {
    final User? user = _client.auth.currentUser;
    if (user == null) return;
    if (user.isAnonymous != true) return;
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kPendingAnonClaim, user.id);
  }

  /// Returns the stashed anon UID and clears it. Called from the
  /// auth-state listener as soon as a real sign-in lands.
  Future<String?> _takePendingAnonUid() async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    final String? uid = prefs.getString(_kPendingAnonClaim);
    if (uid != null) {
      await prefs.remove(_kPendingAnonClaim);
    }
    return uid;
  }

  /// Drives the post-sign-in data transfer. Safe to call repeatedly:
  /// the server no-ops when the stashed UID equals the current UID
  /// (which is what happens on the email-upgrade in-place path).
  Future<void> _runPendingClaim() async {
    try {
      final String? anonUid = await _takePendingAnonUid();
      if (anonUid == null) return;
      final User? current = _client.auth.currentUser;
      if (current == null || current.isAnonymous == true) {
        // Sign-in didn't land yet — re-stash so the next auth state
        // change can retry.
        final SharedPreferences prefs = await SharedPreferences.getInstance();
        await prefs.setString(_kPendingAnonClaim, anonUid);
        return;
      }
      if (anonUid == current.id) {
        // In-place upgrade (updateUser path); no claim required.
        return;
      }
      developer.log(
        'claiming anon data: $anonUid → ${current.id}',
        name: 'auth.claim',
      );
      final FunctionResponse res = await _client.functions.invoke(
        'claim-anonymous-data',
        body: <String, String>{'anon_uid': anonUid},
      );
      developer.log(
        'claim response: status=${res.status} body=${res.data}',
        name: 'auth.claim',
      );
    } catch (e, st) {
      developer.log(
        'claim failed: $e',
        name: 'auth.claim',
        error: e,
        stackTrace: st,
      );
    }
  }

  /// Auto-runs after any auth state change to catch OAuth deep-link
  /// finalizations we don't get to await directly. Wired from
  /// [authClaimWatcherProvider] below.
  Future<void> onAuthStateChange(AuthState event) async {
    if (event.event == AuthChangeEvent.signedIn ||
        event.event == AuthChangeEvent.userUpdated) {
      await _runPendingClaim();
    }
  }

  AuthException _mapAuthError(AuthApiException e) {
    final String msg = e.message.toLowerCase();
    if (msg.contains('not enabled') || msg.contains('provider is not')) {
      return AuthException(
        AuthFailureKind.providerNotEnabled,
        'That sign-in method isn\'t available yet. Use email instead.',
      );
    }
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

/// Subscribes to Supabase auth state changes for the lifetime of the app.
///
/// Does two things on every `signedIn` / `userUpdated` event:
///
///   1. Runs the anon-data claim (transfers any guest work to the
///      now-authenticated user via the claim-anonymous-data function).
///   2. **Invalidates every user-scoped provider** so the rest of the
///      UI re-fetches against the new session immediately. Without
///      this, the subjects list / entitlement / review queue keep
///      showing the prior session's cached data and the user thinks
///      their work disappeared until they force-close the app.
///
/// `accountProvider` and `profileProvider` already self-invalidate
/// because they're built on top of `onAuthStateChange`. The others
/// listed here don't, hence the explicit invalidation.
final authClaimWatcherProvider = Provider<StreamSubscription<AuthState>>((ref) {
  final AuthService service = ref.read(authServiceProvider);
  final StreamSubscription<AuthState> sub = Supabase.instance.client.auth
      .onAuthStateChange
      .listen((AuthState event) async {
    // Claim first so the providers that re-fetch below see the
    // already-transferred data, not empty rows.
    await service.onAuthStateChange(event);

    final bool sessionChanged = event.event == AuthChangeEvent.signedIn ||
        event.event == AuthChangeEvent.signedOut ||
        event.event == AuthChangeEvent.userUpdated;
    if (!sessionChanged) return;

    // Re-fetch every user-scoped surface. Order doesn't matter; each
    // provider rebuilds against the current auth session independently.
    ref.invalidate(subjectsProvider);
    ref.invalidate(recentSessionsProvider);
    ref.invalidate(entitlementProvider);
    ref.invalidate(reviewQueueProvider);
    ref.invalidate(weekActivityProvider);
  });
  ref.onDispose(sub.cancel);
  return sub;
});
