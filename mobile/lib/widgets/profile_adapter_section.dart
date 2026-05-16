import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/learner_profile.dart';
import '../services/notifications_service.dart';
import '../services/profile_service.dart';
import '../theme/yve_colors.dart';
import '../theme/yve_spacing.dart';
import '../utils/app_error.dart';

/// "How Yve adapts" — the explicit knobs the learner can tune. Lives in the
/// Profile tab. Every change writes via [ProfileNotifier.save] so the next
/// `yve-chat` call picks up the new preferences.
class ProfileAdapterSection extends ConsumerWidget {
  const ProfileAdapterSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AsyncValue<LearnerProfile> async = ref.watch(profileProvider);
    return async.when(
      loading: () => const _LoadingShell(),
      error: (Object e, _) => _ErrorShell(message: e.toString()),
      data: (LearnerProfile profile) => _Loaded(profile: profile),
    );
  }
}

class _LoadingShell extends StatelessWidget {
  const _LoadingShell();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: YveSpacing.xl),
      alignment: Alignment.center,
      child: const CircularProgressIndicator(),
    );
  }
}

class _ErrorShell extends StatelessWidget {
  const _ErrorShell({required this.message});
  final String message;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: YveSpacing.lg),
      child: Text(
        message,
        style: const TextStyle(fontSize: 13, color: YveColors.error),
      ),
    );
  }
}

class _Loaded extends ConsumerWidget {
  const _Loaded({required this.profile});
  final LearnerProfile profile;

  Future<void> _save(WidgetRef ref, LearnerProfile next) async {
    HapticFeedback.selectionClick();
    try {
      await ref.read(profileProvider.notifier).save(next);
    } catch (_) {
      // ProfileNotifier already rolled state back; UI auto-refreshes.
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        const _SectionLabel('How Yve adapts'),
        const SizedBox(height: YveSpacing.sm),
        Container(
          decoration: BoxDecoration(
            color: YveColors.surface,
            borderRadius: YveSpacing.cardRadius,
            boxShadow: YveSpacing.cardShadow,
          ),
          padding: const EdgeInsets.all(YveSpacing.lg),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              _ChoiceBlock<ReadingLevel>(
                title: 'Reading level',
                values: ReadingLevel.values,
                selected: profile.readingLevel,
                labelOf: (ReadingLevel v) => v.label,
                taglineOf: (ReadingLevel v) => v.tagline,
                onChanged: (ReadingLevel v) =>
                    _save(ref, profile.copyWith(readingLevel: v)),
              ),
              const Divider(height: YveSpacing.xl * 1.5),
              _ChoiceBlock<ExplanationDepth>(
                title: 'Explanation depth',
                values: ExplanationDepth.values,
                selected: profile.explanationDepth,
                labelOf: (ExplanationDepth v) => v.label,
                taglineOf: (ExplanationDepth v) => v.tagline,
                onChanged: (ExplanationDepth v) =>
                    _save(ref, profile.copyWith(explanationDepth: v)),
              ),
              const Divider(height: YveSpacing.xl * 1.5),
              _ChoiceBlock<TonePreference>(
                title: 'Tone',
                values: TonePreference.values,
                selected: profile.tone,
                labelOf: (TonePreference v) => v.label,
                taglineOf: (TonePreference v) => v.tagline,
                onChanged: (TonePreference v) =>
                    _save(ref, profile.copyWith(tone: v)),
              ),
              const Divider(height: YveSpacing.xl * 1.5),
              _ReadAloudToggle(
                value: profile.readAloud,
                onChanged: (bool v) {
                  // Turning off TTS implicitly disables hands-free; the
                  // loop has no meaning without spoken responses.
                  _save(
                    ref,
                    profile.copyWith(
                      readAloud: v,
                      handsFree: v ? profile.handsFree : false,
                    ),
                  );
                },
              ),
              const SizedBox(height: YveSpacing.md),
              _HandsFreeToggle(
                value: profile.handsFree,
                enabled: profile.readAloud,
                onChanged: (bool v) =>
                    _save(ref, profile.copyWith(handsFree: v)),
              ),
              const SizedBox(height: YveSpacing.md),
              _NotificationsToggle(
                value: profile.notificationsEnabled,
                onChanged: (bool v) async {
                  if (v) {
                    final bool ok = await ref
                        .read(notificationsServiceProvider)
                        .requestPermission();
                    if (!ok) {
                      if (context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                            content: Text(
                              'Notifications were declined. You can enable them in your system settings.',
                            ),
                          ),
                        );
                      }
                      return;
                    }
                  }
                  await _save(
                    ref,
                    profile.copyWith(notificationsEnabled: v),
                  );
                },
              ),
              const Divider(height: YveSpacing.xl * 1.5),
              _TextBlock(
                title: 'Patterns Yve should honor',
                hint:
                    'e.g. "I study best in 15-min bursts" or "I always need an example before the formula."',
                value: profile.observedPatterns,
                onSubmit: (String v) =>
                    _save(ref, profile.copyWith(observedPatterns: v)),
              ),
              const SizedBox(height: YveSpacing.lg),
              _TextBlock(
                title: 'My writing voice (for Write mode)',
                hint:
                    'Notes Yve uses to preserve your voice when polishing — anything from sentence length to favorite phrasing.',
                value: profile.voiceNotes,
                onSubmit: (String v) =>
                    _save(ref, profile.copyWith(voiceNotes: v)),
              ),
            ],
          ),
        ),
        const SizedBox(height: YveSpacing.xl),
        _ObservedByYveSection(profile: profile),
      ],
    );
  }
}

/// "What Yve has noticed" — read-only view of the auto-inferred profile.
/// Includes a Refresh button that triggers `infer-profile`, and surfaces
/// when user-set overrides are masking the auto-inferred values.
class _ObservedByYveSection extends ConsumerWidget {
  const _ObservedByYveSection({required this.profile});
  final LearnerProfile profile;

  Future<void> _refresh(BuildContext context, WidgetRef ref) async {
    HapticFeedback.lightImpact();
    try {
      await ref.read(profileProvider.notifier).refreshInference();
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              AppError.from(e, actionContext: 'profile_observe').userMessage,
            ),
          ),
        );
      }
    }
  }

  String _relativeTime(DateTime t) {
    final Duration diff = DateTime.now().difference(t);
    if (diff.inMinutes < 1) return 'just now';
    if (diff.inMinutes < 60) return '${diff.inMinutes} min ago';
    if (diff.inHours < 24) return '${diff.inHours} hr ago';
    if (diff.inDays == 1) return 'yesterday';
    return '${diff.inDays} days ago';
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AsyncValue<LearnerProfile> async = ref.watch(profileProvider);
    final bool isInferring = async.isLoading;
    final bool hasAnyAuto = (profile.autoObservedPatterns?.trim().isNotEmpty ?? false) ||
        (profile.autoVoiceNotes?.trim().isNotEmpty ?? false);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        const _SectionLabel('What Yve has noticed'),
        const SizedBox(height: YveSpacing.sm),
        Container(
          decoration: BoxDecoration(
            color: YveColors.surface,
            borderRadius: YveSpacing.cardRadius,
            boxShadow: YveSpacing.cardShadow,
          ),
          padding: const EdgeInsets.all(YveSpacing.lg),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Row(
                children: <Widget>[
                  Container(
                    width: 32,
                    height: 32,
                    decoration: const BoxDecoration(
                      gradient: YveColors.brandGradient,
                      shape: BoxShape.circle,
                    ),
                    alignment: Alignment.center,
                    child: const Icon(
                      Icons.auto_awesome,
                      color: YveColors.textInverse,
                      size: 14,
                    ),
                  ),
                  const SizedBox(width: YveSpacing.sm),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Text(
                          'Yve\'s read of you',
                          style: Theme.of(context).textTheme.titleSmall,
                        ),
                        if (profile.lastInferredAt != null)
                          Text(
                            'Updated ${_relativeTime(profile.lastInferredAt!)}',
                            style: const TextStyle(
                              fontSize: 11,
                              color: YveColors.textTertiary,
                            ),
                          ),
                      ],
                    ),
                  ),
                  TextButton.icon(
                    onPressed:
                        isInferring ? null : () => _refresh(context, ref),
                    icon: isInferring
                        ? const SizedBox(
                            width: 14,
                            height: 14,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: YveColors.primary,
                            ),
                          )
                        : const Icon(Icons.refresh_rounded, size: 16),
                    label: Text(isInferring ? 'Observing…' : 'Refresh'),
                  ),
                ],
              ),
              if (!hasAnyAuto && profile.lastInferredAt == null) ...<Widget>[
                const SizedBox(height: YveSpacing.md),
                const Text(
                  'After a few sessions, tap Refresh and Yve will share what she\'s noticed about how you study.',
                  style: TextStyle(
                    fontSize: 13,
                    color: YveColors.textSecondary,
                    height: 1.5,
                  ),
                ),
              ] else ...<Widget>[
                if (profile.autoObservedPatterns != null &&
                    profile.autoObservedPatterns!.trim().isNotEmpty) ...<Widget>[
                  const SizedBox(height: YveSpacing.md),
                  _ObservedBlock(
                    title: 'Patterns',
                    body: profile.autoObservedPatterns!.trim(),
                    overriddenBy: profile.observedPatterns?.trim().isNotEmpty ==
                            true
                        ? 'Currently overridden by your manual notes above.'
                        : null,
                  ),
                ],
                if (profile.autoVoiceNotes != null &&
                    profile.autoVoiceNotes!.trim().isNotEmpty) ...<Widget>[
                  const SizedBox(height: YveSpacing.md),
                  _ObservedBlock(
                    title: 'Writing voice',
                    body: profile.autoVoiceNotes!.trim(),
                    overriddenBy: profile.voiceNotes?.trim().isNotEmpty == true
                        ? 'Currently overridden by your manual notes above.'
                        : null,
                  ),
                ],
              ],
            ],
          ),
        ),
      ],
    );
  }
}

class _ObservedBlock extends StatelessWidget {
  const _ObservedBlock({
    required this.title,
    required this.body,
    this.overriddenBy,
  });

  final String title;
  final String body;
  final String? overriddenBy;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(YveSpacing.md),
      decoration: BoxDecoration(
        color: YveColors.primarySurface,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            title.toUpperCase(),
            style: const TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.w700,
              color: YveColors.primaryLight,
              letterSpacing: 0.8,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            body,
            style: const TextStyle(
              fontSize: 13,
              color: YveColors.primary,
              height: 1.55,
            ),
          ),
          if (overriddenBy != null) ...<Widget>[
            const SizedBox(height: 6),
            Text(
              overriddenBy!,
              style: const TextStyle(
                fontSize: 11,
                fontStyle: FontStyle.italic,
                color: YveColors.textSecondary,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.label);
  final String label;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(left: YveSpacing.xs, bottom: 6),
      child: Text(
        label.toUpperCase(),
        style: const TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w700,
          color: YveColors.textTertiary,
          letterSpacing: 0.8,
        ),
      ),
    );
  }
}

class _ChoiceBlock<T> extends StatelessWidget {
  const _ChoiceBlock({
    required this.title,
    required this.values,
    required this.selected,
    required this.labelOf,
    required this.taglineOf,
    required this.onChanged,
  });

  final String title;
  final List<T> values;
  final T selected;
  final String Function(T) labelOf;
  final String Function(T) taglineOf;
  final ValueChanged<T> onChanged;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(
          title,
          style: Theme.of(context).textTheme.titleSmall,
        ),
        const SizedBox(height: YveSpacing.sm),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: <Widget>[
            for (final T v in values)
              _ChoicePill(
                label: labelOf(v),
                selected: v == selected,
                onTap: () => onChanged(v),
              ),
          ],
        ),
        const SizedBox(height: 4),
        Text(
          taglineOf(selected),
          style: const TextStyle(
            fontSize: 12,
            color: YveColors.textSecondary,
            height: 1.4,
          ),
        ),
      ],
    );
  }
}

class _ChoicePill extends StatelessWidget {
  const _ChoicePill({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final Color bg = selected ? YveColors.primarySurface : YveColors.surface;
    final Color border = selected ? YveColors.primary : YveColors.border;
    final Color fg = selected ? YveColors.primary : YveColors.textPrimary;
    return Material(
      color: bg,
      borderRadius: YveSpacing.pillRadius,
      child: InkWell(
        borderRadius: YveSpacing.pillRadius,
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(
            borderRadius: YveSpacing.pillRadius,
            border: Border.all(color: border, width: 1.5),
          ),
          child: Text(
            label,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: fg,
            ),
          ),
        ),
      ),
    );
  }
}

class _ReadAloudToggle extends StatelessWidget {
  const _ReadAloudToggle({required this.value, required this.onChanged});

  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: <Widget>[
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                'Read responses aloud',
                style: Theme.of(context).textTheme.titleSmall,
              ),
              const SizedBox(height: 2),
              const Text(
                'Yve speaks her answers via your device\'s voice and shortens her responses for the ear.',
                style: TextStyle(
                  fontSize: 12,
                  color: YveColors.textSecondary,
                  height: 1.4,
                ),
              ),
            ],
          ),
        ),
        Switch.adaptive(
          value: value,
          onChanged: onChanged,
          activeColor: YveColors.primary,
        ),
      ],
    );
  }
}

class _HandsFreeToggle extends StatelessWidget {
  const _HandsFreeToggle({
    required this.value,
    required this.enabled,
    required this.onChanged,
  });

  final bool value;
  final bool enabled;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final Color titleColor =
        enabled ? YveColors.textPrimary : YveColors.textTertiary;
    final Color bodyColor =
        enabled ? YveColors.textSecondary : YveColors.textTertiary;
    return Row(
      children: <Widget>[
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                'Hands-free conversation',
                style: Theme.of(context)
                    .textTheme
                    .titleSmall
                    ?.copyWith(color: titleColor),
              ),
              const SizedBox(height: 2),
              Text(
                enabled
                    ? 'After Yve finishes speaking, the mic auto-listens — for car commutes, kitchen study, or studying with your eyes closed.'
                    : 'Turn on "Read responses aloud" first — hands-free has no meaning without spoken answers.',
                style: TextStyle(
                  fontSize: 12,
                  color: bodyColor,
                  height: 1.4,
                ),
              ),
            ],
          ),
        ),
        Switch.adaptive(
          value: value,
          onChanged: enabled ? onChanged : null,
          activeColor: YveColors.primary,
        ),
      ],
    );
  }
}

class _NotificationsToggle extends StatelessWidget {
  const _NotificationsToggle({required this.value, required this.onChanged});

  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: <Widget>[
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                'Daily review nudge',
                style: Theme.of(context).textTheme.titleSmall,
              ),
              const SizedBox(height: 2),
              const Text(
                'A calm 7pm reminder on days when concepts are ready for a refresh. Silent when there\'s nothing due.',
                style: TextStyle(
                  fontSize: 12,
                  color: YveColors.textSecondary,
                  height: 1.4,
                ),
              ),
            ],
          ),
        ),
        Switch.adaptive(
          value: value,
          onChanged: onChanged,
          activeColor: YveColors.primary,
        ),
      ],
    );
  }
}

class _TextBlock extends StatefulWidget {
  const _TextBlock({
    required this.title,
    required this.hint,
    required this.value,
    required this.onSubmit,
  });

  final String title;
  final String hint;
  final String? value;
  final ValueChanged<String> onSubmit;

  @override
  State<_TextBlock> createState() => _TextBlockState();
}

class _TextBlockState extends State<_TextBlock> {
  late final TextEditingController _ctrl =
      TextEditingController(text: widget.value ?? '');
  late String _initial = widget.value ?? '';
  bool _dirty = false;

  @override
  void didUpdateWidget(covariant _TextBlock oldWidget) {
    super.didUpdateWidget(oldWidget);
    if ((widget.value ?? '') != _initial && !_dirty) {
      _initial = widget.value ?? '';
      _ctrl.text = _initial;
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  void _onSubmit() {
    final String v = _ctrl.text.trim();
    widget.onSubmit(v);
    setState(() {
      _initial = v;
      _dirty = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Text(widget.title, style: Theme.of(context).textTheme.titleSmall),
        const SizedBox(height: YveSpacing.sm),
        TextField(
          controller: _ctrl,
          minLines: 2,
          maxLines: 5,
          onChanged: (String v) {
            final bool nowDirty = v.trim() != _initial.trim();
            if (nowDirty != _dirty) setState(() => _dirty = nowDirty);
          },
          decoration: InputDecoration(
            hintText: widget.hint,
            hintMaxLines: 3,
          ),
        ),
        if (_dirty) ...<Widget>[
          const SizedBox(height: YveSpacing.sm),
          Align(
            alignment: Alignment.centerRight,
            child: FilledButton(
              onPressed: _onSubmit,
              child: const Text('Save'),
            ),
          ),
        ],
      ],
    );
  }
}
