import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sentry_flutter/sentry_flutter.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

// Conditional import: real impl on web, no-op stub on mobile/desktop.
// Needed because `package:web` requires `dart:js_interop` which doesn't
// compile on Android/iOS — a runtime kIsWeb guard isn't enough.
import 'utils/web_url_cleanup.dart'
    if (dart.library.js_interop) 'utils/web_url_cleanup_web.dart'
    as web_url;

import 'config/env.dart';
import 'screens/app_shell.dart';
import 'screens/onboarding/onboarding_flow.dart';
import 'services/auth_service.dart';
import 'services/notifications_service.dart';
import 'services/onboarding_service.dart';
import 'theme/yve_colors.dart';
import 'theme/yve_theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Sentry wraps Supabase.init + runApp so we capture errors from both
  // startup and runtime. If SENTRY_DSN is empty (local dev without the
  // dart-define), the SDK initializes with logging disabled but no
  // crashes — the app boots normally without sending any events.
  await SentryFlutter.init(
    (SentryFlutterOptions options) {
      options.dsn = Env.sentryDsn;
      options.environment = Env.env;
      // Errors only — performance tracing has its own quota that we
      // don't need yet. Bump to a sampled value (0.1 or so) once we
      // have real traffic and care about p95 latencies.
      options.tracesSampleRate = 0;
      // Don't auto-attach IPs / cookies / form data. We tag explicitly
      // with user.id below for support attribution.
      options.sendDefaultPii = false;
      // Strip anything that might contain student-typed text from
      // breadcrumbs (chat messages, assignment prompts, etc.) before
      // the event ships. This is conservative — better to lose a bit
      // of debug context than ever leak a learner's draft.
      options.beforeBreadcrumb =
          (Breadcrumb? crumb, Hint hint) => _scrubBreadcrumb(crumb);
      // Filter known-benign noise from reaching Sentry — these are
      // mostly "user reloaded a page that had a stale auth callback"
      // signals that the SDK throws internally but the user already
      // sees a clean app afterward.
      options.beforeSend =
          (SentryEvent event, Hint hint) => _filterKnownNoise(event);
    },
    appRunner: () async {
      // On web, strip any leftover OAuth callback params from the URL
      // BEFORE Supabase.initialize tries to process them. Otherwise a
      // user who reloads the post-OAuth landing page (or bookmarks it)
      // gets a "Code verifier could not be found in local storage"
      // AuthException — the SDK tries to re-exchange a code whose
      // verifier was already consumed on the first visit. The mobile
      // stub is a no-op.
      web_url.clearStaleOAuthParamsFromUrl();

      await Supabase.initialize(
        url: Env.supabaseUrl,
        anonKey: Env.supabaseAnonKey,
      );
      _wireSentryUserContext();
      runApp(const ProviderScope(child: YveApp()));
    },
  );
}

/// Drop or sanitize breadcrumbs that might carry user-typed content
/// into Sentry. We're conservative: anything that could be a chat
/// message, polish draft, or material text gets its `data` field
/// scrubbed before the event ships.
Breadcrumb? _scrubBreadcrumb(Breadcrumb? crumb) {
  if (crumb == null) return null;
  // HTTP breadcrumbs to our own functions can carry user content in
  // the request body. Drop the data map so only the URL + status code
  // remain — enough for debugging routing, not enough to leak content.
  final String? cat = crumb.category;
  if (cat == 'http' || cat == 'console') {
    return crumb.copyWith(data: <String, dynamic>{
      if (crumb.data?['url'] != null) 'url': crumb.data!['url'],
      if (crumb.data?['method'] != null) 'method': crumb.data!['method'],
      if (crumb.data?['status_code'] != null)
        'status_code': crumb.data!['status_code'],
    });
  }
  return crumb;
}

/// Drop benign errors that fire during user-induced races (page
/// reload mid-OAuth, hot-reload during deep-link handling) so they
/// don't drown the real signal in Sentry.
SentryEvent? _filterKnownNoise(SentryEvent event) {
  final String? msg = event.throwable?.toString();
  if (msg == null) return event;
  const List<String> noise = <String>[
    // OAuth race conditions — user reloaded post-callback URL
    'Code verifier could not be found in local storage',
    'invalid flow state, no valid flow state found',
    'flow state not found',
    // User lost network — not a bug, just connectivity. Captures both
    // the Dart-side ClientException and the underlying OSError.
    'No address associated with hostname',
    'Failed host lookup',
    'Software caused connection abort',
    'Connection refused',
    'Connection reset by peer',
    'Network is unreachable',
    'SocketException',
    // Camera plugin dispose race — Dart-side isInitialized is true but
    // the native surface producer is still attaching when the user
    // backs out. Dispose happens anyway, the exception is cosmetic.
    // We also swallow it in scan_screen._safelyDisposeCamera; this
    // filter catches any path we missed.
    'releaseFlutterSurfaceTexture() cannot be called',
    // Flutter web tries to load the open-source NOTICES file from the
    // app bundle for the About dialog. Static hosting doesn't ship it
    // and most users will never open About. Cosmetic.
    'Unable to load asset: "NOTICES"',
    // google_fonts fetches Inter from fonts.gstatic.com at runtime.
    // On flaky networks the fetch throws but the package transparently
    // falls back to the device's system font — the user sees nothing
    // wrong, only Sentry gets noise. Bundling Inter as a local asset
    // would eliminate this entirely (TODO when we revisit theming).
    'Failed to load font with url',
  ];
  for (final String pat in noise) {
    if (msg.contains(pat)) return null; // drop the event
  }
  return event;
}

/// Keep Sentry's user context in sync with Supabase auth so every
/// captured event tells us who hit it (anonymous vs. named) without
/// us having to thread the user_id through every error path.
void _wireSentryUserContext() {
  Future<void> apply(User? user) async {
    if (user == null) {
      await Sentry.configureScope((Scope s) => s.setUser(null));
      return;
    }
    await Sentry.configureScope((Scope s) => s.setUser(SentryUser(
          id: user.id,
          // No email/name — those are PII we don't want in error events.
          // The user_id alone is enough to cross-reference with our DB.
          data: <String, dynamic>{
            'is_anonymous': user.isAnonymous == true,
          },
        )));
  }
  unawaited(apply(Supabase.instance.client.auth.currentUser));
  Supabase.instance.client.auth.onAuthStateChange.listen((AuthState e) {
    unawaited(apply(e.session?.user));
  });
}

class YveApp extends StatelessWidget {
  const YveApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Yve',
      theme: buildYveTheme(),
      home: const _LaunchGate(),
      debugShowCheckedModeBanner: false,
    );
  }
}

/// Resolves auth → onboarding → app shell in that order. Anonymous Supabase
/// auth is established before any RLS-protected query runs, then we check
/// whether the local device has completed onboarding.
class _LaunchGate extends ConsumerWidget {
  const _LaunchGate();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AsyncValue<void> auth = ref.watch(authReadyProvider);
    // Fire-and-forget: we want notifications wired by the time the user
    // reaches a chat, but a tap-cold-start payload is already handled
    // inside the service, so no need to block the UI on it.
    ref.watch(notificationsReadyProvider);
    // Subscribes to onAuthStateChange so the anon-data claim runs as
    // soon as an OAuth deep-link finalizes a real session — even if the
    // UI flow that started the OAuth has already been popped off the
    // navigator. Watching here keeps the subscription alive for the
    // full app lifetime.
    ref.watch(authClaimWatcherProvider);
    return auth.when(
      loading: () => const _SplashScreen(),
      error: (Object e, _) => _ErrorScreen(message: e.toString()),
      data: (_) => const _OnboardingGate(),
    );
  }
}

class _OnboardingGate extends ConsumerWidget {
  const _OnboardingGate();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AsyncValue<bool> complete = ref.watch(onboardingCompleteProvider);
    return complete.when(
      loading: () => const _SplashScreen(),
      error: (_, __) => const AppShell(),
      data: (bool done) => done ? const AppShell() : const OnboardingFlow(),
    );
  }
}

class _SplashScreen extends StatelessWidget {
  const _SplashScreen();

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      backgroundColor: YveColors.primary,
      body: Center(
        child: Text(
          '✦  Yve',
          style: TextStyle(
            fontSize: 32,
            fontWeight: FontWeight.w700,
            color: YveColors.textInverse,
          ),
        ),
      ),
    );
  }
}

class _ErrorScreen extends StatelessWidget {
  const _ErrorScreen({required this.message});
  final String message;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: YveColors.background,
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              const Icon(Icons.cloud_off_rounded,
                  size: 48, color: YveColors.textTertiary),
              const SizedBox(height: 12),
              Text(
                'Couldn\'t reach the server',
                style: Theme.of(context).textTheme.titleSmall,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 4),
              Text(
                message,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontSize: 13,
                  color: YveColors.textSecondary,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
