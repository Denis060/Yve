import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../models/scan_result.dart';

class VisionService {
  VisionService(this._client);
  final SupabaseClient _client;

  /// Sends image bytes to `vision-ingest`. The function classifies the
  /// document, OCRs it, builds a ranked action ladder, and persists a chat
  /// session pre-loaded with the scan. Returns the full result for the
  /// Scan Result sheet to render.
  Future<ScanResult> analyze({
    required Uint8List bytes,
    required String mimeType,
    String? subjectId,
  }) =>
      _invoke(<String, dynamic>{
        'image_base64': base64Encode(bytes),
        'mime_type': mimeType,
        if (subjectId != null) 'subject_id': subjectId,
      });

  /// Sends PDF bytes to `vision-ingest`. Same scan result shape — Claude
  /// reads the document natively via a `document` content block. Up to
  /// ~32MB / 100 pages per the Anthropic limit.
  Future<ScanResult> analyzePdf({
    required Uint8List bytes,
    String? name,
    String? subjectId,
  }) =>
      _invoke(<String, dynamic>{
        'pdf_base64': base64Encode(bytes),
        if (name != null) 'pdf_name': name,
        if (subjectId != null) 'subject_id': subjectId,
      });

  /// Sends DOCX bytes to `vision-ingest`. The server unzips + extracts text
  /// from `word/document.xml` before handing the body to Claude as plain
  /// text (Claude doesn't have a native .docx content block).
  Future<ScanResult> analyzeDocx({
    required Uint8List bytes,
    String? name,
    String? subjectId,
  }) =>
      _invoke(<String, dynamic>{
        'docx_base64': base64Encode(bytes),
        if (name != null) 'docx_name': name,
        if (subjectId != null) 'subject_id': subjectId,
      });

  Future<ScanResult> _invoke(Map<String, dynamic> body) async {
    final res = await _client.functions.invoke('vision-ingest', body: body);
    final Map<String, dynamic> data = res.data is Map
        ? Map<String, dynamic>.from(res.data as Map<dynamic, dynamic>)
        : <String, dynamic>{};
    if (res.status != 200) {
      final String message = (data['error'] as String?) ??
          'Scan failed (status ${res.status}).';
      throw Exception(message);
    }
    return ScanResult.fromJson(data);
  }
}

final visionServiceProvider = Provider<VisionService>((_) {
  return VisionService(Supabase.instance.client);
});
