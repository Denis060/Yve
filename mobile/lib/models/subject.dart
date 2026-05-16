import 'package:flutter/foundation.dart';

/// A persistent learning workspace. Materials, chat sessions, and concept
/// observations all hang off a subject (see Product Vision §6.4 and the
/// Subject Memory schema in migration 0004).
@immutable
class Subject {
  const Subject({
    required this.id,
    required this.name,
    required this.emoji,
    required this.colorSeed,
    this.subtitle,
    this.materialCount = 0,
    this.sessionCount = 0,
    this.conceptCount = 0,
  });

  final String id;
  final String name;
  final String emoji;
  final int colorSeed;
  final String? subtitle;
  final int materialCount;
  final int sessionCount;
  final int conceptCount;

  /// Reads from the `subjects_with_counts` view.
  factory Subject.fromRow(Map<String, dynamic> row) {
    return Subject(
      id: row['id'] as String,
      name: row['name'] as String,
      emoji: (row['emoji'] as String?) ?? '✨',
      colorSeed: (row['color_seed'] as int?) ?? 0,
      subtitle: row['subtitle'] as String?,
      materialCount: (row['material_count'] as int?) ?? 0,
      sessionCount: (row['session_count'] as int?) ?? 0,
      conceptCount: (row['concept_count'] as int?) ?? 0,
    );
  }

  Subject copyWith({
    String? name,
    String? emoji,
    int? colorSeed,
    String? subtitle,
    int? materialCount,
    int? sessionCount,
    int? conceptCount,
  }) {
    return Subject(
      id: id,
      name: name ?? this.name,
      emoji: emoji ?? this.emoji,
      colorSeed: colorSeed ?? this.colorSeed,
      subtitle: subtitle ?? this.subtitle,
      materialCount: materialCount ?? this.materialCount,
      sessionCount: sessionCount ?? this.sessionCount,
      conceptCount: conceptCount ?? this.conceptCount,
    );
  }
}
