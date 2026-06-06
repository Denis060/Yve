import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/auth_service.dart';
import '../theme/yve_colors.dart';
import '../theme/yve_spacing.dart';
import '../utils/app_error.dart';

/// Sign-in / upgrade flow. One sheet covering both:
///   - Anonymous user adds an email → linkIdentity preserves user_id and
///     therefore all their subjects / sessions / observations.
///   - Email is already on another account → fall back to plain sign-in
///     with an explicit "this device's draft data won't carry over" warning.
Future<void> showAuthSheet(BuildContext context) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (_) => const _AuthSheet(),
  );
}

class _AuthSheet extends ConsumerStatefulWidget {
  const _AuthSheet();

  @override
  ConsumerState<_AuthSheet> createState() => _AuthSheetState();
}

enum _Stage { email, code, signInWarning }

class _AuthSheetState extends ConsumerState<_AuthSheet> {
  final TextEditingController _email = TextEditingController();
  final TextEditingController _code = TextEditingController();
  _Stage _stage = _Stage.email;
  bool _isSignIn = false; // true after we've fallen back from upgrade-anonymous to existing-account sign-in
  bool _working = false;
  String? _error;

  @override
  void dispose() {
    _email.dispose();
    _code.dispose();
    super.dispose();
  }

  Future<void> _sendCode({required bool forceSignIn}) async {
    final String email = _email.text.trim();
    if (!email.contains('@')) {
      setState(() => _error = 'That doesn\'t look like an email address.');
      return;
    }
    setState(() {
      _working = true;
      _error = null;
    });
    final AuthService auth = ref.read(authServiceProvider);
    try {
      await auth.sendOtp(
        email,
        purpose: forceSignIn
            ? OtpPurpose.signInExisting
            : OtpPurpose.upgradeAnonymous,
      );
      setState(() {
        _isSignIn = forceSignIn;
        _stage = _Stage.code;
      });
      HapticFeedback.selectionClick();
    } on AuthException catch (e) {
      if (e.kind == AuthFailureKind.emailAlreadyInUse) {
        setState(() => _stage = _Stage.signInWarning);
      } else {
        setState(() => _error = e.message);
      }
    } catch (e) {
      setState(() => _error =
          AppError.from(e, actionContext: 'auth_sheet').userMessage);
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  Future<void> _verify() async {
    final String code = _code.text.trim();
    if (code.length < 6) {
      setState(() => _error = 'Enter the 6-digit code from your email.');
      return;
    }
    setState(() {
      _working = true;
      _error = null;
    });
    final AuthService auth = ref.read(authServiceProvider);
    try {
      await auth.verifyOtp(
        email: _email.text.trim(),
        code: code,
        purpose: _isSignIn
            ? OtpPurpose.signInExisting
            : OtpPurpose.upgradeAnonymous,
      );
      if (!mounted) return;
      HapticFeedback.lightImpact();
      Navigator.of(context).pop();
    } on AuthException catch (e) {
      setState(() => _error = e.message);
    } catch (e) {
      setState(() => _error =
          AppError.from(e, actionContext: 'auth_sheet').userMessage);
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final double topInset = MediaQuery.of(context).padding.top;
    return AnimatedPadding(
      duration: const Duration(milliseconds: 120),
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
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
              _Header(stage: _stage, isSignIn: _isSignIn),
              const SizedBox(height: YveSpacing.lg),
              if (_stage == _Stage.email) ..._emailStage(),
              if (_stage == _Stage.code) ..._codeStage(),
              if (_stage == _Stage.signInWarning) ..._signInWarningStage(),
              if (_error != null) ...<Widget>[
                const SizedBox(height: YveSpacing.md),
                Text(
                  _error!,
                  style: const TextStyle(fontSize: 13, color: YveColors.error),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  List<Widget> _emailStage() {
    return <Widget>[
      TextField(
        controller: _email,
        keyboardType: TextInputType.emailAddress,
        autofocus: true,
        autocorrect: false,
        textInputAction: TextInputAction.go,
        onSubmitted: (_) => _sendCode(forceSignIn: false),
        decoration: const InputDecoration(hintText: 'you@example.com'),
      ),
      const SizedBox(height: YveSpacing.md),
      FilledButton.icon(
        onPressed: _working ? null : () => _sendCode(forceSignIn: false),
        icon: _working
            ? const SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: YveColors.textInverse,
                ),
              )
            : const Icon(Icons.mail_rounded),
        label: Text(_working ? 'Sending code…' : 'Email me a code'),
      ),
    ];
  }

  List<Widget> _codeStage() {
    return <Widget>[
      Text(
        'A 6-digit code is on its way to ${_email.text.trim()}.',
        style: const TextStyle(fontSize: 13, color: YveColors.textSecondary),
      ),
      const SizedBox(height: YveSpacing.md),
      TextField(
        controller: _code,
        keyboardType: TextInputType.number,
        autofocus: true,
        textAlign: TextAlign.center,
        maxLength: 6,
        style: const TextStyle(
          fontSize: 22,
          fontWeight: FontWeight.w600,
          letterSpacing: 12,
        ),
        decoration: const InputDecoration(
          counterText: '',
          hintText: '••••••',
        ),
        onSubmitted: (_) => _verify(),
      ),
      const SizedBox(height: YveSpacing.sm),
      FilledButton(
        onPressed: _working ? null : _verify,
        child: _working
            ? const SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: YveColors.textInverse,
                ),
              )
            : const Text('Verify & continue'),
      ),
      const SizedBox(height: YveSpacing.sm),
      Center(
        child: TextButton(
          onPressed: _working
              ? null
              : () => setState(() {
                    _stage = _Stage.email;
                    _code.clear();
                    _error = null;
                  }),
          child: const Text('Use a different email'),
        ),
      ),
    ];
  }

  List<Widget> _signInWarningStage() {
    return <Widget>[
      Container(
        padding: const EdgeInsets.all(YveSpacing.md),
        decoration: BoxDecoration(
          color: YveColors.tintAmber,
          borderRadius: BorderRadius.circular(12),
        ),
        child: const Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Icon(Icons.info_outline_rounded,
                size: 18, color: Color(0xFFB45309)),
            SizedBox(width: 8),
            Expanded(
              child: Text(
                'That email already has a Yve account. Signing in there will leave the draft subjects, sessions, and notes you\'ve made on this device behind — they stay safe in storage, but this device will see only your other account\'s data.',
                style: TextStyle(
                  fontSize: 13,
                  color: Color(0xFF7C2D12),
                  height: 1.4,
                ),
              ),
            ),
          ],
        ),
      ),
      const SizedBox(height: YveSpacing.md),
      FilledButton(
        onPressed: _working ? null : () => _sendCode(forceSignIn: true),
        child: Text(_working ? 'Sending code…' : 'Sign in anyway'),
      ),
      const SizedBox(height: YveSpacing.sm),
      Center(
        child: TextButton(
          onPressed: _working
              ? null
              : () => setState(() {
                    _stage = _Stage.email;
                    _email.clear();
                    _error = null;
                  }),
          child: const Text('Use a different email'),
        ),
      ),
    ];
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.stage, required this.isSignIn});

  final _Stage stage;
  final bool isSignIn;

  @override
  Widget build(BuildContext context) {
    final String title;
    final String body;
    switch (stage) {
      case _Stage.email:
        title = 'Sign in to save your work';
        body =
            "Yve will email you a 6-digit code. Type it back here — no link to tap, no password to remember. Your subjects, sessions, and notes stay attached.";
      case _Stage.code:
        title = isSignIn ? 'Welcome back' : 'Almost there';
        body = isSignIn
            ? 'Type the code from your email to sign in to your account.'
            : 'Type the code to add this email to your account.';
      case _Stage.signInWarning:
        title = 'Already a Yve account';
        body = 'Heads up before you switch to it.';
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(title, style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 4),
        Text(
          body,
          style: const TextStyle(
            fontSize: 13,
            color: YveColors.textSecondary,
            height: 1.5,
          ),
        ),
      ],
    );
  }
}
