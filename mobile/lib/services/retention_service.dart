import 'dart:ui' as ui;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../models/concept_review.dart';
import '../models/daily_activity.dart';
import '../models/recap.dart';

class RetentionRepository {
  RetentionRepository(this._client);
  final SupabaseClient _client;

  /// Concepts due now (overdue_seconds >= 0), ordered most-overdue-first.
  /// Joined with subjects so the card can show the emoji + name pill.
  Future<List<ConceptReview>> dueQueue({int limit = 6}) async {
    final List<dynamic> rows = await _client
        .from('concept_review_queue')
        .select()
        .gte('overdue_seconds', 0)
        .order('overdue_seconds', ascending: false)
        .limit(limit);

    // Hydrate subject metadata. We use a tiny lookup rather than a foreign-key
    // embed because concept_review_queue is a view and PostgREST embed
    // detection sometimes misses view→table FK chains.
    final List<String> subjectIds = <String>[
      for (final dynamic r in rows)
        if (r is Map<String, dynamic> && r['subject_id'] is String) r['subject_id'] as String,
    ].toSet().toList();

    final Map<String, Map<String, dynamic>> subjectsById =
        <String, Map<String, dynamic>>{};
    if (subjectIds.isNotEmpty) {
      final List<dynamic> sRows = await _client
          .from('subjects')
          .select('id, name, emoji')
          .inFilter('id', subjectIds);
      for (final dynamic s in sRows) {
        if (s is Map<String, dynamic>) {
          subjectsById[s['id'] as String] = s;
        }
      }
    }

    return rows
        .cast<Map<String, dynamic>>()
        .map((Map<String, dynamic> r) =>
            ConceptReview.fromRow(r, subjectsById: subjectsById))
        .toList();
  }

  Future<List<DailyActivity>> activityForWeek() async {
    final DateTime since = DateTime.now().subtract(const Duration(days: 7));
    final List<dynamic> rows = await _client
        .from('daily_activity')
        .select()
        .gte('day', since.toIso8601String().substring(0, 10))
        .order('day', ascending: true);
    return rows
        .cast<Map<String, dynamic>>()
        .map(DailyActivity.fromRow)
        .toList();
  }

  Future<Recap> composeRecap() async {
    final res = await _client.functions.invoke(
      'yve-recap',
      body: <String, dynamic>{
        // Device locale so the weekly recap renders in the learner's
        // language. Server allow-lists supported codes; English-default
        // when unknown.
        'locale': ui.PlatformDispatcher.instance.locale.toLanguageTag(),
      },
    );
    final Map<String, dynamic> data = res.data is Map
        ? Map<String, dynamic>.from(res.data as Map<dynamic, dynamic>)
        : <String, dynamic>{};
    if (res.status != 200) {
      final String message = (data['error'] as String?) ??
          'Recap failed (status ${res.status}).';
      throw Exception(message);
    }
    return Recap.fromJson(data);
  }
}

final retentionRepositoryProvider = Provider<RetentionRepository>((_) {
  return RetentionRepository(Supabase.instance.client);
});

/// Auto-refreshed view of "what to revisit now". Cards on Home consume this.
final reviewQueueProvider =
    FutureProvider<List<ConceptReview>>((ref) async {
  return ref.read(retentionRepositoryProvider).dueQueue();
});

/// 7-day activity bucket. Backs the calm dot strip in the Home greeting.
final weekActivityProvider =
    FutureProvider<List<DailyActivity>>((ref) async {
  final List<DailyActivity> raw =
      await ref.read(retentionRepositoryProvider).activityForWeek();
  return weekStrip(raw);
});
