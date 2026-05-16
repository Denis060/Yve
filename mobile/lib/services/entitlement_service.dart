import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

import '../models/entitlement.dart';

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
    final CheckoutSession session = await ref
        .read(entitlementRepositoryProvider)
        .createCheckoutUrl(
          plan: plan,
          successUrl: successUrl,
          cancelUrl: cancelUrl,
        );
    final bool ok = await launchUrl(
      Uri.parse(session.url),
      mode: LaunchMode.externalApplication,
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
    final String url = await ref
        .read(entitlementRepositoryProvider)
        .createPortalUrl(returnUrl: returnUrl);
    final bool ok = await launchUrl(
      Uri.parse(url),
      mode: LaunchMode.externalApplication,
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
