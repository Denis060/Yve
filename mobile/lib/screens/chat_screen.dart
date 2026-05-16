import 'dart:async';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';
import 'package:url_launcher/url_launcher.dart';

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
import '../widgets/mode_switcher.dart';
import '../widgets/polish_bubble.dart';
import '../widgets/quota_exceeded_card.dart';
import '../widgets/response_actions_menu.dart';
import '../widgets/save_to_subject_sheet.dart';
import '../widgets/scan_result_sheet.dart';
import '../widgets/speak_aloud_button.dart';
import '../widgets/upgrade_sheet.dart';
import '../widgets/voice_input_button.dart';
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
      _voiceTextSub = voice.recognizedText.listen((String recognized) {
        if (!mounted) return;
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
    // Stop any ongoing voice activity tied to this screen.
    final VoiceService voice = ref.read(voiceServiceProvider);
    voice.stopListening();
    voice.stopSpeaking();
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  bool _handsFreeBannerVisible() {
    if (_handsFreePausedForSession) return false;
    final LearnerProfile? profile = ref.read(profileProvider).value;
    return profile?.handsFreeActive ?? false;
  }

  /// Called when Yve's TTS finishes. If the profile says hands-free is on
  /// and we're in a clean idle state, auto-start STT for the next turn.
  Future<void> _maybeStartAutoListen() async {
    if (!mounted) return;
    final LearnerProfile? profile = ref.read(profileProvider).value;
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

  Future<void> _send([String? overrideText]) async {
    final String text = (overrideText ?? _input.text).trim();
    if (text.isEmpty || _sending) return;
    HapticFeedback.lightImpact();

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
    final LearnerProfile? profile = ref.read(profileProvider).value;
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

  /// Capture or pick an image, run it through vision-ingest, then append the
  /// extracted text as a user turn in *this* conversation. Keeps multimodal
  /// fluid — no leaving the chat to scan something into it.
  Future<void> _scanIntoChat(ImageSource source) async {
    if (_scanning || _sending) return;
    HapticFeedback.lightImpact();

    XFile? file;
    try {
      file = await _picker.pickImage(
        source: source,
        maxWidth: 1600,
        maxHeight: 1600,
        imageQuality: 85,
      );
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
    if (file == null) return;

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

  /// Pick a PDF or .docx, run it through vision-ingest, then mirror
  /// [_scanIntoChat]'s behavior — adopt the chat if it's empty, otherwise
  /// surface the scan result sheet so the learner can branch into a fresh
  /// chat or drop the extracted text in here as a draft.
  Future<void> _scanFileIntoChat() async {
    if (_scanning || _sending) return;
    HapticFeedback.lightImpact();

    FilePickerResult? result;
    try {
      result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: const <String>['pdf', 'docx'],
        withData: true,
        allowMultiple: false,
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

    final PlatformFile file = result.files.first;
    final Uint8List? bytes = file.bytes;
    if (bytes == null) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Couldn\'t read the file.')),
      );
      return;
    }
    // Mirror AddMaterialSheet's cap so the request stays under the Edge
    // Function payload budget.
    const int maxBytes = 25 * 1024 * 1024;
    if (bytes.lengthInBytes > maxBytes) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'That file is over 25 MB. Try a smaller one or upload via the subject workspace.',
          ),
        ),
      );
      return;
    }

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

  Future<void> _saveCurrentExchange({required String? suggested}) async {
    final List<Subject> subjectList =
        ref.read(subjectsProvider).value ?? const <Subject>[];
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
            const Positioned.fill(child: YveReadingOverlay()),
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
                    saveToSubjectSuggestion: null,
                  );
                });
              },
            ),
          Expanded(
            child: _loadingHistory
                ? const Center(child: CircularProgressIndicator())
                : (_messages.isEmpty && _quotaHit == null)
                    ? _EmptyChat(mode: _mode)
                    : ListView.builder(
                        controller: _scroll,
                        padding: const EdgeInsets.all(YveSpacing.lg),
                        itemCount:
                            _messages.length + (_quotaHit != null ? 1 : 0),
                        itemBuilder: (BuildContext context, int i) {
                          if (i == _messages.length && _quotaHit != null) {
                            return QuotaExceededCard(
                              quota: _quotaHit!,
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
          _InputBar(
            controller: _input,
            sending: _sending || _scanning,
            listening: _listening,
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
  const _EmptyChat({required this.mode});
  final StudyMode mode;

  @override
  Widget build(BuildContext context) {
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
          child: Text(
            message.text,
            style: const TextStyle(
              color: YveColors.textInverse,
              fontSize: 14,
              height: 1.5,
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
    return MarkdownBody(
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
    code: const TextStyle(
      fontFamily: 'monospace',
      fontSize: 13,
      color: YveColors.primary,
      backgroundColor: YveColors.primarySurface,
    ),
    codeblockDecoration: BoxDecoration(
      color: YveColors.surface2,
      borderRadius: BorderRadius.circular(8),
    ),
    codeblockPadding: const EdgeInsets.all(10),
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

class _InputBar extends StatelessWidget {
  const _InputBar({
    required this.controller,
    required this.sending,
    required this.listening,
    required this.onSend,
    required this.onMic,
    required this.onAttach,
  });

  final TextEditingController controller;
  final bool sending;
  final bool listening;
  final VoidCallback onSend;
  final VoidCallback onMic;
  final VoidCallback onAttach;

  @override
  Widget build(BuildContext context) {
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
              child: TextField(
                controller: controller,
                minLines: 1,
                maxLines: 5,
                textInputAction: TextInputAction.send,
                onSubmitted: (_) => onSend(),
                decoration: InputDecoration(
                  hintText:
                      listening ? 'Listening…' : 'Ask Yve anything…',
                ),
              ),
            ),
          ),
          const SizedBox(width: 8),
          VoiceInputButton(listening: listening, onTap: onMic),
          const SizedBox(width: 8),
          _SendButton(loading: sending, onTap: onSend),
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
