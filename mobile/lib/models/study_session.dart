import 'package:flutter/foundation.dart';

import 'study_mode.dart';

/// A persistent Yve Chat session (chat_sessions table).
@immutable
class StudySession {
  const StudySession({
    required this.id,
    required this.title,
    required this.preview,
    required this.updatedAt,
    required this.messageCount,
    required this.mode,
    this.subjectId,
    this.subjectName,
    this.subjectEmoji,
  });

  final String id;
  final String title;
  final String preview;
  final DateTime updatedAt;
  final int messageCount;
  final StudyMode mode;
  final String? subjectId;
  final String? subjectName;
  final String? subjectEmoji;

  /// Reads from chat_sessions optionally joined with subjects on subject_id.
  factory StudySession.fromRow(Map<String, dynamic> row) {
    final Map<String, dynamic>? subject =
        row['subjects'] as Map<String, dynamic>?;
    return StudySession(
      id: row['id'] as String,
      title: (row['title'] as String?) ?? 'New session',
      preview: (row['last_message_preview'] as String?) ?? '',
      updatedAt: DateTime.parse(row['updated_at'] as String),
      messageCount: (row['message_count'] as int?) ?? 0,
      mode: StudyMode.fromWire(row['mode'] as String?),
      subjectId: row['subject_id'] as String?,
      subjectName: subject?['name'] as String?,
      subjectEmoji: subject?['emoji'] as String?,
    );
  }
}
