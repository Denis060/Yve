import 'package:flutter/foundation.dart';

import '../utils/safe_parse.dart';
import 'yve_response.dart';

/// A row from the `concept_review_queue` view — a concept Yve thinks the
/// learner should revisit, with a friendly relative-time tag.
@immutable
class ConceptReview {
  const ConceptReview({
    required this.concept,
    required this.observations,
    required this.lastSeenAt,
    required this.nextDueAt,
    required this.overdueSeconds,
    required this.confidence,
    this.subjectId,
    this.subjectName,
    this.subjectEmoji,
  });

  final String concept;
  final int observations;
  final DateTime lastSeenAt;
  final DateTime nextDueAt;
  final double overdueSeconds;
  final ConfidenceSignal confidence;
  final String? subjectId;
  final String? subjectName;
  final String? subjectEmoji;

  bool get isDue => overdueSeconds >= 0;
  bool get isOverdue => overdueSeconds > 24 * 60 * 60;

  /// A calm relative label. We deliberately avoid loud framings like
  /// "OVERDUE" — see Product Vision §2 (non-judgmental).
  String get dueLabel {
    if (!isDue) {
      final Duration until = nextDueAt.difference(DateTime.now());
      if (until.inHours < 24) return 'Later today';
      if (until.inDays == 1) return 'Tomorrow';
      return 'In ${until.inDays} days';
    }
    if (overdueSeconds < 24 * 60 * 60) return 'Today';
    final int days = (overdueSeconds / 86400).floor();
    if (days == 1) return 'Since yesterday';
    return 'Since $days days';
  }

  /// Reads from the `concept_review_queue` view, optionally joined with
  /// `subjects` for the emoji + name.
  factory ConceptReview.fromRow(
    Map<String, dynamic> row, {
    Map<String, Map<String, dynamic>>? subjectsById,
  }) {
    final String? subjectId = row['subject_id'] as String?;
    final Map<String, dynamic>? subject =
        subjectId == null ? null : subjectsById?[subjectId];
    return ConceptReview(
      concept: row['concept'] as String,
      observations: (row['n_observations'] as int?) ?? 1,
      lastSeenAt: parseTimestampOr(
        row['last_seen_at'],
        fallback: DateTime.now(),
        context: 'concept_review.last_seen_at',
      ),
      nextDueAt: parseTimestampOr(
        row['next_due_at'],
        fallback: DateTime.now(),
        context: 'concept_review.next_due_at',
      ),
      overdueSeconds: ((row['overdue_seconds'] as num?) ?? 0).toDouble(),
      confidence:
          ConfidenceSignal.fromWire(row['current_confidence'] as String?),
      subjectId: subjectId,
      subjectName: subject?['name'] as String?,
      subjectEmoji: subject?['emoji'] as String?,
    );
  }
}
