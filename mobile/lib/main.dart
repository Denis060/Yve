import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

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
  await Supabase.initialize(
    url: Env.supabaseUrl,
    anonKey: Env.supabaseAnonKey,
  );
  runApp(const ProviderScope(child: YveApp()));
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
