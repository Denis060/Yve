import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../theme/yve_colors.dart';
import 'study_mode.dart';

enum DocumentType {
  worksheet,
  textbook,
  slide,
  handwritten,
  equation,
  article,
  screenshot,
  photo,
  other;

  static DocumentType fromWire(String? value) {
    for (final DocumentType t in DocumentType.values) {
      if (t.name == value) return t;
    }
    return DocumentType.other;
  }

  /// Friendly label rendered in the result sheet.
  String get label {
    switch (this) {
      case DocumentType.worksheet:
        return 'Worksheet';
      case DocumentType.textbook:
        return 'Textbook page';
      case DocumentType.slide:
        return 'Lecture slide';
      case DocumentType.handwritten:
        return 'Handwritten notes';
      case DocumentType.equation:
        return 'Equation';
      case DocumentType.article:
        return 'Article';
      case DocumentType.screenshot:
        return 'Screenshot';
      case DocumentType.photo:
        return 'Photo';
      case DocumentType.other:
        return 'Document';
    }
  }

  IconData get icon {
    switch (this) {
      case DocumentType.worksheet:
      case DocumentType.equation:
        return Icons.assignment_rounded;
      case DocumentType.textbook:
      case DocumentType.article:
        return Icons.menu_book_rounded;
      case DocumentType.slide:
        return Icons.slideshow_rounded;
      case DocumentType.handwritten:
        return Icons.draw_rounded;
      case DocumentType.screenshot:
        return Icons.crop_original_rounded;
      case DocumentType.photo:
      case DocumentType.other:
        return Icons.image_rounded;
    }
  }

  Color get tint {
    switch (this) {
      case DocumentType.worksheet:
      case DocumentType.equation:
        return YveColors.tintBlue;
      case DocumentType.textbook:
      case DocumentType.article:
        return YveColors.tintAmber;
      case DocumentType.slide:
        return YveColors.tintPurple;
      case DocumentType.handwritten:
        return YveColors.tintRose;
      default:
        return YveColors.tintGreen;
    }
  }

  Color get accent {
    switch (this) {
      case DocumentType.worksheet:
      case DocumentType.equation:
        return const Color(0xFF3B82F6);
      case DocumentType.textbook:
      case DocumentType.article:
        return const Color(0xFFF59E0B);
      case DocumentType.slide:
        return const Color(0xFF8B5CF6);
      case DocumentType.handwritten:
        return const Color(0xFFEC4899);
      default:
        return YveColors.primary;
    }
  }
}

enum ScanActionKind {
  solve,
  explain,
  summarize,
  quiz,
  flashcards,
  transcribe,
  save,
  other;

  static ScanActionKind fromWire(String? value) {
    for (final ScanActionKind k in ScanActionKind.values) {
      if (k.name == value) return k;
    }
    return ScanActionKind.other;
  }

  IconData get icon {
    switch (this) {
      case ScanActionKind.solve:
        return Icons.bolt_rounded;
      case ScanActionKind.explain:
        return Icons.psychology_rounded;
      case ScanActionKind.summarize:
        return Icons.summarize_rounded;
      case ScanActionKind.quiz:
        return Icons.track_changes_rounded;
      case ScanActionKind.flashcards:
        return Icons.style_rounded;
      case ScanActionKind.transcribe:
        return Icons.notes_rounded;
      case ScanActionKind.save:
        return Icons.bookmark_add_rounded;
      case ScanActionKind.other:
        return Icons.auto_awesome_rounded;
    }
  }
}

@immutable
class ScanAction {
  const ScanAction({
    required this.label,
    required this.kind,
    required this.mode,
    required this.prompt,
  });

  final String label;
  final ScanActionKind kind;
  final StudyMode mode;
  final String prompt;

  factory ScanAction.fromJson(Map<String, dynamic> json) {
    return ScanAction(
      label: (json['label'] as String?)?.trim() ?? 'Continue',
      kind: ScanActionKind.fromWire(json['kind'] as String?),
      mode: StudyMode.fromWire(json['mode'] as String?),
      prompt: (json['prompt'] as String?)?.trim() ?? '',
    );
  }
}

@immutable
class ScanResult {
  const ScanResult({
    required this.sessionId,
    required this.documentType,
    required this.oneLineSummary,
    required this.extractedText,
    required this.conceptTags,
    required this.actions,
    this.materialId,
    this.saveToSubjectSuggestion,
  });

  final String sessionId;
  final String? materialId;
  final DocumentType documentType;
  final String oneLineSummary;
  final String extractedText;
  final List<String> conceptTags;
  final List<ScanAction> actions;
  final String? saveToSubjectSuggestion;

  factory ScanResult.fromJson(Map<String, dynamic> json) {
    final List<dynamic> tagsRaw =
        (json['concept_tags'] as List<dynamic>?) ?? const <dynamic>[];
    final List<dynamic> actionsRaw =
        (json['suggested_actions'] as List<dynamic>?) ?? const <dynamic>[];
    return ScanResult(
      sessionId: json['session_id'] as String,
      materialId: json['material_id'] as String?,
      documentType: DocumentType.fromWire(json['document_type'] as String?),
      oneLineSummary: (json['one_line_summary'] as String?)?.trim() ??
          'I see your document.',
      extractedText: (json['extracted_text'] as String?)?.trim() ?? '',
      conceptTags: tagsRaw.map((dynamic t) => t.toString()).toList(),
      actions: actionsRaw
          .whereType<Map<String, dynamic>>()
          .map(ScanAction.fromJson)
          .toList(),
      saveToSubjectSuggestion: json['save_to_subject'] as String?,
    );
  }
}
