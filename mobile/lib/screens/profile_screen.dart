import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/account.dart';
import '../models/entitlement.dart';
import '../services/auth_service.dart';
import '../services/entitlement_service.dart';
import '../services/profile_service.dart';
import '../theme/yve_colors.dart';
import '../theme/yve_spacing.dart';
import '../utils/app_error.dart';
import '../widgets/auth_sheet.dart';
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
              onTap: () => showAuthSheet(context),
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
            const SizedBox(height: YveSpacing.md),
            _SignOutButton(
              onTap: () => _confirmSignOut(context, ref),
            ),
          ],
        ],
      ),
    );
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
        if (ent.isPlus) return _PlusRow(entitlement: ent);
        return _FreeRow(entitlement: ent);
      },
    );
  }
}

class _PlusRow extends StatelessWidget {
  const _PlusRow({required this.entitlement});
  final Entitlement entitlement;

  @override
  Widget build(BuildContext context) {
    final String? until = entitlement.currentPeriodEnd != null
        ? _formatDate(entitlement.currentPeriodEnd!)
        : null;
    return Container(
      padding: const EdgeInsets.all(YveSpacing.lg),
      decoration: BoxDecoration(
        gradient: YveColors.brandGradient,
        borderRadius: YveSpacing.cardRadius,
      ),
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
                const Text(
                  'Yve Plus',
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                    color: YveColors.textInverse,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  until != null
                      ? 'Unlimited turns. Renews $until.'
                      : 'Unlimited turns.',
                  style: const TextStyle(
                    fontSize: 12,
                    color: YveColors.textOnGradient,
                    height: 1.4,
                  ),
                ),
              ],
            ),
          ),
        ],
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

  @override
  void didUpdateWidget(covariant _DisplayNameRow old) {
    super.didUpdateWidget(old);
    final String next = widget.current ?? '';
    if (next != _initial) {
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
    setState(() => _initial = v);
    FocusScope.of(context).unfocus();
  }

  @override
  Widget build(BuildContext context) {
    final bool dirty = (_ctrl.text.trim()) != _initial.trim();
    return Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: <Widget>[
        Expanded(
          child: TextField(
            controller: _ctrl,
            decoration: const InputDecoration(
              labelText: 'Display name',
              hintText: 'What Yve should call you',
            ),
            onChanged: (_) => setState(() {}),
            onSubmitted: (_) => _save(),
          ),
        ),
        if (dirty) ...<Widget>[
          const SizedBox(width: YveSpacing.sm),
          FilledButton(
            onPressed: _save,
            child: const Text('Save'),
          ),
        ],
      ],
    );
  }
}
