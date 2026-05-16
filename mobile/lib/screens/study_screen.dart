import 'package:flutter/material.dart';

import '../models/study_mode.dart';
import '../theme/yve_colors.dart';
import '../theme/yve_spacing.dart';
import 'chat_screen.dart';

/// Study tab — Yve's modes (Learn, Practice, Assignment, Write, Materials).
///
/// These aren't isolated tools — they're behaviors of the same chat. Tapping
/// a mode opens a Yve Chat session pre-set to that mode; the learner can
/// still switch modes mid-conversation from the chat header.
class StudyScreen extends StatelessWidget {
  const StudyScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Container(
            color: YveColors.surface,
            padding: const EdgeInsets.fromLTRB(
              YveSpacing.xl,
              YveSpacing.lg,
              YveSpacing.xl,
              YveSpacing.lg,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  'Study',
                  style: Theme.of(context).textTheme.headlineMedium,
                ),
                const SizedBox(height: 2),
                const Text(
                  'Different modes for different moments',
                  style: TextStyle(
                    fontSize: 13,
                    color: YveColors.textSecondary,
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(
                YveSpacing.lg,
                YveSpacing.lg,
                YveSpacing.lg,
                YveSpacing.xxxl,
              ),
              children: <Widget>[
                _PrimaryModeTile(
                  mode: StudyMode.assignment,
                  badge: 'Most urgent',
                  onTap: () => _open(context, StudyMode.assignment),
                ),
                const SizedBox(height: YveSpacing.md),
                _ModeTile(
                  mode: StudyMode.learn,
                  onTap: () => _open(context, StudyMode.learn),
                ),
                _ModeTile(
                  mode: StudyMode.practice,
                  onTap: () => _open(context, StudyMode.practice),
                ),
                _ModeTile(
                  mode: StudyMode.write,
                  onTap: () => _open(context, StudyMode.write),
                ),
                _ModeTile(
                  mode: StudyMode.materials,
                  onTap: () => _open(context, StudyMode.materials),
                ),
                const SizedBox(height: YveSpacing.lg),
                const _ModeHint(),
              ],
            ),
          ),
        ],
      ),
    );
  }

  void _open(BuildContext context, StudyMode mode) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ChatScreen(initialMode: mode),
      ),
    );
  }
}

class _PrimaryModeTile extends StatelessWidget {
  const _PrimaryModeTile({
    required this.mode,
    required this.badge,
    required this.onTap,
  });

  final StudyMode mode;
  final String badge;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: YveColors.primary,
      borderRadius: YveSpacing.cardRadius,
      child: InkWell(
        onTap: onTap,
        borderRadius: YveSpacing.cardRadius,
        child: Container(
          padding: const EdgeInsets.all(YveSpacing.lg),
          decoration: const BoxDecoration(
            gradient: YveColors.brandGradient,
            borderRadius: YveSpacing.cardRadius,
          ),
          child: Row(
            children: <Widget>[
              Container(
                width: 52,
                height: 52,
                decoration: BoxDecoration(
                  color: const Color(0x33FFFFFF),
                  borderRadius: BorderRadius.circular(14),
                ),
                alignment: Alignment.center,
                child: Icon(mode.icon, color: YveColors.textInverse, size: 26),
              ),
              const SizedBox(width: YveSpacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Row(
                      children: <Widget>[
                        Text(
                          mode.label,
                          style: const TextStyle(
                            fontSize: 17,
                            fontWeight: FontWeight.w700,
                            color: YveColors.textInverse,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 8, vertical: 2),
                          decoration: BoxDecoration(
                            color: YveColors.accent,
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: Text(
                            badge,
                            style: const TextStyle(
                              fontSize: 10,
                              fontWeight: FontWeight.w700,
                              color: YveColors.textInverse,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(
                      mode.tagline,
                      style: const TextStyle(
                        fontSize: 13,
                        color: YveColors.textOnGradient,
                        height: 1.4,
                      ),
                    ),
                  ],
                ),
              ),
              const Icon(Icons.arrow_forward_rounded,
                  color: YveColors.textInverse, size: 20),
            ],
          ),
        ),
      ),
    );
  }
}

class _ModeTile extends StatelessWidget {
  const _ModeTile({required this.mode, required this.onTap});

  final StudyMode mode;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final TextTheme text = Theme.of(context).textTheme;
    return Container(
      margin: const EdgeInsets.only(bottom: YveSpacing.sm),
      decoration: BoxDecoration(
        color: YveColors.surface,
        borderRadius: YveSpacing.cardRadius,
        boxShadow: YveSpacing.cardShadow,
      ),
      child: Material(
        color: Colors.transparent,
        borderRadius: YveSpacing.cardRadius,
        child: InkWell(
          onTap: onTap,
          borderRadius: YveSpacing.cardRadius,
          child: Padding(
            padding: const EdgeInsets.all(YveSpacing.lg),
            child: Row(
              children: <Widget>[
                Container(
                  width: 48,
                  height: 48,
                  decoration: BoxDecoration(
                    color: mode.tint,
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: Icon(mode.icon, color: mode.iconColor),
                ),
                const SizedBox(width: YveSpacing.md),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(mode.label, style: text.titleSmall),
                      const SizedBox(height: 2),
                      Text(mode.tagline, style: text.bodySmall),
                    ],
                  ),
                ),
                const Icon(Icons.chevron_right_rounded,
                    color: Color(0xFFD1D5DB)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ModeHint extends StatelessWidget {
  const _ModeHint();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(YveSpacing.md),
      decoration: BoxDecoration(
        color: YveColors.surface2,
        borderRadius: YveSpacing.cardRadius,
      ),
      child: const Row(
        children: <Widget>[
          Icon(Icons.lightbulb_rounded,
              size: 16, color: YveColors.textSecondary),
          SizedBox(width: 8),
          Expanded(
            child: Text(
              'You can switch modes mid-conversation from the chat header — Yve keeps the context.',
              style: TextStyle(
                fontSize: 12,
                color: YveColors.textSecondary,
                height: 1.4,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
