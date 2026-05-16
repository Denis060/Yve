import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../models/subject.dart';

/// Reads + writes against the `subjects_with_counts` view (so material /
/// session / concept counts come back live without trigger maintenance).
class SubjectsRepository {
  SubjectsRepository(this._client);
  final SupabaseClient _client;

  Future<List<Subject>> list() async {
    final String? uid = _client.auth.currentUser?.id;
    if (uid == null) return const <Subject>[];
    final List<dynamic> rows = await _client
        .from('subjects_with_counts')
        .select()
        .filter('archived_at', 'is', null)
        .order('updated_at', ascending: false);
    return rows
        .cast<Map<String, dynamic>>()
        .map(Subject.fromRow)
        .toList();
  }

  Future<Subject> create({
    required String name,
    required String emoji,
    int colorSeed = 0,
  }) async {
    final String? uid = _client.auth.currentUser?.id;
    if (uid == null) {
      throw StateError('Cannot create a subject without an auth session.');
    }
    final Map<String, dynamic> row = await _client
        .from('subjects')
        .insert(<String, dynamic>{
          'user_id': uid,
          'name': name,
          'emoji': emoji,
          'color_seed': colorSeed,
        })
        .select()
        .single();
    // Return a Subject built from the bare row — counts default to 0.
    return Subject.fromRow(<String, dynamic>{
      ...row,
      'material_count': 0,
      'session_count': 0,
      'concept_count': 0,
    });
  }

  Future<Subject?> get(String id) async {
    final List<dynamic> rows = await _client
        .from('subjects_with_counts')
        .select()
        .eq('id', id)
        .limit(1);
    if (rows.isEmpty) return null;
    return Subject.fromRow(rows.first as Map<String, dynamic>);
  }
}

final subjectsRepositoryProvider = Provider<SubjectsRepository>((_) {
  return SubjectsRepository(Supabase.instance.client);
});

/// AsyncNotifier so callers can `await ref.read(subjectsProvider.future)` and
/// the UI can read `AsyncValue<List<Subject>>` for loading / error states.
class SubjectsNotifier extends AsyncNotifier<List<Subject>> {
  @override
  Future<List<Subject>> build() async {
    return ref.read(subjectsRepositoryProvider).list();
  }

  Future<Subject> addSubject({
    required String name,
    required String emoji,
  }) async {
    final List<Subject> current = state.value ?? const <Subject>[];
    final int seed = current.length;
    final Subject created = await ref
        .read(subjectsRepositoryProvider)
        .create(name: name, emoji: emoji, colorSeed: seed);
    state = AsyncData(<Subject>[created, ...current]);
    return created;
  }

  Future<void> refresh() async {
    state = const AsyncLoading<List<Subject>>();
    state = await AsyncValue.guard<List<Subject>>(
      () => ref.read(subjectsRepositoryProvider).list(),
    );
  }
}

final subjectsProvider =
    AsyncNotifierProvider<SubjectsNotifier, List<Subject>>(
  SubjectsNotifier.new,
);

/// Convenience for screens that want a single subject keyed by id (with live
/// counts). Returns null while loading or if not found.
final subjectByIdProvider =
    FutureProvider.family<Subject?, String>((ref, String id) async {
  return ref.read(subjectsRepositoryProvider).get(id);
});
