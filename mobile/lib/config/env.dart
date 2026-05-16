// Fill these in with the values from your Supabase project dashboard.
// (Project Settings → API)
//
// This file is git-ignored. For production builds, prefer
// --dart-define=SUPABASE_URL=... and read from String.fromEnvironment.

class Env {
  static const String supabaseUrl = String.fromEnvironment(
    'SUPABASE_URL',
    defaultValue: 'https://YOUR-PROJECT-REF.supabase.co',
  );

  static const String supabaseAnonKey = String.fromEnvironment(
    'SUPABASE_ANON_KEY',
    defaultValue: 'YOUR-ANON-KEY',
  );
}
