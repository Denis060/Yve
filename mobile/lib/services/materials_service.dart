import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../models/material_item.dart';

class MaterialsRepository {
  MaterialsRepository(this._client);
  final SupabaseClient _client;

  Future<List<MaterialItem>> listForSubject(String subjectId) async {
    final List<dynamic> rows = await _client
        .from('materials')
        .select()
        .eq('subject_id', subjectId)
        .order('created_at', ascending: false);
    return rows
        .cast<Map<String, dynamic>>()
        .map(MaterialItem.fromRow)
        .toList();
  }

  /// Ingest a new material via the `ingest-material` Edge Function. Returns
  /// the newly inserted material once the server has chunked + embedded it.
  ///
  /// For PDFs, pass [pdfBytes] — the server extracts text via Claude.
  /// For DOCX, pass [docxBytes] — the server unzips and parses XML directly.
  Future<MaterialItem> ingest({
    required String subjectId,
    required MaterialKind kind,
    String? name,
    String? content,
    String? url,
    Uint8List? pdfBytes,
    Uint8List? docxBytes,
  }) async {
    final res = await _client.functions.invoke(
      'ingest-material',
      body: <String, dynamic>{
        'subject_id': subjectId,
        'kind': kind.wireName,
        if (name != null && name.isNotEmpty) 'name': name,
        if (content != null) 'content': content,
        if (url != null) 'url': url,
        if (pdfBytes != null) 'pdf_base64': base64Encode(pdfBytes),
        if (docxBytes != null) 'docx_base64': base64Encode(docxBytes),
      },
    );

    final Map<String, dynamic> data =
        Map<String, dynamic>.from(res.data as Map<dynamic, dynamic>);

    if (res.status != 200 || data['status'] != 'ready') {
      final String message = (data['error'] as String?) ??
          'ingest-material failed (status ${res.status}).';
      throw Exception(message);
    }

    final String materialId = data['material_id'] as String;
    final List<dynamic> rows = await _client
        .from('materials')
        .select()
        .eq('id', materialId)
        .limit(1);
    if (rows.isEmpty) {
      throw Exception('material $materialId not found after ingest');
    }
    return MaterialItem.fromRow(rows.first as Map<String, dynamic>);
  }
}

final materialsRepositoryProvider = Provider<MaterialsRepository>((_) {
  return MaterialsRepository(Supabase.instance.client);
});

final materialsBySubjectProvider =
    FutureProvider.family<List<MaterialItem>, String>(
        (ref, String subjectId) async {
  return ref.read(materialsRepositoryProvider).listForSubject(subjectId);
});
