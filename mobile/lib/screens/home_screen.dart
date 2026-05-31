import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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
import '../widgets/anonymous_continuation_panel.dart';
import '../widgets/subject_limit_sheet.dart';
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
    // valueOrNull rather than .value — the latter rethrows on
    // AsyncError state, so any network blip in any of these providers
    // crashes the build with an unhandled exception (captured by
    // Sentry as fatal). Same fix pattern across HomeScreen +
    // AppShell._reschedule (2026-05-19).
    final List<Subject> subjects =
        ref.watch(subjectsProvider).valueOrNull ?? const <Subject>[];
    final List<StudySession> recent =
        ref.watch(recentSessionsProvider).valueOrNull ?? const <StudySession>[];
    final List<ConceptReview> reviewQueue =
        ref.watch(reviewQueueProvider).valueOrNull ?? const <ConceptReview>[];
    final List<DailyActivity> week =
        ref.watch(weekActivityProvider).valueOrNull ?? const <DailyActivity>[];
    final Account? account = ref.watch(accountProvider).valueOrNull;
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

    // Up next merges what used to be three sections (Presence card,
    // Revisit, Continue) into one prioritized list. Same widgets, same
    // navigation — just one "what to do next" door instead of three.
    // Cap at 5 combined slots so the section stays scannable.
    final List<_UpNextItem> upNext = <_UpNextItem>[];
    int remaining = 5;
    if (presence != null && remaining > 0) {
      upNext.add(_UpNextItem.presence(presence));
      remaining--;
    }
    final int reviewSlots = remaining.clamp(0, 3);
    for (final ConceptReview r in reviewQueue.take(reviewSlots)) {
      upNext.add(_UpNextItem.review(r));
      remaining--;
    }
    final int recentSlots = remaining.clamp(0, 2);
    for (final StudySession s in recent.take(recentSlots)) {
      upNext.add(_UpNextItem.recent(s));
      remaining--;
    }

    return SafeArea(
      bottom: false,
      child: ListView(
        padding: EdgeInsets.zero,
        children: <Widget>[
          _Header(name: greetingName, week: week, tip: tip),
          const SizedBox(height: YveSpacing.lg),
          _QuickBar(
            // Assignment lands in the redesigned empty state — no draft,
            // so the snap-a-photo CTA can do the talking.
            onAssignment: () => _openChat(
              context,
              mode: StudyMode.assignment,
              draft: '',
            ),
            onScan: () => _openChat(
              context,
              mode: StudyMode.open,
              draft: 'I have a question from a photo — let me describe it: ',
            ),
            onPolish: () => _openChat(
              context,
              mode: StudyMode.write,
              draft: '',
            ),
            onQuiz: () => _openChat(
              context,
              mode: StudyMode.practice,
              draft: 'Quiz me on ',
            ),
          ),
          if (upNext.isNotEmpty) ...<Widget>[
            const SizedBox(height: YveSpacing.xxl),
            const _SectionLabel(text: 'Up next'),
            const SizedBox(height: YveSpacing.md),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: YveSpacing.xl),
              child: Column(
                children: <Widget>[
                  for (int i = 0; i < upNext.length; i++) ...<Widget>[
                    _renderUpNext(context, ref, upNext[i]),
                    if (i < upNext.length - 1)
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
          const SizedBox(height: 32),
        ],
      ),
    );
  }

  Widget _renderUpNext(
    BuildContext context,
    WidgetRef ref,
    _UpNextItem item,
  ) {
    switch (item.kind) {
      case _UpNextKind.presence:
        return PresenceCard(line: item.presence!);
      case _UpNextKind.review:
        final ConceptReview r = item.review!;
        return ReviewRow(
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
        );
      case _UpNextKind.recent:
        final StudySession s = item.session!;
        return _SessionCard(
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
          onLongPress: () => _confirmDeleteSession(context, ref, s),
        );
    }
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
        final AppError err = AppError.from(e, actionContext: 'create_subject');
        if (err.code == 'anonymous_subject_limit') {
          await showAnonymousContinuation(context);
        } else if (err.code == 'subject_limit') {
          await showSubjectLimitSheet(context);
        } else {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(err.userMessage)),
          );
        }
      }
    }
  }

  /// Long-press on a recent-session card → confirm + delete. We delete
  /// straight from the session list (no separate edit screen) — that
  /// matches every chat app the user has ever used.
  Future<void> _confirmDeleteSession(
    BuildContext context,
    WidgetRef ref,
    StudySession session,
  ) async {
    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        title: const Text('Delete this chat?'),
        content: Text(
          '"${session.title}" and all its messages will be removed. '
          'This can\'t be undone.',
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
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) return;
    try {
      HapticFeedback.heavyImpact();
      await ref
          .read(recentSessionsProvider.notifier)
          .deleteSession(session.id);
      // Subjects display a session count — refresh so the badge moves.
      ref.invalidate(subjectsProvider);
    } catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(
            AppError.from(e, actionContext: 'delete_session').userMessage)),
      );
    }
  }
}

class _Header extends StatelessWidget {
  const _Header({
    required this.name,
    required this.week,
    required this.tip,
  });
  final String name;
  final List<DailyActivity> week;
  final String tip;

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
          const SizedBox(height: YveSpacing.md),
          // Tip moved here from the bottom of the screen — under the
          // activity strip it actually gets read instead of being
          // scrolled past. Muted color so it doesn't compete with the
          // name and greeting.
          Text(
            tip,
            style: TextStyle(
              fontSize: 12,
              color: YveColors.tintGreen.withValues(alpha: 0.85),
              height: 1.4,
            ),
          ),
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
    required this.onPolish,
    required this.onQuiz,
  });

  final VoidCallback onAssignment;
  final VoidCallback onScan;
  final VoidCallback onPolish;
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
          YvePill(label: 'Polish writing', onTap: onPolish),
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
  const _SessionCard({
    required this.session,
    required this.onTap,
    this.onLongPress,
  });

  final StudySession session;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;

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
      onLongPress: onLongPress,
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

/// A single row in the unified "Up next" list. Three flavors:
/// - [presence] — wraps a [PresenceLine] (resume / review-due hint)
/// - [review] — a [ConceptReview] from the spaced-repetition queue
/// - [recent] — a [StudySession] the user worked on recently
enum _UpNextKind { presence, review, recent }

class _UpNextItem {
  const _UpNextItem._(this.kind, this.presence, this.review, this.session);
  factory _UpNextItem.presence(PresenceLine? p) =>
      _UpNextItem._(_UpNextKind.presence, p, null, null);
  factory _UpNextItem.review(ConceptReview r) =>
      _UpNextItem._(_UpNextKind.review, null, r, null);
  factory _UpNextItem.recent(StudySession s) =>
      _UpNextItem._(_UpNextKind.recent, null, null, s);

  final _UpNextKind kind;
  final PresenceLine? presence;
  final ConceptReview? review;
  final StudySession? session;
}
