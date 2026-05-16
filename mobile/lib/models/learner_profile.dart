import 'package:flutter/foundation.dart';

enum ReadingLevel { basic, standard, advanced }

enum ExplanationDepth { brief, standard, thorough }

enum TonePreference { warm, direct, playful }

extension ReadingLevelX on ReadingLevel {
  String get wire => name;
  String get label => switch (this) {
        ReadingLevel.basic => 'Plain language',
        ReadingLevel.standard => 'Standard',
        ReadingLevel.advanced => 'Technical',
      };
  String get tagline => switch (this) {
        ReadingLevel.basic =>
          'Short sentences, jargon defined inline.',
        ReadingLevel.standard =>
          'Yve\'s default register.',
        ReadingLevel.advanced =>
          'Dense formulations, no over-explanation.',
      };

  static ReadingLevel fromWire(String? value) {
    for (final ReadingLevel v in ReadingLevel.values) {
      if (v.name == value) return v;
    }
    return ReadingLevel.standard;
  }
}

extension ExplanationDepthX on ExplanationDepth {
  String get wire => name;
  String get label => switch (this) {
        ExplanationDepth.brief => 'Brief',
        ExplanationDepth.standard => 'Standard',
        ExplanationDepth.thorough => 'Thorough',
      };
  String get tagline => switch (this) {
        ExplanationDepth.brief =>
          'Answer first, expand only on request.',
        ExplanationDepth.standard =>
          'Reasoning + answer, balanced.',
        ExplanationDepth.thorough =>
          'Walk through every step, ground in examples.',
      };

  static ExplanationDepth fromWire(String? value) {
    for (final ExplanationDepth v in ExplanationDepth.values) {
      if (v.name == value) return v;
    }
    return ExplanationDepth.standard;
  }
}

extension TonePreferenceX on TonePreference {
  String get wire => name;
  String get label => switch (this) {
        TonePreference.warm => 'Warm',
        TonePreference.direct => 'Direct',
        TonePreference.playful => 'Playful',
      };
  String get tagline => switch (this) {
        TonePreference.warm =>
          'Supportive and calm — Yve\'s default.',
        TonePreference.direct =>
          'No softeners; plain statements.',
        TonePreference.playful =>
          'Light humor welcome when it fits.',
      };

  static TonePreference fromWire(String? value) {
    for (final TonePreference v in TonePreference.values) {
      if (v.name == value) return v;
    }
    return TonePreference.warm;
  }
}

@immutable
class LearnerProfile {
  const LearnerProfile({
    required this.readingLevel,
    required this.explanationDepth,
    required this.tone,
    this.readAloud = false,
    this.handsFree = false,
    this.notificationsEnabled = false,
    this.observedPatterns,
    this.voiceNotes,
    this.autoObservedPatterns,
    this.autoVoiceNotes,
    this.lastInferredAt,
  });

  final ReadingLevel readingLevel;
  final ExplanationDepth explanationDepth;
  final TonePreference tone;

  /// When true, Yve speaks responses aloud via the device TTS engine AND
  /// adapts her style for the ear (server-side addendum).
  final bool readAloud;

  /// When true (and [readAloud] is also true), the chat auto-listens after
  /// Yve finishes speaking and auto-sends when the learner stops talking.
  /// Meaningless without TTS; the UI gates the toggle on [readAloud].
  final bool handsFree;

  /// When true, the app schedules a local daily review nudge at 7pm local
  /// time on days when the review queue isn't empty. No server-side push
  /// involved in this slice — the substrate is on-device only.
  final bool notificationsEnabled;

  // User-set values from the Profile tab. Override the auto-inferred fields
  // when present.
  final String? observedPatterns;
  final String? voiceNotes;

  // Auto-inferred values from `infer-profile`. Surfaced read-only on the
  // Profile tab under "What Yve has noticed".
  final String? autoObservedPatterns;
  final String? autoVoiceNotes;
  final DateTime? lastInferredAt;

  static const LearnerProfile defaults = LearnerProfile(
    readingLevel: ReadingLevel.standard,
    explanationDepth: ExplanationDepth.standard,
    tone: TonePreference.warm,
  );

  bool get isDefault =>
      readingLevel == ReadingLevel.standard &&
      explanationDepth == ExplanationDepth.standard &&
      tone == TonePreference.warm &&
      !readAloud &&
      !handsFree &&
      !notificationsEnabled &&
      (observedPatterns == null || observedPatterns!.trim().isEmpty) &&
      (voiceNotes == null || voiceNotes!.trim().isEmpty);

  /// Hands-free is only active when *both* preferences are on. The
  /// `handsFree` field can persist as true even if `readAloud` is later
  /// turned off — but the loop won't run until TTS is enabled again.
  bool get handsFreeActive => readAloud && handsFree;

  /// Resolved value that Yve will actually use — user-set wins over
  /// auto-inferred. Mirrors the server-side `pickFirst` in yve_modes.ts.
  String? get effectivePatterns =>
      _firstNonEmpty(observedPatterns, autoObservedPatterns);
  String? get effectiveVoiceNotes =>
      _firstNonEmpty(voiceNotes, autoVoiceNotes);

  LearnerProfile copyWith({
    ReadingLevel? readingLevel,
    ExplanationDepth? explanationDepth,
    TonePreference? tone,
    bool? readAloud,
    bool? handsFree,
    bool? notificationsEnabled,
    String? observedPatterns,
    String? voiceNotes,
    String? autoObservedPatterns,
    String? autoVoiceNotes,
    DateTime? lastInferredAt,
  }) {
    return LearnerProfile(
      readingLevel: readingLevel ?? this.readingLevel,
      explanationDepth: explanationDepth ?? this.explanationDepth,
      tone: tone ?? this.tone,
      readAloud: readAloud ?? this.readAloud,
      handsFree: handsFree ?? this.handsFree,
      notificationsEnabled:
          notificationsEnabled ?? this.notificationsEnabled,
      observedPatterns: observedPatterns ?? this.observedPatterns,
      voiceNotes: voiceNotes ?? this.voiceNotes,
      autoObservedPatterns:
          autoObservedPatterns ?? this.autoObservedPatterns,
      autoVoiceNotes: autoVoiceNotes ?? this.autoVoiceNotes,
      lastInferredAt: lastInferredAt ?? this.lastInferredAt,
    );
  }

  factory LearnerProfile.fromRow(Map<String, dynamic> row) {
    final String? inferredAt = row['last_inferred_at'] as String?;
    return LearnerProfile(
      readingLevel: ReadingLevelX.fromWire(row['reading_level'] as String?),
      explanationDepth:
          ExplanationDepthX.fromWire(row['explanation_depth'] as String?),
      tone: TonePreferenceX.fromWire(row['tone_preference'] as String?),
      readAloud: (row['read_aloud'] as bool?) ?? false,
      handsFree: (row['hands_free'] as bool?) ?? false,
      notificationsEnabled:
          (row['notifications_enabled'] as bool?) ?? false,
      observedPatterns: row['observed_patterns'] as String?,
      voiceNotes: row['voice_notes'] as String?,
      autoObservedPatterns: row['auto_observed_patterns'] as String?,
      autoVoiceNotes: row['auto_voice_notes'] as String?,
      lastInferredAt: inferredAt == null ? null : DateTime.parse(inferredAt),
    );
  }

  Map<String, dynamic> toUpsertRow(String userId) {
    // Note: we only write the user-controlled fields here. The auto_* values
    // and last_inferred_at are server-owned and never updated client-side.
    return <String, dynamic>{
      'user_id': userId,
      'reading_level': readingLevel.wire,
      'explanation_depth': explanationDepth.wire,
      'tone_preference': tone.wire,
      'read_aloud': readAloud,
      'hands_free': handsFree,
      'notifications_enabled': notificationsEnabled,
      'observed_patterns': observedPatterns,
      'voice_notes': voiceNotes,
      'updated_at': DateTime.now().toUtc().toIso8601String(),
    };
  }
}

String? _firstNonEmpty(String? a, String? b) {
  if (a != null && a.trim().isNotEmpty) return a.trim();
  if (b != null && b.trim().isNotEmpty) return b.trim();
  return null;
}
