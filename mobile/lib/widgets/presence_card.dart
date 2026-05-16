import 'package:flutter/material.dart';

import '../models/daily_activity.dart';
import '../models/study_session.dart';
import '../theme/yve_colors.dart';
import '../theme/yve_spacing.dart';

/// A single contextual line from Yve — the relational layer on Home.
///
/// Templates are selected from the local context (time of day, last session
/// age, due reviews count, active-day count). No LLM call: this needs to be
/// instant on every Home render, and templated variety is better than rote
/// LLM-generated lines spaced 30 minutes apart.
@immutable
class PresenceLine {
  const PresenceLine({required this.message, this.cta, this.onCta});

  final String message;
  final String? cta;
  final VoidCallback? onCta;
}

/// Resolves the most relevant presence line for the current context.
PresenceLine? resolvePresence({
  required List<DailyActivity> week,
  required List<StudySession> recent,
  required int dueReviewCount,
  VoidCallback? onResumeLast,
  VoidCallback? onReviewDue,
}) {
  final DateTime now = DateTime.now();
  final int hour = now.hour;
  final int daysActive = week.where((DailyActivity d) => d.messageCount > 0).length;

  StudySession? lastSession;
  if (recent.isNotEmpty) lastSession = recent.first;

  final Duration? sinceLast = lastSession != null
      ? now.difference(lastSession.updatedAt)
      : null;

  // 1. Strong overdue review — prioritize the practical pull.
  if (dueReviewCount >= 3) {
    return PresenceLine(
      message:
          'A few things are sitting in your revisit list. Two minutes can clear them.',
      cta: 'Start with one',
      onCta: onReviewDue,
    );
  }

  // 2. Just came back after a long absence.
  if (sinceLast != null && sinceLast.inDays >= 3) {
    return PresenceLine(
      message:
          'Welcome back. Want a soft restart, or pick up where you were?',
      cta: 'Pick up',
      onCta: onResumeLast,
    );
  }

  // 3. First open of the morning.
  if (hour >= 5 && hour < 11) {
    if (daysActive >= 4) {
      return const PresenceLine(
        message: 'Morning. Steady week — what\'s on the plate today?',
      );
    }
    return const PresenceLine(
      message: 'Morning. What are we working on?',
    );
  }

  // 4. Late night — calm acknowledgment.
  if (hour >= 22 || hour < 5) {
    return const PresenceLine(
      message: 'Studying late. I\'ll keep it short and useful.',
    );
  }

  // 5. Mid-day patterns.
  if (sinceLast != null && sinceLast.inMinutes < 30 && lastSession != null) {
    return PresenceLine(
      message: 'Good momentum. Keep going on ${lastSession.title}?',
      cta: 'Resume',
      onCta: onResumeLast,
    );
  }

  // 6. Solid week.
  if (daysActive >= 5) {
    return const PresenceLine(
      message: 'Nice rhythm this week. Anything you want to dig into?',
    );
  }

  // 7. New learner, no activity yet.
  if (daysActive == 0 && recent.isEmpty) {
    return const PresenceLine(
      message:
          'Whenever you\'re ready — scan a worksheet, or pick a study mode below.',
    );
  }

  // 8. Default afternoon/evening.
  if (hour >= 18) {
    return const PresenceLine(
      message: 'Evening. What\'s on your mind?',
    );
  }
  return const PresenceLine(
    message: 'Hey. What would you like to work on?',
  );
}

class PresenceCard extends StatelessWidget {
  const PresenceCard({super.key, required this.line});

  final PresenceLine line;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(YveSpacing.lg),
      decoration: BoxDecoration(
        color: YveColors.primarySurface,
        borderRadius: YveSpacing.cardRadius,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Container(
            width: 32,
            height: 32,
            decoration: const BoxDecoration(
              gradient: YveColors.brandGradient,
              shape: BoxShape.circle,
            ),
            alignment: Alignment.center,
            child: const Text(
              '✦',
              style: TextStyle(
                color: YveColors.textInverse,
                fontSize: 16,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          const SizedBox(width: YveSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  line.message,
                  style: const TextStyle(
                    fontSize: 14,
                    color: YveColors.primary,
                    height: 1.5,
                  ),
                ),
                if (line.cta != null && line.onCta != null) ...<Widget>[
                  const SizedBox(height: YveSpacing.sm),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton(
                      onPressed: line.onCta,
                      style: TextButton.styleFrom(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 6,
                        ),
                        backgroundColor: YveColors.primary,
                        foregroundColor: YveColors.textInverse,
                        textStyle: const TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                        ),
                        shape: const StadiumBorder(),
                      ),
                      child: Text(line.cta!),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}
