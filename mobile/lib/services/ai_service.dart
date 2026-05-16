import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:supabase_flutter/supabase_flutter.dart';

import '../config/env.dart';
import '../models/chat_message.dart';
import '../models/chat_stream_event.dart';
import '../utils/app_error.dart';
import '../models/study_mode.dart';

class AiService {
  AiService(this._client);

  final SupabaseClient _client;
  final http.Client _http = http.Client();

  /// Streams a turn from `yve-chat`. Yields parsed events in order: a single
  /// [ChatStreamStart], one or more [ChatStreamTextDelta] as the answer
  /// arrives, one [ChatStreamMetadata] after the answer completes, then
  /// either [ChatStreamDone] or [ChatStreamError]. The caller is responsible
  /// for awaiting the stream and reacting to each event.
  Stream<ChatStreamEvent> chatStream({
    required StudyMode mode,
    required List<ChatMessage> history,
    String? subjectId,
    String? sessionId,
  }) async* {
    final List<Map<String, String>> messages = history
        .map((ChatMessage m) => <String, String>{
              'role': m.role == ChatRole.user ? 'user' : 'assistant',
              'content': m.text,
            })
        .toList();

    final String url = '${Env.supabaseUrl}/functions/v1/yve-chat';
    final String accessToken =
        _client.auth.currentSession?.accessToken ?? Env.supabaseAnonKey;

    final http.Request req = http.Request('POST', Uri.parse(url));
    req.headers['authorization'] = 'Bearer $accessToken';
    req.headers['apikey'] = Env.supabaseAnonKey;
    req.headers['content-type'] = 'application/json';
    req.headers['accept'] = 'application/x-ndjson';
    req.body = jsonEncode(<String, dynamic>{
      'mode': mode.wireName,
      'messages': messages,
      if (subjectId != null) 'subject_id': subjectId,
      if (sessionId != null) 'session_id': sessionId,
    });

    http.StreamedResponse resp;
    try {
      resp = await _http.send(req);
    } catch (e) {
      yield ChatStreamError(
        AppError.from(e, actionContext: 'yve_chat_send').userMessage,
      );
      return;
    }

    if (resp.statusCode != 200) {
      // Drain the body for the dev log only — the user sees a calm
      // generic message tuned to the status code.
      final String body = await resp.stream.bytesToString();
      yield ChatStreamError(
        AppError.from(
          Exception('yve-chat ${resp.statusCode}: $body'),
          actionContext: 'yve_chat_status',
        ).userMessage,
      );
      return;
    }

    final Stream<String> lines =
        resp.stream.transform(utf8.decoder).transform(const LineSplitter());

    await for (final String line in lines) {
      if (line.isEmpty) continue;
      Map<String, dynamic> parsed;
      try {
        parsed = jsonDecode(line) as Map<String, dynamic>;
      } catch (_) {
        continue; // Tolerant of partial / malformed lines.
      }
      final ChatStreamEvent? event = parseChatStreamEvent(parsed);
      if (event != null) yield event;
    }
  }

  void dispose() {
    _http.close();
  }
}

final aiServiceProvider = Provider<AiService>((ref) {
  final AiService service = AiService(Supabase.instance.client);
  ref.onDispose(service.dispose);
  return service;
});
