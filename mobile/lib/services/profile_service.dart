import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../models/account.dart';
import '../models/learner_profile.dart';

class ProfileRepository {
  ProfileRepository(this._client);
  final SupabaseClient _client;

  /// Reads the current learner's profile. Returns [LearnerProfile.defaults]
  /// when no row exists yet — the substrate is implicit until the learner
  /// explicitly tunes something or sends their first chat turn.
  Future<LearnerProfile> read() async {
    final String? uid = _client.auth.currentUser?.id;
    if (uid == null) return LearnerProfile.defaults;
    final List<dynamic> rows = await _client
        .from('learner_profiles')
        .select()
        .eq('user_id', uid)
        .limit(1);
    if (rows.isEmpty) return LearnerProfile.defaults;
    return LearnerProfile.fromRow(rows.first as Map<String, dynamic>);
  }

  Future<LearnerProfile> upsert(LearnerProfile profile) async {
    final String? uid = _client.auth.currentUser?.id;
    if (uid == null) {
      throw StateError('Cannot save profile without an auth session.');
    }
    final Map<String, dynamic> row = await _client
        .from('learner_profiles')
        .upsert(profile.toUpsertRow(uid), onConflict: 'user_id')
        .select()
        .single();
    return LearnerProfile.fromRow(row);
  }

  /// Reads the learner's display name from the `profiles` table. Returns
  /// null when no row exists yet (anonymous user who's never set one).
  Future<String?> readDisplayName() async {
    final String? uid = _client.auth.currentUser?.id;
    if (uid == null) return null;
    final List<dynamic> rows = await _client
        .from('profiles')
        .select('display_name')
        .eq('id', uid)
        .limit(1);
    if (rows.isEmpty) return null;
    return (rows.first as Map<String, dynamic>)['display_name'] as String?;
  }

  /// Upserts the display name. Pass null to clear it.
  Future<void> writeDisplayName(String? name) async {
    final String? uid = _client.auth.currentUser?.id;
    if (uid == null) {
      throw StateError('Cannot save display name without an auth session.');
    }
    await _client.from('profiles').upsert(<String, dynamic>{
      'id': uid,
      'display_name': name,
    });
  }

  /// Triggers `infer-profile` which observes the learner's chat history and
  /// writes the result back into the auto_* columns. Returns the freshly
  /// refreshed profile so the UI updates with both auto fields and the
  /// last-inferred timestamp.
  Future<LearnerProfile> inferNow() async {
    final res = await _client.functions.invoke(
      'infer-profile',
      body: <String, dynamic>{},
    );
    final Map<String, dynamic> data = res.data is Map
        ? Map<String, dynamic>.from(res.data as Map<dynamic, dynamic>)
        : <String, dynamic>{};
    if (res.status != 200) {
      final String message = (data['error'] as String?) ??
          'Inference failed (status ${res.status}).';
      throw Exception(message);
    }
    // The function persisted the row already; re-read so the local model
    // reflects the canonical state including auto + user-set fields.
    return read();
  }
}

final profileRepositoryProvider = Provider<ProfileRepository>((_) {
  return ProfileRepository(Supabase.instance.client);
});

class ProfileNotifier extends AsyncNotifier<LearnerProfile> {
  @override
  Future<LearnerProfile> build() {
    return ref.read(profileRepositoryProvider).read();
  }

  /// Optimistic update: write the new profile locally first so the UI feels
  /// instant, then sync to Postgres. On failure we surface the error and
  /// roll back to whatever the server has.
  Future<void> save(LearnerProfile next) async {
    final AsyncValue<LearnerProfile> previous = state;
    state = AsyncData(next);
    try {
      final LearnerProfile saved =
          await ref.read(profileRepositoryProvider).upsert(next);
      state = AsyncData(saved);
    } catch (e, st) {
      state = AsyncError(e, st);
      // Restore the previous-known-good value so the UI doesn't get stuck.
      if (previous is AsyncData<LearnerProfile>) {
        state = previous;
      }
      rethrow;
    }
  }

  /// Kicks off auto-inference. Surfaces a transient AsyncLoading state so
  /// the UI can show the "Yve is observing…" pulse without blocking other
  /// fields. The eventual AsyncData carries the merged profile (user-set
  /// preferences preserved, auto_* fields refreshed).
  Future<void> refreshInference() async {
    final AsyncValue<LearnerProfile> previous = state;
    state = const AsyncLoading<LearnerProfile>();
    try {
      final LearnerProfile fresh =
          await ref.read(profileRepositoryProvider).inferNow();
      state = AsyncData(fresh);
    } catch (e, st) {
      state = AsyncError(e, st);
      if (previous is AsyncData<LearnerProfile>) {
        state = previous;
      }
      rethrow;
    }
  }
}

final profileProvider =
    AsyncNotifierProvider<ProfileNotifier, LearnerProfile>(
  ProfileNotifier.new,
);

/// Live account stream. Emits on every Supabase auth state change
/// (anonymous → linked, sign-in, sign-out) so Home greetings, Profile
/// headers, and the auth-sheet dismiss-on-success all react together.
final accountProvider = StreamProvider<Account>((ref) async* {
  final SupabaseClient client = Supabase.instance.client;
  Future<Account> build() async {
    final User? user = client.auth.currentUser;
    if (user == null) {
      return const Account(userId: '', isAnonymous: true);
    }
    String? displayName;
    try {
      displayName = await ref.read(profileRepositoryProvider).readDisplayName();
    } catch (_) {
      displayName = null;
    }
    return Account(
      userId: user.id,
      isAnonymous: user.isAnonymous == true,
      email: user.email,
      displayName: displayName,
    );
  }

  yield await build();
  await for (final _ in client.auth.onAuthStateChange) {
    // Profile + adaptation rows are user-scoped; invalidate so subsequent
    // reads see the new user's data, not the previous user's cache.
    ref.invalidate(profileProvider);
    yield await build();
  }
});

