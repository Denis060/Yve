import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/voice_service.dart';
import '../theme/yve_colors.dart';

/// Per-Yve-bubble speaker icon that toggles TTS playback for that message.
/// Subscribes to [VoiceService.speakingMessageId] so the icon flips between
/// idle / now-speaking states across all bubbles in real time.
class SpeakAloudButton extends ConsumerStatefulWidget {
  const SpeakAloudButton({
    super.key,
    required this.messageId,
    required this.text,
    required this.enabled,
  });

  final String messageId;
  final String text;

  /// False while the message is still streaming — no point speaking a chunk
  /// that's about to change. Renders the icon dimmed and inert.
  final bool enabled;

  @override
  ConsumerState<SpeakAloudButton> createState() => _SpeakAloudButtonState();
}

class _SpeakAloudButtonState extends ConsumerState<SpeakAloudButton> {
  String? _activeId;

  @override
  void initState() {
    super.initState();
    final VoiceService voice = ref.read(voiceServiceProvider);
    _activeId = voice.currentlySpeakingMessageId;
    voice.speakingMessageId.listen((String? id) {
      if (!mounted) return;
      setState(() => _activeId = id);
    });
  }

  Future<void> _onTap() async {
    HapticFeedback.selectionClick();
    final VoiceService voice = ref.read(voiceServiceProvider);
    if (_activeId == widget.messageId) {
      await voice.stopSpeaking();
    } else {
      await voice.speak(widget.messageId, widget.text);
    }
  }

  @override
  Widget build(BuildContext context) {
    final bool playing = _activeId == widget.messageId;
    final bool disabled = !widget.enabled;
    final Color color = disabled
        ? YveColors.textTertiary
        : playing
            ? YveColors.accent
            : YveColors.textSecondary;

    return InkWell(
      onTap: disabled ? null : _onTap,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.all(4),
        child: Icon(
          playing ? Icons.stop_circle_rounded : Icons.volume_up_rounded,
          size: 16,
          color: color,
        ),
      ),
    );
  }
}
