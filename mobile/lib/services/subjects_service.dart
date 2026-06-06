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

  /// Creates a subject via the create-subject Edge Function. The
  /// function enforces the per-tier subjects_max cap server-side —
  /// anonymous users are blocked at 1 subject (lifetime), free users
  /// at the plan_limits value, Pro is unlimited. A cap hit comes back
  /// as a FunctionException with code 'anonymous_subject_limit' or
  /// 'subject_limit', which AppError.from maps to a calm UX message.
  Future<Subject> create({
    required String name,
    required String emoji,
    int colorSeed = 0,
  }) async {
    final res = await _client.functions.invoke(
      'create-subject',
      body: <String, dynamic>{
        'name': name,
        'emoji': emoji,
        'color_seed': colorSeed,
      },
    );
    if (res.status != 200) {
      final Map<String, dynamic> data = res.data is Map
          ? Map<String, dynamic>.from(res.data as Map<dynamic, dynamic>)
          : <String, dynamic>{};
      final String message = (data['error'] as String?) ??
          'Couldn\'t create subject (status ${res.status}).';
      throw Exception(message);
    }
    final Map<String, dynamic> row =
        Map<String, dynamic>.from(res.data as Map<dynamic, dynamic>);
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

  /// Rename a subject. The `subjects_self_update` RLS policy gates
  /// this to the current user only — no separate ownership check
  /// needed in code. `emoji` is optional so callers can change name
  /// alone or both at once.
  Future<void> rename({
    required String id,
    required String name,
    String? emoji,
  }) async {
    final Map<String, dynamic> patch = <String, dynamic>{
      'name': name,
      'updated_at': DateTime.now().toUtc().toIso8601String(),
    };
    if (emoji != null && emoji.trim().isNotEmpty) {
      patch['emoji'] = emoji.trim();
    }
    await _client.from('subjects').update(patch).eq('id', id);
  }

  /// Delete a subject. Cascades to its materials, chat_sessions,
  /// chat_messages, material_chunks, and concept_observations via
  /// the foreign-key `on delete cascade` constraints from
  /// migration 0004. Gated by the `subjects_self_delete` RLS policy.
  Future<void> delete(String id) async {
    await _client.from('subjects').delete().eq('id', id);
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

  /// Rename a subject and patch local state in-place so the UI updates
  /// before the next full refresh.
  Future<void> renameSubject({
    required String id,
    required String name,
    String? emoji,
  }) async {
    await ref
        .read(subjectsRepositoryProvider)
        .rename(id: id, name: name, emoji: emoji);
    final List<Subject> current = state.value ?? const <Subject>[];
    state = AsyncData(<Subject>[
      for (final Subject s in current)
        if (s.id == id)
          s.copyWith(name: name, emoji: emoji?.trim().isNotEmpty == true ? emoji!.trim() : s.emoji)
        else
          s,
    ]);
  }

  /// Delete a subject and remove it from local state immediately.
  Future<void> deleteSubject(String id) async {
    await ref.read(subjectsRepositoryProvider).delete(id);
    final List<Subject> current = state.value ?? const <Subject>[];
    state = AsyncData(<Subject>[
      for (final Subject s in current)
        if (s.id != id) s,
    ]);
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
