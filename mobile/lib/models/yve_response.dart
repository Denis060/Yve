import 'package:flutter/foundation.dart';

import 'study_mode.dart';

// Conversion-engine value types. The whole-response wrapper [YveResponse]
// existed before the chat went streaming; the streaming pipeline now uses
// [ChatStreamEvent] instead. These types remain because they're the shape
// of the structured-state side of every turn — used by chat messages,
// session messages restored from Postgres, concept rollups, and the recap.

/// The recommended next-step ladder Yve attaches to each response. This is
/// the conversion engine's user-facing output: chips that subtly route a
/// "help me finish" into "help me learn."
@immutable
class PostSolveOffer {
  const PostSolveOffer({required this.suggestions});

  final List<OfferSuggestion> suggestions;

  static PostSolveOffer generic(StudyMode mode) {
    switch (mode) {
      case StudyMode.assignment:
        return const PostSolveOffer(suggestions: <OfferSuggestion>[
          OfferSuggestion(label: 'Explain the concept',
              kind: OfferKind.explain),
          OfferSuggestion(label: 'Check my work', kind: OfferKind.check),
          OfferSuggestion(label: 'Quiz me on this', kind: OfferKind.quiz),
          OfferSuggestion(label: 'Save to subject', kind: OfferKind.save),
        ]);
      case StudyMode.learn:
        return const PostSolveOffer(suggestions: <OfferSuggestion>[
          OfferSuggestion(
              label: 'Check my understanding', kind: OfferKind.check),
          OfferSuggestion(label: 'Simplify', kind: OfferKind.simplify),
          OfferSuggestion(label: 'Show an example', kind: OfferKind.example),
          OfferSuggestion(label: 'Quiz me', kind: OfferKind.quiz),
        ]);
      case StudyMode.practice:
        return const PostSolveOffer(suggestions: <OfferSuggestion>[
          OfferSuggestion(label: 'Next question', kind: OfferKind.next),
          OfferSuggestion(label: 'Explain why', kind: OfferKind.explain),
          OfferSuggestion(label: 'Harder', kind: OfferKind.harder),
          OfferSuggestion(label: 'Easier', kind: OfferKind.easier),
        ]);
      case StudyMode.write:
        return const PostSolveOffer(suggestions: <OfferSuggestion>[
          OfferSuggestion(label: 'Tighter', kind: OfferKind.tighten),
          OfferSuggestion(label: 'More formal', kind: OfferKind.formal),
          OfferSuggestion(label: 'Add examples', kind: OfferKind.example),
          OfferSuggestion(label: 'Different opening',
              kind: OfferKind.rephrase),
        ]);
      case StudyMode.materials:
        return const PostSolveOffer(suggestions: <OfferSuggestion>[
          OfferSuggestion(label: 'Summarize', kind: OfferKind.summarize),
          OfferSuggestion(label: 'Quiz me on this', kind: OfferKind.quiz),
          OfferSuggestion(label: 'Show me where', kind: OfferKind.cite),
        ]);
      case StudyMode.open:
        return const PostSolveOffer(suggestions: <OfferSuggestion>[
          OfferSuggestion(label: 'Explain more', kind: OfferKind.explain),
          OfferSuggestion(label: 'Simplify', kind: OfferKind.simplify),
          OfferSuggestion(label: 'Quiz me on this', kind: OfferKind.quiz),
          OfferSuggestion(label: 'Save note', kind: OfferKind.save),
        ]);
    }
  }

  factory PostSolveOffer.fromJson(Map<String, dynamic> json) {
    final List<dynamic> raw =
        (json['suggestions'] as List<dynamic>?) ?? const <dynamic>[];
    final List<OfferSuggestion> suggestions = raw
        .whereType<Map<String, dynamic>>()
        .map(OfferSuggestion.fromJson)
        .toList();
    return PostSolveOffer(suggestions: suggestions);
  }
}

/// A single chip in the post-solve ladder.
@immutable
class OfferSuggestion {
  const OfferSuggestion({
    required this.label,
    required this.kind,
    this.payload,
  });

  final String label;
  final OfferKind kind;

  /// Optional seed for the next user turn. When null, the [label] itself is
  /// sent as the next user message.
  final String? payload;

  String get effectivePrompt => payload ?? label;

  factory OfferSuggestion.fromJson(Map<String, dynamic> json) {
    return OfferSuggestion(
      label: (json['label'] as String?)?.trim() ?? 'Continue',
      kind: OfferKindX.fromWire(json['kind'] as String?),
      payload: json['payload'] as String?,
    );
  }
}

/// What kind of action the chip represents. The client uses this to decide
/// whether to send the chip as a new user turn or to open a local flow
/// (e.g. [OfferKind.save] launches the save-to-subject sheet).
enum OfferKind {
  explain,
  simplify,
  example,
  check,
  quiz,
  flashcards,
  next,
  harder,
  easier,
  related,
  practice,
  summarize,
  cite,
  tighten,
  formal,
  rephrase,
  save,
  unknown,
}

extension OfferKindX on OfferKind {
  String get wireName => name;

  /// Local action chips don't send a new user turn — they trigger a local
  /// flow instead (save sheet, etc.).
  bool get isLocal => this == OfferKind.save;

  static OfferKind fromWire(String? value) {
    if (value == null) return OfferKind.unknown;
    for (final OfferKind k in OfferKind.values) {
      if (k.name == value) return k;
    }
    return OfferKind.unknown;
  }
}

/// Did the learner appear to grasp the concept, struggle, or stay neutral?
/// Sourced from the user's phrasing on the *next* turn ("got it" vs
/// "wait, what?"). Eventually feeds spaced-review priority.
enum ConfidenceSignal {
  grasped,
  partial,
  struggling,
  unknown;

  static ConfidenceSignal fromWire(String? value) {
    for (final ConfidenceSignal c in ConfidenceSignal.values) {
      if (c.name == value) return c;
    }
    return ConfidenceSignal.unknown;
  }
}
