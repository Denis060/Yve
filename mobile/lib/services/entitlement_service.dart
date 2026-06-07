import 'dart:async';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

import '../config/billing_config.dart';
import '../models/entitlement.dart';

/// Custom-scheme deep link Stripe redirects back to after Checkout on
/// mobile. Must match an intent-filter <data> entry in AndroidManifest
/// (and the equivalent CFBundleURLTypes entry on iOS, when wired). The
/// `?return=...` query lets us distinguish which screen to land on if
/// we ever want explicit routing — for now app_shell.dart just refreshes
/// entitlement on AppLifecycleState.resumed, so either path works.
const String _mobileCheckoutSuccess =
    'https://app.getyve.com/checkout/success';
const String _mobileCheckoutCancel =
    'https://app.getyve.com/checkout/cancel';

/// Web fallbacks — the in-tab Stripe Checkout returns the user to the
/// origin so they land back on the running SPA. Server-side defaults
/// (STRIPE_SUCCESS_URL / STRIPE_CANCEL_URL env vars) are only used if
/// the client doesn't pass a value — which it now always does.
String _webCheckoutSuccess() => '${Uri.base.origin}/upgrade/success';
String _webCheckoutCancel() => '${Uri.base.origin}/upgrade/cancel';

class EntitlementRepository {
  EntitlementRepository(this._client);
  final SupabaseClient _client;

  /// Reads the current learner's entitlement. Lazily defaults to
  /// [Entitlement.freeDefault] when no subscriptions row exists yet —
  /// matches the server-side lazy default in `_shared/entitlements.ts`.
  Future<Entitlement> read() async {
    final String? uid = _client.auth.currentUser?.id;
    if (uid == null) return Entitlement.freeDefault;
    try {
      final List<dynamic> rows = await _client
          .from('subscriptions')
          .select()
          .eq('user_id', uid)
          .limit(1);
      if (rows.isEmpty) return Entitlement.freeDefault;
      return Entitlement.fromRow(rows.first as Map<String, dynamic>);
    } catch (_) {
      return Entitlement.freeDefault;
    }
  }

  /// Asks the server to create a Stripe Checkout session for the
  /// specified plan and returns the URL + whether a 3-day trial was
  /// granted. The client opens the URL in an in-app browser; Stripe
  /// collects the card, creates the subscription, redirects back.
  Future<CheckoutSession> createCheckoutUrl({
    required Plan plan,
    String? successUrl,
    String? cancelUrl,
  }) async {
    if (!plan.isPro) {
      throw EntitlementException(
        message: 'Free is not a checkout target.',
      );
    }
    final res = await _client.functions.invoke(
      'create-checkout-session',
      body: <String, dynamic>{
        'plan_code': plan.wire,
        if (successUrl != null) 'success_url': successUrl,
        if (cancelUrl != null) 'cancel_url': cancelUrl,
      },
    );
    final Map<String, dynamic> data = res.data is Map
        ? Map<String, dynamic>.from(res.data as Map<dynamic, dynamic>)
        : <String, dynamic>{};
    if (res.status != 200) {
      final String message = (data['error'] as String?) ??
          'Couldn\'t start checkout (status ${res.status}).';
      throw EntitlementException(
        code: data['code'] as String?,
        message: message,
      );
    }
    final String? url = data['url'] as String?;
    if (url == null || url.isEmpty) {
      throw EntitlementException(message: 'Server didn\'t return a URL.');
    }
    return CheckoutSession(
      url: url,
      trialGranted: (data['trial_granted'] as bool?) ?? false,
    );
  }

  /// Asks the server to create a Stripe Customer Portal session for
  /// the current user. Used to cancel, update card, or switch plans.
  /// Returns the URL to open.
  Future<String> createPortalUrl({String? returnUrl}) async {
    final res = await _client.functions.invoke(
      'stripe-customer-portal',
      body: <String, dynamic>{
        if (returnUrl != null) 'return_url': returnUrl,
      },
    );
    final Map<String, dynamic> data = res.data is Map
        ? Map<String, dynamic>.from(res.data as Map<dynamic, dynamic>)
        : <String, dynamic>{};
    if (res.status != 200) {
      throw EntitlementException(
        code: data['error'] as String?,
        message: (data['detail'] as String?) ??
            (data['error'] as String?) ??
            'Couldn\'t open billing portal (status ${res.status}).',
      );
    }
    final String? url = data['url'] as String?;
    if (url == null || url.isEmpty) {
      throw EntitlementException(message: 'Server didn\'t return a URL.');
    }
    return url;
  }
}

class CheckoutSession {
  const CheckoutSession({required this.url, required this.trialGranted});
  final String url;
  final bool trialGranted;
}

class EntitlementException implements Exception {
  EntitlementException({required this.message, this.code});
  final String? code;
  final String message;
  @override
  String toString() => message;
}

final entitlementRepositoryProvider = Provider<EntitlementRepository>((_) {
  return EntitlementRepository(Supabase.instance.client);
});

/// Live entitlement. Refetches on every Supabase auth state change (so
/// signing in / out flips the plan correctly) and exposes a manual
/// `refresh()` for after the Checkout flow returns.
class EntitlementNotifier extends AsyncNotifier<Entitlement> {
  StreamSubscription<AuthState>? _authSub;

  @override
  Future<Entitlement> build() async {
    // Re-fetch when auth changes — the user_id is the cache key implicitly.
    _authSub?.cancel();
    _authSub = Supabase.instance.client.auth.onAuthStateChange.listen((_) {
      refresh();
    });
    ref.onDispose(() => _authSub?.cancel());
    return ref.read(entitlementRepositoryProvider).read();
  }

  Future<void> refresh() async {
    state = const AsyncLoading<Entitlement>();
    state = await AsyncValue.guard<Entitlement>(
      () => ref.read(entitlementRepositoryProvider).read(),
    );
  }

  /// Kicks off the upgrade flow for the chosen plan. Server creates a
  /// Stripe Checkout session; we open the returned URL in the in-app
  /// browser. The actual entitlement flip arrives via the webhook;
  /// the caller should `refresh()` when the user returns to the app.
  Future<CheckoutSession> launchCheckoutFor(
    Plan plan, {
    String? successUrl,
    String? cancelUrl,
  }) async {
    // Hard backstop for App Store compliance: never open an external
    // Stripe checkout on iOS until the External Link entitlement lands.
    // No iOS UI path reaches here while the gate is closed; this guards
    // against future callers slipping through.
    if (!BillingConfig.upgradeEnabled) {
      throw EntitlementException(
        message: 'In-app upgrades aren\'t available here yet.',
      );
    }
    // Default to platform-appropriate return URLs so the user lands back
    // in the app instead of getting stranded on a Stripe-hosted page.
    final String resolvedSuccess = successUrl ??
        (kIsWeb ? _webCheckoutSuccess() : _mobileCheckoutSuccess);
    final String resolvedCancel = cancelUrl ??
        (kIsWeb ? _webCheckoutCancel() : _mobileCheckoutCancel);
    final CheckoutSession session = await ref
        .read(entitlementRepositoryProvider)
        .createCheckoutUrl(
          plan: plan,
          successUrl: resolvedSuccess,
          cancelUrl: resolvedCancel,
        );
    final bool ok = await launchUrl(
      Uri.parse(session.url),
      // Mobile: external in-app browser, app resumes after (app_shell
      // refreshes entitlement on AppLifecycleState.resumed).
      // Web: navigate the SAME tab (_self). Opening a new tab strands the
      // user in a second app instance and the original never refreshes —
      // web has no reliable resume signal. Same-tab means Stripe's
      // success redirect re-enters one app, which reads ?checkout=success
      // on load and refreshes (see main.dart bootstrap).
      mode: kIsWeb
          ? LaunchMode.platformDefault
          : LaunchMode.externalApplication,
      webOnlyWindowName: kIsWeb ? '_self' : null,
    );
    if (!ok) {
      throw EntitlementException(
        message: 'Couldn\'t open the checkout page. Try again.',
      );
    }
    return session;
  }

  /// Opens the Stripe Customer Portal — cancel, switch plan, update
  /// card. The portal handles state changes; the webhook fires events
  /// that flow back into [refresh].
  Future<void> launchPortal({String? returnUrl}) async {
    // Same App Store backstop as launchCheckoutFor — no external billing
    // portal link on iOS while the upgrade gate is closed.
    if (!BillingConfig.upgradeEnabled) {
      throw EntitlementException(
        message: 'Billing management isn\'t available here yet.',
      );
    }
    // Stripe Customer Portal needs a return URL to send the user back
    // to. Same deep-link trick as Checkout — mobile gets the custom
    // scheme, web gets the running origin.
    final String resolvedReturn = returnUrl ??
        (kIsWeb
            // Was '/billing' — a page that doesn't exist, so Stripe's
            // "return to merchant" 404'd. Use the real portal return page,
            // which bounces back into the SPA.
            ? '${Uri.base.origin}/upgrade/portal'
            : 'https://app.getyve.com/checkout/portal');
    final String url = await ref
        .read(entitlementRepositoryProvider)
        .createPortalUrl(returnUrl: resolvedReturn);
    final bool ok = await launchUrl(
      Uri.parse(url),
      // Same rationale as launchCheckoutFor: same-tab on web, external
      // browser on mobile.
      mode: kIsWeb
          ? LaunchMode.platformDefault
          : LaunchMode.externalApplication,
      webOnlyWindowName: kIsWeb ? '_self' : null,
    );
    if (!ok) {
      throw EntitlementException(
        message: 'Couldn\'t open the billing portal. Try again.',
      );
    }
  }
}

final entitlementProvider =
    AsyncNotifierProvider<EntitlementNotifier, Entitlement>(
  EntitlementNotifier.new,
);
