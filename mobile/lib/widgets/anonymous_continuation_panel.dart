// Shown when an anonymous (guest) user hits a lifetime cap on Yve's
// preview tier. This is NOT an error or paywall — it's the calm
// continuity moment described in the monetization spec:
//
//   "Anonymous mode should prove value.
//    Account creation should protect continuity.
//    Paid plans should unlock repeated academic workflow."
//
// Copy is preservation-framed ("Keep going with Yve", "Save your work")
// rather than restriction-framed. The buttons match the auth flow used
// everywhere else (Continue with Apple / Google / Use email instead +
// Maybe later). When the user converts, Supabase's in-place upgrade
// preserves the same user_id so all their guest work carries forward.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show OAuthProvider;

import '../config/auth_config.dart';
import '../services/auth_service.dart';
import '../theme/yve_colors.dart';
import '../theme/yve_spacing.dart';
import '../utils/app_error.dart';

/// Shows the "Keep going with Yve" continuity modal. Resolves to true
/// if the user successfully created or linked an account (caller can
/// resume the action that hit the cap), false if dismissed.
Future<bool> showAnonymousContinuation(
  BuildContext context, {
  String title = 'Keep going with Yve',
  String body =
      "You've finished your first assignment with Yve. Create a free account to keep your work, continue tomorrow, and protect your progress across devices.",
}) async {
  final bool? result = await showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (_) => _AnonymousContinuationPanel(title: title, body: body),
  );
  return result ?? false;
}

class _AnonymousContinuationPanel extends ConsumerStatefulWidget {
  const _AnonymousContinuationPanel({required this.title, required this.body});
  final String title;
  final String body;

  @override
  ConsumerState<_AnonymousContinuationPanel> createState() =>
      _AnonymousContinuationPanelState();
}

enum _Stage { chooser, emailEntry, emailCode }

class _AnonymousContinuationPanelState
    extends ConsumerState<_AnonymousContinuationPanel> {
  final TextEditingController _email = TextEditingController();
  final TextEditingController _code = TextEditingController();
  _Stage _stage = _Stage.chooser;
  bool _working = false;
  AppError? _error;
  bool _isSignInFallback = false;

  @override
  void dispose() {
    _email.dispose();
    _code.dispose();
    super.dispose();
  }

  Future<void> _continueWithOAuth(OAuthProvider provider) async {
    HapticFeedback.selectionClick();
    setState(() {
      _working = true;
      _error = null;
    });
    try {
      final bool ok = await ref.read(authServiceProvider).continueWithOAuth(
            provider,
            context: context,
          );
      if (!mounted) return;
      if (ok) {
        // Real sign-in landed → pop with success so the auth gate
        // proceeds with whatever action the user was trying to do.
        Navigator.of(context).pop(true);
      } else {
        // User dismissed the OAuth WebView. Stay on the chooser so
        // they can try again or pick a different sign-in method.
        // Do NOT pop with true — that would let gated actions
        // (Word export, etc.) fire as if sign-in succeeded.
        if (mounted) setState(() => _working = false);
      }
    } catch (e) {
      setState(() => _error = AppError.from(e, actionContext: 'anon_oauth'));
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  void _continueWithEmail() {
    setState(() {
      _stage = _Stage.emailEntry;
      _error = null;
    });
  }

  Future<void> _sendCode({required bool forceSignIn}) async {
    final String email = _email.text.trim();
    if (!email.contains('@')) {
      setState(() => _error = const AppError(
            kind: AppErrorKind.validation,
            userMessage: "That doesn't look like an email address.",
          ));
      return;
    }
    setState(() {
      _working = true;
      _error = null;
    });
    try {
      _isSignInFallback = forceSignIn;
      await ref.read(authServiceProvider).sendOtp(
            email,
            purpose: forceSignIn
                ? OtpPurpose.signInExisting
                : OtpPurpose.upgradeAnonymous,
          );
      HapticFeedback.selectionClick();
      if (!mounted) return;
      setState(() => _stage = _Stage.emailCode);
    } on AuthException catch (e) {
      if (e.kind == AuthFailureKind.emailAlreadyInUse) {
        // Don't silently flip to "sign in to existing" — that's how
        // people end up logged into the wrong account with all their
        // guest work orphaned. Ask explicitly. The claim function will
        // move guest data over after the confirmed sign-in.
        if (!mounted) return;
        setState(() => _working = false);
        final bool? confirmed = await _confirmSignInToExisting(email);
        if (confirmed == true) {
          await _sendCode(forceSignIn: true);
        }
        return;
      }
      setState(() =>
          _error = AppError.from(e, actionContext: 'anon_email_send'));
    } catch (e) {
      setState(() =>
          _error = AppError.from(e, actionContext: 'anon_email_send'));
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  /// Shown when the typed email already belongs to a Yve account.
  /// Two choices, both explicit:
  ///   - "Sign in to that account" — we move guest work over via the
  ///     claim function (this is the safe path now)
  ///   - "Use a different email" — go back to the email field
  Future<bool?> _confirmSignInToExisting(String email) {
    return showDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        title: const Text('That email already has a Yve account'),
        content: Text(
          'Sign in to the existing account for $email? Your guest '
          'subjects, chats, and progress will be moved over.',
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Use a different email'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Sign in & transfer'),
          ),
        ],
      ),
    );
  }

  Future<void> _verifyCode() async {
    final String code = _code.text.trim();
    if (code.length < 6) {
      setState(() => _error = const AppError(
            kind: AppErrorKind.validation,
            userMessage: 'Enter the 6-digit code from your email.',
          ));
      return;
    }
    setState(() {
      _working = true;
      _error = null;
    });
    try {
      await ref.read(authServiceProvider).verifyOtp(
            email: _email.text.trim(),
            code: code,
            purpose: _isSignInFallback
                ? OtpPurpose.signInExisting
                : OtpPurpose.upgradeAnonymous,
          );
      HapticFeedback.lightImpact();
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } catch (e) {
      setState(
          () => _error = AppError.from(e, actionContext: 'anon_email_verify'));
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  void _back() {
    setState(() {
      _stage = _Stage.chooser;
      _error = null;
      _code.clear();
    });
  }

  @override
  Widget build(BuildContext context) {
    final double topInset = MediaQuery.of(context).padding.top;
    return AnimatedPadding(
      duration: const Duration(milliseconds: 120),
      padding:
          EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: Container(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(context).size.height - topInset - 32,
        ),
        decoration: const BoxDecoration(
          color: YveColors.surface,
          borderRadius: BorderRadius.only(
            topLeft: Radius.circular(28),
            topRight: Radius.circular(28),
          ),
        ),
        padding: const EdgeInsets.fromLTRB(
          YveSpacing.xl,
          YveSpacing.md,
          YveSpacing.xl,
          YveSpacing.xl,
        ),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Center(
                child: Container(
                  width: 36,
                  height: 4,
                  decoration: BoxDecoration(
                    color: YveColors.border,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const SizedBox(height: YveSpacing.lg),
              // Soft ✦ disc anchors the moment as Yve, not as an
              // upgrade prompt. Slightly larger than other auth surfaces.
              Center(
                child: Container(
                  width: 56,
                  height: 56,
                  decoration: const BoxDecoration(
                    gradient: YveColors.brandGradient,
                    shape: BoxShape.circle,
                  ),
                  alignment: Alignment.center,
                  child: const Text(
                    '✦',
                    style: TextStyle(
                      fontSize: 28,
                      color: YveColors.textInverse,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: YveSpacing.lg),
              _Header(
                title: _stage == _Stage.chooser
                    ? widget.title
                    : (_isSignInFallback ? 'Welcome back' : 'Almost there'),
                body: _stage == _Stage.chooser
                    ? widget.body
                    : _stage == _Stage.emailEntry
                        ? "We'll email you a 6-digit code. No password to remember, no link to tap — just type it back here."
                        : 'Type the 6-digit code we just sent to ${_email.text.trim()}.',
              ),
              const SizedBox(height: YveSpacing.lg),
              if (_stage == _Stage.chooser) ..._chooserStage(),
              if (_stage == _Stage.emailEntry) ..._emailEntryStage(),
              if (_stage == _Stage.emailCode) ..._emailCodeStage(),
              if (_error != null) ...<Widget>[
                const SizedBox(height: YveSpacing.md),
                _InlineError(error: _error!),
              ],
              const SizedBox(height: YveSpacing.md),
              Center(
                child: TextButton(
                  onPressed:
                      _working ? null : () => Navigator.of(context).pop(false),
                  style: TextButton.styleFrom(
                    foregroundColor: YveColors.textTertiary,
                  ),
                  child: Text(_stage == _Stage.chooser
                      ? 'Maybe later'
                      : 'Cancel'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // Apple Sign In hidden until the Apple Developer membership activates
  // (currently pending). When ready, uncomment _continueWithApple +
  // the _OAuthButton entry below — auth_service.continueWithApple is
  // already wired with proper nonce hashing and just needs Supabase's
  // Apple provider config + iOS capability set up in Xcode.
  // ignore: unused_element
  // Future<void> _continueWithApple() async { ... }

  List<Widget> _chooserStage() {
    return <Widget>[
      // _OAuthButton(
      //   icon: Icons.apple,
      //   label: 'Continue with Apple',
      //   background: const Color(0xFF000000),
      //   foreground: Colors.white,
      //   onPressed: _working ? null : _continueWithApple,
      // ),
      // const SizedBox(height: YveSpacing.sm),
      // Google hidden on iOS (App Store Guideline 4.8 needs an Apple-
      // equivalent; and Guideline 4 wants in-app sign-in, not a browser).
      // iOS falls back to in-app email-code sign-in. Web + Android keep it.
      if (AuthConfig.socialLoginEnabled) ...<Widget>[
        _OAuthButton(
          icon: Icons.g_mobiledata,
          iconSize: 28,
          label: 'Continue with Google',
          background: YveColors.surface,
          foreground: YveColors.textPrimary,
          borderColor: YveColors.border,
          onPressed: _working
              ? null
              : () => _continueWithOAuth(OAuthProvider.google),
        ),
        const SizedBox(height: YveSpacing.sm),
      ],
      _OAuthButton(
        icon: Icons.mail_outline_rounded,
        label: 'Use email instead',
        background: YveColors.surface,
        foreground: YveColors.textPrimary,
        borderColor: YveColors.border,
        onPressed: _working ? null : _continueWithEmail,
      ),
    ];
  }

  List<Widget> _emailEntryStage() {
    return <Widget>[
      TextField(
        controller: _email,
        keyboardType: TextInputType.emailAddress,
        autofocus: true,
        autocorrect: false,
        autofillHints: const <String>[],
        textInputAction: TextInputAction.go,
        onSubmitted: (_) => _sendCode(forceSignIn: false),
        decoration: const InputDecoration(hintText: 'you@example.com'),
      ),
      const SizedBox(height: YveSpacing.md),
      FilledButton(
        onPressed: _working ? null : () => _sendCode(forceSignIn: false),
        style: FilledButton.styleFrom(
          backgroundColor: YveColors.primary,
          foregroundColor: YveColors.textInverse,
          padding: const EdgeInsets.symmetric(vertical: 14),
          shape: const StadiumBorder(),
          textStyle: const TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w700,
          ),
        ),
        child: _working
            ? const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: YveColors.textInverse,
                ),
              )
            : const Text('Email me a code'),
      ),
      const SizedBox(height: YveSpacing.sm),
      Center(
        child: TextButton(
          onPressed: _working ? null : _back,
          child: const Text('Back'),
        ),
      ),
    ];
  }

  List<Widget> _emailCodeStage() {
    return <Widget>[
      TextField(
        controller: _code,
        keyboardType: TextInputType.number,
        autofocus: true,
        textAlign: TextAlign.center,
        maxLength: 6,
        autofillHints: const <String>[],
        style: const TextStyle(
          fontSize: 22,
          fontWeight: FontWeight.w600,
          letterSpacing: 12,
        ),
        decoration: const InputDecoration(counterText: '', hintText: '••••••'),
        onSubmitted: (_) => _verifyCode(),
      ),
      const SizedBox(height: YveSpacing.sm),
      FilledButton(
        onPressed: _working ? null : _verifyCode,
        style: FilledButton.styleFrom(
          backgroundColor: YveColors.primary,
          foregroundColor: YveColors.textInverse,
          padding: const EdgeInsets.symmetric(vertical: 14),
          shape: const StadiumBorder(),
          textStyle: const TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w700,
          ),
        ),
        child: _working
            ? const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: YveColors.textInverse,
                ),
              )
            : const Text('Verify and continue'),
      ),
      const SizedBox(height: YveSpacing.sm),
      Center(
        child: TextButton(
          onPressed: _working ? null : _back,
          child: const Text('Use a different method'),
        ),
      ),
    ];
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.title, required this.body});
  final String title;
  final String body;
  @override
  Widget build(BuildContext context) {
    return Column(
      children: <Widget>[
        Text(
          title,
          textAlign: TextAlign.center,
          style: const TextStyle(
            fontSize: 22,
            fontWeight: FontWeight.w700,
            color: YveColors.textPrimary,
            letterSpacing: -0.3,
            height: 1.25,
          ),
        ),
        const SizedBox(height: YveSpacing.sm),
        Text(
          body,
          textAlign: TextAlign.center,
          style: const TextStyle(
            fontSize: 14,
            color: YveColors.textSecondary,
            height: 1.55,
          ),
        ),
      ],
    );
  }
}

class _OAuthButton extends StatelessWidget {
  const _OAuthButton({
    required this.icon,
    required this.label,
    required this.background,
    required this.foreground,
    required this.onPressed,
    this.borderColor,
    this.iconSize = 20,
  });

  final IconData icon;
  final String label;
  final Color background;
  final Color foreground;
  final Color? borderColor;
  final double iconSize;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      child: Material(
        color: background,
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          onTap: onPressed,
          borderRadius: BorderRadius.circular(12),
          child: Container(
            padding: const EdgeInsets.symmetric(vertical: 14),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              border: borderColor != null
                  ? Border.all(color: borderColor!, width: 1)
                  : null,
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: <Widget>[
                Icon(icon, size: iconSize, color: foreground),
                const SizedBox(width: 10),
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: foreground,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _InlineError extends StatelessWidget {
  const _InlineError({required this.error});
  final AppError error;
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(YveSpacing.md),
      decoration: BoxDecoration(
        color: const Color(0xFFFEF2F2),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: const Color(0xFFFCA5A5), width: 1),
      ),
      child: Text(
        error.userMessage,
        style: const TextStyle(
          fontSize: 13,
          color: Color(0xFFB91C1C),
          height: 1.45,
        ),
      ),
    );
  }
}
