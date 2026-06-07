import 'dart:async';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';
import 'package:url_launcher/url_launcher.dart';

import '../config/billing_config.dart';
import '../models/chat_message.dart';
import '../models/chat_stream_event.dart';
import '../models/entitlement.dart';
import '../models/learner_profile.dart';
import '../models/polish.dart';
import '../models/scan_result.dart';
import '../models/study_mode.dart';
import '../models/subject.dart';
import '../models/yve_response.dart';
import '../services/ai_service.dart';
import '../services/profile_service.dart';
import '../services/retention_service.dart';
import '../services/sessions_service.dart';
import '../services/subjects_service.dart';
import '../services/vision_service.dart';
import '../services/voice_service.dart';
import '../utils/app_error.dart';
import '../widgets/anonymous_continuation_panel.dart';
import '../widgets/mode_switcher.dart';
import '../widgets/polish_bubble.dart';
import '../widgets/quota_exceeded_card.dart';
import '../widgets/response_actions_menu.dart';
import '../widgets/save_to_subject_sheet.dart';
import '../widgets/scan_result_sheet.dart';
import '../widgets/speak_aloud_button.dart';
import '../widgets/upgrade_sheet.dart';
import '../widgets/voice_input_button.dart';
import '../widgets/yve_markdown.dart';
import '../widgets/yve_pill.dart';
import '../widgets/yve_reading_overlay.dart';
import '../theme/yve_colors.dart';
import '../theme/yve_spacing.dart';

/// Yve Chat — the core experience. Every workflow lands here.
///
/// The conversion engine drives the follow-up ladder: Yve's responses carry
/// generated chip suggestions (not hardcoded) that map to the concepts she
/// just taught. A mode switcher in the header lets the learner pivot from
/// "solve this" to "quiz me on it" without losing context.
class ChatScreen extends ConsumerStatefulWidget {
  const ChatScreen({
    super.key,
    this.subjectId,
    this.subjectName,
    this.subjectEmoji,
    this.initialDraft,
    this.initialTitle,
    this.initialMode = StudyMode.open,
    this.resumeSessionId,
  });

  /// Resume an existing chat. The screen loads the persisted message history
  /// from `chat_messages` before allowing new turns. [initialDraft] is the
  /// optional follow-up message to pre-fill in the input (used by the Scan
  /// flow to drop the chosen action's prompt into a one-tap-send state).
  const ChatScreen.resume({
    Key? key,
    required String sessionId,
    required String sessionTitle,
    String? subjectId,
    String? subjectName,
    String? subjectEmoji,
    StudyMode initialMode = StudyMode.open,
    String? initialDraft,
  }) : this(
          key: key,
          resumeSessionId: sessionId,
          initialTitle: sessionTitle,
          subjectId: subjectId,
          subjectName: subjectName,
          subjectEmoji: subjectEmoji,
          initialMode: initialMode,
          initialDraft: initialDraft,
        );

  final String? subjectId;
  final String? subjectName;
  final String? subjectEmoji;
  final String? initialDraft;
  final String? initialTitle;
  final StudyMode initialMode;
  final String? resumeSessionId;

  @override
  ConsumerState<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends ConsumerState<ChatScreen> {
  /// Max attachments accepted in a single batch. Each one is a sequential
  /// vision-ingest call, so an uncapped pick (40 photos) means a long,
  /// quota-draining batch and possible Edge-function rate-limiting. 5 keeps
  /// "Reading 4 of 5…" fast while covering the realistic worksheet case.
  static const int _maxBatchFiles = 5;

  /// Per-image byte ceiling. Mirrors the 25 MB guard already applied to
  /// PDFs/DOCX so a giant photo can't blow the vision-ingest payload.
  static const int _maxAttachmentBytes = 25 * 1024 * 1024;

  final TextEditingController _input = TextEditingController();
  final ScrollController _scroll = ScrollController();
  final List<ChatMessage> _messages = <ChatMessage>[];
  final ImagePicker _picker = ImagePicker();
  StreamSubscription<ChatStreamEvent>? _activeStream;
  StreamSubscription<String>? _voiceTextSub;
  StreamSubscription<bool>? _voiceListeningSub;
  StreamSubscription<String?>? _ttsCompletionSub;
  bool _sending = false;
  bool _loadingHistory = false;
  bool _scanning = false;
  bool _listening = false;
  bool _inAutoLoop = false;
  bool _handsFreePausedForSession = false;
  QuotaExceeded? _quotaHit;
  String _voicePrefix = '';
  late String _title = widget.initialTitle ?? 'New session';
  late StudyMode _mode = widget.initialMode;
  String? _sessionId;

  /// Write-mode sub-action. 'polish' improves the learner's own draft;
  /// 'humanize' rewrites likely-AI text to read human while keeping the
  /// meaning. Only surfaced/used when [_mode] is [StudyMode.write].
  String _writeIntent = 'polish';

  /// Smart actions surfaced right after a multi-question worksheet
  /// upload in Assignment mode. The learner came here to get the work
  /// solved — these chips capture intent in one tap instead of forcing
  /// them to type "answer all questions" (the bug the user hit on
  /// 2026-05-19). Cleared on first send.
  List<_SmartAction>? _smartActions;

  /// Extracted text from a batch attach (2+ files at once). Stays out of
  /// the input box (could be tens of thousands of words) and gets
  /// prepended to the next outgoing message — typed or smart-action.
  /// The pending-attachment pill shows learners what's queued and lets
  /// them discard it before sending.
  String? _pendingAttachmentText;
  List<String> _pendingAttachmentNames = const <String>[];

  /// Batch-scan progress for the reading overlay — "Reading 2 of 5…"
  /// is less anxiety-inducing than an indeterminate spinner when the
  /// learner just uploaded a fistful of PDFs.
  int _batchTotal = 0;
  int _batchProgress = 0;

  /// Cached VoiceService so dispose() can stop any in-flight TTS/STT
  /// without calling `ref.read`. ConsumerStatefulElement disposes ref
  /// before our dispose() runs, so a `ref.read` here throws
  /// `Cannot use "ref" after the widget was disposed` (caught in
  /// Sentry 2026-05-18).
  VoiceService? _voice;

  @override
  void initState() {
    super.initState();
    if (widget.initialDraft != null && widget.initialDraft!.isNotEmpty) {
      _input.text = widget.initialDraft!;
    }
    if (widget.resumeSessionId != null) {
      _sessionId = widget.resumeSessionId;
      _loadingHistory = true;
      WidgetsBinding.instance.addPostFrameCallback((_) => _loadHistory());
    }
    // Voice plumbing: recognized text replaces the live tail of the input
    // (everything after the prefix that was already there when we started
    // listening). This way the learner can keep typed context and add
    // spoken words on top without losing either.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final VoiceService voice = ref.read(voiceServiceProvider);
      _voice = voice; // cache for dispose()
      _voiceTextSub = voice.recognizedText.listen((String recognized) {
        if (!mounted) return;
        // A late voice event arriving *during* send would overwrite the
        // input we just cleared — mom kept seeing her last question
        // sitting in the box after sending it. Guard with _sending so
        // post-send events get dropped.
        if (_sending) return;
        if (!_listening) return;
        _input.text = '$_voicePrefix$recognized'.trimLeft();
        _input.selection = TextSelection.collapsed(offset: _input.text.length);
      });
      _voiceListeningSub = voice.listeningChanged.listen((bool isListening) {
        if (!mounted) return;
        setState(() => _listening = isListening);
        // Auto-send when STT ends inside the hands-free loop. Tapping the
        // mic manually also ends listening — we still auto-send in that
        // case because the user is in hands-free mode and dictation is the
        // commit signal regardless of how it terminated.
        if (!isListening && _inAutoLoop) {
          _inAutoLoop = false;
          final String text = _input.text.trim();
          if (text.isEmpty) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text(
                  'Hands-free paused — no voice detected. Tap the mic to resume.',
                ),
              ),
            );
          } else {
            _send();
          }
        }
      });
      // Yve finishing a spoken turn is the cue to re-open the mic in the
      // hands-free loop. We hook the TTS state stream (emits null when
      // speaking stops) and gate on profile.handsFreeActive at fire time
      // so toggling the preference takes effect on the next turn.
      _ttsCompletionSub = voice.speakingMessageId.listen((String? id) {
        if (id != null) return; // speaking just started, not ended
        _maybeStartAutoListen();
      });
    });
  }

  Future<void> _loadHistory() async {
    final String? sid = _sessionId;
    if (sid == null) return;
    try {
      final List<ChatMessage> history = await ref
          .read(sessionsRepositoryProvider)
          .messages(sid);
      if (!mounted) return;
      setState(() {
        _messages
          ..clear()
          ..addAll(history);
        _loadingHistory = false;
      });
      _scrollToBottom();
    } catch (e) {
      if (!mounted) return;
      setState(() => _loadingHistory = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            AppError.from(e, actionContext: 'load_history').userMessage,
          ),
        ),
      );
    }
  }

  @override
  void dispose() {
    _activeStream?.cancel();
    _voiceTextSub?.cancel();
    _voiceListeningSub?.cancel();
    _ttsCompletionSub?.cancel();
    // Use the cached VoiceService — `ref` is unavailable in dispose().
    _voice?.stopListening();
    _voice?.stopSpeaking();
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  bool _handsFreeBannerVisible() {
    if (_handsFreePausedForSession) return false;
    final LearnerProfile? profile = ref.read(profileProvider).valueOrNull;
    return profile?.handsFreeActive ?? false;
  }

  /// Called when Yve's TTS finishes. If the profile says hands-free is on
  /// and we're in a clean idle state, auto-start STT for the next turn.
  Future<void> _maybeStartAutoListen() async {
    if (!mounted) return;
    final LearnerProfile? profile = ref.read(profileProvider).valueOrNull;
    if (profile == null || !profile.handsFreeActive) return;
    if (_handsFreePausedForSession) return;
    if (_sending || _scanning || _listening || _loadingHistory) return;
    if (_messages.isEmpty || _messages.last.role != ChatRole.yve) return;
    // Don't loop on error messages — _onStreamEvent stamps them with
    // empty offers and Yve-side italic copy; auto-listening after an error
    // would feel broken.
    if (_messages.last.text.startsWith('Sorry —')) return;
    _voicePrefix = '';
    _input.clear();
    _inAutoLoop = true;
    final VoiceService voice = ref.read(voiceServiceProvider);
    final bool ok = await voice.ensureSttReady();
    if (!ok) {
      _inAutoLoop = false;
      return;
    }
    await voice.startListening();
  }

  Future<void> _toggleVoiceInput() async {
    final VoiceService voice = ref.read(voiceServiceProvider);
    if (_listening) {
      await voice.stopListening();
      return;
    }
    final bool ok = await voice.ensureSttReady();
    if (!ok) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Voice input isn\'t available on this device.'),
        ),
      );
      return;
    }
    // Anchor what's currently typed; recognized words extend it.
    _voicePrefix =
        _input.text.isEmpty ? '' : '${_input.text.trimRight()} ';
    await voice.startListening();
  }

  /// Decide whether to surface the Assignment-mode "what should I do?"
  /// chip strip. Only fires when the chat just adopted an uploaded
  /// document AND we're in Assignment mode AND the doc looks like a
  /// multi-question worksheet (or has enough extracted text to suggest
  /// it). The chips disappear as soon as the learner sends anything.
  void _maybeOfferSmartActions(ScanResult sr) {
    if (_mode != StudyMode.assignment) return;
    final bool looksLikeWorksheet =
        sr.documentType == DocumentType.worksheet ||
            sr.extractedText.length > 600;
    if (!looksLikeWorksheet) return;
    setState(() {
      _smartActions = const <_SmartAction>[
        _SmartAction(
          label: 'Solve all questions',
          prompt:
              'Solve every question in this assignment, organized section by section. Answer all of them in full — short answers, true/false, multiple choice, scenarios, everything. Don\'t summarize and stop; work through the whole document.',
          filled: true,
        ),
        _SmartAction(
          label: 'Section by section',
          prompt:
              'Walk me through this assignment one section at a time. Solve Section 1 in full first, then pause and let me say "next" before continuing.',
        ),
        _SmartAction(
          label: 'Explain concepts first',
          prompt:
              'Before solving, give me a clear explanation of the key concepts this assignment covers. Then we can work through the questions together.',
        ),
      ];
    });
  }

  Future<void> _send([String? overrideText]) async {
    final String typed = (overrideText ?? _input.text).trim();
    // Multi-file batch attaches stash their combined extracted text here;
    // prepend it to the outgoing message so Yve sees the documents
    // regardless of whether the learner typed something themselves or
    // tapped a smart-action chip.
    final String pending = _pendingAttachmentText ?? '';
    final String text;
    if (pending.isEmpty) {
      text = typed;
    } else if (typed.isEmpty) {
      text = pending;
    } else {
      text = '$pending\n\n---\n\n$typed';
    }
    if (text.isEmpty || _sending) return;
    HapticFeedback.lightImpact();
    // First send clears the smart-action strip — once the learner has
    // expressed intent (via chip or typing), we hide the prompts.
    if (_smartActions != null) {
      setState(() => _smartActions = null);
    }
    // Pending attachment is consumed on send — no second-prepend on the
    // next turn. The user bubble already carries the full text.
    if (_pendingAttachmentText != null) {
      _pendingAttachmentText = null;
      _pendingAttachmentNames = const <String>[];
    }

    final ChatMessage userMsg = ChatMessage(
      id: 'u${DateTime.now().millisecondsSinceEpoch}',
      role: ChatRole.user,
      text: text,
      createdAt: DateTime.now(),
    );
    final String yveId = 'y${DateTime.now().millisecondsSinceEpoch}';
    final ChatMessage yvePlaceholder = ChatMessage(
      id: yveId,
      role: ChatRole.yve,
      text: '',
      createdAt: DateTime.now(),
      isStreaming: true,
    );

    // Stop the mic and reset voice state *before* we clear the field —
    // otherwise a late-arriving recognized-text event can re-populate
    // the input box right after we cleared it, leaving the user's words
    // lingering in the box even though they've already been sent.
    final VoiceService voice = ref.read(voiceServiceProvider);
    if (_listening) {
      unawaited(voice.stopListening());
    }
    _voicePrefix = '';

    setState(() {
      _messages.add(userMsg);
      _messages.add(yvePlaceholder);
      if (_messages.length == 2) {
        _title = _autoTitle(text);
      }
      _input.clear();
      _sending = true;
      // Clear any quota banner; a fresh attempt either succeeds (Plus
      // upgrade landed) or re-trips the gate and re-sets _quotaHit.
      _quotaHit = null;
    });
    _scrollToBottom();

    final Stream<ChatStreamEvent> stream = ref.read(aiServiceProvider).chatStream(
          mode: _mode,
          // Drop the placeholder Yve message we just added — server doesn't
          // need it (and shouldn't see an empty assistant turn in history).
          history: _messages.sublist(0, _messages.length - 1),
          subjectId: widget.subjectId,
          sessionId: _sessionId,
          writeIntent: _mode == StudyMode.write ? _writeIntent : null,
        );

    final Completer<void> completer = Completer<void>();
    _activeStream = stream.listen(
      (ChatStreamEvent event) => _onStreamEvent(yveId, event),
      onDone: () {
        if (!completer.isCompleted) completer.complete();
        _finalizeStream();
      },
      onError: (Object e) {
        _onStreamEvent(yveId, ChatStreamError(e.toString()));
        if (!completer.isCompleted) completer.complete();
        _finalizeStream();
      },
      cancelOnError: false,
    );
    await completer.future;
  }

  void _onStreamEvent(String yveId, ChatStreamEvent event) {
    if (!mounted) return;
    final int idx = _messages.indexWhere((ChatMessage m) => m.id == yveId);
    if (idx < 0) return;

    switch (event) {
      case ChatStreamStart(:final String sessionId):
        _sessionId ??= sessionId;
        return;
      case ChatStreamTextDelta(:final String delta):
        setState(() {
          _messages[idx] = _messages[idx].copyWith(
            text: _messages[idx].text + delta,
            isStreaming: true,
          );
        });
        _scrollToBottom();
        return;
      case ChatStreamMetadata(
          :final List<String> conceptTags,
          :final PostSolveOffer offer,
          :final String? saveToSubjectSuggestion,
        ):
        setState(() {
          _messages[idx] = _messages[idx].copyWith(
            offer: offer,
            conceptTags: conceptTags,
            saveToSubjectSuggestion: saveToSubjectSuggestion,
            isStreaming: false,
          );
        });
        HapticFeedback.selectionClick();
        _maybeAutoSpeak(_messages[idx]);
        _scrollToBottom();
        return;
      case ChatStreamDone():
        setState(() {
          _messages[idx] = _messages[idx].copyWith(isStreaming: false);
        });
        return;
      case ChatStreamError(:final String message):
        setState(() {
          final ChatMessage existing = _messages[idx];
          // If we already streamed some text, keep it and append the error
          // inline. If the bubble is still empty, replace its content.
          final String body = existing.text.isEmpty
              ? 'Sorry — I couldn\'t finish that response.\n\n_${message}_'
              : '${existing.text}\n\n_Connection dropped: ${message}_';
          _messages[idx] = existing.copyWith(
            text: body,
            isStreaming: false,
            offer: existing.offer ?? PostSolveOffer.generic(_mode),
          );
        });
        return;
      case ChatStreamPolish(:final Polish polish):
        // Write-mode arrival — the response is structured polish, not a
        // streamed markdown answer. Drop the placeholder bubble's text
        // (the polish UI takes over) and stash the polish payload so
        // _Bubble can render the PolishBubble specialization.
        setState(() {
          _messages[idx] = _messages[idx].copyWith(
            text: polish.polishedText,
            polish: polish,
            isStreaming: false,
          );
        });
        HapticFeedback.selectionClick();
        _scrollToBottom();
        return;
      case ChatStreamQuotaExceeded(:final QuotaExceeded quota):
        // Drop the empty Yve placeholder we added on send — the quota card
        // takes its place below the conversation. Restore the user's draft
        // so they can edit and try again after they upgrade.
        setState(() {
          final ChatMessage placeholder = _messages[idx];
          _messages.removeAt(idx);
          // The user message is at idx - 1; pull its text back into the
          // input so the learner doesn't lose it.
          if (idx - 1 >= 0 && _messages[idx - 1].role == ChatRole.user) {
            _input.text = _messages[idx - 1].text;
            _input.selection =
                TextSelection.collapsed(offset: _input.text.length);
            _messages.removeAt(idx - 1);
          }
          _quotaHit = quota;
          // placeholder is just GC'd; nothing to do with it.
          if (placeholder.id.isEmpty) {} // satisfy the analyzer
        });
        return;
    }
  }

  /// Auto-plays the just-finished Yve turn if the learner has "Read aloud"
  /// turned on in their profile. We trigger this on the metadata event (the
  /// stream's natural finish for the answer text) so we don't speak mid-
  /// stream chunks. Silent no-op when the preference is off or the message
  /// has no body.
  void _maybeAutoSpeak(ChatMessage msg) {
    final LearnerProfile? profile = ref.read(profileProvider).valueOrNull;
    if (profile == null || !profile.readAloud) return;
    if (msg.text.trim().isEmpty) return;
    ref.read(voiceServiceProvider).speak(msg.id, msg.text);
  }

  void _finalizeStream() {
    if (!mounted) return;
    setState(() => _sending = false);
    _activeStream = null;

    // Refresh sidebar lists so Home and Subject Workspace see the new turn,
    // including the retention surfaces that derive from concept observations.
    ref.invalidate(recentSessionsProvider);
    ref.invalidate(reviewQueueProvider);
    ref.invalidate(weekActivityProvider);
    if (widget.subjectId != null) {
      ref.invalidate(sessionsBySubjectProvider(widget.subjectId!));
    }
    _scrollToBottom();
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scroll.hasClients) return;
      _scroll.animateTo(
        _scroll.position.maxScrollExtent,
        duration: const Duration(milliseconds: 240),
        curve: Curves.easeOutCubic,
      );
    });
  }

  String _autoTitle(String firstMessage) {
    final String trimmed = firstMessage.trim();
    if (trimmed.length <= 36) return trimmed;
    return '${trimmed.substring(0, 33)}...';
  }

  void _onModeChanged(StudyMode m) {
    setState(() => _mode = m);
    // Inline whisper from Yve so the mode shift is felt, not silent.
    setState(() {
      _messages.add(
        ChatMessage(
          id: 'sys${DateTime.now().millisecondsSinceEpoch}',
          role: ChatRole.yve,
          text: '_Switched to ${m.label} mode — ${m.tagline.toLowerCase()}._',
          createdAt: DateTime.now(),
          offer: PostSolveOffer.generic(m),
        ),
      );
    });
    _scrollToBottom();
  }

  Future<void> _onOfferTap(OfferSuggestion s) async {
    if (s.kind == OfferKind.save) {
      await _saveCurrentExchange(suggested: null);
      return;
    }
    await _send(s.effectivePrompt);
  }

  /// Capture or pick image(s), run them through vision-ingest, then route
  /// based on count:
  ///  - 1 image  → existing single-file flow (session adoption / scan sheet).
  ///  - 2+ images → batch-process, combine extracted text into a pending
  ///    attachment that gets prepended to the learner's next message.
  ///    Camera is inherently one-shot; gallery uses pickMultiImage.
  Future<void> _scanIntoChat(ImageSource source) async {
    if (_scanning || _sending) return;
    HapticFeedback.lightImpact();

    List<XFile> files;
    try {
      if (source == ImageSource.gallery) {
        // NB: image_picker 1.0.7 has no native `limit:` param, so we cap
        // after the fact in the trim step below.
        files = await _picker.pickMultiImage(
          maxWidth: 1600,
          maxHeight: 1600,
          imageQuality: 85,
        );
      } else {
        final XFile? one = await _picker.pickImage(
          source: source,
          maxWidth: 1600,
          maxHeight: 1600,
          imageQuality: 85,
        );
        files = one == null ? <XFile>[] : <XFile>[one];
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            AppError.from(e, actionContext: 'open_camera').userMessage,
          ),
        ),
      );
      return;
    }
    if (files.isEmpty) return;

    // Enforce the batch cap. `limit:` is only honored on iOS 14+/Android,
    // so web and older platforms can still hand back more — trim and tell
    // the learner what we kept.
    final bool trimmed = files.length > _maxBatchFiles;
    if (trimmed) files = files.sublist(0, _maxBatchFiles);

    // Size guard: drop oversized images before they hit vision-ingest.
    final List<XFile> ok = <XFile>[];
    final List<String> rejected = <String>[];
    for (final XFile f in files) {
      if (await f.length() > _maxAttachmentBytes) {
        rejected.add('${f.name} (>25 MB)');
      } else {
        ok.add(f);
      }
    }
    if (mounted && (trimmed || rejected.isNotEmpty)) {
      final List<String> notes = <String>[
        if (trimmed) 'Added the first $_maxBatchFiles — that\'s the limit per batch.',
        if (rejected.isNotEmpty) 'Skipped: ${rejected.join(', ')}',
      ];
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(notes.join(' '))),
      );
    }
    if (ok.isEmpty) return;

    if (ok.length == 1) {
      await _processSingleImage(ok.first);
    } else {
      // Build pending-scan list and hand to the batch helper. Each entry
      // captures the async call so the helper doesn't care whether it's
      // an image or a file under the hood.
      final List<_PendingScan> scans = <_PendingScan>[];
      for (final XFile f in ok) {
        scans.add(_PendingScan(
          name: f.name,
          process: () async {
            final Uint8List bytes = await f.readAsBytes();
            return ref.read(visionServiceProvider).analyze(
                  bytes: bytes,
                  mimeType: _mimeFromName(f.name),
                  subjectId: widget.subjectId,
                );
          },
        ));
      }
      await _processBatchScans(scans);
    }
  }

  Future<void> _processSingleImage(XFile file) async {
    final Uint8List bytes = await file.readAsBytes();
    final String mime = _mimeFromName(file.name);

    setState(() => _scanning = true);
    try {
      final ScanResult result =
          await ref.read(visionServiceProvider).analyze(
                bytes: bytes,
                mimeType: mime,
                subjectId: widget.subjectId,
              );
      if (!mounted) return;

      // The scan created its own session. Two paths:
      //  - If THIS chat has no session yet (still empty), adopt the scan's.
      //  - Otherwise, surface the result sheet so the learner can either
      //    open the scan-session standalone or have the extracted text
      //    pasted in here as the next user turn.
      if (_sessionId == null && _messages.isEmpty) {
        _sessionId = result.sessionId;
        await _loadHistory();
        _maybeOfferSmartActions(result);
      } else {
        final ScanAction? action = await showScanResultSheet(
          context,
          result: result,
          imageBytes: bytes,
          onTypeInstead: () {
            // Drop the extracted text into the current chat as a draft.
            _input.text = '${_input.text}\n\n${result.extractedText}'.trim();
          },
        );
        if (action != null && mounted) {
          // Open the scan's session in the chosen mode.
          Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (_) => ChatScreen.resume(
                sessionId: result.sessionId,
                sessionTitle: result.oneLineSummary,
                initialMode: action.mode,
                initialDraft: action.prompt,
              ),
            ),
          );
        }
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            AppError.from(e, actionContext: 'scan').userMessage,
          ),
        ),
      );
    } finally {
      if (mounted) setState(() => _scanning = false);
    }
  }

  String _mimeFromName(String name) {
    final String lower = name.toLowerCase();
    if (lower.endsWith('.png')) return 'image/png';
    if (lower.endsWith('.webp')) return 'image/webp';
    if (lower.endsWith('.gif')) return 'image/gif';
    return 'image/jpeg';
  }

  /// Pick PDF/DOCX file(s) and route by count, mirroring [_scanIntoChat].
  /// `allowMultiple: true` so a learner with three worksheet PDFs can grab
  /// them in one go.
  Future<void> _scanFileIntoChat() async {
    if (_scanning || _sending) return;
    HapticFeedback.lightImpact();

    FilePickerResult? result;
    try {
      result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: const <String>['pdf', 'docx'],
        withData: true,
        allowMultiple: true,
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            AppError.from(e, actionContext: 'file_picker').userMessage,
          ),
        ),
      );
      return;
    }
    if (result == null || result.files.isEmpty) return;

    // file_picker has no built-in count cap, so trim to the batch limit
    // before validating.
    final bool trimmed = result.files.length > _maxBatchFiles;
    final List<PlatformFile> picked =
        trimmed ? result.files.sublist(0, _maxBatchFiles) : result.files;

    // Validate each file up-front (size + readable bytes) so we don't
    // get half-way through a 5-file batch before realising one is bad.
    final List<PlatformFile> ok = <PlatformFile>[];
    final List<String> rejected = <String>[];
    for (final PlatformFile f in picked) {
      if (f.bytes == null) {
        rejected.add('${f.name} (unreadable)');
        continue;
      }
      if (f.bytes!.lengthInBytes > _maxAttachmentBytes) {
        rejected.add('${f.name} (>25 MB)');
        continue;
      }
      ok.add(f);
    }
    if (mounted && (trimmed || rejected.isNotEmpty)) {
      final List<String> notes = <String>[
        if (trimmed) 'Added the first $_maxBatchFiles — that\'s the limit per batch.',
        if (rejected.isNotEmpty) 'Skipped: ${rejected.join(', ')}',
      ];
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(notes.join(' '))),
      );
    }
    if (ok.isEmpty) return;

    if (ok.length == 1) {
      await _processSingleFile(ok.first);
    } else {
      final List<_PendingScan> scans = <_PendingScan>[];
      for (final PlatformFile f in ok) {
        final bool isDocx = f.name.toLowerCase().endsWith('.docx');
        scans.add(_PendingScan(
          name: f.name,
          process: () => isDocx
              ? ref.read(visionServiceProvider).analyzeDocx(
                    bytes: f.bytes!,
                    name: f.name,
                    subjectId: widget.subjectId,
                  )
              : ref.read(visionServiceProvider).analyzePdf(
                    bytes: f.bytes!,
                    name: f.name,
                    subjectId: widget.subjectId,
                  ),
        ));
      }
      await _processBatchScans(scans);
    }
  }

  Future<void> _processSingleFile(PlatformFile file) async {
    final Uint8List bytes = file.bytes!;
    final bool isDocx = file.name.toLowerCase().endsWith('.docx');

    setState(() => _scanning = true);
    try {
      final ScanResult sr = isDocx
          ? await ref.read(visionServiceProvider).analyzeDocx(
                bytes: bytes,
                name: file.name,
                subjectId: widget.subjectId,
              )
          : await ref.read(visionServiceProvider).analyzePdf(
                bytes: bytes,
                name: file.name,
                subjectId: widget.subjectId,
              );
      if (!mounted) return;

      if (_sessionId == null && _messages.isEmpty) {
        _sessionId = sr.sessionId;
        await _loadHistory();
        _maybeOfferSmartActions(sr);
      } else {
        final ScanAction? action = await showScanResultSheet(
          context,
          result: sr,
          // No imageBytes for PDFs — the sheet renders a doc-type thumbnail.
          onTypeInstead: () {
            _input.text = '${_input.text}\n\n${sr.extractedText}'.trim();
          },
        );
        if (action != null && mounted) {
          Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (_) => ChatScreen.resume(
                sessionId: sr.sessionId,
                sessionTitle: sr.oneLineSummary,
                initialMode: action.mode,
                initialDraft: action.prompt,
              ),
            ),
          );
        }
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            AppError.from(e, actionContext: 'read_file').userMessage,
          ),
        ),
      );
    } finally {
      if (mounted) setState(() => _scanning = false);
    }
  }

  /// Batch processor for 2+ attachments. Runs vision-ingest sequentially
  /// (parallel would hammer the Edge function and risk per-user rate
  /// limits), tracks progress for the overlay, and stashes the combined
  /// extracted text as a pending attachment that gets prepended to the
  /// next outgoing message.
  ///
  /// We deliberately skip the session-adoption / scan-result-sheet path
  /// the single-file flow uses — multi-file is the "I just want this
  /// done" gesture, so the destination is always *this* chat, never a
  /// branched session.
  Future<void> _processBatchScans(List<_PendingScan> scans) async {
    setState(() {
      _scanning = true;
      _batchTotal = scans.length;
      _batchProgress = 0;
    });

    final List<_BatchResult> processed = <_BatchResult>[];
    final List<String> failed = <String>[];

    try {
      for (int i = 0; i < scans.length; i++) {
        final _PendingScan s = scans[i];
        if (mounted) setState(() => _batchProgress = i + 1);
        try {
          final ScanResult sr = await s.process();
          if (sr.extractedText.trim().isEmpty) {
            failed.add(s.name);
          } else {
            processed.add(_BatchResult(
              name: s.name,
              extractedText: sr.extractedText.trim(),
            ));
          }
        } catch (_) {
          failed.add(s.name);
        }
      }
    } finally {
      if (mounted) {
        setState(() {
          _scanning = false;
          _batchTotal = 0;
          _batchProgress = 0;
        });
      }
    }

    if (!mounted) return;

    if (processed.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text("Couldn't read any of those files. Try again?"),
        ),
      );
      return;
    }

    // Build the combined attachment block. Each doc is fenced with its
    // filename so Yve can address questions per-document if the learner
    // asks (e.g. "answer page 2 of worksheet2.pdf").
    final StringBuffer buf = StringBuffer();
    buf.write(
      processed.length == 1
          ? 'Attached document:\n\n'
          : 'Attached ${processed.length} documents:\n\n',
    );
    for (int i = 0; i < processed.length; i++) {
      final _BatchResult r = processed[i];
      buf.writeln('--- ${r.name} ---');
      buf.writeln(r.extractedText);
      if (i < processed.length - 1) buf.writeln();
    }

    setState(() {
      _pendingAttachmentText = buf.toString().trimRight();
      _pendingAttachmentNames =
          processed.map((_BatchResult r) => r.name).toList();
      // Surface the assignment smart actions so the most common next
      // step ("solve all") is one tap away. Only meaningful in
      // Assignment mode; cleared on first send like the single-file
      // path.
      if (_mode == StudyMode.assignment) {
        _smartActions = const <_SmartAction>[
          _SmartAction(
            label: 'Solve all questions',
            prompt:
                'Solve every question in these documents, organized by document and section. Answer all of them in full — short answers, true/false, multiple choice, scenarios, everything. Don\'t summarize and stop; work through everything.',
            filled: true,
          ),
          _SmartAction(
            label: 'Section by section',
            prompt:
                'Walk me through these documents one section at a time. Solve the first section in full, then pause and let me say "next" before continuing.',
          ),
          _SmartAction(
            label: 'Explain concepts first',
            prompt:
                'Before solving, give me a clear explanation of the key concepts these documents cover. Then we can work through the questions together.',
          ),
        ];
      }
    });

    if (failed.isNotEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text("Couldn't read: ${failed.join(', ')}")),
      );
    }
  }

  Future<void> _saveCurrentExchange({required String? suggested}) async {
    final List<Subject> subjectList =
        ref.read(subjectsProvider).valueOrNull ?? const <Subject>[];
    final Subject? selected = await showSaveToSubjectSheet(
      context,
      subjects: subjectList,
      suggested: suggested,
    );
    if (selected != null && mounted) {
      HapticFeedback.lightImpact();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Saved to ${selected.name}.')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final ChatMessage? lastYve =
        _messages.lastWhereOrNull((ChatMessage m) => m.role == ChatRole.yve);
    final String? saveSuggestion = lastYve?.saveToSubjectSuggestion;

    return Scaffold(
      body: Stack(
        children: <Widget>[
          _buildChatColumn(saveSuggestion, lastYve),
          if (_scanning)
            Positioned.fill(
              child: YveReadingOverlay(
                message: _batchTotal > 1
                    ? 'Yve is reading $_batchProgress of $_batchTotal…'
                    : 'Yve is reading your scan…',
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildChatColumn(String? saveSuggestion, ChatMessage? lastYve) {
    return Column(
        children: <Widget>[
          _ChatHeader(
            title: _title,
            subjectName: widget.subjectName,
            subjectEmoji: widget.subjectEmoji,
            onBack: () => Navigator.of(context).maybePop(),
          ),
          Container(
            color: YveColors.surface,
            padding: const EdgeInsets.only(bottom: YveSpacing.sm),
            child: ModeSwitcher(
              current: _mode,
              onChanged: _onModeChanged,
            ),
          ),
          if (_handsFreeBannerVisible())
            _HandsFreeBanner(
              listening: _listening,
              onPause: () {
                setState(() => _handsFreePausedForSession = true);
                final VoiceService voice = ref.read(voiceServiceProvider);
                voice.stopListening();
                voice.stopSpeaking();
                _inAutoLoop = false;
              },
            ),
          if (saveSuggestion != null && !_sending)
            _SaveSuggestionBanner(
              subjectName: saveSuggestion,
              onTap: () => _saveCurrentExchange(suggested: saveSuggestion),
              onDismiss: () {
                if (lastYve == null) return;
                setState(() {
                  final int idx = _messages.indexOf(lastYve);
                  _messages[idx] = lastYve.copyWith(
                    clearSaveToSubjectSuggestion: true,
                  );
                });
              },
            ),
          Expanded(
            child: _loadingHistory
                ? const Center(child: CircularProgressIndicator())
                : (_messages.isEmpty && _quotaHit == null)
                    ? _EmptyChat(
                        mode: _mode,
                        // Assignment mode surfaces the attach CTAs in its
                        // empty state — the same handlers the paperclip
                        // uses. Other modes ignore these and show the
                        // minimal icon+tagline.
                        onCamera: () => _scanIntoChat(ImageSource.camera),
                        onGallery: () => _scanIntoChat(ImageSource.gallery),
                        onFile: _scanFileIntoChat,
                      )
                    : ListView.builder(
                        controller: _scroll,
                        padding: const EdgeInsets.all(YveSpacing.lg),
                        itemCount:
                            _messages.length + (_quotaHit != null ? 1 : 0),
                        itemBuilder: (BuildContext context, int i) {
                          if (i == _messages.length && _quotaHit != null) {
                            return QuotaExceededCard(
                              quota: _quotaHit!,
                              upgradeEnabled: BillingConfig.upgradeEnabled,
                              onUpgrade: () {
                                showUpgradeSheet(context);
                              },
                            );
                          }
                          return _Bubble(
                            message: _messages[i],
                            onOfferTap: _onOfferTap,
                            subjectName: widget.subjectName,
                            sessionTitle: _title,
                            mode: _mode,
                          );
                        },
                      ),
          ),
          if (_pendingAttachmentNames.isNotEmpty)
            _PendingAttachmentPill(
              names: _pendingAttachmentNames,
              onClear: () {
                setState(() {
                  _pendingAttachmentText = null;
                  _pendingAttachmentNames = const <String>[];
                });
              },
            ),
          if (_smartActions != null && _smartActions!.isNotEmpty)
            _SmartActionsBar(
              actions: _smartActions!,
              onTap: (_SmartAction a) => _send(a.prompt),
            ),
          // Write mode exposes a Polish/Humanize switch right above the
          // input so the learner picks the action before sending. Hidden
          // in every other mode.
          if (_mode == StudyMode.write && _quotaHit == null)
            _WriteIntentToggle(
              intent: _writeIntent,
              enabled: !_sending,
              onChanged: (String next) {
                if (next == _writeIntent) return;
                HapticFeedback.selectionClick();
                setState(() => _writeIntent = next);
              },
            ),
          _InputBar(
            controller: _input,
            sending: _sending || _scanning,
            listening: _listening,
            // When an anonymous user hits the lifetime cap, lock the
            // entire input so they can't keep typing/sending into a
            // wall. The QuotaExceededCard above the input is the only
            // path forward — sign in. Tapping the disabled input
            // re-shows the continuation panel so the user isn't lost.
            blocked: _quotaHit?.kind == CapKind.anonymousLimit,
            onBlockedTap: () => showAnonymousContinuation(
              context,
              title: 'Save your work to Yve',
              body: 'You\'ve finished your first assignment with Yve. '
                  'Create a free account to keep going, save what you '
                  'have, and pick up where you left off tomorrow.',
            ),
            onSend: () => _send(),
            onMic: _toggleVoiceInput,
            onAttach: () {
              showModalBottomSheet<void>(
                context: context,
                builder: (_) => _AttachSheet(
                  onCamera: () {
                    Navigator.of(context).pop();
                    _scanIntoChat(ImageSource.camera);
                  },
                  onGallery: () {
                    Navigator.of(context).pop();
                    _scanIntoChat(ImageSource.gallery);
                  },
                  onFile: () {
                    Navigator.of(context).pop();
                    _scanFileIntoChat();
                  },
                ),
              );
            },
          ),
        ],
    );
  }
}

extension<T> on Iterable<T> {
  T? lastWhereOrNull(bool Function(T) test) {
    T? match;
    for (final T item in this) {
      if (test(item)) match = item;
    }
    return match;
  }
}

class _ChatHeader extends StatelessWidget {
  const _ChatHeader({
    required this.title,
    required this.onBack,
    this.subjectName,
    this.subjectEmoji,
  });

  final String title;
  final VoidCallback onBack;
  final String? subjectName;
  final String? subjectEmoji;

  @override
  Widget build(BuildContext context) {
    final double topInset = MediaQuery.of(context).padding.top;
    return Container(
      decoration: const BoxDecoration(
        color: YveColors.surface,
        border: Border(bottom: BorderSide(color: YveColors.borderSubtle)),
      ),
      padding: EdgeInsets.fromLTRB(
        YveSpacing.lg,
        topInset + 12,
        YveSpacing.lg,
        12,
      ),
      child: Row(
        children: <Widget>[
          IconButton(
            onPressed: onBack,
            icon: const Icon(Icons.arrow_back_rounded,
                color: YveColors.primary),
            padding: EdgeInsets.zero,
            visualDensity: VisualDensity.compact,
          ),
          const SizedBox(width: YveSpacing.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                if (subjectName != null)
                  Text(
                    '${subjectEmoji ?? '✦'}  ${subjectName!.toUpperCase()}',
                    style: const TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      color: YveColors.accent,
                      letterSpacing: 0.5,
                    ),
                  ),
                Text(
                  title,
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                    color: YveColors.textPrimary,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          const Icon(Icons.more_horiz_rounded, color: YveColors.textSecondary),
        ],
      ),
    );
  }
}

class _SaveSuggestionBanner extends StatelessWidget {
  const _SaveSuggestionBanner({
    required this.subjectName,
    required this.onTap,
    required this.onDismiss,
  });

  final String subjectName;
  final VoidCallback onTap;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.fromLTRB(
        YveSpacing.lg,
        YveSpacing.sm,
        YveSpacing.lg,
        0,
      ),
      decoration: BoxDecoration(
        color: YveColors.primarySurface,
        borderRadius: YveSpacing.cardRadius,
      ),
      child: Material(
        color: Colors.transparent,
        borderRadius: YveSpacing.cardRadius,
        child: InkWell(
          onTap: onTap,
          borderRadius: YveSpacing.cardRadius,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(
              YveSpacing.md,
              YveSpacing.md,
              YveSpacing.sm,
              YveSpacing.md,
            ),
            child: Row(
              children: <Widget>[
                const Icon(Icons.bookmark_add_rounded,
                    size: 18, color: YveColors.primary),
                const SizedBox(width: YveSpacing.sm),
                Expanded(
                  child: Text(
                    'Save this to $subjectName?',
                    style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: YveColors.primary,
                    ),
                  ),
                ),
                IconButton(
                  onPressed: onDismiss,
                  icon: const Icon(Icons.close_rounded,
                      size: 16, color: YveColors.textSecondary),
                  padding: EdgeInsets.zero,
                  constraints:
                      const BoxConstraints(minWidth: 28, minHeight: 28),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Slim pill that lets the learner know the hands-free loop is active and
/// gives them a one-tap way to pause it for this chat without flipping the
/// persistent profile preference.
class _HandsFreeBanner extends StatelessWidget {
  const _HandsFreeBanner({required this.listening, required this.onPause});

  final bool listening;
  final VoidCallback onPause;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.fromLTRB(
        YveSpacing.lg,
        YveSpacing.sm,
        YveSpacing.lg,
        0,
      ),
      padding:
          const EdgeInsets.symmetric(horizontal: YveSpacing.md, vertical: 8),
      decoration: BoxDecoration(
        color: YveColors.primarySurface,
        borderRadius: YveSpacing.pillRadius,
      ),
      child: Row(
        children: <Widget>[
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(
              color: listening ? YveColors.error : YveColors.accent,
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              listening
                  ? 'Hands-free • listening for you'
                  : 'Hands-free • Yve will listen after she speaks',
              style: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: YveColors.primary,
              ),
            ),
          ),
          InkWell(
            onTap: onPause,
            borderRadius: BorderRadius.circular(6),
            child: const Padding(
              padding: EdgeInsets.symmetric(horizontal: 6, vertical: 4),
              child: Text(
                'Pause',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  color: YveColors.primaryLight,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _EmptyChat extends StatelessWidget {
  const _EmptyChat({
    required this.mode,
    this.onCamera,
    this.onGallery,
    this.onFile,
  });
  final StudyMode mode;

  /// Attach handlers — only surfaced in Assignment mode where the
  /// "how do I even use this?" question has a concrete answer.
  /// Null for other modes (and they don't render the buttons).
  final VoidCallback? onCamera;
  final VoidCallback? onGallery;
  final VoidCallback? onFile;

  @override
  Widget build(BuildContext context) {
    if (mode == StudyMode.assignment &&
        onCamera != null &&
        onGallery != null &&
        onFile != null) {
      return _AssignmentEmptyState(
        onCamera: onCamera!,
        onGallery: onGallery!,
        onFile: onFile!,
      );
    }

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(YveSpacing.xxxl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Container(
              width: 64,
              height: 64,
              decoration: BoxDecoration(
                color: mode.tint,
                shape: BoxShape.circle,
              ),
              child: Center(
                child: Icon(mode.icon, size: 28, color: mode.iconColor),
              ),
            ),
            const SizedBox(height: YveSpacing.md),
            Text(
              mode == StudyMode.open ? 'Ask Yve anything' : mode.label,
              style: Theme.of(context).textTheme.titleSmall,
            ),
            const SizedBox(height: 4),
            Text(
              mode.tagline,
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontSize: 13,
                color: YveColors.textSecondary,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Write-mode action switch: Polish (improve the learner's own draft) vs
/// Humanize (rewrite likely-AI text to read human, meaning preserved).
/// Sits just above the input bar. A small caption under the segmented
/// control states the honest detector position for the Humanize action.
class _WriteIntentToggle extends StatelessWidget {
  const _WriteIntentToggle({
    required this.intent,
    required this.onChanged,
    required this.enabled,
  });

  final String intent;
  final ValueChanged<String> onChanged;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final bool isHumanize = intent == 'humanize';
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(
        YveSpacing.lg,
        YveSpacing.sm,
        YveSpacing.lg,
        YveSpacing.sm,
      ),
      decoration: const BoxDecoration(
        color: YveColors.surface,
        border: Border(top: BorderSide(color: YveColors.borderSubtle)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Container(
            padding: const EdgeInsets.all(3),
            decoration: BoxDecoration(
              color: YveColors.surface2,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Row(
              children: <Widget>[
                _segment(
                  label: 'Polish',
                  icon: Icons.auto_fix_high_rounded,
                  selected: !isHumanize,
                  onTap: enabled ? () => onChanged('polish') : null,
                ),
                _segment(
                  label: 'Humanize',
                  icon: Icons.psychology_alt_rounded,
                  selected: isHumanize,
                  onTap: enabled ? () => onChanged('humanize') : null,
                ),
              ],
            ),
          ),
          const SizedBox(height: 6),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 2),
            child: Text(
              isHumanize
                  ? 'Rewrites AI text to read naturally and human while keeping your meaning. No tool can guarantee an AI detector result.'
                  : 'Improves clarity, grammar, and flow while keeping your voice.',
              style: const TextStyle(
                fontSize: 11,
                color: YveColors.textTertiary,
                height: 1.35,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _segment({
    required String label,
    required IconData icon,
    required bool selected,
    required VoidCallback? onTap,
  }) {
    return Expanded(
      child: GestureDetector(
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          padding: const EdgeInsets.symmetric(vertical: 8),
          decoration: BoxDecoration(
            color: selected ? YveColors.surface : Colors.transparent,
            borderRadius: BorderRadius.circular(8),
            boxShadow: selected ? YveSpacing.cardShadow : null,
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: <Widget>[
              Icon(
                icon,
                size: 15,
                color: selected ? YveColors.primary : YveColors.textSecondary,
              ),
              const SizedBox(width: 6),
              Text(
                label,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: selected ? FontWeight.w700 : FontWeight.w600,
                  color: selected ? YveColors.primary : YveColors.textSecondary,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Assignment-specific landing — three big attach CTAs because the most
/// common first move in this mode is "snap my worksheet", not "type a
/// question". The paperclip in the input bar still works; this just
/// stops requiring the learner to discover it.
class _AssignmentEmptyState extends StatelessWidget {
  const _AssignmentEmptyState({
    required this.onCamera,
    required this.onGallery,
    required this.onFile,
  });

  final VoidCallback onCamera;
  final VoidCallback onGallery;
  final VoidCallback onFile;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(
          YveSpacing.xl,
          YveSpacing.xxl,
          YveSpacing.xl,
          YveSpacing.xl,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Center(
              child: Container(
                width: 64,
                height: 64,
                decoration: const BoxDecoration(
                  gradient: YveColors.brandGradient,
                  shape: BoxShape.circle,
                ),
                child: const Center(
                  child: Icon(
                    Icons.edit_note_rounded,
                    size: 30,
                    color: YveColors.textInverse,
                  ),
                ),
              ),
            ),
            const SizedBox(height: YveSpacing.md),
            Text(
              'Solve your assignment',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 4),
            const Text(
              'Snap a photo, upload a file, or paste your question — Yve will work through it.',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 13,
                color: YveColors.textSecondary,
                height: 1.4,
              ),
            ),
            const SizedBox(height: YveSpacing.xl),
            _AttachCta(
              icon: Icons.camera_alt_rounded,
              label: 'Take a photo',
              hint: 'Snap your worksheet or notes',
              onTap: onCamera,
              filled: true,
            ),
            const SizedBox(height: YveSpacing.sm),
            _AttachCta(
              icon: Icons.photo_library_rounded,
              label: 'Pick from gallery',
              hint: 'Up to 5 photos',
              onTap: onGallery,
            ),
            const SizedBox(height: YveSpacing.sm),
            _AttachCta(
              icon: Icons.upload_file_rounded,
              label: 'Upload PDF or Doc',
              hint: 'Up to 5 files',
              onTap: onFile,
            ),
            const SizedBox(height: YveSpacing.lg),
            const Center(
              child: Text(
                'Or just type your question below.',
                style: TextStyle(
                  fontSize: 12,
                  color: YveColors.textTertiary,
                  height: 1.4,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _AttachCta extends StatelessWidget {
  const _AttachCta({
    required this.icon,
    required this.label,
    required this.hint,
    required this.onTap,
    this.filled = false,
  });

  final IconData icon;
  final String label;
  final String hint;
  final VoidCallback onTap;
  final bool filled;

  @override
  Widget build(BuildContext context) {
    final Color background = filled ? YveColors.primary : YveColors.surface;
    final Color foreground =
        filled ? YveColors.textInverse : YveColors.textPrimary;
    final Color iconBackground =
        filled ? const Color(0x33FFFFFF) : YveColors.primarySurface;
    final Color iconColor = filled ? YveColors.textInverse : YveColors.primary;
    final Color hintColor = filled
        ? YveColors.textOnGradient
        : YveColors.textSecondary;

    return Material(
      color: background,
      borderRadius: YveSpacing.cardRadius,
      child: InkWell(
        onTap: onTap,
        borderRadius: YveSpacing.cardRadius,
        child: Container(
          padding: const EdgeInsets.all(YveSpacing.lg),
          decoration: BoxDecoration(
            borderRadius: YveSpacing.cardRadius,
            border: filled
                ? null
                : Border.all(color: YveColors.border, width: 1),
            boxShadow: filled ? null : YveSpacing.cardShadow,
            color: background,
          ),
          child: Row(
            children: <Widget>[
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: iconBackground,
                  borderRadius: BorderRadius.circular(12),
                ),
                alignment: Alignment.center,
                child: Icon(icon, color: iconColor, size: 22),
              ),
              const SizedBox(width: YveSpacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      label,
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                        color: foreground,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      hint,
                      style: TextStyle(
                        fontSize: 12,
                        color: hintColor,
                        height: 1.4,
                      ),
                    ),
                  ],
                ),
              ),
              Icon(
                Icons.arrow_forward_rounded,
                color: foreground.withValues(alpha: 0.7),
                size: 18,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Bubble extends StatelessWidget {
  const _Bubble({
    required this.message,
    required this.onOfferTap,
    this.subjectName,
    this.sessionTitle,
    required this.mode,
  });

  final ChatMessage message;
  final ValueChanged<OfferSuggestion> onOfferTap;
  // Context threaded into export menus so saved files carry structured
  // names (Yve_Subject_Title_YYYY-MM-DD_HH-mm.docx) instead of being
  // derived from the AI response text.
  final String? subjectName;
  final String? sessionTitle;
  final StudyMode mode;

  @override
  Widget build(BuildContext context) {
    if (message.role == ChatRole.user) {
      return Container(
        margin: const EdgeInsets.only(bottom: YveSpacing.lg),
        alignment: Alignment.centerRight,
        child: GestureDetector(
          // Long-press anywhere on the user's own bubble to copy.
          // Matches the WhatsApp / iMessage pattern — users expect to
          // be able to reuse their own prompts.
          onLongPress: () async {
            await Clipboard.setData(ClipboardData(text: message.text));
            HapticFeedback.selectionClick();
            if (!context.mounted) return;
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text('Copied'),
                duration: Duration(seconds: 1),
                behavior: SnackBarBehavior.floating,
              ),
            );
          },
          child: Container(
            padding: const EdgeInsets.symmetric(
              horizontal: YveSpacing.lg,
              vertical: 12,
            ),
            constraints: BoxConstraints(
              maxWidth: MediaQuery.of(context).size.width * 0.8,
            ),
            decoration: const BoxDecoration(
              color: YveColors.primary,
              borderRadius: BorderRadius.only(
                topLeft: Radius.circular(18),
                topRight: Radius.circular(18),
                bottomLeft: Radius.circular(18),
                bottomRight: Radius.circular(4),
              ),
            ),
            // SelectableText so users can also drag-select part of their
            // own message (eg to copy just one sentence from a long
            // prompt). The selection handles use the brand accent.
            child: SelectableText(
              message.text,
              style: const TextStyle(
                color: YveColors.textInverse,
                fontSize: 14,
                height: 1.5,
              ),
              selectionControls: MaterialTextSelectionControls(),
            ),
          ),
        ),
      );
    }

    final PostSolveOffer? offer = message.offer;

    return Container(
      margin: const EdgeInsets.only(bottom: YveSpacing.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              const Icon(Icons.auto_awesome,
                  size: 12, color: YveColors.accent),
              const SizedBox(width: 4),
              const Text(
                'Yve',
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: YveColors.accent,
                ),
              ),
              if (message.text.isNotEmpty) ...<Widget>[
                const SizedBox(width: 6),
                SpeakAloudButton(
                  messageId: message.id,
                  // For polish turns, the speaker reads only the polished
                  // draft — not the analysis sections.
                  text: message.polish?.polishedText ?? message.text,
                  enabled: !message.isStreaming,
                ),
                // Generic export menu is hidden for polish turns — the
                // PolishBubble has its own dedicated Copy buttons so the
                // primary action copies ONLY the polished draft.
                if (!message.isStreaming && message.polish == null) ...<Widget>[
                  const SizedBox(width: 2),
                  ResponseActionsMenu(
                    text: message.text,
                    subjectName: subjectName,
                    sessionTitle: sessionTitle,
                    toolLabel: mode.label,
                  ),
                ],
              ],
            ],
          ),
          const SizedBox(height: 4),
          ConstrainedBox(
            constraints: BoxConstraints(
              maxWidth: MediaQuery.of(context).size.width * 0.9,
            ),
            child: message.polish != null
                ? PolishBubble(
                    polish: message.polish!,
                    subjectName: subjectName,
                    sessionTitle: sessionTitle,
                    onFollowUpTap: (String label) =>
                        onOfferTap(OfferSuggestion(
                      label: label,
                      kind: OfferKind.rephrase,
                      payload: label,
                    )),
                  )
                : Container(
                    padding: const EdgeInsets.all(YveSpacing.md),
                    decoration: BoxDecoration(
                      color: YveColors.surface,
                      borderRadius: const BorderRadius.only(
                        topLeft: Radius.circular(4),
                        topRight: Radius.circular(18),
                        bottomLeft: Radius.circular(18),
                        bottomRight: Radius.circular(18),
                      ),
                      boxShadow: YveSpacing.cardShadow,
                    ),
                    child: message.isStreaming && message.text.isEmpty
                        ? const _PulseDot()
                        : _StreamingText(
                            text: message.text,
                            streaming: message.isStreaming,
                          ),
                  ),
          ),
          if (message.conceptTags.isNotEmpty) ...<Widget>[
            const SizedBox(height: 8),
            _ConceptTagRow(tags: message.conceptTags),
          ],
          if (offer != null && offer.suggestions.isNotEmpty) ...<Widget>[
            const SizedBox(height: YveSpacing.sm),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: <Widget>[
                for (int i = 0; i < offer.suggestions.length; i++)
                  _OfferChip(
                    suggestion: offer.suggestions[i],
                    primary: i == 0,
                    onTap: () => onOfferTap(offer.suggestions[i]),
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class _ConceptTagRow extends StatelessWidget {
  const _ConceptTagRow({required this.tags});
  final List<String> tags;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 6,
      runSpacing: 4,
      children: <Widget>[
        for (final String t in tags)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(
              color: YveColors.primarySurface,
              borderRadius: BorderRadius.circular(6),
            ),
            child: Text(
              t,
              style: const TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: YveColors.primary,
              ),
            ),
          ),
      ],
    );
  }
}

class _OfferChip extends StatelessWidget {
  const _OfferChip({
    required this.suggestion,
    required this.onTap,
    this.primary = false,
  });

  final OfferSuggestion suggestion;
  final VoidCallback onTap;
  final bool primary;

  @override
  Widget build(BuildContext context) {
    final bool isSave = suggestion.kind == OfferKind.save;
    final Color borderColor =
        isSave ? YveColors.accent : (primary ? YveColors.primary : YveColors.border);
    final Color textColor = isSave
        ? YveColors.primary
        : (primary ? YveColors.primary : YveColors.textPrimary);
    final IconData? icon = _iconFor(suggestion.kind);
    return Material(
      color: isSave ? YveColors.primarySurface : YveColors.surface,
      borderRadius: YveSpacing.pillRadius,
      child: InkWell(
        borderRadius: YveSpacing.pillRadius,
        onTap: () {
          HapticFeedback.selectionClick();
          onTap();
        },
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(
            borderRadius: YveSpacing.pillRadius,
            border: Border.all(color: borderColor, width: 1.5),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              if (icon != null) ...<Widget>[
                Icon(icon, size: 12, color: textColor),
                const SizedBox(width: 4),
              ],
              Text(
                suggestion.label,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: textColor,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  IconData? _iconFor(OfferKind kind) {
    switch (kind) {
      case OfferKind.save:
        return Icons.bookmark_add_rounded;
      case OfferKind.quiz:
      case OfferKind.practice:
        return Icons.track_changes_rounded;
      case OfferKind.flashcards:
        return Icons.style_rounded;
      case OfferKind.check:
        return Icons.fact_check_rounded;
      case OfferKind.next:
        return Icons.arrow_forward_rounded;
      case OfferKind.harder:
        return Icons.trending_up_rounded;
      case OfferKind.easier:
        return Icons.trending_down_rounded;
      case OfferKind.cite:
        return Icons.menu_book_rounded;
      case OfferKind.summarize:
        return Icons.summarize_rounded;
      default:
        return null;
    }
  }
}

/// Pre-first-token state: a single pulsing accent dot inside the Yve bubble.
/// Replaces the legacy [_TypingIndicator] now that the in-flight Yve bubble
/// serves the role itself.
class _PulseDot extends StatefulWidget {
  const _PulseDot();
  @override
  State<_PulseDot> createState() => _PulseDotState();
}

class _PulseDotState extends State<_PulseDot>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl =
      AnimationController(vsync: this, duration: const Duration(seconds: 1))
        ..repeat(reverse: true);

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        FadeTransition(
          opacity: _ctrl,
          child: Container(
            width: 10,
            height: 10,
            decoration: const BoxDecoration(
              color: YveColors.accent,
              shape: BoxShape.circle,
            ),
          ),
        ),
      ],
    );
  }
}

/// Renders the streaming Yve text.
///
/// While the response is mid-stream we render plain text + a blinking caret
/// — markdown parsed on every keystroke would flicker through half-built
/// elements (`**bo` rendering as literal asterisks until `**bold**` closes).
/// Once streaming ends, we swap to a full markdown render with proper
/// headings, lists, code blocks, and links.
class _StreamingText extends StatelessWidget {
  const _StreamingText({required this.text, required this.streaming});

  final String text;
  final bool streaming;

  @override
  Widget build(BuildContext context) {
    if (streaming) {
      return Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: <Widget>[
          Flexible(
            child: Text(
              text,
              style: const TextStyle(
                color: YveColors.textPrimary,
                fontSize: 14,
                height: 1.6,
              ),
            ),
          ),
          const _BlinkingCaret(),
        ],
      );
    }
    return YveMarkdownBody(
      data: text,
      selectable: true,
      onTapLink: (String _, String? href, String __) async {
        if (href == null) return;
        final Uri? uri = Uri.tryParse(href);
        if (uri == null || !uri.hasScheme) return;
        await launchUrl(uri, mode: LaunchMode.externalApplication);
      },
      styleSheet: _yveMarkdownStyle(context),
    );
  }
}

MarkdownStyleSheet _yveMarkdownStyle(BuildContext context) {
  const TextStyle body = TextStyle(
    color: YveColors.textPrimary,
    fontSize: 14,
    height: 1.6,
  );
  return MarkdownStyleSheet(
    p: body,
    h1: body.copyWith(
        fontSize: 18, fontWeight: FontWeight.w700, height: 1.4),
    h2: body.copyWith(
        fontSize: 16, fontWeight: FontWeight.w700, height: 1.4),
    h3: body.copyWith(
        fontSize: 15, fontWeight: FontWeight.w700, height: 1.4),
    strong: body.copyWith(fontWeight: FontWeight.w700),
    em: body.copyWith(fontStyle: FontStyle.italic),
    listBullet: body,
    blockquote: body.copyWith(
        color: YveColors.textSecondary, fontStyle: FontStyle.italic),
    blockquoteDecoration: const BoxDecoration(
      border: Border(
        left: BorderSide(color: YveColors.accent, width: 3),
      ),
    ),
    blockquotePadding: const EdgeInsets.only(left: 12),
    // Inline code style — used for short algebra expressions Yve drops
    // into prose (`x^2 + 3x`). Darker text + a tiny baseline shift via
    // letterSpacing makes the block read as definitive rather than
    // ambient. The flutter_markdown styleSheet doesn't support padding
    // on the inline `code` background, so we boost the contrast and
    // size to give the block visual weight.
    code: const TextStyle(
      fontFamily: 'monospace',
      fontSize: 13.5,
      fontWeight: FontWeight.w600,
      color: YveColors.textPrimary,
      backgroundColor: YveColors.primarySurface,
      letterSpacing: 0.2,
    ),
    // Display code blocks (```...```) — bigger, with a softer left
    // border so they read as "examined material" rather than just
    // shaded text.
    codeblockDecoration: BoxDecoration(
      color: YveColors.surface2,
      borderRadius: BorderRadius.circular(10),
      border: const Border(
        left: BorderSide(color: YveColors.accent, width: 3),
      ),
    ),
    codeblockPadding: const EdgeInsets.fromLTRB(14, 12, 12, 12),
    a: body.copyWith(
      color: YveColors.primary,
      decoration: TextDecoration.underline,
    ),
    horizontalRuleDecoration: const BoxDecoration(
      border: Border(
        top: BorderSide(color: YveColors.borderSubtle, width: 1),
      ),
    ),
    blockSpacing: 8,
    listIndent: 18,
  );
}

class _BlinkingCaret extends StatefulWidget {
  const _BlinkingCaret();
  @override
  State<_BlinkingCaret> createState() => _BlinkingCaretState();
}

class _BlinkingCaretState extends State<_BlinkingCaret>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 800),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: _ctrl,
      child: Container(
        margin: const EdgeInsets.only(left: 2, bottom: 4),
        width: 6,
        height: 14,
        decoration: BoxDecoration(
          color: YveColors.accent,
          borderRadius: BorderRadius.circular(1),
        ),
      ),
    );
  }
}

/// Smart-action chip strip surfaced above the input after a worksheet
/// upload in Assignment mode. Single tap → sends an explicit intent to
/// Yve so the learner doesn't have to type "answer all questions" to
/// get the assignment solved end-to-end.
class _SmartAction {
  const _SmartAction({
    required this.label,
    required this.prompt,
    this.filled = false,
  });

  final String label;
  final String prompt;
  final bool filled;
}

/// A scan job queued for batch processing — image or PDF, doesn't matter
/// here. [process] kicks off the vision-ingest call when the batch
/// helper is ready to run it.
class _PendingScan {
  const _PendingScan({required this.name, required this.process});
  final String name;
  final Future<ScanResult> Function() process;
}

/// One successfully-processed scan in a batch. We only need the
/// extracted text — the rest of ScanResult (sessionId, action ladder,
/// etc.) isn't used in the multi-file path because batch attaches
/// don't adopt vision-ingest sessions.
class _BatchResult {
  const _BatchResult({required this.name, required this.extractedText});
  final String name;
  final String extractedText;
}

/// Pill shown above the input bar when a batch attach has stashed
/// extracted text waiting to be sent. Tells the learner what's queued,
/// lets them throw it out if they changed their mind.
class _PendingAttachmentPill extends StatelessWidget {
  const _PendingAttachmentPill({
    required this.names,
    required this.onClear,
  });

  final List<String> names;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    final String summary = names.length == 1
        ? names.first
        : '${names.length} documents — ${names.first}'
            '${names.length > 1 ? ', …' : ''}';
    return Container(
      margin: const EdgeInsets.fromLTRB(
        YveSpacing.lg,
        YveSpacing.sm,
        YveSpacing.lg,
        0,
      ),
      padding: const EdgeInsets.symmetric(
        horizontal: YveSpacing.md,
        vertical: 8,
      ),
      decoration: BoxDecoration(
        color: YveColors.primarySurface,
        borderRadius: YveSpacing.pillRadius,
        border: Border.all(color: YveColors.border, width: 1),
      ),
      child: Row(
        children: <Widget>[
          const Icon(
            Icons.attach_file_rounded,
            size: 16,
            color: YveColors.primary,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              summary,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: YveColors.primary,
              ),
            ),
          ),
          InkWell(
            onTap: onClear,
            borderRadius: BorderRadius.circular(6),
            child: const Padding(
              padding: EdgeInsets.symmetric(horizontal: 6, vertical: 4),
              child: Icon(
                Icons.close_rounded,
                size: 14,
                color: YveColors.textSecondary,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _SmartActionsBar extends StatelessWidget {
  const _SmartActionsBar({
    required this.actions,
    required this.onTap,
  });

  final List<_SmartAction> actions;
  final void Function(_SmartAction) onTap;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(
        YveSpacing.lg,
        YveSpacing.sm,
        YveSpacing.lg,
        YveSpacing.sm,
      ),
      decoration: const BoxDecoration(
        border: Border(
          top: BorderSide(color: YveColors.borderSubtle, width: 0.5),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          const Padding(
            padding: EdgeInsets.only(left: 2, bottom: 6),
            child: Text(
              'How should Yve handle this?',
              style: TextStyle(
                fontSize: 12,
                color: YveColors.textSecondary,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
          SizedBox(
            height: 36,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: actions.length,
              separatorBuilder: (_, __) =>
                  const SizedBox(width: YveSpacing.sm),
              itemBuilder: (BuildContext context, int i) {
                final _SmartAction a = actions[i];
                return YvePill(
                  label: a.label,
                  filled: a.filled,
                  onTap: () => onTap(a),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _InputBar extends StatelessWidget {
  const _InputBar({
    required this.controller,
    required this.sending,
    required this.listening,
    required this.blocked,
    required this.onBlockedTap,
    required this.onSend,
    required this.onMic,
    required this.onAttach,
  });

  final TextEditingController controller;
  final bool sending;
  final bool listening;

  /// True when the user has hit a hard cap that can't be cleared by
  /// retrying (anonymous-lifetime limit, primarily). Disables typing,
  /// mic, and send — only the attach button (which routes through
  /// runIfAuthed and will also gate) and a tap-to-explain handler stay
  /// active. The QuotaExceededCard rendered above the input has the
  /// recovery CTA.
  final bool blocked;
  final VoidCallback onBlockedTap;

  final VoidCallback onSend;
  final VoidCallback onMic;
  final VoidCallback onAttach;

  @override
  Widget build(BuildContext context) {
    final String hint = blocked
        ? 'Sign in to keep going'
        : (listening ? 'Listening…' : 'Ask Yve anything…');
    return Container(
      decoration: const BoxDecoration(
        color: YveColors.surface,
        border: Border(top: BorderSide(color: YveColors.borderSubtle)),
      ),
      padding: EdgeInsets.fromLTRB(
        YveSpacing.lg,
        YveSpacing.md,
        YveSpacing.lg,
        MediaQuery.of(context).padding.bottom + YveSpacing.md,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: <Widget>[
          _IconChip(icon: Icons.attach_file_rounded, onTap: onAttach),
          const SizedBox(width: 10),
          Expanded(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 140),
              child: blocked
                  // Tap-to-gate: when the user taps the disabled-looking
                  // input, route them to the same continuation panel
                  // the QuotaExceededCard CTA opens. Otherwise the
                  // visual signal ("input is dim, why?") leaves them
                  // stuck without a path forward.
                  ? GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: onBlockedTap,
                      child: AbsorbPointer(
                        child: TextField(
                          enabled: false,
                          decoration: InputDecoration(hintText: hint),
                        ),
                      ),
                    )
                  : TextField(
                      controller: controller,
                      minLines: 1,
                      maxLines: 5,
                      // `newline` makes Enter insert a paragraph break,
                      // letting users compose multi-paragraph questions
                      // (mom's ask). Sending happens only via the send
                      // button below. No `onSubmitted` — that fired
                      // even on newline-key presses in some Android
                      // keyboards.
                      keyboardType: TextInputType.multiline,
                      textInputAction: TextInputAction.newline,
                      decoration: InputDecoration(hintText: hint),
                    ),
            ),
          ),
          const SizedBox(width: 8),
          VoiceInputButton(
            listening: listening,
            onTap: blocked ? onBlockedTap : onMic,
          ),
          const SizedBox(width: 8),
          _SendButton(
            loading: sending,
            onTap: blocked ? onBlockedTap : onSend,
          ),
        ],
      ),
    );
  }
}

class _IconChip extends StatelessWidget {
  const _IconChip({required this.icon, required this.onTap});

  final IconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: YveColors.surface2,
      borderRadius: YveSpacing.inputRadius,
      child: InkWell(
        onTap: onTap,
        borderRadius: YveSpacing.inputRadius,
        child: SizedBox(
          width: 40,
          height: 40,
          child: Icon(icon, size: 18, color: YveColors.textPrimary),
        ),
      ),
    );
  }
}

class _SendButton extends StatelessWidget {
  const _SendButton({required this.loading, required this.onTap});

  final bool loading;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: YveColors.primary,
      shape: const CircleBorder(),
      child: InkWell(
        onTap: loading ? null : onTap,
        customBorder: const CircleBorder(),
        child: SizedBox(
          width: 40,
          height: 40,
          child: Center(
            child: loading
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: YveColors.textInverse,
                    ),
                  )
                : const Icon(
                    Icons.arrow_upward_rounded,
                    color: YveColors.textInverse,
                  ),
          ),
        ),
      ),
    );
  }
}

class _AttachSheet extends StatelessWidget {
  const _AttachSheet({
    required this.onCamera,
    required this.onGallery,
    required this.onFile,
  });

  final VoidCallback onCamera;
  final VoidCallback onGallery;
  final VoidCallback onFile;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(YveSpacing.lg),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            ListTile(
              leading: const Icon(Icons.camera_alt_rounded),
              title: const Text('Camera'),
              onTap: onCamera,
            ),
            ListTile(
              leading: const Icon(Icons.photo_library_rounded),
              title: const Text('Gallery'),
              onTap: onGallery,
            ),
            ListTile(
              leading: const Icon(Icons.upload_file_rounded),
              title: const Text('File (PDF / Doc)'),
              onTap: onFile,
            ),
          ],
        ),
      ),
    );
  }
}
