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
          _userWantsToDictate = false;
          _listeningController.add(false);
        },
        onStatus: (String status) {
          // status is 'listening' | 'notListening' | 'done'
          //
          // Android's system recognizer hard-times-out after 3-5s of
          // silence regardless of our pauseFor: 15s setting. When that
          // happens we silently restart the session WITHOUT toggling
          // the UI state — the user sees a continuous "still recording"
          // mic, never realizes the engine briefly stopped. If they
          // actually tap stop, that calls stopListening() which sets
          // _userWantsToDictate = false and breaks the loop.
          final bool isListening = status == 'listening';
          if (!isListening) {
            _foldCurrentIntoAccumulated();
            // Engine stopped on its own. If user is still expecting to
            // dictate, restart silently — don't surface notListening
            // to the UI (no flicker). If user explicitly tapped stop,
            // _userWantsToDictate is already false and we fall through
            // to surfacing the stopped state.
            if (_userWantsToDictate) {
              unawaited(_silentRestart());
              return; // suppress the false emission
            }
          }
          _listeningController.add(isListening);
        },
      );
    } catch (e) {
      _sttAvailable = false;
    }
    _sttReady = true;
    return _sttAvailable;
  }

  /// Whether the user is *intending* to dictate right now. Tracked so
  /// that when the platform STT engine times out mid-thought (Android's
  /// system recognizer typically gives up after a few seconds of
  /// silence regardless of `pauseFor`), we can transparently restart
  /// listening — and crucially, preserve everything they've already
  /// said so far instead of clearing the field on every restart.
  bool _userWantsToDictate = false;
  String? _activeLocale;

  /// Words from previous completed STT sessions in this dictation turn.
  /// Each `_stt.listen()` call resets the engine's view of the world,
  /// so we accumulate locally and emit `accumulated + current` to the
  /// UI. Cleared when the user explicitly taps stop.
  String _accumulatedText = '';

  /// What the current STT session has recognized so far. Tracked so we
  /// know how much to fold into `_accumulatedText` when the engine
  /// closes the session (status → notListening).
  String _currentSessionText = '';

  /// Throttle for the auto-restart loop. Without this, status callbacks
  /// can fire rapidly on some devices and we end up stop/start-thrashing
  /// the engine — which the user experiences as a jittery, stuttering mic.
  DateTime? _lastRestartAt;

  Future<void> startListening({String? localeId}) async {
    final bool ok = await ensureSttReady();
    if (!ok) return;
    _userWantsToDictate = true;
    _activeLocale = localeId;
    _accumulatedText = '';
    _currentSessionText = '';
    _lastRestartAt = null;
    await _startInternal();
  }

  Future<void> _startInternal() async {
    if (!_userWantsToDictate) return;
    if (_stt.isListening) return;
    _currentSessionText = '';
    await _stt.listen(
      onResult: (SpeechRecognitionResult result) {
        _currentSessionText = result.recognizedWords;
        _emitFullText();
      },
      // Bumped from the package's 3-second / 30-second defaults — they
      // assumed a "say one command" UX, not a learner talking through
      // their reasoning. We still get cut off on some Android devices
      // (the system recognizer ignores pauseFor), which is why we also
      // run the auto-restart loop below.
      listenFor: const Duration(minutes: 5),
      pauseFor: const Duration(seconds: 15),
      listenOptions: SpeechListenOptions(
        partialResults: true,
        cancelOnError: false,
        listenMode: ListenMode.dictation,
      ),
      localeId: _activeLocale,
    );
    _listeningController.add(true);
  }

  Future<void> stopListening() async {
    _userWantsToDictate = false;
    if (_stt.isListening) {
      await _stt.stop();
    }
    // Fold the final-but-not-yet-final words into accumulated so any
    // text shown in the field reflects the entire turn, then clear so
    // the next start() begins clean.
    _foldCurrentIntoAccumulated();
    _accumulatedText = '';
    _currentSessionText = '';
    _lastRestartAt = null;
    _listeningController.add(false);
  }

  void _foldCurrentIntoAccumulated() {
    final String trimmed = _currentSessionText.trim();
    if (trimmed.isEmpty) return;
    if (_accumulatedText.isEmpty) {
      _accumulatedText = trimmed;
    } else {
      _accumulatedText = '$_accumulatedText $trimmed';
    }
    _currentSessionText = '';
  }

  /// Re-enters listening mode without flipping the UI state.
  /// Throttled so a chatty status callback can't melt the engine.
  Future<void> _silentRestart() async {
    if (!_userWantsToDictate) return;
    if (_stt.isListening) return;
    final DateTime now = DateTime.now();
    final DateTime? last = _lastRestartAt;
    if (last != null && now.difference(last).inMilliseconds < 500) return;
    _lastRestartAt = now;
    // Brief breath so the engine releases mic locks before we re-grab.
    await Future<void>.delayed(const Duration(milliseconds: 200));
    if (!_userWantsToDictate) return;
    try {
      await _startInternal();
    } catch (_) {
      // Restart failed — fall back to surfacing the stopped state so
      // the user can tap again manually.
      _userWantsToDictate = false;
      _listeningController.add(false);
    }
  }

  void _emitFullText() {
    final String live = _currentSessionText.trim();
    final String full = _accumulatedText.isEmpty
        ? live
        : (live.isEmpty ? _accumulatedText : '$_accumulatedText $live');
    _recognizedController.add(full);
  }


  // ---------- TTS ----------

  /// Speak the given text aloud, tagged with [messageId] so the bubble UI
  /// can show a "now speaking" state on the right message.
  Future<void> speak(String messageId, String text) async {
    final String cleaned = _cleanForSpeech(text);
    if (cleaned.isEmpty) return;
    await stopSpeaking();
    _pendingMessageId = messageId;
    await _ensureBestVoice();
    // 0.5 was too slow and made Yve sound mechanical. 0.55 is a calm
    // tutor pace — natural without rushing. flutter_tts treats this
    // as a normalized 0.0–1.0 on every platform.
    await _tts.setSpeechRate(0.55);
    await _tts.setPitch(1.05); // a hair brighter than default = warmer
    await _tts.setVolume(1.0);
    await _tts.speak(cleaned);
  }

  bool _voiceSet = false;

  /// Pick the most natural-sounding voice the OS / browser exposes.
  /// Browser speechSynthesis on Windows defaults to robotic voices like
  /// Microsoft David; if we don't override, every Yve response sounds
  /// like a 90s screen reader. We iterate available voices once and
  /// pick the best en-US match using a small preference list.
  Future<void> _ensureBestVoice() async {
    if (_voiceSet) return;
    try {
      final dynamic raw = await _tts.getVoices;
      if (raw is! List) return;
      final List<Map<String, String>> voices = raw
          .map<Map<String, String>>((dynamic v) =>
              Map<String, String>.from(v as Map))
          .toList();
      // Preference order: names known to sound the most natural across
      // OSes. We rank by substring match against the voice name.
      const List<String> preferences = <String>[
        'Samantha',          // macOS / iOS default — very natural
        'Google US English', // Android / Chrome — quite natural
        'Microsoft Aria',    // Win 11 cloud voice — most natural Win voice
        'Microsoft Jenny',
        'Microsoft Zira',    // fallback — older but better than David
      ];
      Map<String, String>? pick;
      for (final String pref in preferences) {
        pick = voices.firstWhere(
          (v) => (v['name'] ?? '').contains(pref),
          orElse: () => const <String, String>{},
        );
        if (pick.isNotEmpty) break;
      }
      // Fallback: first en-US voice we find.
      if (pick == null || pick.isEmpty) {
        pick = voices.firstWhere(
          (v) => (v['locale'] ?? '').toLowerCase().startsWith('en-us'),
          orElse: () => const <String, String>{},
        );
      }
      if (pick != null && pick.isNotEmpty) {
        await _tts.setVoice(<String, String>{
          'name': pick['name'] ?? '',
          'locale': pick['locale'] ?? 'en-US',
        });
      } else {
        // Last resort — just set the language.
        await _tts.setLanguage('en-US');
      }
      _voiceSet = true;
    } catch (e) {
      if (kDebugMode) print('TTS voice selection failed: $e');
    }
  }

  Future<void> stopSpeaking() async {
    await _tts.stop();
    _currentlySpeakingMessageId = null;
    _pendingMessageId = null;
    _ttsStateController.add(null);
  }

  /// Reshapes a Yve response into something a TTS engine can read in a
  /// way that sounds like a calm tutor, not a rendering pipeline. The
  /// surface bugs we're solving:
  ///
  ///   • Raw `$x^2$` would be voiced as "dollar x caret 2 dollar"
  ///   • `**bold**` was previously stripped but headings still slipped
  ///     through with their `#` prefix
  ///   • Numbered lists "1. step" sounded like "1 dot step"
  ///   • Pipes from tables and `>` from blockquotes were spoken literally
  ///   • Emojis sometimes get spelled out by the engine ("sparkles")
  ///
  /// We never try to *render* math (that's the visual layer's job) — we
  /// just translate the common LaTeX vocabulary into spoken English so
  /// the listener can follow along. Anything we don't recognize gets
  /// dropped silently; better a beat of silence than dictation noise.
  @visibleForTesting
  static String cleanForSpeech(String text) {
    String t = text;

    // 1) Inline & display math: $...$ / $...$.
    //    Convert the LaTeX inside to spoken English, then drop the wrappers.
    t = t.replaceAllMapped(
      RegExp(r'\$\$([\s\S]+?)\$\$', multiLine: true),
      (Match m) => ' ${_latexToSpeech(m.group(1) ?? '')} ',
    );
    t = t.replaceAllMapped(
      RegExp(r'\$([^\$\n]+?)\$'),
      (Match m) => ' ${_latexToSpeech(m.group(1) ?? '')} ',
    );

    // 2) Block & inline structure. Patterns use non-greedy quantifiers
    // and dotAll where the marker pair might span multiple lines
    // (common in long polish output), and the simpler `[^*]+`-style
    // bodies are replaced with `.+?` so they don't fail when the
    // content contains nested emphasis characters or stray asterisks.
    t = t
        .replaceAll(RegExp(r'```[\s\S]*?```'), ' ')                  // fenced code
        // NOTE: Dart's String.replaceAll does NOT substitute capture
        // groups (unlike JS) — passing r'$1' inserts the literal text
        // "$1", which the later `$`-strip then turned into "1". That
        // corrupted every bold/italic/link in spoken answers. Use
        // replaceAllMapped + m.group(1) to keep the captured content.
        .replaceAllMapped(RegExp(r'`(.+?)`'), (Match m) => m.group(1) ?? '')                       // inline code
        .replaceAllMapped(RegExp(r'\*\*(.+?)\*\*', dotAll: true), (Match m) => m.group(1) ?? '')   // bold
        .replaceAllMapped(RegExp(r'__(.+?)__', dotAll: true), (Match m) => m.group(1) ?? '')       // bold (alt)
        .replaceAllMapped(RegExp(r'\*(.+?)\*', dotAll: true), (Match m) => m.group(1) ?? '')       // italic
        .replaceAllMapped(RegExp(r'(?<!_)_(.+?)_(?!_)', dotAll: true), (Match m) => m.group(1) ?? '') // italic (alt)
        .replaceAllMapped(RegExp(r'~~(.+?)~~', dotAll: true), (Match m) => m.group(1) ?? '')       // strikethrough
        .replaceAll(RegExp(r'^#{1,6}\s+', multiLine: true), '')       // ATX heading
        .replaceAll(RegExp(r'^={3,}|^-{3,}', multiLine: true), '')    // setext heading rules
        .replaceAll(RegExp(r'^>\s?', multiLine: true), '')            // blockquote
        .replaceAll(RegExp(r'^[\-\*\+]\s+', multiLine: true), '')     // bullets
        .replaceAll(RegExp(r'^\d+\.\s+', multiLine: true), '')        // numbered lists
        .replaceAllMapped(RegExp(r'\[([^\]]+)\]\([^)]+\)'), (Match m) => m.group(1) ?? '')         // links → label
        .replaceAll(RegExp(r'!\[[^\]]*\]\([^)]+\)'), '')              // images → gone
        .replaceAll(RegExp(r'\|'), ' ')                               // table separators
        .replaceAll(RegExp(r'<[^>]+>'), '')                           // stray html
        // Belt-and-suspenders: any stray `*` or `_` left over from a
        // mismatched pair should never reach the TTS engine — they
        // get spoken as "asterisk" / "underscore" otherwise.
        .replaceAll(RegExp(r'\*+'), '')
        // Strip any orphan `$` that survived the math step (mismatched
        // pair, raw dollar in source text, etc.) — TTS pronounces $
        // as "dollar" otherwise and the listener panics.
        .replaceAll(RegExp(r'\$+'), '')
        .replaceAll('✦', '')
        .replaceAll('—', ', ')                                        // em dash → comma pause
        .replaceAll('–', ', ')                                        // en dash → comma pause
        .replaceAll(RegExp(r'\n{2,}'), '. ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();

    // 3) Trim trailing punctuation pile-ups from list/heading stripping.
    t = t.replaceAll(RegExp(r'\s+([.,;:])'), r'$1');
    t = t.replaceAll(RegExp(r'([.,;:]){2,}'), r'$1');
    return t;
  }

  /// Kept for callers inside this file; the public API is the static.
  String _cleanForSpeech(String text) => cleanForSpeech(text);

  // ── LaTeX → spoken English ─────────────────────────────────────────
  static const Map<String, String> _latexLiterals = <String, String>{
    // Greek
    r'\alpha': 'alpha', r'\beta': 'beta', r'\gamma': 'gamma',
    r'\delta': 'delta', r'\epsilon': 'epsilon', r'\zeta': 'zeta',
    r'\eta': 'eta', r'\theta': 'theta', r'\iota': 'iota',
    r'\kappa': 'kappa', r'\lambda': 'lambda', r'\mu': 'mu',
    r'\nu': 'nu', r'\xi': 'xi', r'\pi': 'pi', r'\rho': 'rho',
    r'\sigma': 'sigma', r'\tau': 'tau', r'\phi': 'phi',
    r'\chi': 'chi', r'\psi': 'psi', r'\omega': 'omega',
    r'\Gamma': 'capital gamma', r'\Delta': 'capital delta',
    r'\Theta': 'capital theta', r'\Lambda': 'capital lambda',
    r'\Pi': 'capital pi', r'\Sigma': 'capital sigma',
    r'\Phi': 'capital phi', r'\Omega': 'capital omega',
    // Operators
    r'\cdot': 'times', r'\times': 'times', r'\div': 'divided by',
    r'\pm': 'plus or minus', r'\mp': 'minus or plus',
    r'\leq': 'less than or equal to', r'\le': 'less than or equal to',
    r'\geq': 'greater than or equal to', r'\ge': 'greater than or equal to',
    r'\neq': 'not equal to', r'\ne': 'not equal to',
    r'\approx': 'approximately', r'\equiv': 'is equivalent to',
    r'\propto': 'is proportional to', r'\sim': 'similar to',
    r'\to': 'goes to', r'\rightarrow': 'goes to', r'\Rightarrow': 'implies',
    r'\leftarrow': 'comes from', r'\Leftrightarrow': 'if and only if',
    r'\infty': 'infinity', r'\partial': 'partial',
    r'\nabla': 'nabla', r'\sum': 'sum', r'\prod': 'product',
    r'\int': 'integral', r'\oint': 'contour integral', r'\lim': 'limit',
    r'\sin': 'sine', r'\cos': 'cosine', r'\tan': 'tangent',
    r'\log': 'log', r'\ln': 'natural log', r'\exp': 'exponential',
    r'\sqrt': 'square root', r'\in': 'is in', r'\notin': 'is not in',
    r'\subset': 'subset of', r'\supset': 'superset of',
    r'\cup': 'union', r'\cap': 'intersection',
    r'\emptyset': 'empty set', r'\forall': 'for all', r'\exists': 'there exists',
    // Common typography
    r'\\': ',', r'\,': ' ', r'\;': ' ', r'\:': ' ', r'\!': '',
    r'\left': '', r'\right': '', r'\,\!': '',
    r'\text': '',
  };

  /// Best-effort LaTeX → English. Not a real math TTS — just enough so
  /// "$\frac{1}{2}$" reads as "1 over 2" instead of dictation noise.
  static String _latexToSpeech(String latex) {
    String s = latex;

    // Strip math environments / structural macros.
    s = s.replaceAll(RegExp(r'\\begin\{[^}]+\}|\\end\{[^}]+\}'), ' ');
    s = s.replaceAll(RegExp(r'\\tag\{[^}]*\}|\\label\{[^}]*\}|\\nonumber'), ' ');

    // \frac{a}{b} → "a over b". Apply twice to catch a couple nesting levels.
    final RegExp frac = RegExp(r'\\(?:d?frac|tfrac)\s*\{([^{}]+)\}\s*\{([^{}]+)\}');
    for (int i = 0; i < 3; i++) {
      if (!frac.hasMatch(s)) break;
      s = s.replaceAllMapped(frac, (Match m) => '(${m.group(1)}) over (${m.group(2)})');
    }

    // \sqrt{x} → "square root of x"
    s = s.replaceAllMapped(
      RegExp(r'\\sqrt\s*\{([^{}]+)\}'),
      (Match m) => 'square root of ${m.group(1)}',
    );

    // x^{2} or x^2 → "x squared" / "x cubed" / "x to the N"
    s = s.replaceAllMapped(
      RegExp(r'\^(?:\{([^{}]+)\}|(\w))'),
      (Match m) {
        final String exp = (m.group(1) ?? m.group(2) ?? '').trim();
        if (exp == '2') return ' squared';
        if (exp == '3') return ' cubed';
        return ' to the $exp';
      },
    );

    // x_{n} or x_n → "x sub n"
    s = s.replaceAllMapped(
      RegExp(r'_(?:\{([^{}]+)\}|(\w))'),
      (Match m) => ' sub ${(m.group(1) ?? m.group(2) ?? '').trim()}',
    );

    // Literal macro substitution (apply longest-first so \leq beats \le).
    final List<String> keys = _latexLiterals.keys.toList()
      ..sort((String a, String b) => b.length.compareTo(a.length));
    for (final String key in keys) {
      s = s.replaceAll(key, ' ${_latexLiterals[key]!} ');
    }

    // Remove any remaining \command{...} we didn't translate, keep the inside.
    s = s.replaceAllMapped(
      RegExp(r'\\[a-zA-Z]+\s*\{([^{}]*)\}'),
      (Match m) => m.group(1) ?? '',
    );

    // Drop leftover braces and stray commands.
    s = s.replaceAll(RegExp(r'\\[a-zA-Z]+'), '');
    s = s.replaceAll(RegExp(r'[{}]'), '');

    // Tidy spacing.
    s = s.replaceAll(RegExp(r'\s+'), ' ').trim();
    return s;
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
