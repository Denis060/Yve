import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/subject.dart';
import '../services/subjects_service.dart';
import '../theme/yve_colors.dart';
import '../theme/yve_spacing.dart';
import '../utils/app_error.dart';
import '../widgets/yve_card.dart';
import 'subject_workspace_screen.dart';

class SubjectsScreen extends ConsumerWidget {
  const SubjectsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AsyncValue<List<Subject>> subjectsAsync =
        ref.watch(subjectsProvider);

    return SafeArea(
      child: RefreshIndicator(
        onRefresh: () => ref.read(subjectsProvider.notifier).refresh(),
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.fromLTRB(
            YveSpacing.xl,
            YveSpacing.lg,
            YveSpacing.xl,
            YveSpacing.xxxl,
          ),
          children: <Widget>[
            Text(
              'Subjects',
              style: Theme.of(context).textTheme.headlineMedium,
            ),
            const SizedBox(height: 2),
            const Text(
              'Your workspaces, materials, and study history',
              style: TextStyle(fontSize: 13, color: YveColors.textSecondary),
            ),
            const SizedBox(height: YveSpacing.xl),
            subjectsAsync.when(
              loading: () => const Padding(
                padding: EdgeInsets.symmetric(vertical: YveSpacing.xxxl),
                child: Center(child: CircularProgressIndicator()),
              ),
              error: (Object e, _) => Padding(
                padding: const EdgeInsets.symmetric(vertical: YveSpacing.lg),
                child: Text(
                  e.toString(),
                  style: const TextStyle(color: YveColors.error),
                ),
              ),
              data: (List<Subject> subjects) {
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    for (final Subject s in subjects) ...<Widget>[
                      _SubjectRow(
                        subject: s,
                        onTap: () => Navigator.of(context).push(
                          MaterialPageRoute<void>(
                            builder: (_) =>
                                SubjectWorkspaceScreen(subjectId: s.id),
                          ),
                        ),
                      ),
                      const SizedBox(height: YveSpacing.md),
                    ],
                  ],
                );
              },
            ),
            _AddSubjectButton(
              onTap: () => _addSubject(context, ref),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _addSubject(BuildContext context, WidgetRef ref) async {
    final TextEditingController nameCtrl = TextEditingController();
    final TextEditingController emojiCtrl = TextEditingController(text: '✨');
    final ({String name, String emoji})? result =
        await showModalBottomSheet<({String name, String emoji})>(
      context: context,
      isScrollControlled: true,
      builder: (BuildContext sheetContext) {
        return Padding(
          padding: EdgeInsets.only(
            left: YveSpacing.xl,
            right: YveSpacing.xl,
            top: YveSpacing.xl,
            bottom: MediaQuery.of(sheetContext).viewInsets.bottom +
                YveSpacing.xl,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Text(
                'New subject',
                style: Theme.of(sheetContext).textTheme.titleMedium,
              ),
              const SizedBox(height: YveSpacing.md),
              TextField(
                controller: nameCtrl,
                autofocus: true,
                decoration:
                    const InputDecoration(hintText: 'e.g. Nursing 201'),
              ),
              const SizedBox(height: YveSpacing.sm),
              TextField(
                controller: emojiCtrl,
                decoration: const InputDecoration(hintText: 'Emoji (optional)'),
              ),
              const SizedBox(height: YveSpacing.md),
              FilledButton(
                onPressed: () {
                  final String name = nameCtrl.text.trim();
                  if (name.isEmpty) return;
                  Navigator.of(sheetContext).pop(
                    (
                      name: name,
                      emoji: emojiCtrl.text.trim().isEmpty
                          ? '✨'
                          : emojiCtrl.text.trim(),
                    ),
                  );
                },
                child: const Text('Create'),
              ),
            ],
          ),
        );
      },
    );
    if (result != null) {
      try {
        await ref
            .read(subjectsProvider.notifier)
            .addSubject(name: result.name, emoji: result.emoji);
      } catch (e) {
        if (!context.mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              AppError.from(e, actionContext: 'create_subject').userMessage,
            ),
          ),
        );
      }
    }
  }
}

class _SubjectRow extends StatelessWidget {
  const _SubjectRow({required this.subject, required this.onTap});

  final Subject subject;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final TextTheme text = Theme.of(context).textTheme;
    return YveCard(
      onTap: onTap,
      child: Row(
        children: <Widget>[
          Container(
            width: 48,
            height: 48,
            decoration: BoxDecoration(
              color: YveColors.subjectColor(subject.colorSeed).withOpacity(0.18),
              borderRadius: BorderRadius.circular(14),
            ),
            alignment: Alignment.center,
            child: Text(subject.emoji, style: const TextStyle(fontSize: 22)),
          ),
          const SizedBox(width: YveSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(subject.name, style: text.titleSmall),
                const SizedBox(height: 2),
                Text(
                  '${subject.materialCount} materials · ${subject.sessionCount} sessions',
                  style: text.bodySmall,
                ),
              ],
            ),
          ),
          const Icon(Icons.chevron_right_rounded,
              color: YveColors.textTertiary),
        ],
      ),
    );
  }
}

class _AddSubjectButton extends StatelessWidget {
  const _AddSubjectButton({required this.onTap});
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      borderRadius: YveSpacing.cardRadius,
      child: InkWell(
        onTap: onTap,
        borderRadius: YveSpacing.cardRadius,
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 18),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: YveColors.surface,
            borderRadius: YveSpacing.cardRadius,
            border: Border.all(
              color: const Color(0xFFD1D5DB),
              style: BorderStyle.solid,
              width: 1.5,
            ),
          ),
          child: const Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Icon(Icons.add_rounded, color: YveColors.primary),
              SizedBox(width: YveSpacing.sm),
              Text(
                'Add subject',
                style: TextStyle(
                  color: YveColors.primary,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
