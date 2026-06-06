// Compile-time config baked into the build via --dart-define-from-file.
// See mobile/dart_defines.json (gitignored) and the matching .template.
//
//   flutter run --dart-define-from-file=dart_defines.json
//   flutter build apk --release --dart-define-from-file=dart_defines.json
//
// The defaults below are the obvious-bad-value sentinels so a build that
// forgot the flag fails loudly at first network call instead of silently
// pointing at a fake Supabase URL.

class Env {
  static const String supabaseUrl = String.fromEnvironment(
    'SUPABASE_URL',
    defaultValue: 'https://YOUR-PROJECT-REF.supabase.co',
  );

  static const String supabaseAnonKey = String.fromEnvironment(
    'SUPABASE_ANON_KEY',
    defaultValue: 'YOUR-ANON-KEY',
  );

  /// Sentry DSN. Empty default disables Sentry entirely — useful for
  /// local dev where we don't want every hot-reload exception landing
  /// in the production project's error log.
  static const String sentryDsn = String.fromEnvironment(
    'SENTRY_DSN',
    defaultValue: '',
  );

  /// Override the Sentry `environment` tag at build time. Defaults to
  /// "production" — local dev should pass `--dart-define=ENV=debug`
  /// (or just leave SENTRY_DSN empty) so hot-reload exceptions don't
  /// land in the production error log.
  static const String env = String.fromEnvironment(
    'ENV',
    defaultValue: 'production',
  );
}
