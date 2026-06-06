import 'dart:async';
import 'dart:io' show Platform;

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../theme/yve_colors.dart';

/// Runs Yve's OAuth flow inside an embedded WebView instead of handing
/// off to an external browser. We do this on Android because:
///
///   • Chrome Custom Tabs don't dispatch Android App Link intents on a
///     server-side 302 redirect (verified 2026-05-17). The user sees a
///     404 on the bridge page instead of being routed back to Yve.
///   • Samsung Internet silently swallows `intent://` and custom-scheme
///     links even from a fully-rendered bridge page — no error, just
///     nothing happens.
///   • External browsers can leave Yve in the background, making the
///     return trip feel disconnected ("did it work? am I signed in?").
///
/// The WebView approach owns the navigation surface end-to-end. When
/// the OAuth provider returns to `https://app.getyve.com/auth/callback`,
/// we intercept the URL via `NavigationDelegate.onNavigationRequest`
/// BEFORE the WebView actually loads it, then hand the URL back to
/// `Supabase.instance.client.auth.getSessionFromUrl(...)` which does
/// the PKCE token exchange using the verifier the SDK stored locally
/// when we called `getOAuthSignInUrl()`.
///
/// We set a desktop-Chrome User-Agent so Google's "browser may not be
/// secure" check doesn't flag us — Google's heuristic is mainly looking
/// for the default Android WebView UA.
///
/// Returns `true` on successful sign-in, `false` on user cancellation.
class OAuthWebViewScreen extends StatefulWidget {
  const OAuthWebViewScreen({
    super.key,
    required this.authUrl,
    required this.callbackHost,
    required this.callbackPathPrefix,
  });

  /// The Supabase /authorize URL produced by `getOAuthSignInUrl()`.
  final String authUrl;

  /// Host the OAuth callback comes back to (typically `app.getyve.com`).
  final String callbackHost;

  /// Path prefix that signals "this is the callback" — typically
  /// `/auth/callback`. Any navigation matching host + path-prefix gets
  /// intercepted and treated as the OAuth return.
  final String callbackPathPrefix;

  @override
  State<OAuthWebViewScreen> createState() => _OAuthWebViewScreenState();
}

class _OAuthWebViewScreenState extends State<OAuthWebViewScreen> {
  WebViewController? _controller;
  bool _loading = true;
  bool _completed = false;

  /// Generic fallback if device_info lookup fails — never used in
  /// practice but means a single failed call doesn't kill OAuth.
  static const String _fallbackUserAgent =
      'Mozilla/5.0 (Linux; Android 14; K) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/123.0.0.0 Mobile Safari/537.36';

  @override
  void initState() {
    super.initState();
    unawaited(_initWebView());
  }

  /// Build the WebView with a User-Agent that reflects the *user's
  /// actual phone*, not a hardcoded Pixel 6. Google's post-sign-in
  /// security notification ("you signed in with <device>") reads the
  /// UA — using a real device name keeps users from panicking that
  /// someone in Mountain View hacked their account.
  Future<void> _initWebView() async {
    final String ua = await _buildUserAgent();
    if (!mounted) return;
    final WebViewController controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setUserAgent(ua)
      ..setBackgroundColor(YveColors.surface)
      ..setNavigationDelegate(NavigationDelegate(
        onPageStarted: (_) {
          if (mounted) setState(() => _loading = true);
        },
        onPageFinished: (_) {
          if (mounted) setState(() => _loading = false);
        },
        onNavigationRequest: _onNavigationRequest,
        onWebResourceError: (WebResourceError err) {
          if (mounted && _loading) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text(_friendly(err.description))),
            );
          }
        },
      ))
      ..loadRequest(Uri.parse(widget.authUrl));
    setState(() => _controller = controller);
  }

  Future<String> _buildUserAgent() async {
    try {
      final DeviceInfoPlugin info = DeviceInfoPlugin();
      if (Platform.isAndroid) {
        final AndroidDeviceInfo a = await info.androidInfo;
        // Compose a UA Chrome-on-Android would send. `a.model` is the
        // human-friendly model (e.g. "Galaxy A25 5G") on most devices;
        // `a.version.release` is the OS string ("14"). The Chrome
        // version doesn't need to be live-accurate — Google's UA
        // parser only really uses the platform/model fields.
        final String model = a.model.isEmpty ? 'K' : a.model;
        final String android = a.version.release.isEmpty
            ? '14' : a.version.release;
        return 'Mozilla/5.0 (Linux; Android $android; $model) '
            'AppleWebKit/537.36 (KHTML, like Gecko) '
            'Chrome/123.0.0.0 Mobile Safari/537.36';
      }
      if (Platform.isIOS) {
        final IosDeviceInfo i = await info.iosInfo;
        final String os = i.systemVersion.replaceAll('.', '_');
        return 'Mozilla/5.0 (${i.utsname.machine}; CPU iPhone OS '
            '$os like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) '
            'Version/17.0 Mobile/15E148 Safari/604.1';
      }
    } catch (_) {
      // Fall through to the generic fallback below.
    }
    return _fallbackUserAgent;
  }

  Future<NavigationDecision> _onNavigationRequest(NavigationRequest req) async {
    final Uri uri = Uri.tryParse(req.url) ?? Uri();
    final bool isCallback = uri.host == widget.callbackHost &&
        uri.path.startsWith(widget.callbackPathPrefix);
    if (!isCallback) return NavigationDecision.navigate;

    // We have the callback URL. Tell Supabase to complete the PKCE
    // exchange using the stored code_verifier, then close ourselves.
    if (_completed) return NavigationDecision.prevent;
    _completed = true;

    try {
      await Supabase.instance.client.auth.getSessionFromUrl(uri);
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(_friendly(e.toString()))),
        );
        Navigator.of(context).pop(false);
      }
    }
    return NavigationDecision.prevent;
  }

  String _friendly(String raw) {
    final String lower = raw.toLowerCase();
    if (lower.contains('expired') || lower.contains('used')) {
      return 'That sign-in window expired — try again.';
    }
    if (lower.contains('network') || lower.contains('connection')) {
      return 'Network hiccup — try again.';
    }
    return 'Couldn\'t finish sign-in. Try again.';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: YveColors.surface,
      appBar: AppBar(
        backgroundColor: YveColors.surface,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.close, color: YveColors.textPrimary),
          onPressed: () => Navigator.of(context).pop(false),
          tooltip: 'Cancel',
        ),
        title: const Text(
          'Sign in',
          style: TextStyle(
            color: YveColors.textPrimary,
            fontSize: 16,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
      body: Stack(
        children: <Widget>[
          if (_controller != null)
            WebViewWidget(controller: _controller!)
          else
            const Center(
              child: CircularProgressIndicator(
                valueColor: AlwaysStoppedAnimation<Color>(YveColors.accent),
              ),
            ),
          if (_loading)
            const LinearProgressIndicator(
              minHeight: 2,
              color: YveColors.accent,
              backgroundColor: Colors.transparent,
            ),
        ],
      ),
    );
  }
}
