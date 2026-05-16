import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../models/concept_mastery.dart';

class ConceptsRepository {
  ConceptsRepository(this._client);
  final SupabaseClient _client;

  Future<List<ConceptMastery>> listForSubject(String subjectId) async {
    final List<dynamic> rows = await _client
        .from('concept_mastery')
        .select()
        .eq('subject_id', subjectId)
        .order('last_seen_at', ascending: false);
    return rows
        .cast<Map<String, dynamic>>()
        .map(ConceptMastery.fromRow)
        .toList();
  }
}

final conceptsRepositoryProvider = Provider<ConceptsRepository>((_) {
  return ConceptsRepository(Supabase.instance.client);
});

final conceptsBySubjectProvider =
    FutureProvider.family<List<ConceptMastery>, String>(
        (ref, String subjectId) async {
  return ref.read(conceptsRepositoryProvider).listForSubject(subjectId);
});
