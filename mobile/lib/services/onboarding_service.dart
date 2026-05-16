import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

const String _onboardingKey = 'yve.onboarding_complete_v1';

class OnboardingService {
  Future<bool> isComplete() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_onboardingKey) ?? false;
  }

  Future<void> markComplete() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_onboardingKey, true);
  }
}

final onboardingServiceProvider = Provider<OnboardingService>(
  (_) => OnboardingService(),
);

final onboardingCompleteProvider = FutureProvider<bool>((ref) async {
  return ref.read(onboardingServiceProvider).isComplete();
});
