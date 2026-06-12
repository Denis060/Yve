import 'dart:async';
import 'dart:io' show File;
import 'dart:typed_data';

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_cropper/image_cropper.dart';
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
/// Three stages:
///   1. Live camera viewfinder (camera plugin) → tap shutter to capture,
///      OR pick from gallery (image_picker).
///   2. Native cropper (image_cropper / UCrop on Android) → user trims
///      to a single question / removes glare / fixes rotation.
///   3. Bytes go to vision-ingest → scan result sheet → continue in chat.
///
/// The live preview is what makes the camera feel like a real scanner
/// instead of a black box. The crop step makes Yve readable on
/// worksheets, screenshots, and partial-page captures.
class ScanScreen extends ConsumerStatefulWidget {
  const ScanScreen({super.key});

  @override
  ConsumerState<ScanScreen> createState() => _ScanScreenState();
}

class _ScanScreenState extends ConsumerState<ScanScreen>
    with WidgetsBindingObserver {
  final ImagePicker _picker = ImagePicker();

  CameraController? _camera;
  Future<void>? _cameraInit;
  List<CameraDescription> _availableCameras = const <CameraDescription>[];
  String? _cameraError;

  bool _processing = false;
  bool _capturing = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _initCamera();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _safelyDisposeCamera(_camera);
    super.dispose();
  }

  /// Pause/resume the camera with the app lifecycle. Without this the
  /// preview keeps the camera locked even when the app is backgrounded,
  /// which Samsung and other vendors warn about with a notification.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final CameraController? cam = _camera;
    if (cam == null || !cam.value.isInitialized) return;
    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused) {
      _safelyDisposeCamera(cam);
      _camera = null;
      _cameraInit = null;
      if (mounted) setState(() {});
    } else if (state == AppLifecycleState.resumed) {
      _initCamera();
    }
  }

  /// camerax can throw `releaseFlutterSurfaceTexture() cannot be called
  /// if the flutterSurfaceProducer for the camera preview has not yet
  /// been initialized` when the user backs out of the scan screen
  /// before the native surface producer finishes attaching — the
  /// Dart-side `isInitialized` flag flips true at one point during
  /// setup but the platform-side producer isn't ready until slightly
  /// later. The dispose is happening anyway; swallowing the platform
  /// exception is harmless and keeps Sentry's signal clean
  /// (Sentry 7493500688, 2026-05-19).
  void _safelyDisposeCamera(CameraController? cam) {
    if (cam == null) return;
    try {
      cam.dispose();
    } catch (_) {
      // intentionally suppressed
    }
  }

  Future<void> _initCamera() async {
    try {
      _availableCameras = await availableCameras();
      if (_availableCameras.isEmpty) {
        setState(() => _cameraError = 'No camera found on this device.');
        return;
      }
      // Prefer the back camera (clearer text capture); fall back to
      // whatever's available. On desktop/laptop web that's usually a
      // front-facing webcam — fine for OCR if the user holds a page up.
      final CameraDescription chosen = _availableCameras.firstWhere(
        (CameraDescription c) => c.lensDirection == CameraLensDirection.back,
        orElse: () => _availableCameras.first,
      );
      // `camera_web` ignores ImageFormatGroup; mobile picks JPEG to
      // skip an unnecessary YUV→JPEG conversion at capture time.
      final CameraController controller = CameraController(
        chosen,
        ResolutionPreset.high,
        enableAudio: false,
        imageFormatGroup: kIsWeb ? null : ImageFormatGroup.jpeg,
      );
      _camera = controller;
      _cameraInit = controller.initialize();
      await _cameraInit;
      if (!mounted) return;
      setState(() => _cameraError = null);
    } catch (e) {
      if (!mounted) return;
      setState(() => _cameraError = _humanizeCameraError(e));
    }
  }

  String _humanizeCameraError(Object e) {
    final String s = e.toString().toLowerCase();
    if (s.contains('denied') || s.contains('permission')) {
      return 'Camera access is off for Yve. Enable it in Settings → '
          'Apps → Yve → Permissions.';
    }
    return 'Couldn\'t open the camera. Try again, or use Gallery.';
  }

  // ── Capture / cropping ─────────────────────────────────────────────

  Future<void> _captureFromCamera() async {
    if (_capturing) return;
    final CameraController? cam = _camera;
    if (cam == null || !cam.value.isInitialized) return;
    setState(() => _capturing = true);
    HapticFeedback.lightImpact();
    try {
      // Works on both mobile AND web — `camera_web` returns an XFile
      // whose path is a blob URL we never need to dereference directly;
      // `_ingestPickedFile` reads bytes via XFile.readAsBytes().
      final XFile shot = await cam.takePicture();
      if (!mounted) return;
      await _ingestPickedFile(shot);
    } catch (e) {
      if (!mounted) return;
      _showError(e, 'scan_capture');
    } finally {
      if (mounted) setState(() => _capturing = false);
    }
  }

  Future<void> _captureFromGallery() async {
    if (_processing) return;
    HapticFeedback.selectionClick();
    try {
      final XFile? file = await _picker.pickImage(
        source: ImageSource.gallery,
        maxWidth: 2400,
        maxHeight: 2400,
        imageQuality: 90,
      );
      if (file == null) return;
      if (!mounted) return;
      await _ingestPickedFile(file);
    } catch (e) {
      if (!mounted) return;
      _showError(e, 'scan_gallery');
    }
  }

  /// Bridge: on mobile run the captured image through the native
  /// cropper (UCrop on Android), on web skip the cropper (image_cropper
  /// has no web implementation) and feed bytes directly to ingest.
  /// Either way the OCR call receives a Uint8List + mime type.
  Future<void> _ingestPickedFile(XFile picked) async {
    if (kIsWeb) {
      final Uint8List bytes = await picked.readAsBytes();
      final String mime = picked.mimeType ?? 'image/jpeg';
      await _ingestBytes(bytes, mime);
      return;
    }
    await _runCropAndIngest(File(picked.path));
  }

  /// Hand the captured image to the native cropper. Lets the user trim
  /// glare, isolate a single question, or fix orientation before OCR.
  /// Mobile-only — `image_cropper` has no web implementation.
  Future<void> _runCropAndIngest(File sourceFile) async {
    final CroppedFile? cropped = await ImageCropper().cropImage(
      sourcePath: sourceFile.path,
      compressFormat: ImageCompressFormat.jpg,
      compressQuality: 88,
      uiSettings: <PlatformUiSettings>[
        AndroidUiSettings(
          toolbarTitle: 'Crop your scan',
          toolbarColor: YveColors.primary,
          toolbarWidgetColor: YveColors.textInverse,
          activeControlsWidgetColor: YveColors.accent,
          backgroundColor: const Color(0xFF0A0A0A),
          initAspectRatio: CropAspectRatioPreset.original,
          lockAspectRatio: false,
          hideBottomControls: false,
          showCropGrid: true,
        ),
      ],
    );
    if (cropped == null) {
      // User cancelled the crop — leave the scan screen as-is so they
      // can re-shoot if they want.
      return;
    }
    final Uint8List bytes = await File(cropped.path).readAsBytes();
    await _ingestBytes(bytes, 'image/jpeg');
  }

  Future<void> _ingestBytes(Uint8List bytes, String mime) async {
    setState(() => _processing = true);
    try {
      final ScanResult result = await ref
          .read(visionServiceProvider)
          .analyze(bytes: bytes, mimeType: mime);
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
      _showError(e, 'scan_ingest');
    } finally {
      if (mounted) setState(() => _processing = false);
    }
  }

  void _showError(Object e, String ctx) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(AppError.from(e, actionContext: ctx).userMessage)),
    );
  }

  void _openChatForAction(ScanResult result, ScanAction action) {
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

  // ── UI ────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: <Widget>[
        _Viewfinder(
          camera: _camera,
          error: _cameraError,
        ),
        Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          child: _ActionSheet(
            // Both web and mobile run through CameraController now,
            // so the same readiness check applies on both platforms.
            captureEnabled:
                _camera?.value.isInitialized == true && !_capturing,
            onCapture: _captureFromCamera,
            onGallery: _captureFromGallery,
            onType: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => const ChatScreen(),
              ),
            ),
          ),
        ),
        if (_processing)
          const Positioned.fill(child: YveReadingOverlay()),
      ],
    );
  }
}

class _Viewfinder extends StatelessWidget {
  const _Viewfinder({required this.camera, required this.error});
  final CameraController? camera;
  final String? error;

  @override
  Widget build(BuildContext context) {
    final double topInset = MediaQuery.of(context).padding.top;
    final bool ready = camera?.value.isInitialized == true;

    return DecoratedBox(
      decoration: const BoxDecoration(color: Color(0xFF0A0A0A)),
      child: SizedBox.expand(
        child: Stack(
          fit: StackFit.expand,
          children: <Widget>[
            if (ready)
              // The live preview itself. Wrapped in CameraPreview with a
              // FittedBox so it covers the screen without distortion.
              FittedBox(
                fit: BoxFit.cover,
                child: SizedBox(
                  width: camera!.value.previewSize?.height ?? 1080,
                  height: camera!.value.previewSize?.width ?? 1920,
                  child: CameraPreview(camera!),
                ),
              )
            else if (error != null)
              _CameraUnavailable(message: error!)
            else
              const Center(
                child: CircularProgressIndicator(
                  valueColor: AlwaysStoppedAnimation<Color>(YveColors.accent),
                ),
              ),

            // Darkening vignette around the crop guides for contrast
            // against bright paper — only when the preview is live.
            if (ready)
              IgnorePointer(
                child: Container(
                  decoration: const BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: <Color>[
                        Color(0xCC000000),
                        Color(0x33000000),
                        Color(0xCC000000),
                      ],
                      stops: <double>[0.0, 0.4, 1.0],
                    ),
                  ),
                ),
              ),

            // Top label
            Padding(
              padding: EdgeInsets.fromLTRB(
                YveSpacing.xl,
                topInset + 8,
                YveSpacing.xl,
                0,
              ),
              child: const Row(
                children: <Widget>[
                  _TopPill(
                    label: 'Scan',
                    icon: Icons.center_focus_strong_rounded,
                  ),
                ],
              ),
            ),

            // No crop-guide box: Yve captures the full frame and the user
            // trims it in the next step (like Gauth). A box here was
            // deceptive — it made people back the phone away to fit the
            // page inside it, producing tiny, far-away photos.
            const Positioned(
              bottom: 300,
              left: 0,
              right: 0,
              child: Center(
                child: Text(
                  'Fill the screen with your page — you can trim it next',
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

class _CameraUnavailable extends StatelessWidget {
  const _CameraUnavailable({required this.message});
  final String message;
  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            const Icon(
              Icons.camera_alt_outlined,
              size: 48,
              color: Color(0x80FFFFFF),
            ),
            const SizedBox(height: 14),
            Text(
              message,
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: Color(0xCCFFFFFF),
                fontSize: 14,
                height: 1.5,
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
        color: const Color(0x80000000),
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

// (Removed _CropGuidePainter — the camera no longer draws a crop-guide box;
// Yve captures the full frame and the user trims it in the next step.)

class _ActionSheet extends StatelessWidget {
  const _ActionSheet({
    required this.captureEnabled,
    required this.onCapture,
    required this.onGallery,
    required this.onType,
  });

  final bool captureEnabled;
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
            'Point your camera so the page fills the screen, tap Capture, '
            'then trim it before Yve reads.',
            style: TextStyle(fontSize: 13, color: YveColors.textSecondary),
          ),
          const SizedBox(height: YveSpacing.xl),
          FilledButton.icon(
            onPressed: captureEnabled ? onCapture : null,
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
