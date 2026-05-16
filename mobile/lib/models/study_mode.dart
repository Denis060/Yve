import 'package:flutter/material.dart';

import '../theme/yve_colors.dart';

/// A Yve study mode. Modes are not separate screens — they're behaviors of
/// the same chat. Changing modes mid-conversation changes the system prompt
/// the server sends to Claude on the next turn, without losing context.
enum StudyMode {
  open,
  learn,
  practice,
  assignment,
  write,
  materials;

  String get wireName => switch (this) {
        StudyMode.open => 'open',
        StudyMode.learn => 'learn',
        StudyMode.practice => 'practice',
        StudyMode.assignment => 'assignment',
        StudyMode.write => 'write',
        StudyMode.materials => 'materials',
      };

  String get label => switch (this) {
        StudyMode.open => 'Ask Yve',
        StudyMode.learn => 'Learn',
        StudyMode.practice => 'Practice',
        StudyMode.assignment => 'Assignment',
        StudyMode.write => 'Write',
        StudyMode.materials => 'Materials',
      };

  String get tagline => switch (this) {
        StudyMode.open => 'Open conversation',
        StudyMode.learn => 'Build understanding, concept by concept',
        StudyMode.practice => 'Drill questions and flashcards',
        StudyMode.assignment => 'Worked solutions you can actually learn from',
        StudyMode.write => 'Polish, structure, keep your voice',
        StudyMode.materials => 'Ask your library — grounded in what you uploaded',
      };

  IconData get icon => switch (this) {
        StudyMode.open => Icons.auto_awesome_rounded,
        StudyMode.learn => Icons.psychology_rounded,
        StudyMode.practice => Icons.track_changes_rounded,
        StudyMode.assignment => Icons.edit_note_rounded,
        StudyMode.write => Icons.auto_fix_high_rounded,
        StudyMode.materials => Icons.folder_special_rounded,
      };

  Color get tint => switch (this) {
        StudyMode.open => YveColors.primarySurface,
        StudyMode.learn => YveColors.tintPurple,
        StudyMode.practice => YveColors.tintGreen,
        StudyMode.assignment => YveColors.tintBlue,
        StudyMode.write => YveColors.tintRose,
        StudyMode.materials => YveColors.tintAmber,
      };

  Color get iconColor => switch (this) {
        StudyMode.open => YveColors.primary,
        StudyMode.learn => const Color(0xFF8B5CF6),
        StudyMode.practice => YveColors.primary,
        StudyMode.assignment => const Color(0xFF3B82F6),
        StudyMode.write => const Color(0xFFEC4899),
        StudyMode.materials => const Color(0xFFF59E0B),
      };

  /// User-facing modes shown in the Study tab and the in-chat switcher. We
  /// hide [open] from those surfaces since it's the implicit default.
  static const List<StudyMode> userFacing = <StudyMode>[
    StudyMode.learn,
    StudyMode.practice,
    StudyMode.assignment,
    StudyMode.write,
    StudyMode.materials,
  ];

  static StudyMode fromWire(String? value) {
    for (final StudyMode m in StudyMode.values) {
      if (m.wireName == value) return m;
    }
    return StudyMode.open;
  }
}
