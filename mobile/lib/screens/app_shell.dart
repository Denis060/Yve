import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/concept_review.dart';
import '../models/learner_profile.dart';
import '../services/entitlement_service.dart';
import '../services/notifications_service.dart';
import '../services/profile_service.dart';
import '../services/retention_service.dart';
// Conditional import: real impl reads the URL on web, no-op stub on
// mobile (where Stripe return is handled via the resume lifecycle).
import '../utils/web_url_cleanup.dart'
    if (dart.library.js_interop) '../utils/web_url_cleanup_web.dart'
    as web_url;
import '../widgets/yve_bottom_nav.dart';
import 'home_screen.dart';
import 'profile_screen.dart';
import 'scan_screen.dart';
import 'study_screen.dart';
import 'subjects_screen.dart';

/// Top-level container holding the five tabs. Uses [IndexedStack] so each tab
/// keeps its scroll position and ephemeral state when the user swaps tabs.
///
/// Also the orchestration point for daily review-nudge scheduling — anytime
/// the profile or the review queue changes, we re-evaluate whether a local
/// notification should be on the calendar.
class AppShell extends ConsumerStatefulWidget {
  const AppShell({super.key, this.initialIndex = 0});

  final int initialIndex;

  @override
  ConsumerState<AppShell> createState() => _AppShellState();
}

class _AppShellState extends ConsumerState<AppShell>
    with WidgetsBindingObserver {
  late int _index = widget.initialIndex;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // Web: Stripe Checkout returns the user to the SAME tab with a
    // `?checkout=success|cancel` marker (mobile uses the resume lifecycle
    // below instead). On a success return, refresh entitlement so the
    // plan flips without a manual tap, and confirm with a toast. On
    // mobile this is a no-op stub.
    final String? checkoutReturn = web_url.takeCheckoutReturnSignal();
    if (checkoutReturn != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        if (checkoutReturn == 'success') {
          ref.read(entitlementProvider.notifier).refresh();
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text("You're on Yve Pro. Welcome aboard."),
            ),
          );
        }
        // 'cancel' just lands them back in the app silently — no toast,
        // no plan change. The marker is already stripped from the URL.
      });
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Returning from the in-app browser (Stripe Checkout) is the most
    // likely reason for a foreground resume right after a purchase, so
    // refresh entitlement so the new plan lands without a manual tap.
    if (state == AppLifecycleState.resumed) {
      ref.read(entitlementProvider.notifier).refresh();
    }
  }

  void _reschedule() {
    // `.valueOrNull` is the safe accessor — `.value` in newer Riverpod
    // *rethrows* the provider's error state, so a transient network
    // failure during a profile fetch escapes as an unhandled exception
    // (caught by Sentry as fatal). Captured 2026-05-19 from users with
    // intermittent connectivity.
    final LearnerProfile? profile = ref.read(profileProvider).valueOrNull;
    final List<ConceptReview> queue =
        ref.read(reviewQueueProvider).valueOrNull ?? const <ConceptReview>[];
    if (profile == null) return;
    final bool active = profile.notificationsEnabled && queue.isNotEmpty;
    unawaited(
      ref
          .read(notificationsServiceProvider)
          .reschedule(hasDueReviews: active),
    );
  }

  @override
  Widget build(BuildContext context) {
    // Side-effectful listeners — they fire on every change of either
    // source. The reschedule itself is idempotent (it cancels + replaces
    // any pending nudge), so duplicate fires are safe.
    ref.listen<AsyncValue<LearnerProfile>>(
      profileProvider,
      (_, __) => _reschedule(),
    );
    ref.listen<AsyncValue<List<ConceptReview>>>(
      reviewQueueProvider,
      (_, __) => _reschedule(),
    );

    return Scaffold(
      body: IndexedStack(
        index: _index,
        children: const <Widget>[
          HomeScreen(),
          SubjectsScreen(),
          ScanScreen(),
          StudyScreen(),
          ProfileScreen(),
        ],
      ),
      bottomNavigationBar: YveBottomNav(
        currentIndex: _index,
        onTap: (int i) => setState(() => _index = i),
      ),
    );
  }
}

