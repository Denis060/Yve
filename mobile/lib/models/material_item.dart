import 'package:flutter/foundation.dart';

enum MaterialKind { pdf, image, note, url, doc }

enum MaterialStatus { queued, processing, ready, failed }

extension MaterialKindX on MaterialKind {
  String get wireName => name;

  static MaterialKind fromWire(String? value) {
    for (final MaterialKind k in MaterialKind.values) {
      if (k.name == value) return k;
    }
    return MaterialKind.note;
  }
}

extension MaterialStatusX on MaterialStatus {
  static MaterialStatus fromWire(String? value) {
    for (final MaterialStatus s in MaterialStatus.values) {
      if (s.name == value) return s;
    }
    return MaterialStatus.queued;
  }
}

@immutable
class MaterialItem {
  const MaterialItem({
    required this.id,
    required this.subjectId,
    required this.kind,
    required this.name,
    required this.addedAt,
    required this.status,
    this.sourceUri,
    this.error,
  });

  final String id;
  final String subjectId;
  final MaterialKind kind;
  final String name;
  final DateTime addedAt;
  final MaterialStatus status;
  final String? sourceUri;
  final String? error;

  String get statusLabel {
    switch (status) {
      case MaterialStatus.queued:
        return 'Queued';
      case MaterialStatus.processing:
        return 'Yve is reading…';
      case MaterialStatus.ready:
        return 'Ready';
      case MaterialStatus.failed:
        return 'Failed';
    }
  }

  factory MaterialItem.fromRow(Map<String, dynamic> row) {
    return MaterialItem(
      id: row['id'] as String,
      subjectId: row['subject_id'] as String,
      kind: MaterialKindX.fromWire(row['kind'] as String?),
      name: (row['name'] as String?) ?? 'Untitled',
      addedAt: DateTime.parse(row['created_at'] as String),
      status: MaterialStatusX.fromWire(row['status'] as String?),
      sourceUri: row['source_uri'] as String?,
      error: row['error'] as String?,
    );
  }
}
