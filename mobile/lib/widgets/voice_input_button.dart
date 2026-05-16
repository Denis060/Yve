import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme/yve_colors.dart';
import '../theme/yve_spacing.dart';

/// Mic button rendered in the chat input bar. Tap to start, tap to stop.
/// While listening, the icon pulses red to make the state unmistakable.
class VoiceInputButton extends StatefulWidget {
  const VoiceInputButton({
    super.key,
    required this.listening,
    required this.onTap,
  });

  final bool listening;
  final VoidCallback onTap;

  @override
  State<VoiceInputButton> createState() => _VoiceInputButtonState();
}

class _VoiceInputButtonState extends State<VoiceInputButton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  );

  @override
  void initState() {
    super.initState();
    if (widget.listening) _ctrl.repeat(reverse: true);
  }

  @override
  void didUpdateWidget(covariant VoiceInputButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.listening && !_ctrl.isAnimating) {
      _ctrl.repeat(reverse: true);
    } else if (!widget.listening && _ctrl.isAnimating) {
      _ctrl.stop();
      _ctrl.value = 0;
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final bool listening = widget.listening;
    final Color bg = listening ? YveColors.error : YveColors.surface2;
    final Color fg = listening ? YveColors.textInverse : YveColors.textPrimary;

    return Material(
      color: bg,
      borderRadius: YveSpacing.inputRadius,
      child: InkWell(
        onTap: () {
          HapticFeedback.lightImpact();
          widget.onTap();
        },
        borderRadius: YveSpacing.inputRadius,
        child: SizedBox(
          width: 40,
          height: 40,
          child: Center(
            child: listening
                ? FadeTransition(
                    opacity: _ctrl.drive(
                      Tween<double>(begin: 0.5, end: 1),
                    ),
                    child: Icon(Icons.stop_rounded, color: fg, size: 18),
                  )
                : Icon(Icons.mic_rounded, color: fg, size: 18),
          ),
        ),
      ),
    );
  }
}
