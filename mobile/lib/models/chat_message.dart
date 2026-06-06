import 'package:flutter/foundation.dart';

import 'polish.dart';
import 'yve_response.dart';

enum ChatRole { user, yve }

/// A single turn in a Yve Chat session. Yve turns carry the conversion
/// engine's structured state — concept tags, generated follow-up offer,
/// confidence read, save-to-subject suggestion. For Write-mode turns they
/// also carry the [polish] structured output; the bubble swaps to the
/// Polish renderer when present.
@immutable
class ChatMessage {
  const ChatMessage({
    required this.id,
    required this.role,
    required this.text,
    required this.createdAt,
    this.offer,
    this.conceptTags = const <String>[],
    this.saveToSubjectSuggestion,
    this.isStreaming = false,
    this.polish,
  });

  final String id;
  final ChatRole role;
  final String text;
  final DateTime createdAt;
  final PostSolveOffer? offer;
  final List<String> conceptTags;
  final String? saveToSubjectSuggestion;
  final bool isStreaming;
  final Polish? polish;

  /// `copyWith` can't *clear* an optional field via `field: null`
  /// because the `??` fallback treats null as "no override". For each
  /// nullable field the caller wants to set back to null (the dismiss-
  /// banner case is the canonical example), pass the matching `clear*`
  /// flag instead.
  ChatMessage copyWith({
    String? text,
    PostSolveOffer? offer,
    List<String>? conceptTags,
    String? saveToSubjectSuggestion,
    bool clearSaveToSubjectSuggestion = false,
    bool? isStreaming,
    Polish? polish,
  }) {
    return ChatMessage(
      id: id,
      role: role,
      text: text ?? this.text,
      createdAt: createdAt,
      offer: offer ?? this.offer,
      conceptTags: conceptTags ?? this.conceptTags,
      saveToSubjectSuggestion: clearSaveToSubjectSuggestion
          ? null
          : (saveToSubjectSuggestion ?? this.saveToSubjectSuggestion),
      isStreaming: isStreaming ?? this.isStreaming,
      polish: polish ?? this.polish,
    );
  }
}
