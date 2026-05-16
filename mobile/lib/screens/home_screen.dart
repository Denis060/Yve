import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/account.dart';
import '../models/concept_review.dart';
import '../models/daily_activity.dart';
import '../models/study_mode.dart';
import '../models/study_session.dart';
import '../models/subject.dart';
import '../services/profile_service.dart';
import '../services/retention_service.dart';
import '../services/sessions_service.dart';
import '../services/subjects_service.dart';
import '../theme/yve_colors.dart';
import '../theme/yve_spacing.dart';
import '../utils/app_error.dart';
import '../widgets/activity_strip.dart';
import '../widgets/presence_card.dart';
import '../widgets/recap_sheet.dart';
import '../widgets/review_queue_card.dart';
import '../widgets/yve_card.dart';
import '../widgets/yve_pill.dart';
import 'chat_screen.dart';
import 'subject_workspace_screen.dart';

/// Home — personalized, calm dashboard (Product Vision §6.1).
///
/// The greeting adapts to the time of day. The body is intentionally a single
/// scroll so the eye flows: greeting → next action → continue → subjects → tip.
class HomeScreen extends ConsumerWidget {
  const HomeScreen({super.key});

  static const List<String> _tips = <String>[
    'Upload your syllabus to a subject and Yve will help you study smarter all semester.',
    'Stuck? Try "Simplify" after Yve\'s reply — same answer, plainer words.',
    'Scan a page once, then ask Yve as many questions about it as you want.',
    'Generate a quick quiz from any session to lock in what you just learned.',
  ];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final List<Subject> subjects =
        ref.watch(subjectsProvider).value ?? const <Subject>[];
    final List<StudySession> recent =
        ref.watch(recentSessionsProvider).value ?? const <StudySession>[];
    final List<ConceptReview> reviewQueue =
        ref.watch(reviewQueueProvider).value ?? const <ConceptReview>[];
    final List<DailyActivity> week =
        ref.watch(weekActivityProvider).value ?? const <DailyActivity>[];
    final Account? account = ref.watch(accountProvider).value;
    final String greetingName = account?.friendlyName ?? 'there';
    final String tip = _tips[DateTime.now().day % _tips.length];

    StudySession? lastSession;
    if (recent.isNotEmpty) lastSession = recent.first;
    final PresenceLine? presence = resolvePresence(
      week: week,
      recent: recent,
      dueReviewCount: reviewQueue.length,
      onResumeLast: lastSession == null
          ? null
          : () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => ChatScreen.resume(
                    sessionId: lastSession!.id,
                    sessionTitle: lastSession.title,
                    subjectId: lastSession.subjectId,
                    subjectName: lastSession.subjectName,
                    subjectEmoji: lastSession.subjectEmoji,
                    initialMode: lastSession.mode,
                  ),
                ),
              ),
      onReviewDue: reviewQueue.isEmpty
          ? null
          : () {
              final ConceptReview r = reviewQueue.first;
              Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => ChatScreen(
                    subjectId: r.subjectId,
                    subjectName: r.subjectName,
                    subjectEmoji: r.subjectEmoji,
                    initialMode: StudyMode.practice,
                    initialDraft: 'Quiz me on ${r.concept}',
                  ),
                ),
              );
            },
    );

    return SafeArea(
      bottom: false,
      child: ListView(
        padding: EdgeInsets.zero,
        children: <Widget>[
          _Header(name: greetingName, week: week),
          if (presence != null) ...<Widget>[
            const SizedBox(height: YveSpacing.lg),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: YveSpacing.xl),
              child: PresenceCard(line: presence),
            ),
          ],
          const SizedBox(height: YveSpacing.lg),
          _QuickBar(
            onAssignment: () => _openChat(
              context,
              mode: StudyMode.assignment,
              draft: 'Help me solve this assignment: ',
            ),
            onScan: () => _openChat(
              context,
              mode: StudyMode.open,
              draft: 'I have a question from a photo — let me describe it: ',
            ),
            onQuiz: () => _openChat(
              context,
              mode: StudyMode.practice,
              draft: 'Quiz me on ',
            ),
          ),
          if (reviewQueue.isNotEmpty) ...<Widget>[
            const SizedBox(height: YveSpacing.xxl),
            const _SectionLabel(text: 'Revisit'),
            const SizedBox(height: YveSpacing.md),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: YveSpacing.xl),
              child: Column(
                children: <Widget>[
                  for (final ConceptReview r in reviewQueue.take(3)) ...<Widget>[
                    ReviewRow(
                      review: r,
                      onTap: () => Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          builder: (_) => ChatScreen(
                            subjectId: r.subjectId,
                            subjectName: r.subjectName,
                            subjectEmoji: r.subjectEmoji,
                            initialMode: StudyMode.practice,
                            initialDraft: 'Quiz me on ${r.concept}',
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: YveSpacing.sm),
                  ],
                ],
              ),
            ),
          ],
          if (recent.isNotEmpty) ...<Widget>[
            const SizedBox(height: YveSpacing.xxl),
            _SectionLabel(text: 'Continue'),
            const SizedBox(height: YveSpacing.md),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: YveSpacing.xl),
              child: Column(
                children: <Widget>[
                  for (final StudySession s in recent.take(2)) ...<Widget>[
                    _SessionCard(
                      session: s,
                      onTap: () => Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          builder: (_) => ChatScreen.resume(
                            sessionId: s.id,
                            sessionTitle: s.title,
                            subjectId: s.subjectId,
                            subjectName: s.subjectName,
                            subjectEmoji: s.subjectEmoji,
                            initialMode: s.mode,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: YveSpacing.sm),
                  ],
                ],
              ),
            ),
          ],
          const SizedBox(height: YveSpacing.xl),
          _SectionLabel(text: 'Your Subjects'),
          const SizedBox(height: YveSpacing.md),
          SizedBox(
            height: 96,
            child: ListView.separated(
              padding: const EdgeInsets.symmetric(horizontal: YveSpacing.xl),
              scrollDirection: Axis.horizontal,
              itemCount: subjects.length + 1,
              separatorBuilder: (_, __) => const SizedBox(width: YveSpacing.sm),
              itemBuilder: (BuildContext context, int i) {
                if (i == subjects.length) {
                  return _AddSubjectCard(onTap: () => _promptAddSubject(context, ref));
                }
                final Subject s = subjects[i];
                return _SubjectChipCard(
                  subject: s,
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => SubjectWorkspaceScreen(subjectId: s.id),
                    ),
                  ),
                );
              },
            ),
          ),
          const SizedBox(height: YveSpacing.xl),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: YveSpacing.xl),
            child: _RecapCta(
              onTap: () => showYveRecap(context, ref),
            ),
          ),
          const SizedBox(height: YveSpacing.md),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: YveSpacing.xl),
            child: _TipCard(text: tip),
          ),
          const SizedBox(height: 32),
        ],
      ),
    );
  }

  void _openChat(
    BuildContext context, {
    required StudyMode mode,
    required String draft,
  }) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ChatScreen(initialMode: mode, initialDraft: draft),
      ),
    );
  }

  Future<void> _promptAddSubject(BuildContext context, WidgetRef ref) async {
    final TextEditingController controller = TextEditingController();
    final String? name = await showModalBottomSheet<String>(
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
                controller: controller,
                autofocus: true,
                decoration: const InputDecoration(hintText: 'e.g. Biology 101'),
                onSubmitted: (String v) =>
                    Navigator.of(sheetContext).pop(v.trim()),
              ),
              const SizedBox(height: YveSpacing.md),
              FilledButton(
                onPressed: () =>
                    Navigator.of(sheetContext).pop(controller.text.trim()),
                child: const Text('Create'),
              ),
            ],
          ),
        );
      },
    );
    if (name != null && name.isNotEmpty) {
      try {
        await ref
            .read(subjectsProvider.notifier)
            .addSubject(name: name, emoji: '✨');
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

class _Header extends StatelessWidget {
  const _Header({required this.name, required this.week});
  final String name;
  final List<DailyActivity> week;

  String get _greeting {
    final int hour = DateTime.now().hour;
    if (hour < 12) return 'Good morning';
    if (hour < 18) return 'Good afternoon';
    return 'Good evening';
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(gradient: YveColors.brandGradient),
      padding: const EdgeInsets.fromLTRB(
        YveSpacing.xl,
        YveSpacing.lg,
        YveSpacing.xl,
        24,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            _greeting,
            style: const TextStyle(fontSize: 13, color: YveColors.tintGreen),
          ),
          const SizedBox(height: 4),
          Row(
            children: <Widget>[
              Text(
                name,
                style: const TextStyle(
                  fontSize: 24,
                  fontWeight: FontWeight.w700,
                  color: YveColors.textInverse,
                ),
              ),
              const SizedBox(width: 6),
              const Text('👋', style: TextStyle(fontSize: 22)),
            ],
          ),
          if (week.isNotEmpty) ...<Widget>[
            const SizedBox(height: YveSpacing.md),
            ActivityStrip(week: week),
          ],
        ],
      ),
    );
  }
}

class _RecapCta extends StatelessWidget {
  const _RecapCta({required this.onTap});
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: YveColors.surface,
      borderRadius: YveSpacing.cardRadius,
      child: InkWell(
        borderRadius: YveSpacing.cardRadius,
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.all(YveSpacing.lg),
          decoration: BoxDecoration(
            borderRadius: YveSpacing.cardRadius,
            boxShadow: YveSpacing.cardShadow,
            border: Border.all(color: YveColors.primarySurface, width: 1.5),
            color: YveColors.surface,
          ),
          child: Row(
            children: <Widget>[
              Container(
                width: 42,
                height: 42,
                decoration: const BoxDecoration(
                  gradient: YveColors.brandGradient,
                  shape: BoxShape.circle,
                ),
                alignment: Alignment.center,
                child: const Icon(
                  Icons.auto_awesome,
                  color: YveColors.textInverse,
                  size: 20,
                ),
              ),
              const SizedBox(width: YveSpacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      'How am I doing this week?',
                      style: Theme.of(context).textTheme.titleSmall,
                    ),
                    const SizedBox(height: 2),
                    const Text(
                      'A quick recap from Yve — what stuck, what to revisit.',
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

class _QuickBar extends StatelessWidget {
  const _QuickBar({
    required this.onAssignment,
    required this.onScan,
    required this.onQuiz,
  });

  final VoidCallback onAssignment;
  final VoidCallback onScan;
  final VoidCallback onQuiz;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 44,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: YveSpacing.xl),
        children: <Widget>[
          YvePill(label: 'Solve assignment', filled: true, onTap: onAssignment),
          const SizedBox(width: YveSpacing.sm),
          YvePill(label: 'Scan & ask', onTap: onScan),
          const SizedBox(width: YveSpacing.sm),
          YvePill(label: 'Quiz me', onTap: onQuiz),
        ],
      ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel({required this.text});
  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: YveSpacing.xl),
      child: Text(
        text.toUpperCase(),
        style: const TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w600,
          color: YveColors.textSecondary,
          letterSpacing: 0.5,
        ),
      ),
    );
  }
}

class _SessionCard extends StatelessWidget {
  const _SessionCard({required this.session, required this.onTap});

  final StudySession session;
  final VoidCallback onTap;

  String _relative() {
    final Duration diff = DateTime.now().difference(session.updatedAt);
    if (diff.inMinutes < 60) return '${diff.inMinutes} min ago';
    if (diff.inHours < 24) return '${diff.inHours} hours ago';
    if (diff.inDays == 1) return 'Yesterday';
    return '${diff.inDays} days ago';
  }

  @override
  Widget build(BuildContext context) {
    final TextTheme text = Theme.of(context).textTheme;
    return YveCard(
      onTap: onTap,
      padding: const EdgeInsets.symmetric(
        horizontal: YveSpacing.lg,
        vertical: 14,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: YveColors.primarySurface,
              borderRadius: BorderRadius.circular(12),
            ),
            alignment: Alignment.center,
            child: Text(
              session.subjectEmoji ?? '✦',
              style: const TextStyle(fontSize: 18),
            ),
          ),
          const SizedBox(width: YveSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  session.subjectName ?? session.title,
                  style: text.titleSmall,
                ),
                const SizedBox(height: 2),
                Text(
                  session.preview,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: text.bodySmall,
                ),
                const SizedBox(height: 4),
                Text(
                  _relative(),
                  style: const TextStyle(
                    fontSize: 11,
                    color: YveColors.textTertiary,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _SubjectChipCard extends StatelessWidget {
  const _SubjectChipCard({required this.subject, required this.onTap});

  final Subject subject;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final TextTheme text = Theme.of(context).textTheme;
    return SizedBox(
      width: 132,
      child: YveCard(
        onTap: onTap,
        padding: const EdgeInsets.all(YveSpacing.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: <Widget>[
            Container(
              width: 10,
              height: 10,
              decoration: BoxDecoration(
                color: YveColors.subjectColor(subject.colorSeed),
                shape: BoxShape.circle,
              ),
            ),
            const SizedBox(height: YveSpacing.sm),
            Text(
              subject.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: text.titleSmall,
            ),
            const SizedBox(height: 2),
            Text(
              '${subject.materialCount} materials',
              style: text.labelSmall,
            ),
          ],
        ),
      ),
    );
  }
}

class _AddSubjectCard extends StatelessWidget {
  const _AddSubjectCard({required this.onTap});
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 132,
      child: Material(
        color: YveColors.surface,
        borderRadius: YveSpacing.cardRadius,
        child: InkWell(
          onTap: onTap,
          borderRadius: YveSpacing.cardRadius,
          child: DottedBorder(
            child: const Center(
              child: Padding(
                padding: EdgeInsets.all(YveSpacing.md),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: <Widget>[
                    Icon(Icons.add_rounded, color: YveColors.primary),
                    SizedBox(height: 4),
                    Text(
                      'Add subject',
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: YveColors.primary,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class DottedBorder extends StatelessWidget {
  const DottedBorder({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      painter: _DottedPainter(),
      child: child,
    );
  }
}

class _DottedPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final Paint paint = Paint()
      ..color = const Color(0xFFD1D5DB)
      ..strokeWidth = 1.5
      ..style = PaintingStyle.stroke;
    final RRect rrect = RRect.fromRectAndRadius(
      Offset.zero & size,
      const Radius.circular(YveSpacing.radiusCard),
    );
    final Path path = Path()..addRRect(rrect);
    final ui.PathMetrics metrics = path.computeMetrics();
    for (final ui.PathMetric m in metrics) {
      double distance = 0;
      while (distance < m.length) {
        final ui.Tangent? tangent = m.getTangentForOffset(distance);
        if (tangent != null) {
          canvas.drawCircle(tangent.position, 0.9, paint);
        }
        distance += 5;
      }
    }
  }

  @override
  bool shouldRepaint(_DottedPainter oldDelegate) => false;
}

class _TipCard extends StatelessWidget {
  const _TipCard({required this.text});
  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(YveSpacing.lg),
      decoration: BoxDecoration(
        color: YveColors.primarySurface,
        borderRadius: YveSpacing.cardRadius,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: const <Widget>[
              Icon(Icons.auto_awesome, size: 14, color: YveColors.primaryLight),
              SizedBox(width: 4),
              Text(
                'YVE TIP',
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: YveColors.primaryLight,
                  letterSpacing: 0.5,
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            text,
            style: const TextStyle(
              fontSize: 13,
              color: YveColors.primary,
              height: 1.5,
            ),
          ),
        ],
      ),
    );
  }
}
