import 'package:flutter/material.dart';

import '../theme/yve_colors.dart';
import 'yve_response.dart';

/// Per-concept rollup from the concept_mastery view. Powers the Subject
/// Workspace's "Practice" tab and (eventually) the Home retention queue.
@immutable
class ConceptMastery {
  const ConceptMastery({
    required this.concept,
    required this.observations,
    required this.lastSeenAt,
    required this.confidence,
    this.subjectId,
  });

  final String concept;
  final int observations;
  final DateTime lastSeenAt;
  final ConfidenceSignal confidence;
  final String? subjectId;

  Color get tint {
    switch (confidence) {
      case ConfidenceSignal.grasped:
        return YveColors.tintGreen;
      case ConfidenceSignal.partial:
        return YveColors.tintAmber;
      case ConfidenceSignal.struggling:
        return YveColors.tintRose;
      case ConfidenceSignal.unknown:
        return YveColors.surface2;
    }
  }

  Color get foreground {
    switch (confidence) {
      case ConfidenceSignal.grasped:
        return YveColors.primary;
      case ConfidenceSignal.partial:
        return const Color(0xFFB45309);
      case ConfidenceSignal.struggling:
        return const Color(0xFFBE185D);
      case ConfidenceSignal.unknown:
        return YveColors.textSecondary;
    }
  }

  String get confidenceLabel {
    switch (confidence) {
      case ConfidenceSignal.grasped:
        return 'Got it';
      case ConfidenceSignal.partial:
        return 'Almost';
      case ConfidenceSignal.struggling:
        return 'Review';
      case ConfidenceSignal.unknown:
        return 'Seen';
    }
  }

  IconData get icon {
    switch (confidence) {
      case ConfidenceSignal.grasped:
        return Icons.check_circle_rounded;
      case ConfidenceSignal.partial:
        return Icons.adjust_rounded;
      case ConfidenceSignal.struggling:
        return Icons.refresh_rounded;
      case ConfidenceSignal.unknown:
        return Icons.circle_outlined;
    }
  }

  factory ConceptMastery.fromRow(Map<String, dynamic> row) {
    return ConceptMastery(
      concept: row['concept'] as String,
      observations: (row['n_observations'] as int?) ?? 1,
      lastSeenAt: DateTime.parse(row['last_seen_at'] as String),
      confidence:
          ConfidenceSignal.fromWire(row['current_confidence'] as String?),
      subjectId: row['subject_id'] as String?,
    );
  }
}
