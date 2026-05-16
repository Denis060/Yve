import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/entitlement.dart';
import '../services/entitlement_service.dart';
import '../theme/yve_colors.dart';
import '../theme/yve_spacing.dart';
import '../utils/app_error.dart';
import '../widgets/auth_continuation_panel.dart';

/// Which audience this pricing screen was opened for. Drives the
/// default-selected tier and the headline framing. Same product, same
/// three tiers — different first impression per acquisition channel.
///
///   general          → in-app entry; default Semester
///   nursing          → /for-nursing-students; default Semester
///   certifications   → /for-certifications; default Monthly
enum PricingAudience { general, nursing, certifications }

/// The pricing surface. Intent-first ("Which describes your studies?"),
/// three Pro tiers, single CTA per tier ("Start your 3-day Pro trial").
/// CTA opens Stripe Checkout in the browser; the entitlement flips when
/// the webhook fires and the user returns to the app.
///
/// Already-on-Pro state shows the user their current plan + a Manage
/// billing button that opens the Stripe Customer Portal.
class PricingScreen extends ConsumerStatefulWidget {
  const PricingScreen({
    super.key,
    this.audience = PricingAudience.general,
  });

  final PricingAudience audience;

  @override
  ConsumerState<PricingScreen> createState() => _PricingScreenState();
}

class _PricingScreenState extends ConsumerState<PricingScreen> {
  late Plan _selected = _defaultForAudience(widget.audience);
  bool _launching = false;
  AppError? _error;

  static Plan _defaultForAudience(PricingAudience a) {
    return switch (a) {
      PricingAudience.nursing => Plan.proSemester,
      PricingAudience.certifications => Plan.proMonthly,
      PricingAudience.general => Plan.proSemester,
    };
  }

  Future<void> _startTrial() async {
    HapticFeedback.selectionClick();
    setState(() {
      _launching = true;
      _error = null;
    });

    try {
      final CheckoutSession session = await ref
          .read(entitlementProvider.notifier)
          .launchCheckoutFor(_selected);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            session.trialGranted
                ? 'Opening Stripe — your 3-day trial starts when you confirm.'
                : 'Opening Stripe — subscribe to continue.',
          ),
        ),
      );
    } catch (e) {
      final AppError err = AppError.from(e, actionContext: 'start_trial');

      // The anonymous-user case is not an error — it's a sequencing
      // signal that the user needs to commit to identity first. Show
      // the auth continuation panel; if they complete auth, resume
      // the trial automatically without making them re-tap the CTA.
      if (err.kind == AppErrorKind.authRequired) {
        if (!mounted) return;
        // Clear the loading state while the panel is up — the user is
        // now in an auth flow, not waiting on a checkout request.
        setState(() => _launching = false);
        final bool authed = await showAuthContinuation(
          context,
          title: 'Keep your work with Yve',
          body: 'Your Pro trial attaches to your account so Yve can save '
              'your subjects, assignments, and progress across every '
              'device you study from.',
        );
        if (authed && mounted) {
          // Wait briefly for the entitlement provider to pick up the
          // new auth state, then resume the trial. The auth-state
          // listener on EntitlementNotifier fires automatically; the
          // small delay keeps us from racing it.
          await Future<void>.delayed(const Duration(milliseconds: 250));
          if (mounted) _startTrial();
        }
        return;
      }

      // Anything else gets the calm error banner.
      if (mounted) setState(() => _error = err);
    } finally {
      if (mounted && _launching) setState(() => _launching = false);
    }
  }

  Future<void> _openPortal() async {
    HapticFeedback.selectionClick();
    setState(() => _launching = true);
    try {
      await ref.read(entitlementProvider.notifier).launchPortal();
    } catch (e) {
      if (mounted) {
        setState(() => _error = AppError.from(e, actionContext: 'open_portal'));
      }
    } finally {
      if (mounted) setState(() => _launching = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final AsyncValue<Entitlement> entAsync = ref.watch(entitlementProvider);
    final Entitlement ent = entAsync.value ?? Entitlement.freeDefault;

    return Scaffold(
      backgroundColor: YveColors.background,
      appBar: AppBar(
        backgroundColor: YveColors.background,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.close_rounded, color: YveColors.textPrimary),
          onPressed: () => Navigator.of(context).pop(),
        ),
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(
            YveSpacing.xl,
            YveSpacing.sm,
            YveSpacing.xl,
            YveSpacing.xxxl,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              _Header(audience: widget.audience),
              const SizedBox(height: YveSpacing.xxl),

              if (ent.isPro) ...<Widget>[
                _AlreadyProCard(
                  entitlement: ent,
                  onManage: _openPortal,
                  launching: _launching,
                ),
              ] else ...<Widget>[
                _IntentLabel(),
                const SizedBox(height: YveSpacing.md),
                _TierCard(
                  tier: Plan.proMonthly,
                  badge: 'Short courses, certifications',
                  selected: _selected == Plan.proMonthly,
                  onTap: () => setState(() => _selected = Plan.proMonthly),
                ),
                const SizedBox(height: YveSpacing.md),
                _TierCard(
                  tier: Plan.proSemester,
                  badge: 'Most popular — through finals',
                  selected: _selected == Plan.proSemester,
                  isFeatured: true,
                  onTap: () => setState(() => _selected = Plan.proSemester),
                ),
                const SizedBox(height: YveSpacing.md),
                _TierCard(
                  tier: Plan.proAnnual,
                  badge: 'All year, best price',
                  selected: _selected == Plan.proAnnual,
                  onTap: () => setState(() => _selected = Plan.proAnnual),
                ),
                const SizedBox(height: YveSpacing.xxl),
                _CtaButton(
                  label: 'Start your 3-day Pro trial',
                  launching: _launching,
                  onPressed: _startTrial,
                ),
                const SizedBox(height: YveSpacing.sm),
                const _CtaSubLine(),
              ],

              if (_error != null) ...<Widget>[
                const SizedBox(height: YveSpacing.md),
                _ErrorBanner(error: _error!),
              ],

              const SizedBox(height: YveSpacing.xl),
              _FeatureRows(),
            ],
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────
// Header — kind of audience drives the framing
// ─────────────────────────────────────────────────────────────────────

class _Header extends StatelessWidget {
  const _Header({required this.audience});
  final PricingAudience audience;

  @override
  Widget build(BuildContext context) {
    final ({String title, String subtitle}) copy = switch (audience) {
      PricingAudience.nursing => (
        title: 'Yve through your whole program.',
        subtitle:
            'Built for nursing and allied-health students. Assignment loops, '
            'rubric-aware help, polished writing, and a memory that grows '
            'with you semester by semester.',
      ),
      PricingAudience.certifications => (
        title: 'Yve for the length of your course.',
        subtitle:
            'Whether your program is six weeks or twelve, only pay for what '
            'you need. The Monthly plan flexes with your certification '
            'timeline.',
      ),
      PricingAudience.general => (
        title: 'Pick the pace of your semester.',
        subtitle:
            'Three plans, one product. Yve learns your subjects, polishes '
            'your writing, and stays with you through every assignment.',
      ),
    };

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(
          copy.title,
          style: const TextStyle(
            fontSize: 26,
            fontWeight: FontWeight.w700,
            color: YveColors.textPrimary,
            height: 1.2,
            letterSpacing: -0.5,
          ),
        ),
        const SizedBox(height: YveSpacing.md),
        Text(
          copy.subtitle,
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

class _IntentLabel extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return const Text(
      'WHICH DESCRIBES YOUR STUDIES?',
      style: TextStyle(
        fontSize: 11,
        fontWeight: FontWeight.w700,
        color: YveColors.textTertiary,
        letterSpacing: 1.0,
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────
// Tier card
// ─────────────────────────────────────────────────────────────────────

class _TierCard extends StatelessWidget {
  const _TierCard({
    required this.tier,
    required this.badge,
    required this.selected,
    required this.onTap,
    this.isFeatured = false,
  });

  final Plan tier;
  final String badge;
  final bool selected;
  final VoidCallback onTap;
  final bool isFeatured;

  @override
  Widget build(BuildContext context) {
    final ({String price, String perMonth, String label}) c = _copyFor(tier);
    return Material(
      color: selected ? YveColors.primarySurface : YveColors.surface,
      borderRadius: YveSpacing.cardRadius,
      child: InkWell(
        onTap: () {
          HapticFeedback.selectionClick();
          onTap();
        },
        borderRadius: YveSpacing.cardRadius,
        child: Container(
          padding: const EdgeInsets.all(YveSpacing.lg),
          decoration: BoxDecoration(
            borderRadius: YveSpacing.cardRadius,
            border: Border.all(
              color: selected ? YveColors.primary : YveColors.border,
              width: selected ? 2 : 1,
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Row(
                children: <Widget>[
                  _SelectIndicator(selected: selected),
                  const SizedBox(width: YveSpacing.md),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Row(
                          children: <Widget>[
                            Text(
                              c.label,
                              style: const TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.w700,
                                color: YveColors.textPrimary,
                                letterSpacing: -0.2,
                              ),
                            ),
                            if (isFeatured) ...<Widget>[
                              const SizedBox(width: YveSpacing.sm),
                              const _FeaturedTag(),
                            ],
                          ],
                        ),
                        const SizedBox(height: 2),
                        Text(
                          badge,
                          style: const TextStyle(
                            fontSize: 12,
                            color: YveColors.textTertiary,
                            height: 1.4,
                          ),
                        ),
                      ],
                    ),
                  ),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: <Widget>[
                      Text(
                        c.price,
                        style: const TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w700,
                          color: YveColors.primary,
                          letterSpacing: -0.3,
                        ),
                      ),
                      Text(
                        c.perMonth,
                        style: const TextStyle(
                          fontSize: 11,
                          color: YveColors.textTertiary,
                          height: 1.3,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  static ({String price, String perMonth, String label}) _copyFor(Plan t) {
    return switch (t) {
      Plan.proMonthly => (
        price: '\$29',
        perMonth: '\$29/mo',
        label: 'Monthly',
      ),
      Plan.proSemester => (
        price: '\$89',
        perMonth: '\$22/mo · 4 months',
        label: 'Semester',
      ),
      Plan.proAnnual => (
        price: '\$229',
        perMonth: '\$19/mo · 12 months',
        label: 'Annual',
      ),
      _ => (price: '', perMonth: '', label: t.label),
    };
  }
}

class _SelectIndicator extends StatelessWidget {
  const _SelectIndicator({required this.selected});
  final bool selected;
  @override
  Widget build(BuildContext context) {
    return Container(
      width: 20,
      height: 20,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: Border.all(
          color: selected ? YveColors.primary : YveColors.border,
          width: 2,
        ),
      ),
      child: selected
          ? Container(
              margin: const EdgeInsets.all(3),
              decoration: const BoxDecoration(
                color: YveColors.primary,
                shape: BoxShape.circle,
              ),
            )
          : null,
    );
  }
}

class _FeaturedTag extends StatelessWidget {
  const _FeaturedTag();
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        gradient: YveColors.brandGradient,
        borderRadius: BorderRadius.circular(10),
      ),
      child: const Text(
        'POPULAR',
        style: TextStyle(
          fontSize: 9,
          fontWeight: FontWeight.w800,
          color: YveColors.textInverse,
          letterSpacing: 0.8,
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────
// CTA + sublines
// ─────────────────────────────────────────────────────────────────────

class _CtaButton extends StatelessWidget {
  const _CtaButton({
    required this.label,
    required this.launching,
    required this.onPressed,
  });

  final String label;
  final bool launching;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      child: FilledButton(
        onPressed: launching ? null : onPressed,
        style: FilledButton.styleFrom(
          backgroundColor: YveColors.primary,
          foregroundColor: YveColors.textInverse,
          padding: const EdgeInsets.symmetric(vertical: 16),
          shape: const StadiumBorder(),
          textStyle: const TextStyle(
            fontSize: 15,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.2,
          ),
        ),
        child: launching
            ? const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  valueColor: AlwaysStoppedAnimation<Color>(YveColors.textInverse),
                ),
              )
            : Text(label),
      ),
    );
  }
}

class _CtaSubLine extends StatelessWidget {
  const _CtaSubLine();
  @override
  Widget build(BuildContext context) {
    return const Text(
      'Card required. Cancel anytime in the first 3 days — no charge.',
      textAlign: TextAlign.center,
      style: TextStyle(
        fontSize: 12,
        color: YveColors.textTertiary,
        height: 1.5,
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────
// Already-Pro state
// ─────────────────────────────────────────────────────────────────────

class _AlreadyProCard extends StatelessWidget {
  const _AlreadyProCard({
    required this.entitlement,
    required this.onManage,
    required this.launching,
  });
  final Entitlement entitlement;
  final VoidCallback onManage;
  final bool launching;

  String _statusLine() {
    final String label = entitlement.plan.label;
    if (entitlement.status == EntitlementStatus.trialing) {
      return 'You\'re on $label — trial active.';
    }
    if (entitlement.status == EntitlementStatus.pastDue) {
      return 'You\'re on $label, but your last charge failed. Update your card to keep Pro.';
    }
    if (entitlement.cancelAtPeriodEnd) {
      return 'You\'re on $label — cancels at the end of this period.';
    }
    return 'You\'re on $label.';
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(YveSpacing.xl),
      decoration: BoxDecoration(
        color: YveColors.primarySurface,
        borderRadius: YveSpacing.cardRadius,
        border: Border.all(color: YveColors.border, width: 1),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            _statusLine(),
            style: const TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w700,
              color: YveColors.textPrimary,
              height: 1.4,
            ),
          ),
          const SizedBox(height: YveSpacing.md),
          const Text(
            'Switch plans, update your card, or cancel — all from the billing portal.',
            style: TextStyle(
              fontSize: 13,
              color: YveColors.textSecondary,
              height: 1.5,
            ),
          ),
          const SizedBox(height: YveSpacing.lg),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton(
              onPressed: launching ? null : onManage,
              style: OutlinedButton.styleFrom(
                foregroundColor: YveColors.primary,
                side: const BorderSide(color: YveColors.primary, width: 1.5),
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: const StadiumBorder(),
                textStyle: const TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                ),
              ),
              child: launching
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                      ),
                    )
                  : const Text('Manage billing'),
            ),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────
// Features list — under-fold reassurance
// ─────────────────────────────────────────────────────────────────────

class _FeatureRows extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        const Text(
          'EVERY PRO PLAN INCLUDES',
          style: TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w700,
            color: YveColors.textTertiary,
            letterSpacing: 1.0,
          ),
        ),
        const SizedBox(height: YveSpacing.md),
        ..._items.map((String i) => _FeatureRow(text: i)),
      ],
    );
  }

  static const List<String> _items = <String>[
    'Unlimited chat through your assignments',
    'Scan worksheets and screenshots from your phone',
    'Polish drafts up to 10,000 words',
    'Unlimited subjects and material uploads',
    'Memory that grows with you over the semester',
  ];
}

class _FeatureRow extends StatelessWidget {
  const _FeatureRow({required this.text});
  final String text;
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          const Padding(
            padding: EdgeInsets.only(top: 2),
            child: Icon(
              Icons.check_rounded,
              size: 16,
              color: YveColors.primary,
            ),
          ),
          const SizedBox(width: YveSpacing.sm),
          Expanded(
            child: Text(
              text,
              style: const TextStyle(
                fontSize: 13.5,
                color: YveColors.textPrimary,
                height: 1.5,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────
// Inline error
// ─────────────────────────────────────────────────────────────────────

class _ErrorBanner extends StatelessWidget {
  const _ErrorBanner({required this.error});
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
          height: 1.4,
        ),
      ),
    );
  }
}
