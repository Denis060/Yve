import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:speech_to_text/speech_recognition_result.dart';
import 'package:speech_to_text/speech_to_text.dart';

/// Unified voice surface — STT for input and TTS for output. Built on the
/// device-native engines (Siri/Speech.framework on iOS, Google STT/TTS on
/// Android) so the slice doesn't add cloud-service dependencies.
class VoiceService {
  VoiceService() {
    _tts.setStartHandler(() {
      _currentlySpeakingMessageId = _pendingMessageId;
      _pendingMessageId = null;
      _ttsStateController.add(_currentlySpeakingMessageId);
    });
    _tts.setCompletionHandler(() {
      _currentlySpeakingMessageId = null;
      _ttsStateController.add(null);
    });
    _tts.setCancelHandler(() {
      _currentlySpeakingMessageId = null;
      _ttsStateController.add(null);
    });
    _tts.setErrorHandler((dynamic message) {
      _currentlySpeakingMessageId = null;
      _ttsStateController.add(null);
    });
  }

  final SpeechToText _stt = SpeechToText();
  final FlutterTts _tts = FlutterTts();
  bool _sttReady = false;
  bool _sttAvailable = false;

  // STT plumbing
  final StreamController<String> _recognizedController =
      StreamController<String>.broadcast();
  final StreamController<bool> _listeningController =
      StreamController<bool>.broadcast();

  /// Each event is the *full* recognized text so far (replaces previous).
  Stream<String> get recognizedText => _recognizedController.stream;
  Stream<bool> get listeningChanged => _listeningController.stream;
  bool get isListening => _stt.isListening;
  bool get sttAvailable => _sttAvailable;

  // TTS plumbing
  final StreamController<String?> _ttsStateController =
      StreamController<String?>.broadcast();

  /// Stream of the message id currently being spoken (null when idle).
  Stream<String?> get speakingMessageId => _ttsStateController.stream;

  String? _currentlySpeakingMessageId;
  String? _pendingMessageId;

  String? get currentlySpeakingMessageId => _currentlySpeakingMessageId;

  // ---------- STT ----------

  /// Initializes the STT engine and asks for mic + speech permissions if
  /// they haven't been granted yet. Returns true when listening is possible.
  Future<bool> ensureSttReady() async {
    if (_sttReady) return _sttAvailable;
    try {
      _sttAvailable = await _stt.initialize(
        onError: (Object e) {
          if (kDebugMode) print('STT error: $e');
          _listeningController.add(false);
        },
        onStatus: (String status) {
          // status is 'listening' | 'notListening' | 'done'
          _listeningController.add(status == 'listening');
        },
      );
    } catch (e) {
      _sttAvailable = false;
    }
    _sttReady = true;
    return _sttAvailable;
  }

  Future<void> startListening({String? localeId}) async {
    final bool ok = await ensureSttReady();
    if (!ok) return;
    await _stt.listen(
      onResult: (SpeechRecognitionResult result) {
        _recognizedController.add(result.recognizedWords);
      },
      listenOptions: SpeechListenOptions(
        partialResults: true,
        cancelOnError: true,
      ),
      localeId: localeId,
    );
    _listeningController.add(true);
  }

  Future<void> stopListening() async {
    if (_stt.isListening) {
      await _stt.stop();
    }
    _listeningController.add(false);
  }

  // ---------- TTS ----------

  /// Speak the given text aloud, tagged with [messageId] so the bubble UI
  /// can show a "now speaking" state on the right message.
  Future<void> speak(String messageId, String text) async {
    final String cleaned = _cleanForSpeech(text);
    if (cleaned.isEmpty) return;
    // If something's already playing, stop it first — only one stream of
    // Yve's voice at a time.
    await stopSpeaking();
    _pendingMessageId = messageId;
    await _tts.setSpeechRate(0.5); // a touch slower than default; calmer pace
    await _tts.speak(cleaned);
  }

  Future<void> stopSpeaking() async {
    await _tts.stop();
    _currentlySpeakingMessageId = null;
    _pendingMessageId = null;
    _ttsStateController.add(null);
  }

  /// Strips markdown noise that doesn't read aloud well. Yve's system
  /// addendum tells her to avoid these structures when read_aloud is on,
  /// but we still scrub defensively for ad-hoc bullets, code fences, etc.
  String _cleanForSpeech(String text) {
    return text
        .replaceAll(RegExp(r'```[\s\S]*?```'), ' ') // fenced code
        .replaceAll(RegExp(r'`([^`]+)`'), r'$1') // inline code
        .replaceAll(RegExp(r'\*\*([^*]+)\*\*'), r'$1') // bold
        .replaceAll(RegExp(r'\*([^*]+)\*'), r'$1') // italic
        .replaceAll(RegExp(r'^#{1,6}\s+', multiLine: true), '') // headings
        .replaceAll(RegExp(r'^[\-\*]\s+', multiLine: true), '') // bullets
        .replaceAll(RegExp(r'\[([^\]]+)\]\([^)]+\)'), r'$1') // links → label
        .replaceAll('✦', '')
        .replaceAll(RegExp(r'\n{2,}'), '. ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }

  void dispose() {
    _recognizedController.close();
    _listeningController.close();
    _ttsStateController.close();
    _tts.stop();
  }
}

final voiceServiceProvider = Provider<VoiceService>((ref) {
  final VoiceService svc = VoiceService();
  ref.onDispose(svc.dispose);
  return svc;
});
