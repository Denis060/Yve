import 'package:flutter/material.dart';

import '../models/subject.dart';
import '../theme/yve_colors.dart';
import '../theme/yve_spacing.dart';

/// Bottom sheet that confirms which subject to save the current exchange to.
/// [suggested] surfaces Yve's recommendation at the top when present.
Future<Subject?> showSaveToSubjectSheet(
  BuildContext context, {
  required List<Subject> subjects,
  String? suggested,
}) {
  return showModalBottomSheet<Subject>(
    context: context,
    isScrollControlled: true,
    builder: (BuildContext sheetContext) {
      Subject? suggestedSubject;
      if (suggested != null) {
        for (final Subject s in subjects) {
          if (s.name.toLowerCase() == suggested.toLowerCase()) {
            suggestedSubject = s;
            break;
          }
        }
      }
      final List<Subject> others = suggestedSubject == null
          ? subjects
          : subjects
              .where((Subject s) => s.id != suggestedSubject!.id)
              .toList();

      return SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(
            YveSpacing.xl,
            YveSpacing.lg,
            YveSpacing.xl,
            YveSpacing.xl,
          ),
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
              Text(
                'Save to a subject',
                style: Theme.of(sheetContext).textTheme.titleMedium,
              ),
              const SizedBox(height: 4),
              const Text(
                'Yve will keep this exchange in your subject workspace.',
                style:
                    TextStyle(fontSize: 13, color: YveColors.textSecondary),
              ),
              const SizedBox(height: YveSpacing.lg),
              if (suggestedSubject != null) ...<Widget>[
                _SubjectRow(
                  subject: suggestedSubject,
                  suggested: true,
                  onTap: () =>
                      Navigator.of(sheetContext).pop(suggestedSubject),
                ),
                if (others.isNotEmpty) ...<Widget>[
                  const SizedBox(height: YveSpacing.md),
                  const _DividerLabel(text: 'Other subjects'),
                ],
              ],
              for (final Subject s in others)
                _SubjectRow(
                  subject: s,
                  suggested: false,
                  onTap: () => Navigator.of(sheetContext).pop(s),
                ),
            ],
          ),
        ),
      );
    },
  );
}

class _DividerLabel extends StatelessWidget {
  const _DividerLabel({required this.text});
  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: YveSpacing.sm),
      child: Text(
        text.toUpperCase(),
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

class _SubjectRow extends StatelessWidget {
  const _SubjectRow({
    required this.subject,
    required this.suggested,
    required this.onTap,
  });

  final Subject subject;
  final bool suggested;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: suggested ? YveColors.primarySurface : YveColors.surface,
      borderRadius: YveSpacing.cardRadius,
      child: InkWell(
        onTap: onTap,
        borderRadius: YveSpacing.cardRadius,
        child: Container(
          padding: const EdgeInsets.all(YveSpacing.md),
          margin: const EdgeInsets.only(bottom: YveSpacing.sm),
          decoration: BoxDecoration(
            borderRadius: YveSpacing.cardRadius,
            border: Border.all(
              color: suggested ? YveColors.primary : YveColors.border,
              width: suggested ? 1.5 : 1,
            ),
          ),
          child: Row(
            children: <Widget>[
              Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  color: YveColors.subjectColor(subject.colorSeed)
                      .withOpacity(0.18),
                  borderRadius: BorderRadius.circular(10),
                ),
                alignment: Alignment.center,
                child:
                    Text(subject.emoji, style: const TextStyle(fontSize: 18)),
              ),
              const SizedBox(width: YveSpacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Row(
                      children: <Widget>[
                        Flexible(
                          child: Text(
                            subject.name,
                            style: Theme.of(context).textTheme.titleSmall,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        if (suggested) ...<Widget>[
                          const SizedBox(width: 6),
                          const _SuggestedBadge(),
                        ],
                      ],
                    ),
                    Text(
                      '${subject.materialCount} materials',
                      style: const TextStyle(
                        fontSize: 12,
                        color: YveColors.textSecondary,
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

class _SuggestedBadge extends StatelessWidget {
  const _SuggestedBadge();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: YveColors.primary,
        borderRadius: BorderRadius.circular(6),
      ),
      child: const Text(
        '✦ Yve suggests',
        style: TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.w700,
          color: YveColors.textInverse,
        ),
      ),
    );
  }
}
