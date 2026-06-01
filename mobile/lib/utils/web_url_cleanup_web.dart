// Web implementation — strips leftover OAuth callback params from the
// URL on app boot so the SDK doesn't try to re-exchange a code whose
// PKCE verifier has already been consumed (or never existed).
//
// The error this prevents:
//   "Code verifier could not be found in local storage."
// — fires when supabase_flutter's deep-link observer sees `?code=` in
// the URL but has no matching verifier in localStorage. Common after
// page reload of the post-OAuth landing URL, or after bookmarking it.

import 'package:web/web.dart' as web;

void clearStaleOAuthParamsFromUrl() {
  try {
    final web.Location loc = web.window.location;
    final Uri uri = Uri.parse(loc.href);
    final bool hasOAuthSurface = uri.queryParameters.containsKey('code') ||
        uri.queryParameters.containsKey('error') ||
        uri.fragment.contains('access_token=') ||
        uri.fragment.contains('error_description=');
    if (!hasOAuthSurface) return;

    // Real callback in flight: localStorage will have a code-verifier
    // entry from when we kicked off the OAuth. Leave the URL alone so
    // the SDK can do its thing.
    final web.Storage ls = web.window.localStorage;
    for (int i = 0; i < ls.length; i++) {
      final String? key = ls.key(i);
      if (key != null &&
          (key.contains('code-verifier') ||
              key.contains('codeVerifier') ||
              key.endsWith('-code-verifier'))) {
        return; // genuine in-flight callback
      }
    }

    // Stale callback — strip query + fragment, keep the path.
    web.window.history.replaceState(null, '', uri.path);
  } catch (_) {
    // Best-effort. Never block startup on URL cleanup.
  }
}

/// Reads a `?checkout=success|cancel` marker off the current URL (set by
/// Stripe's return pages when they bounce the user back into the SPA),
/// then strips it so a reload doesn't re-trigger the celebration. Returns
/// the value ('success' / 'cancel') or null when absent.
String? takeCheckoutReturnSignal() {
  try {
    final web.Location loc = web.window.location;
    final Uri uri = Uri.parse(loc.href);
    final String? signal = uri.queryParameters['checkout'];
    if (signal == null) return null;
    // Strip the param so a refresh won't replay the toast. Preserve any
    // other query params the SPA might care about.
    final Map<String, String> rest =
        Map<String, String>.from(uri.queryParameters)..remove('checkout');
    final Uri cleaned = uri.replace(
      queryParameters: rest.isEmpty ? null : rest,
    );
    web.window.history.replaceState(
      null,
      '',
      rest.isEmpty ? cleaned.path : '${cleaned.path}?${cleaned.query}',
    );
    return signal;
  } catch (_) {
    return null;
  }
}
