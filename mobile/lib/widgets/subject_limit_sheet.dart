// The "you hit the free subject limit" moment for *signed-in* free users.
//
// This is the highest-intent monetization surface in the funnel: the
// user is actively trying to organize more of their semester and Free
// won't let them. Tone needs to feel like *celebration of growth*, not
// a denial. No "you've been blocked" framing.
//
// The decision matrix this surface is making for the learner:
//   "Yve is becoming the place I track all my courses → do I commit?"
//
// Copy direction (validated with the team 2026-05-16):
//   ✓ "Your semester is growing"
//   ✓ "Keep every class organized in Yve"
//   ✗ "You've reached the subject limit"
//   ✗ "Upgrade required"
//
// CTA opens the PricingScreen (the existing 3-tier upgrade surface);
// dismiss goes back to subjects list with the new subject NOT created.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../config/billing_config.dart';
import '../screens/pricing_screen.dart';
import '../theme/yve_colors.dart';
import '../theme/yve_spacing.dart';

/// Shows the modal. Returns true if the user opted into the upgrade
/// flow (Pricing screen was opened), false if dismissed. The caller
/// doesn't need to do anything with the return — the actual entitlement
/// flip happens via webhook + lifecycle resume.
Future<bool> showSubjectLimitSheet(BuildContext context) async {
  final bool? opted = await showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    barrierColor: Colors.black.withOpacity(0.5),
    builder: (_) => const _SubjectLimitSheet(),
  );
  return opted == true;
}

class _SubjectLimitSheet extends StatelessWidget {
  const _SubjectLimitSheet();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom,
      ),
      child: Container(
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
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            // Handle
            Center(
              child: Container(
                width: 40,
                height: 4,
                margin: const EdgeInsets.only(bottom: YveSpacing.md),
                decoration: BoxDecoration(
                  color: YveColors.border,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const _BrandRow(),
            const SizedBox(height: YveSpacing.lg),
            const _SubjectStackIllustration(),
            const SizedBox(height: YveSpacing.lg),
            const Text(
              'Your semester is growing.',
              style: TextStyle(
                fontSize: 22,
                fontWeight: FontWeight.w700,
                color: YveColors.primary,
                height: 1.25,
                letterSpacing: -0.3,
              ),
            ),
            const SizedBox(height: YveSpacing.sm),
            const Text(
              'Unlock unlimited subjects and keep every class — '
              'lectures, readings, notes, drafts — organized in one '
              'place. Pro gives you the room to study the way your '
              'semester actually looks.',
              style: TextStyle(
                fontSize: 14,
                color: YveColors.textSecondary,
                height: 1.55,
              ),
            ),
            const SizedBox(height: YveSpacing.lg),
            const _ValueBullets(),
            const SizedBox(height: YveSpacing.xl),
            _ActionRow(
              // iOS pre-entitlement: no path to the Stripe pricing screen,
              // so the upgrade CTA is hidden and only "Maybe later" shows.
              onUpgrade: !BillingConfig.upgradeEnabled
                  ? null
                  : () {
                      HapticFeedback.selectionClick();
                      Navigator.of(context).pop(true);
                      Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          builder: (_) => const PricingScreen(),
                        ),
                      );
                    },
              onLater: () => Navigator.of(context).pop(false),
            ),
          ],
        ),
      ),
    );
  }
}

class _BrandRow extends StatelessWidget {
  const _BrandRow();
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
            letterSpacing: 0.5,
          ),
        ),
      ],
    );
  }
}

/// A small visual cue — three stacked subject cards with the third
/// disabled/dim — so the user *sees* the limit they're pressing against
/// without us writing "limit" anywhere in the copy.
class _SubjectStackIllustration extends StatelessWidget {
  const _SubjectStackIllustration();
  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 84,
      child: Stack(
        clipBehavior: Clip.none,
        children: <Widget>[
          Positioned(
            left: 0, top: 24,
            child: _MiniSubjectChip(
              label: 'Anatomy', emoji: '🧠',
              color: const Color(0xFFD8F3DC),
            ),
          ),
          Positioned(
            left: 56, top: 0,
            child: _MiniSubjectChip(
              label: 'Pharmacology', emoji: '💊',
              color: const Color(0xFFFFE8C5),
            ),
          ),
          Positioned(
            left: 168, top: 30,
            child: _MiniSubjectChip(
              label: 'Pathology', emoji: '🔬',
              color: const Color(0xFFE5DAFB),
              dim: true,
            ),
          ),
        ],
      ),
    );
  }
}

class _MiniSubjectChip extends StatelessWidget {
  const _MiniSubjectChip({
    required this.label,
    required this.emoji,
    required this.color,
    this.dim = false,
  });
  final String label;
  final String emoji;
  final Color color;
  final bool dim;
  @override
  Widget build(BuildContext context) {
    return Opacity(
      opacity: dim ? 0.45 : 1.0,
      child: Container(
        padding: const EdgeInsets.symmetric(
            horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: color,
          borderRadius: BorderRadius.circular(14),
          boxShadow: dim
              ? null
              : <BoxShadow>[
                  BoxShadow(
                    color: Colors.black.withOpacity(0.06),
                    blurRadius: 12,
                    offset: const Offset(0, 4),
                  ),
                ],
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Text(emoji, style: const TextStyle(fontSize: 16)),
            const SizedBox(width: 6),
            Text(
              label,
              style: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: YveColors.primary,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ValueBullets extends StatelessWidget {
  const _ValueBullets();
  @override
  Widget build(BuildContext context) {
    const List<_ValueItem> items = <_ValueItem>[
      _ValueItem(
        icon: Icons.school_outlined,
        title: 'Every class, one home',
        body: 'Add every course you\'re taking this semester — no caps.',
      ),
      _ValueItem(
        icon: Icons.auto_awesome_outlined,
        title: 'Pro chat that thinks deeper',
        body: 'Longer reasoning, smarter polish, unlimited daily turns.',
      ),
      _ValueItem(
        icon: Icons.lock_outline,
        title: 'Your study history, protected',
        body: 'Everything syncs across devices, kept private to you.',
      ),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        for (final _ValueItem v in items) ...<Widget>[
          _ValueRow(item: v),
          if (v != items.last) const SizedBox(height: YveSpacing.md),
        ],
      ],
    );
  }
}

class _ValueItem {
  const _ValueItem({
    required this.icon,
    required this.title,
    required this.body,
  });
  final IconData icon;
  final String title;
  final String body;
}

class _ValueRow extends StatelessWidget {
  const _ValueRow({required this.item});
  final _ValueItem item;
  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Container(
          width: 32, height: 32,
          decoration: BoxDecoration(
            color: YveColors.primarySurface,
            borderRadius: BorderRadius.circular(10),
          ),
          alignment: Alignment.center,
          child: Icon(item.icon,
              size: 18, color: YveColors.primary),
        ),
        const SizedBox(width: YveSpacing.md),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                item.title,
                style: const TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                  color: YveColors.primary,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                item.body,
                style: const TextStyle(
                  fontSize: 13,
                  color: YveColors.textSecondary,
                  height: 1.45,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _ActionRow extends StatelessWidget {
  const _ActionRow({required this.onUpgrade, required this.onLater});

  /// Null when the upgrade gate is closed (iOS pre-entitlement) — the
  /// "See Pro plans" button is omitted and only the dismiss action shows.
  final VoidCallback? onUpgrade;
  final VoidCallback onLater;
  @override
  Widget build(BuildContext context) {
    return Column(
      children: <Widget>[
        if (onUpgrade != null) ...<Widget>[
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              onPressed: onUpgrade,
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
              child: const Text('See Pro plans'),
            ),
          ),
          const SizedBox(height: YveSpacing.xs),
        ],
        SizedBox(
          width: double.infinity,
          child: TextButton(
            onPressed: onLater,
            style: TextButton.styleFrom(
              foregroundColor: YveColors.textTertiary,
            ),
            child: Text(onUpgrade == null ? 'OK' : 'Maybe later'),
          ),
        ),
      ],
    );
  }
}
