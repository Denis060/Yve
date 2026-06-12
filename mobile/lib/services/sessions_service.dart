import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../models/chat_message.dart';
import '../models/polish.dart';
import '../models/study_mode.dart';
import '../models/study_session.dart';
import '../models/yve_response.dart';
import '../utils/safe_parse.dart';

class SessionsRepository {
  SessionsRepository(this._client);
  final SupabaseClient _client;

  /// Recent sessions for the current user, newest first. Used by Home's
  /// "Continue where you left off" cards.
  Future<List<StudySession>> recent({int limit = 8}) async {
    final List<dynamic> rows = await _client
        .from('chat_sessions')
        .select('*, subjects(name, emoji)')
        .order('updated_at', ascending: false)
        .limit(limit);
    return rows
        .cast<Map<String, dynamic>>()
        .map(StudySession.fromRow)
        .toList();
  }

  /// All sessions linked to a given subject.
  Future<List<StudySession>> forSubject(String subjectId) async {
    final List<dynamic> rows = await _client
        .from('chat_sessions')
        .select('*, subjects(name, emoji)')
        .eq('subject_id', subjectId)
        .order('updated_at', ascending: false);
    return rows
        .cast<Map<String, dynamic>>()
        .map(StudySession.fromRow)
        .toList();
  }

  /// Full message history for resuming a session.
  Future<List<ChatMessage>> messages(String sessionId) async {
    final List<dynamic> rows = await _client
        .from('chat_messages')
        .select()
        .eq('session_id', sessionId)
        .order('created_at', ascending: true)
        // Tiebreaker: the scan-ingest flow seeds the user + assistant rows
        // in a single batch insert, so they share an identical created_at
        // and their relative order would otherwise be undefined (id is a
        // random UUID, no help). role DESC puts 'user' before 'assistant'
        // on a tie (u > a), keeping the "I scanned this" → "here's what I
        // see" order correct. Normal turns differ in created_at, so this
        // only ever matters for the scan seed pair.
        .order('role', ascending: false);
    return rows.cast<Map<String, dynamic>>().map(_messageFromRow).toList();
  }

  /// Delete a chat session. The `chat_messages` rows for this session
  /// cascade-delete via the FK constraint. Gated by the
  /// `chat_sessions_self_delete` RLS policy.
  Future<void> delete(String sessionId) async {
    await _client.from('chat_sessions').delete().eq('id', sessionId);
  }
}

ChatMessage _messageFromRow(Map<String, dynamic> row) {
  final String roleStr = row['role'] as String;
  final ChatRole role = roleStr == 'user' ? ChatRole.user : ChatRole.yve;
  final List<dynamic> tagsRaw =
      (row['concept_tags'] as List<dynamic>?) ?? const <dynamic>[];
  final Map<String, dynamic>? offerRaw =
      row['offer'] as Map<String, dynamic>?;
  // yve-chat persists Write-mode polish under offer.polish; reconstruct it
  // so resumed sessions show the structured polish bubble, not a markdown
  // dump of the polished text.
  Polish? polish;
  if (offerRaw != null && offerRaw['polish'] is Map<String, dynamic>) {
    polish = Polish.fromJson(offerRaw['polish'] as Map<String, dynamic>);
  }
  return ChatMessage(
    id: row['id'] as String,
    role: role,
    text: row['content'] as String,
    createdAt: parseTimestampOr(
      row['created_at'],
      fallback: DateTime.now(),
      context: 'chat_message.created_at',
    ),
    conceptTags: tagsRaw.map((dynamic t) => t.toString()).toList(),
    offer: offerRaw != null ? PostSolveOffer.fromJson(offerRaw) : null,
    saveToSubjectSuggestion: row['save_to_subject'] as String?,
    polish: polish,
  );
}

final sessionsRepositoryProvider = Provider<SessionsRepository>((_) {
  return SessionsRepository(Supabase.instance.client);
});

class RecentSessionsNotifier extends AsyncNotifier<List<StudySession>> {
  @override
  Future<List<StudySession>> build() {
    return ref.read(sessionsRepositoryProvider).recent();
  }

  Future<void> refresh() async {
    state = const AsyncLoading<List<StudySession>>();
    state = await AsyncValue.guard<List<StudySession>>(
      () => ref.read(sessionsRepositoryProvider).recent(),
    );
  }

  /// Delete a session + patch local state immediately so the user
  /// doesn't see a "deleting…" lag.
  Future<void> deleteSession(String sessionId) async {
    await ref.read(sessionsRepositoryProvider).delete(sessionId);
    final List<StudySession> current = state.value ?? const <StudySession>[];
    state = AsyncData(<StudySession>[
      for (final StudySession s in current)
        if (s.id != sessionId) s,
    ]);
    // Also invalidate the per-subject session list so the Subject
    // workspace view refreshes if the user navigates there next.
    ref.invalidate(sessionsBySubjectProvider);
  }
}

final recentSessionsProvider =
    AsyncNotifierProvider<RecentSessionsNotifier, List<StudySession>>(
  RecentSessionsNotifier.new,
);

final sessionsBySubjectProvider =
    FutureProvider.family<List<StudySession>, String>(
        (ref, String subjectId) async {
  return ref.read(sessionsRepositoryProvider).forSubject(subjectId);
});

final sessionMessagesProvider =
    FutureProvider.family<List<ChatMessage>, String>(
        (ref, String sessionId) async {
  return ref.read(sessionsRepositoryProvider).messages(sessionId);
});

/// Helper for the Home tiny dot indicating a session was opened recently.
StudyMode modeForSession(StudySession s) => s.mode;
