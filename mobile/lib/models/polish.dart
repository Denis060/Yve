import 'package:flutter/foundation.dart';

/// One concrete edit Yve made — what was there, what she changed it to,
/// and why. Drives the "What changed and why" section of the polish UI.
@immutable
class PolishChange {
  const PolishChange({
    required this.original,
    required this.revision,
    required this.reason,
  });

  final String original;
  final String revision;
  final String reason;

  factory PolishChange.fromJson(Map<String, dynamic> json) {
    return PolishChange(
      original: (json['original'] as String?)?.trim() ?? '',
      revision: (json['revision'] as String?)?.trim() ?? '',
      reason: (json['reason'] as String?)?.trim() ?? '',
    );
  }
}

/// Structured output of Write mode's `polish_text` tool. The Polish bubble
/// renders all sections, but the primary Copy button copies *only*
/// [polishedText] — no headings, no analysis, no markdown separators.
@immutable
class Polish {
  const Polish({
    required this.polishedText,
    this.changes = const <PolishChange>[],
    this.preservedPhrases = const <String>[],
    this.flags = const <String>[],
    this.followUpSuggestions = const <String>[],
  });

  final String polishedText;
  final List<PolishChange> changes;
  final List<String> preservedPhrases;
  final List<String> flags;
  final List<String> followUpSuggestions;

  bool get isEmpty => polishedText.isEmpty;

  factory Polish.fromJson(Map<String, dynamic> json) {
    final List<dynamic> changesRaw =
        (json['change_summary'] as List<dynamic>?) ?? const <dynamic>[];
    final List<dynamic> preservedRaw =
        (json['preserved_phrases'] as List<dynamic>?) ?? const <dynamic>[];
    final List<dynamic> flagsRaw =
        (json['flags'] as List<dynamic>?) ?? const <dynamic>[];
    final List<dynamic> followUpsRaw =
        (json['follow_up_suggestions'] as List<dynamic>?) ?? const <dynamic>[];
    return Polish(
      polishedText: (json['polished_text'] as String?)?.trim() ?? '',
      changes: changesRaw
          .whereType<Map<String, dynamic>>()
          .map(PolishChange.fromJson)
          .toList(),
      preservedPhrases:
          preservedRaw.map((dynamic e) => e.toString()).toList(),
      flags: flagsRaw.map((dynamic e) => e.toString()).toList(),
      followUpSuggestions:
          followUpsRaw.map((dynamic e) => e.toString()).toList(),
    );
  }

  /// Plain-text rendering of the *full analysis* — used by the secondary
  /// "Copy full analysis" button. Stays markdown-light on purpose so it
  /// reads cleanly when pasted into any editor.
  String toFullAnalysisText() {
    final StringBuffer b = StringBuffer();
    b.writeln('POLISHED DRAFT');
    b.writeln('');
    b.writeln(polishedText);
    if (changes.isNotEmpty) {
      b.writeln('');
      b.writeln('');
      b.writeln('WHAT CHANGED AND WHY');
      b.writeln('');
      for (final PolishChange c in changes) {
        b.writeln('• "${c.original}" → "${c.revision}"');
        b.writeln('  Why: ${c.reason}');
        b.writeln('');
      }
    }
    if (preservedPhrases.isNotEmpty) {
      b.writeln('');
      b.writeln('PHRASES KEPT IN YOUR VOICE');
      b.writeln('');
      for (final String p in preservedPhrases) {
        b.writeln('• $p');
      }
    }
    if (flags.isNotEmpty) {
      b.writeln('');
      b.writeln('');
      b.writeln('NOTES TO CONSIDER');
      b.writeln('');
      for (final String f in flags) {
        b.writeln('• $f');
      }
    }
    return b.toString().trim();
  }
}
