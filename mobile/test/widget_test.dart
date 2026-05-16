// Placeholder smoke test. Full widget tests need a mocked Supabase client
// (anonymous auth fires from main(), which boots a real network call) and
// will land in a dedicated test slice. For now, this just verifies the
// app's basic widget tree imports cleanly.

import 'package:flutter_test/flutter_test.dart';
import 'package:yve/theme/yve_theme.dart';

void main() {
  test('Yve theme builds without throwing', () {
    final theme = buildYveTheme();
    expect(theme.useMaterial3, isTrue);
  });
}
