// Stub for non-web platforms — no URL to clean. The conditional
// import in main.dart resolves this on Android / iOS / desktop and
// resolves `web_url_cleanup_web.dart` on Flutter web.

void clearStaleOAuthParamsFromUrl() {}

/// Web-only: reads and clears a `?checkout=success|cancel` marker that
/// Stripe's return pages append when they bounce the user back into the
/// SPA. Returns null on mobile (Stripe return is handled via the app
/// resume lifecycle instead).
String? takeCheckoutReturnSignal() => null;
