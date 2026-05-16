import 'package:flutter/material.dart';

import '../theme/yve_colors.dart';
import '../theme/yve_spacing.dart';

/// Calm processing overlay shown while vision-ingest is running. The pulsing
/// dot replaces a spinner — keeps the moment feeling alive rather than
/// mechanical (Product Vision §3.4 motion).
class YveReadingOverlay extends StatefulWidget {
  const YveReadingOverlay({
    super.key,
    this.message = 'Yve is reading your scan…',
  });

  final String message;

  @override
  State<YveReadingOverlay> createState() => _YveReadingOverlayState();
}

class _YveReadingOverlayState extends State<YveReadingOverlay>
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
    return Container(
      color: const Color(0xCC1A1A2E),
      alignment: Alignment.center,
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: YveSpacing.xxl,
          vertical: YveSpacing.xl,
        ),
        decoration: BoxDecoration(
          color: YveColors.surface,
          borderRadius: YveSpacing.cardRadius,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            FadeTransition(
              opacity: _ctrl,
              child: Container(
                width: 14,
                height: 14,
                decoration: const BoxDecoration(
                  color: YveColors.accent,
                  shape: BoxShape.circle,
                ),
              ),
            ),
            const SizedBox(width: 12),
            Text(
              widget.message,
              style: const TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: YveColors.textPrimary,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
