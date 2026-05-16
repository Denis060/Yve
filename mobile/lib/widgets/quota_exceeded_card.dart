import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/entitlement.dart';
import '../theme/yve_colors.dart';
import '../theme/yve_spacing.dart';

/// The cap-hit moment — the single most important conversion event in
/// Yve's funnel. A learner hit a wall. They're now deciding whether
/// Yve is worth paying for. This card is designed to make that
/// decision feel like *continuation*, not restriction.
///
/// Design choices:
///   • Reference the *specific* unfinished work when the server
///     provided session context — "You and Yve were 10 turns into
///     Frank-Starling assignment." Generic copy only when context is
///     missing (cap hit before any session existed).
///   • Primary CTA is "Start 3-day Pro trial" — framed as continuing
///     the work, not unlocking the product.
///   • Secondary line is the calm "or wait until <reset>" so the user
///     never feels trapped. No countdown timers, no exclamation marks.
///   • Copy varies by [CapKind] — running out of chats hits differently
///     than your draft being too long.
///
/// The CTA wires to the existing upgrade flow (the upgrade sheet);
/// Phase 4's pricing page will replace that surface but the contract
/// here stays the same — render the moment, hand off to upgrade.
class QuotaExceededCard extends StatelessWidget {
  const QuotaExceededCard({
    super.key,
    required this.quota,
    required this.onUpgrade,
  });

  final QuotaExceeded quota;
  final VoidCallback onUpgrade;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: YveSpacing.lg),
      padding: const EdgeInsets.all(YveSpacing.xl),
      decoration: BoxDecoration(
        color: YveColors.primarySurface,
        borderRadius: YveSpacing.cardRadius,
        border: Border.all(color: YveColors.border, width: 1),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          _Identity(),
          const SizedBox(height: YveSpacing.md),
          _Headline(quota: quota),
          const SizedBox(height: YveSpacing.sm),
          _SubLine(quota: quota),
          if (_contextLine(quota) case final String ctx) ...<Widget>[
            const SizedBox(height: YveSpacing.md),
            _ContextBlock(text: ctx),
          ],
          const SizedBox(height: YveSpacing.lg),
          _CtaRow(quota: quota, onUpgrade: onUpgrade),
        ],
      ),
    );
  }

  /// The "your work in progress" surface beneath the headline. Returns
  /// the rendered string when the server provided enough context;
  /// otherwise null and the card collapses that section.
  static String? _contextLine(QuotaExceeded q) {
    switch (q.kind) {
      case CapKind.chat:
        if (!q.hasSessionContext) return null;
        final String concept = q.primaryConcept ?? q.sessionTitle ?? 'this';
        final int turns = q.turnsThisSession ?? 0;
        final String turnsLabel = turns == 1 ? '1 turn' : '$turns turns';
        return 'You and Yve were $turnsLabel into "$concept".';
      case CapKind.polish:
        if (q.draftPreview == null || q.draftPreview!.isEmpty) return null;
        return 'Your draft: "${q.draftPreview}"';
      case CapKind.word:
        if (q.draftPreview == null || q.draftPreview!.isEmpty) return null;
        return 'Your draft starts: "${q.draftPreview}"';
      case CapKind.scan:
      case CapKind.subjects:
        return null;
    }
  }
}

class _Identity extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Row(
      children: <Widget>[
        Container(
          width: 28,
          height: 28,
          decoration: const BoxDecoration(
            gradient: YveColors.brandGradient,
            shape: BoxShape.circle,
          ),
          alignment: Alignment.center,
          child: const Text(
            '✦',
            style: TextStyle(
              fontSize: 14,
              color: YveColors.textInverse,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
        const SizedBox(width: YveSpacing.sm),
        const Text(
          'Yve',
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w700,
            color: YveColors.accent,
          ),
        ),
      ],
    );
  }
}

class _Headline extends StatelessWidget {
  const _Headline({required this.quota});
  final QuotaExceeded quota;

  @override
  Widget build(BuildContext context) {
    final String text = switch (quota.kind) {
      CapKind.chat   => 'Your work is paused.',
      CapKind.polish => 'Polish is paused this week.',
      CapKind.word   => 'Your draft is longer than Free can polish.',
      CapKind.scan   => 'Daily scans used.',
      CapKind.subjects => 'You\'re at the Free subject limit.',
    };
    return Text(
      text,
      style: const TextStyle(
        fontSize: 18,
        fontWeight: FontWeight.w700,
        color: YveColors.primary,
        height: 1.3,
        letterSpacing: -0.2,
      ),
    );
  }
}

class _SubLine extends StatelessWidget {
  const _SubLine({required this.quota});
  final QuotaExceeded quota;

  @override
  Widget build(BuildContext context) {
    final String text = switch (quota.kind) {
      CapKind.chat => quota.resetAtUtc == null
          ? 'You\'ve used Free\'s daily chats.'
          : 'You\'ve used Free\'s ${quota.limit} daily chats. They come back ${quota.resetRelative}.',
      CapKind.polish => quota.resetAtUtc == null
          ? 'You\'ve used your Free polish for the week.'
          : 'You\'ve used your Free polish this week. Resets ${quota.resetRelative}.',
      CapKind.word =>
        'Your draft is ${quota.used} words. Free polishes up to ${quota.limit} at a time — Pro polishes up to 10,000.',
      CapKind.scan =>
        quota.resetAtUtc == null
            ? 'Free includes a few scans a day. More with Pro.'
            : 'Free includes ${quota.limit} scans a day. Resets ${quota.resetRelative}.',
      CapKind.subjects =>
        'Free includes ${quota.limit} subject. Pro includes as many as you need.',
    };
    return Text(
      text,
      style: const TextStyle(
        fontSize: 14,
        color: YveColors.textSecondary,
        height: 1.5,
      ),
    );
  }
}

class _ContextBlock extends StatelessWidget {
  const _ContextBlock({required this.text});
  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: YveSpacing.md,
        vertical: YveSpacing.sm,
      ),
      decoration: BoxDecoration(
        color: YveColors.surface,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: YveColors.border, width: 1),
      ),
      child: Text(
        text,
        style: const TextStyle(
          fontSize: 13,
          color: YveColors.textPrimary,
          height: 1.5,
        ),
      ),
    );
  }
}

class _CtaRow extends StatelessWidget {
  const _CtaRow({required this.quota, required this.onUpgrade});
  final QuotaExceeded quota;
  final VoidCallback onUpgrade;

  @override
  Widget build(BuildContext context) {
    // CTA label hints at the trial only when it's actually offered
    // (i.e. for free users). A Pro user hitting the fair-use ceiling
    // would see different copy — that path isn't exercised in v1, but
    // we keep the label generic ("Continue with Pro") when not free.
    final String primaryLabel = quota.plan == Plan.free
        ? 'Start your 3-day Pro trial'
        : 'Continue with Pro';
    final String? secondary = quota.resetAtUtc == null
        ? null
        : 'Or wait — your chats come back ${quota.resetRelative}';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        SizedBox(
          width: double.infinity,
          child: FilledButton(
            onPressed: () {
              HapticFeedback.selectionClick();
              onUpgrade();
            },
            style: FilledButton.styleFrom(
              backgroundColor: YveColors.primary,
              foregroundColor: YveColors.textInverse,
              padding: const EdgeInsets.symmetric(vertical: 14),
              shape: const StadiumBorder(),
              textStyle: const TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.1,
              ),
            ),
            child: Text(primaryLabel),
          ),
        ),
        if (secondary != null) ...<Widget>[
          const SizedBox(height: YveSpacing.sm),
          Text(
            secondary,
            style: const TextStyle(
              fontSize: 12,
              color: YveColors.textTertiary,
              height: 1.5,
            ),
          ),
        ],
      ],
    );
  }
}
