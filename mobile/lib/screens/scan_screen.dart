import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';

import '../models/scan_result.dart';
import '../services/sessions_service.dart';
import '../services/subjects_service.dart';
import '../services/vision_service.dart';
import '../theme/yve_colors.dart';
import '../theme/yve_spacing.dart';
import '../utils/app_error.dart';
import '../widgets/scan_result_sheet.dart';
import '../widgets/yve_reading_overlay.dart';
import 'chat_screen.dart';

/// Scan (Product Vision §6.2) — the fastest path to help.
///
/// One tap from anywhere. The flow:
///   1. Camera or Gallery via image_picker (handles permissions natively).
///   2. Bytes go to vision-ingest, which classifies + OCRs + builds the
///      action ladder + creates a chat session preloaded with the scan.
///   3. Scan Result sheet slides up. The learner picks an action.
///   4. We resume the new chat session in the action's mode with a short
///      follow-up draft. The chat already carries the scanned content.
class ScanScreen extends ConsumerStatefulWidget {
  const ScanScreen({super.key});

  @override
  ConsumerState<ScanScreen> createState() => _ScanScreenState();
}

class _ScanScreenState extends ConsumerState<ScanScreen> {
  final ImagePicker _picker = ImagePicker();
  bool _processing = false;

  Future<void> _capture(ImageSource source) async {
    if (_processing) return;
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
            AppError.from(e, actionContext: 'scan_camera').userMessage,
          ),
        ),
      );
      return;
    }
    if (file == null) return; // user cancelled

    final Uint8List bytes = await file.readAsBytes();
    final String mime = _mimeFromName(file.name);

    setState(() => _processing = true);
    try {
      final ScanResult result =
          await ref.read(visionServiceProvider).analyze(
                bytes: bytes,
                mimeType: mime,
              );
      if (!mounted) return;

      // Refresh sidebar lists — vision-ingest just created a session.
      ref.invalidate(recentSessionsProvider);
      ref.invalidate(subjectsProvider);

      HapticFeedback.selectionClick();
      final ScanAction? action = await showScanResultSheet(
        context,
        result: result,
        imageBytes: bytes,
        onTypeInstead: () => _openChatTextOnly(result),
      );
      if (action != null && mounted) {
        _openChatForAction(result, action);
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(_friendlyError(e))),
      );
    } finally {
      if (mounted) setState(() => _processing = false);
    }
  }

  void _openChatForAction(ScanResult result, ScanAction action) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ChatScreen.resume(
          sessionId: result.sessionId,
          sessionTitle: result.oneLineSummary,
          initialMode: action.mode,
          // The chat history already contains the scanned text. The action's
          // short prompt drops into the input ready to send.
          initialDraft: action.prompt,
        ),
      ),
    );
  }

  void _openChatTextOnly(ScanResult result) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ChatScreen.resume(
          sessionId: result.sessionId,
          sessionTitle: result.oneLineSummary,
        ),
      ),
    );
  }

  String _mimeFromName(String name) {
    final String lower = name.toLowerCase();
    if (lower.endsWith('.png')) return 'image/png';
    if (lower.endsWith('.webp')) return 'image/webp';
    if (lower.endsWith('.gif')) return 'image/gif';
    return 'image/jpeg';
  }

  String _friendlyError(Object e) {
    final String text = e.toString();
    if (text.contains('not authenticated')) {
      return 'Couldn\'t reach Yve — try again in a moment.';
    }
    if (text.contains('not enough text') || text.contains('couldn\'t pick up')) {
      return 'I couldn\'t read this scan. Try better lighting or get closer.';
    }
    return text;
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: <Widget>[
        const _Viewfinder(),
        Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          child: _ActionSheet(
            onCapture: () => _capture(ImageSource.camera),
            onGallery: () => _capture(ImageSource.gallery),
            onType: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => const ChatScreen(),
              ),
            ),
          ),
        ),
        if (_processing)
          const Positioned.fill(
            child: YveReadingOverlay(),
          ),
      ],
    );
  }
}

class _Viewfinder extends StatelessWidget {
  const _Viewfinder();

  @override
  Widget build(BuildContext context) {
    final double topInset = MediaQuery.of(context).padding.top;
    return DecoratedBox(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: <Color>[Color(0xFF0A0A0A), Color(0xFF1A1A1A)],
        ),
      ),
      child: SizedBox.expand(
        child: Stack(
          children: <Widget>[
            Padding(
              padding: EdgeInsets.fromLTRB(
                YveSpacing.xl,
                topInset + 8,
                YveSpacing.xl,
                0,
              ),
              child: const Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: <Widget>[
                  _TopPill(label: 'Scan', icon: Icons.center_focus_strong_rounded),
                ],
              ),
            ),
            Center(
              child: Padding(
                padding: const EdgeInsets.only(bottom: 240),
                child: SizedBox(
                  width: 300,
                  height: 220,
                  child: CustomPaint(painter: _CropGuidePainter()),
                ),
              ),
            ),
            const Positioned(
              bottom: 280,
              left: 0,
              right: 0,
              child: Center(
                child: Text(
                  'Snap a worksheet, page, or screenshot',
                  style: TextStyle(
                    color: Color(0xB3FFFFFF),
                    fontSize: 13,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _TopPill extends StatelessWidget {
  const _TopPill({required this.label, required this.icon});
  final String label;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: const Color(0x26FFFFFF),
        borderRadius: BorderRadius.circular(YveSpacing.radiusPill),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(icon, size: 14, color: YveColors.textInverse),
          const SizedBox(width: 6),
          Text(
            label,
            style: const TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: YveColors.textInverse,
            ),
          ),
        ],
      ),
    );
  }
}

class _CropGuidePainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final Paint corner = Paint()
      ..color = YveColors.accent
      ..strokeWidth = 3
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;

    const double len = 22;

    canvas.drawLine(const Offset(0, 0), const Offset(len, 0), corner);
    canvas.drawLine(const Offset(0, 0), const Offset(0, len), corner);
    canvas.drawLine(Offset(size.width - len, 0), Offset(size.width, 0), corner);
    canvas.drawLine(Offset(size.width, 0), Offset(size.width, len), corner);
    canvas.drawLine(Offset(0, size.height - len), Offset(0, size.height), corner);
    canvas.drawLine(Offset(0, size.height), Offset(len, size.height), corner);
    canvas.drawLine(Offset(size.width, size.height - len),
        Offset(size.width, size.height), corner);
    canvas.drawLine(Offset(size.width - len, size.height),
        Offset(size.width, size.height), corner);

    final Paint outline = Paint()
      ..color = YveColors.accent.withOpacity(0.5)
      ..strokeWidth = 1
      ..style = PaintingStyle.stroke;
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Offset.zero & size,
        const Radius.circular(YveSpacing.radiusCard),
      ),
      outline,
    );
  }

  @override
  bool shouldRepaint(_CropGuidePainter oldDelegate) => false;
}

class _ActionSheet extends StatelessWidget {
  const _ActionSheet({
    required this.onCapture,
    required this.onGallery,
    required this.onType,
  });

  final VoidCallback onCapture;
  final VoidCallback onGallery;
  final VoidCallback onType;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        color: YveColors.surface,
        borderRadius: BorderRadius.only(
          topLeft: Radius.circular(28),
          topRight: Radius.circular(28),
        ),
      ),
      padding: EdgeInsets.fromLTRB(
        YveSpacing.xxl,
        YveSpacing.xl,
        YveSpacing.xxl,
        MediaQuery.of(context).padding.bottom + YveSpacing.xxxl,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Center(
            child: Container(
              width: 36,
              height: 4,
              decoration: BoxDecoration(
                color: YveColors.border,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          const SizedBox(height: YveSpacing.xl),
          Text(
            'Scan & ask',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 4),
          const Text(
            'Yve will read it and suggest what to do next.',
            style: TextStyle(fontSize: 13, color: YveColors.textSecondary),
          ),
          const SizedBox(height: YveSpacing.xl),
          FilledButton.icon(
            onPressed: onCapture,
            icon: const Icon(Icons.camera_alt_rounded),
            label: const Text('Capture'),
          ),
          const SizedBox(height: YveSpacing.md),
          Row(
            children: <Widget>[
              Expanded(
                child: _AltButton(
                  icon: Icons.photo_library_rounded,
                  label: 'Gallery',
                  onTap: onGallery,
                ),
              ),
              const SizedBox(width: YveSpacing.md),
              Expanded(
                child: _AltButton(
                  icon: Icons.edit_rounded,
                  label: 'Type instead',
                  onTap: onType,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _AltButton extends StatelessWidget {
  const _AltButton({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: YveColors.surface2,
      borderRadius: YveSpacing.inputRadius,
      child: InkWell(
        onTap: onTap,
        borderRadius: YveSpacing.inputRadius,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 14),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Icon(icon, size: 18, color: YveColors.textPrimary),
              const SizedBox(height: 4),
              Text(
                label,
                style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: YveColors.textPrimary,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

