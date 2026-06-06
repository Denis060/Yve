import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../models/account.dart';
import '../models/entitlement.dart';
import '../services/auth_service.dart';
import '../services/entitlement_service.dart';
import '../services/profile_service.dart';
import '../theme/yve_colors.dart';
import '../theme/yve_spacing.dart';
import '../utils/app_error.dart';
import '../widgets/anonymous_continuation_panel.dart';
import '../widgets/profile_adapter_section.dart';
import '../widgets/upgrade_sheet.dart';
import '../widgets/yve_card.dart';

class ProfileScreen extends ConsumerWidget {
  const ProfileScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final TextTheme text = Theme.of(context).textTheme;
    final AsyncValue<Account> accountAsync = ref.watch(accountProvider);
    return SafeArea(
      child: ListView(
        padding: const EdgeInsets.fromLTRB(
          YveSpacing.xl,
          YveSpacing.lg,
          YveSpacing.xl,
          YveSpacing.xxxl,
        ),
        children: <Widget>[
          Text('Profile', style: text.headlineMedium),
          const SizedBox(height: YveSpacing.xl),
          accountAsync.when(
            loading: () => const _LoadingCard(),
            error: (Object e, _) => _ErrorCard(message: e.toString()),
            data: (Account account) => _AccountCard(account: account),
          ),
          const SizedBox(height: YveSpacing.xl),
          const _PlanCard(),
          const SizedBox(height: YveSpacing.xl),
          const ProfileAdapterSection(),
        ],
      ),
    );
  }
}

class _LoadingCard extends StatelessWidget {
  const _LoadingCard();
  @override
  Widget build(BuildContext context) {
    return const YveCard(
      child: SizedBox(
        height: 72,
        child: Center(child: CircularProgressIndicator()),
      ),
    );
  }
}

class _ErrorCard extends StatelessWidget {
  const _ErrorCard({required this.message});
  final String message;
  @override
  Widget build(BuildContext context) {
    return YveCard(
      child: Text(
        message,
        style: const TextStyle(fontSize: 13, color: YveColors.error),
      ),
    );
  }
}

class _AccountCard extends ConsumerWidget {
  const _AccountCard({required this.account});
  final Account account;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final TextTheme text = Theme.of(context).textTheme;
    final String initial = account.friendlyName.substring(0, 1).toUpperCase();

    return YveCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Row(
            children: <Widget>[
              Container(
                width: 56,
                height: 56,
                decoration: const BoxDecoration(
                  gradient: YveColors.brandGradient,
                  shape: BoxShape.circle,
                ),
                alignment: Alignment.center,
                child: Text(
                  account.isAnonymous ? '✦' : initial,
                  style: const TextStyle(
                    fontSize: 24,
                    fontWeight: FontWeight.w700,
                    color: YveColors.textInverse,
                  ),
                ),
              ),
              const SizedBox(width: YveSpacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(account.friendlyName, style: text.titleSmall),
                    const SizedBox(height: 2),
                    Text(
                      account.statusLine,
                      style: const TextStyle(
                        fontSize: 12,
                        color: YveColors.textSecondary,
                        height: 1.4,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: YveSpacing.lg),
          if (account.isAnonymous)
            _SignInButton(
              onTap: () => showAnonymousContinuation(
                context,
                title: 'Save your work to Yve',
                body: 'Keep your subjects, chats, and progress across '
                    'every device — and unlock continuity for new semesters.',
              ),
            )
          else ...<Widget>[
            _DisplayNameRow(
              current: account.displayName,
              onSave: (String? name) async {
                try {
                  await ref
                      .read(profileRepositoryProvider)
                      .writeDisplayName(name);
                  ref.invalidate(accountProvider);
                } catch (e) {
                  if (!context.mounted) return;
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text(
                        AppError.from(e, actionContext: 'profile_save').userMessage,
                      ),
                    ),
                  );
                }
              },
            ),
            // Manage plan — visible whenever the user has any flavor
            // of active subscription (trialing, active, past_due,
            // incomplete) so they can always cancel, update card, or
            // change tier. Trial users especially need an obvious path
            // here — we promise "Cancel anytime in the first 3 days"
            // on the pricing screen and this is how they make good on it.
            Consumer(builder: (BuildContext _, WidgetRef innerRef, __) {
              final AsyncValue<Entitlement> ent =
                  innerRef.watch(entitlementProvider);
              final Entitlement? e = ent.value;
              final bool showPortal = e != null && e.isPro;
              if (!showPortal) return const SizedBox.shrink();
              return Padding(
                padding: const EdgeInsets.only(top: YveSpacing.md),
                child: _ManagePlanButton(
                  trialing: e.status == EntitlementStatus.trialing,
                  trialEnd: e.trialEnd,
                  onTap: () => _openBillingPortal(context, innerRef),
                ),
              );
            }),
            const SizedBox(height: YveSpacing.md),
            _SignOutButton(
              onTap: () => _confirmSignOut(context, ref),
            ),
          ],
          // Account deletion: always offered, even to anonymous users.
          // Required by Google Play Store policy (Apps must offer in-app
          // account deletion). For named users this also cancels any
          // active Stripe subscription server-side.
          const SizedBox(height: YveSpacing.lg),
          _DeleteAccountButton(
            onTap: () => _confirmDeleteAccount(context, ref),
          ),
        ],
      ),
    );
  }

  /// Opens the Stripe-hosted Customer Portal — Stripe takes the
  /// user from there: update card, cancel before trial ends, switch
  /// tier, download invoices. Webhook fires the relevant subscription
  /// events on cancel/update, which flips entitlement back to Free
  /// at end-of-period (or immediately for trial cancel).
  Future<void> _openBillingPortal(BuildContext context, WidgetRef ref) async {
    try {
      HapticFeedback.selectionClick();
      await ref.read(entitlementProvider.notifier).launchPortal();
    } catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            AppError.from(e, actionContext: 'billing_portal').userMessage,
          ),
        ),
      );
    }
  }

  /// Two-step confirmation: an explanation dialog, then a typed-in
  /// confirmation. Borrowed from the GitHub / Stripe / 1Password
  /// pattern — strong enough friction that nobody nukes their account
  /// by mistapping, but not so painful that a determined user can't
  /// finish in 30 seconds.
  Future<void> _confirmDeleteAccount(
    BuildContext context,
    WidgetRef ref,
  ) async {
    final bool? wantsExplanation = await showDialog<bool>(
      context: context,
      builder: (BuildContext ctx) {
        return AlertDialog(
          title: const Text('Delete your account?'),
          content: const Text(
            "This permanently removes your subjects, chats, scans, notes, "
            "and account from Yve. We can't recover any of it.\n\n"
            "Any active Pro subscription will be canceled immediately, with "
            "unused time refunded.\n\n"
            "If you only want a break, sign out instead — your work stays "
            "and you can come back any time.",
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: YveColors.error,
                foregroundColor: YveColors.textInverse,
              ),
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text('Continue'),
            ),
          ],
        );
      },
    );
    if (wantsExplanation != true || !context.mounted) return;

    // Stage 2: typed confirmation.
    final TextEditingController controller = TextEditingController();
    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext ctx) {
        bool canDelete = false;
        return StatefulBuilder(builder: (BuildContext ctx, StateSetter setSt) {
          return AlertDialog(
            title: const Text('Type DELETE to confirm'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                const Text(
                  "Last step. Once you tap Delete account, your data is gone.",
                ),
                const SizedBox(height: YveSpacing.md),
                TextField(
                  controller: controller,
                  autofocus: true,
                  decoration: const InputDecoration(
                    hintText: 'Type DELETE',
                  ),
                  onChanged: (String v) {
                    setSt(() => canDelete = v.trim() == 'DELETE');
                  },
                ),
              ],
            ),
            actions: <Widget>[
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(false),
                child: const Text('Cancel'),
              ),
              FilledButton(
                style: FilledButton.styleFrom(
                  backgroundColor: YveColors.error,
                  foregroundColor: YveColors.textInverse,
                ),
                onPressed: canDelete
                    ? () => Navigator.of(ctx).pop(true)
                    : null,
                child: const Text('Delete account'),
              ),
            ],
          );
        });
      },
    );
    controller.dispose();
    if (confirmed != true || !context.mounted) return;

    // Fire-and-forget loading dialog + the actual delete call.
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const Center(
        child: CircularProgressIndicator(
          valueColor: AlwaysStoppedAnimation<Color>(YveColors.accent),
        ),
      ),
    );

    try {
      HapticFeedback.heavyImpact();
      await Supabase.instance.client.functions.invoke('delete-account');
      // Sign out (which immediately establishes a fresh anonymous
      // session) so RLS-protected reads don't see the now-orphaned
      // user_id and 401.
      await ref.read(authServiceProvider).signOut();
      if (!context.mounted) return;
      Navigator.of(context).pop(); // dismiss loading
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Your Yve account has been deleted.'),
        ),
      );
    } catch (e) {
      if (!context.mounted) return;
      Navigator.of(context).pop(); // dismiss loading
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Account deletion failed: ${AppError.from(e, actionContext: "delete_account").userMessage}',
          ),
        ),
      );
    }
  }

  Future<void> _confirmSignOut(BuildContext context, WidgetRef ref) async {
    final bool? ok = await showDialog<bool>(
      context: context,
      builder: (BuildContext ctx) {
        return AlertDialog(
          title: const Text('Sign out?'),
          content: const Text(
            'You\'ll go back to a fresh anonymous session. Sign back in any '
            'time to pick up your work.',
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text('Sign out'),
            ),
          ],
        );
      },
    );
    if (ok != true) return;
    try {
      HapticFeedback.lightImpact();
      await ref.read(authServiceProvider).signOut();
    } catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            AppError.from(e, actionContext: 'sign_out').userMessage,
          ),
        ),
      );
    }
  }
}

class _PlanCard extends ConsumerWidget {
  const _PlanCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AsyncValue<Entitlement> async = ref.watch(entitlementProvider);
    return async.when(
      loading: () => const SizedBox.shrink(),
      error: (_, __) => const SizedBox.shrink(),
      data: (Entitlement ent) {
        if (ent.isPlus) {
          return _PlusRow(
            entitlement: ent,
            onTap: () async {
              try {
                HapticFeedback.selectionClick();
                await ref.read(entitlementProvider.notifier).launchPortal();
              } catch (e) {
                if (!context.mounted) return;
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text(
                    AppError.from(e, actionContext: 'plan_card_tap').userMessage,
                  )),
                );
              }
            },
          );
        }
        return _FreeRow(entitlement: ent);
      },
    );
  }
}

class _PlusRow extends StatelessWidget {
  const _PlusRow({required this.entitlement, this.onTap});
  final Entitlement entitlement;
  final VoidCallback? onTap;

  String get _planLabel {
    switch (entitlement.plan) {
      case Plan.proMonthly:  return 'Yve Pro Monthly';
      case Plan.proSemester: return 'Yve Pro Semester';
      case Plan.proAnnual:   return 'Yve Pro Annual';
      case Plan.proTrial:    return 'Yve Pro Trial';
      case Plan.free:        return 'Yve Pro';
    }
  }

  String get _statusLine {
    final DateTime? trialEnd = entitlement.trialEnd;
    final DateTime? periodEnd = entitlement.currentPeriodEnd;
    if (entitlement.status == EntitlementStatus.trialing && trialEnd != null) {
      return 'Trial ends ${_formatDate(trialEnd)}. Cancel anytime before then.';
    }
    if (periodEnd != null) {
      return 'Renews ${_formatDate(periodEnd)}.';
    }
    return 'Unlimited turns.';
  }

  @override
  Widget build(BuildContext context) {
    // The whole plan card is the affordance — tap anywhere on it to
    // open the Stripe Customer Portal (cancel, update card, etc).
    // A trailing chevron + InkWell make it visually clear it's tappable.
    return Material(
      color: Colors.transparent,
      borderRadius: YveSpacing.cardRadius,
      child: InkWell(
        onTap: onTap,
        borderRadius: YveSpacing.cardRadius,
        child: Ink(
          decoration: BoxDecoration(
            gradient: YveColors.brandGradient,
            borderRadius: YveSpacing.cardRadius,
          ),
          padding: const EdgeInsets.all(YveSpacing.lg),
          child: Row(
            children: <Widget>[
              Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  color: const Color(0x33FFFFFF),
                  borderRadius: BorderRadius.circular(12),
                ),
                alignment: Alignment.center,
                child: const Icon(Icons.auto_awesome,
                    color: YveColors.textInverse, size: 18),
              ),
              const SizedBox(width: YveSpacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      _planLabel,
                      style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                        color: YveColors.textInverse,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      _statusLine,
                      style: const TextStyle(
                        fontSize: 12,
                        color: YveColors.textOnGradient,
                        height: 1.4,
                      ),
                    ),
                  ],
                ),
              ),
              const Icon(
                Icons.chevron_right_rounded,
                color: YveColors.textInverse,
              ),
            ],
          ),
        ),
      ),
    );
  }

  String _formatDate(DateTime d) {
    final DateTime local = d.toLocal();
    const List<String> months = <String>[
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
    ];
    return '${months[local.month - 1]} ${local.day}';
  }
}

class _FreeRow extends ConsumerWidget {
  const _FreeRow({required this.entitlement});
  final Entitlement entitlement;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Material(
      color: YveColors.surface,
      borderRadius: YveSpacing.cardRadius,
      child: InkWell(
        borderRadius: YveSpacing.cardRadius,
        onTap: () => showUpgradeSheet(context),
        child: Container(
          padding: const EdgeInsets.all(YveSpacing.lg),
          decoration: BoxDecoration(
            color: YveColors.surface,
            borderRadius: YveSpacing.cardRadius,
            border: Border.all(color: YveColors.primarySurface, width: 1.5),
          ),
          child: Row(
            children: <Widget>[
              Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  color: YveColors.primarySurface,
                  borderRadius: BorderRadius.circular(12),
                ),
                alignment: Alignment.center,
                child: const Icon(Icons.lock_open_rounded,
                    color: YveColors.primary, size: 18),
              ),
              const SizedBox(width: YveSpacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      'You\'re on the free plan',
                      style: Theme.of(context).textTheme.titleSmall,
                    ),
                    const SizedBox(height: 2),
                    const Text(
                      '10 chat turns a day. Tap to unlock unlimited.',
                      style: TextStyle(
                        fontSize: 12,
                        color: YveColors.textSecondary,
                        height: 1.4,
                      ),
                    ),
                  ],
                ),
              ),
              const Icon(Icons.chevron_right_rounded,
                  color: YveColors.textTertiary),
            ],
          ),
        ),
      ),
    );
  }
}

class _SignInButton extends StatelessWidget {
  const _SignInButton({required this.onTap});
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) {
    return FilledButton.icon(
      onPressed: onTap,
      icon: const Icon(Icons.lock_open_rounded),
      label: const Text('Sign in to keep your work'),
    );
  }
}

class _SignOutButton extends StatelessWidget {
  const _SignOutButton({required this.onTap});
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) {
    return OutlinedButton.icon(
      onPressed: onTap,
      icon: const Icon(Icons.logout_rounded),
      label: const Text('Sign out'),
    );
  }
}

/// "Manage plan" button. Shows trial countdown for trialing users so
/// "Cancel anytime in the first 3 days" feels real and tangible.
class _ManagePlanButton extends StatelessWidget {
  const _ManagePlanButton({
    required this.trialing,
    required this.trialEnd,
    required this.onTap,
  });
  final bool trialing;
  final DateTime? trialEnd;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final String label = trialing && trialEnd != null
        ? 'Manage plan • Trial ends ${_humanize(trialEnd!)}'
        : 'Manage plan';
    return FilledButton.icon(
      onPressed: onTap,
      icon: const Icon(Icons.receipt_long_rounded),
      label: Text(label, overflow: TextOverflow.ellipsis),
      style: FilledButton.styleFrom(
        backgroundColor: YveColors.primary,
        foregroundColor: YveColors.textInverse,
        minimumSize: const Size.fromHeight(48),
      ),
    );
  }

  /// "Mar 21" / "in 2 days" / "tomorrow" — whichever is most natural.
  String _humanize(DateTime when) {
    final Duration delta = when.difference(DateTime.now());
    if (delta.inHours < 24 && delta.inHours > 0) return 'in ${delta.inHours}h';
    if (delta.inDays == 0) return 'today';
    if (delta.inDays == 1) return 'tomorrow';
    if (delta.inDays > 1 && delta.inDays < 7) return 'in ${delta.inDays} days';
    const List<String> months = <String>[
      'Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'
    ];
    return '${months[when.month - 1]} ${when.day}';
  }
}

/// Subtle destructive action — text-only button in `YveColors.error`
/// so it doesn't compete with the primary actions above. Required by
/// Google Play Store policy; mounted at the bottom of the Profile so
/// it's always findable but never the first thing the eye lands on.
class _DeleteAccountButton extends StatelessWidget {
  const _DeleteAccountButton({required this.onTap});
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) {
    return TextButton.icon(
      onPressed: onTap,
      icon: const Icon(Icons.delete_outline_rounded, size: 16),
      label: const Text('Delete account'),
      style: TextButton.styleFrom(
        foregroundColor: YveColors.error,
        padding: const EdgeInsets.symmetric(vertical: 12),
      ),
    );
  }
}

class _DisplayNameRow extends StatefulWidget {
  const _DisplayNameRow({required this.current, required this.onSave});

  final String? current;
  final ValueChanged<String?> onSave;

  @override
  State<_DisplayNameRow> createState() => _DisplayNameRowState();
}

class _DisplayNameRowState extends State<_DisplayNameRow> {
  late final TextEditingController _ctrl =
      TextEditingController(text: widget.current ?? '');
  late String _initial = widget.current ?? '';
  // True once the user has typed since the last sync with the server.
  // While dirty, didUpdateWidget will NOT clobber _ctrl.text — otherwise
  // a parent rebuild (which happens on every Supabase auth tick because
  // Account has no operator==) would erase mid-typing input.
  bool _dirty = false;

  @override
  void didUpdateWidget(covariant _DisplayNameRow old) {
    super.didUpdateWidget(old);
    final String next = widget.current ?? '';
    if (next != _initial && !_dirty) {
      _initial = next;
      _ctrl.text = next;
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  void _save() {
    final String v = _ctrl.text.trim();
    widget.onSave(v.isEmpty ? null : v);
    setState(() {
      _initial = v;
      _dirty = false;
    });
    FocusScope.of(context).unfocus();
  }

  @override
  Widget build(BuildContext context) {
    final bool dirty = _dirty;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        TextField(
          controller: _ctrl,
          // Disable browser autofill — on Flutter web, Chrome's autofill
          // engine sometimes fights with the TextField and resets typed
          // characters, especially on fields it heuristically associates
          // with "name" inputs. Explicit empty hints opt out.
          autofillHints: const <String>[],
          autocorrect: false,
          enableSuggestions: false,
          textInputAction: TextInputAction.done,
          decoration: const InputDecoration(
            labelText: 'Display name',
            hintText: 'What Yve should call you',
          ),
          onChanged: (String v) {
            final bool nowDirty = v.trim() != _initial.trim();
            if (nowDirty != _dirty) setState(() => _dirty = nowDirty);
          },
          onSubmitted: (_) => _save(),
        ),
        if (dirty) ...<Widget>[
          const SizedBox(height: YveSpacing.sm),
          Align(
            alignment: Alignment.centerRight,
            child: FilledButton(
              onPressed: _save,
              child: const Text('Save'),
            ),
          ),
        ],
      ],
    );
  }
}
