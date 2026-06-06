import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../models/material_item.dart';
import '../utils/app_error.dart';

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
    FunctionResponse res;
    try {
      res = await _client.functions.invoke(
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
    } on FunctionException catch (e) {
      // Supabase's functions.invoke() throws FunctionException for any
      // non-2xx response. ingest-material returns 500 with our typed
      // { code, error } body in that case — extract it here so the
      // user sees "That page took too long to respond." instead of
      // the generic "Yve is having a brief moment." fallback.
      throw _ingestAppErrorFromException(e);
    }

    final Map<String, dynamic> data =
        Map<String, dynamic>.from(res.data as Map<dynamic, dynamic>);

    // Belt-and-braces: defensive against any path where the function
    // returns 2xx but signals failure inside the body.
    if (res.status != 200 || data['status'] != 'ready') {
      final String? code = data['code'] as String?;
      final String message = (data['error'] as String?) ??
          "Yve couldn't add that material. Try again in a moment.";
      throw AppError(
        kind: _ingestKindForCode(code),
        userMessage: message,
        code: code,
        retryable: _ingestRetryable(code),
      );
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

  /// Lift the typed { code, error } body out of a FunctionException
  /// thrown by `_client.functions.invoke()` on a non-2xx response.
  /// supabase_flutter stores the JSON body on `details` (sometimes as
  /// a String, sometimes a Map depending on version + content type),
  /// so we normalize both shapes.
  static AppError _ingestAppErrorFromException(FunctionException e) {
    Map<String, dynamic> body = const <String, dynamic>{};
    final dynamic d = e.details;
    if (d is Map) {
      body = d.map((k, v) => MapEntry(k.toString(), v));
    } else if (d is String && d.isNotEmpty) {
      try {
        final parsed = jsonDecode(d);
        if (parsed is Map) {
          body = parsed.map((k, v) => MapEntry(k.toString(), v));
        }
      } catch (_) {
        // Not JSON — leave body empty, fall through to generic.
      }
    }
    final String? code = body['code'] as String?;
    final String message = (body['error'] as String?) ??
        "Yve couldn't add that material. Try again in a moment.";
    return AppError(
      kind: _ingestKindForCode(code),
      userMessage: message,
      code: code,
      cause: e,
      retryable: _ingestRetryable(code),
    );
  }

  /// Which AppErrorKind to surface for a typed ingest-material code.
  /// Most go through `serverError` (retryable, transient feel); a few
  /// validation-like cases use `validation` (definitively wrong input).
  static AppErrorKind _ingestKindForCode(String? code) {
    switch (code) {
      case 'url_invalid':
      case 'url_unsupported_scheme':
      case 'url_unsupported_content_type':
      case 'subject_required':
      case 'unsupported_kind':
        return AppErrorKind.validation;
      case 'url_too_large':
        return AppErrorKind.fileTooLarge;
      case 'url_timeout':
      case 'url_unreachable':
      case 'url_server_error':
        return AppErrorKind.network;
      default:
        return AppErrorKind.serverError;
    }
  }

  static bool _ingestRetryable(String? code) {
    switch (code) {
      case 'url_invalid':
      case 'url_unsupported_scheme':
      case 'url_unsupported_content_type':
      case 'url_not_found':
      case 'url_blocked':
      case 'url_too_large':
      case 'url_empty_or_jsrendered':
      case 'pdf_extract_failed':
      case 'subject_required':
      case 'unsupported_kind':
        return false;
      default:
        return true;
    }
  }

  /// Deletes a material the current user owns. material_chunks rows
  /// cascade-delete via the FK on the server side. Throws on auth /
  /// ownership / network failure; the caller maps those via AppError.
  Future<void> delete(String materialId) async {
    final res = await _client.functions.invoke(
      'delete-material',
      body: <String, dynamic>{'material_id': materialId},
    );
    if (res.status != 200) {
      final Map<String, dynamic> data = res.data is Map
          ? Map<String, dynamic>.from(res.data as Map<dynamic, dynamic>)
          : <String, dynamic>{};
      final String message = (data['detail'] as String?) ??
          (data['error'] as String?) ??
          'Couldn\'t delete material (status ${res.status}).';
      throw Exception(message);
    }
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
