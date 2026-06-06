import 'package:flutter/foundation.dart';

import '../utils/safe_parse.dart';
import 'entitlement.dart';
import 'polish.dart';
import 'yve_response.dart';

/// Events emitted by `yve-chat`'s NDJSON stream as Yve composes a turn.
///
/// The chat surface listens to this stream: `Start` carries the session id;
/// `TextDelta` events append to the in-flight Yve bubble; `Metadata` arrives
/// once after the answer completes, carrying the conversion engine's typed
/// state (concept tags, generated offer chips, confidence read, save
/// suggestion); `Done` terminates; `Error` surfaces a recoverable failure.
@immutable
sealed class ChatStreamEvent {
  const ChatStreamEvent();
}

@immutable
class ChatStreamStart extends ChatStreamEvent {
  const ChatStreamStart({required this.sessionId});
  final String sessionId;
}

@immutable
class ChatStreamTextDelta extends ChatStreamEvent {
  const ChatStreamTextDelta(this.delta);
  final String delta;
}

@immutable
class ChatStreamMetadata extends ChatStreamEvent {
  const ChatStreamMetadata({
    required this.conceptTags,
    required this.offer,
    required this.confidence,
    this.saveToSubjectSuggestion,
    this.groundedMaterialIds = const <String>[],
  });

  final List<String> conceptTags;
  final PostSolveOffer offer;
  final ConfidenceSignal confidence;
  final String? saveToSubjectSuggestion;
  final List<String> groundedMaterialIds;
}

@immutable
class ChatStreamDone extends ChatStreamEvent {
  const ChatStreamDone();
}

@immutable
class ChatStreamError extends ChatStreamEvent {
  const ChatStreamError(this.message);
  final String message;
}

/// Server rejected the turn because the learner's free quota is exhausted.
/// Not an error — the chat surface renders an inline upgrade card. Carries
/// the snapshot needed to show "resets tomorrow" without an extra fetch.
@immutable
class ChatStreamQuotaExceeded extends ChatStreamEvent {
  const ChatStreamQuotaExceeded(this.quota);
  final QuotaExceeded quota;
}

/// Write-mode turn returned a structured polish instead of a streamed
/// markdown answer. The chat bubble swaps to the Polish renderer when it
/// sees this event — sections for polished draft, what changed, flags,
/// follow-ups; primary Copy copies only the polished text.
@immutable
class ChatStreamPolish extends ChatStreamEvent {
  const ChatStreamPolish(this.polish);
  final Polish polish;
}

/// Parses a single NDJSON line from the server into a typed event. Returns
/// null for lines that don't match a known event kind (forwards-compatible).
ChatStreamEvent? parseChatStreamEvent(Map<String, dynamic> json) {
  final String? type = json['type'] as String?;
  switch (type) {
    case 'start':
      final String? sid = json['session_id'] as String?;
      if (sid == null) return null;
      return ChatStreamStart(sessionId: sid);
    case 'text':
      final String? delta = json['delta'] as String?;
      if (delta == null) return null;
      return ChatStreamTextDelta(delta);
    case 'metadata':
      final List<dynamic> tagsRaw =
          (json['concept_tags'] as List<dynamic>?) ?? const <dynamic>[];
      final Map<String, dynamic> offerRaw =
          (json['post_solve_offer'] as Map<String, dynamic>?) ??
              const <String, dynamic>{};
      final List<dynamic> groundedRaw =
          (json['grounded_material_ids'] as List<dynamic>?) ??
              const <dynamic>[];
      return ChatStreamMetadata(
        conceptTags: tagsRaw.map((dynamic t) => t.toString()).toList(),
        offer: PostSolveOffer.fromJson(offerRaw),
        confidence:
            ConfidenceSignal.fromWire(json['confidence_signal'] as String?),
        saveToSubjectSuggestion: json['save_to_subject'] as String?,
        groundedMaterialIds:
            groundedRaw.map((dynamic id) => id.toString()).toList(),
      );
    case 'done':
      return const ChatStreamDone();
    case 'error':
      return ChatStreamError(
        (json['message'] as String?) ?? 'Unknown error',
      );
    case 'polish':
      final Map<String, dynamic>? raw =
          json['polish'] as Map<String, dynamic>?;
      if (raw == null) return null;
      return ChatStreamPolish(Polish.fromJson(raw));
    case 'quota_exceeded':
      // Anonymous cap-hits send reset_at='' (no daily reset path).
      // safe-parse handles null, empty string, and malformed input
      // uniformly — never throws _FormatException.
      return ChatStreamQuotaExceeded(
        QuotaExceeded(
          plan: PlanX.fromWire(json['plan'] as String?),
          kind: CapKindX.fromWire(json['kind'] as String?),
          used: (json['used'] as int?) ?? 0,
          limit: (json['limit'] as int?) ?? 0,
          resetAtUtc: parseTimestampOrNull(
            json['reset_at'],
            context: 'quota_exceeded.reset_at',
          ),
          mode: json['mode'] as String?,
          sessionId: json['session_id'] as String?,
          sessionTitle: json['session_title'] as String?,
          turnsThisSession: json['turns_this_session'] as int?,
          primaryConcept: json['primary_concept'] as String?,
          draftPreview: json['draft_preview'] as String?,
        ),
      );
    default:
      return null;
  }
}
