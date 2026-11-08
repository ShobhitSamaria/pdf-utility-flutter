import 'dart:async';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app/app_brand.dart';
import '../app/app_theme.dart';

/// Why the camera is not usable, in terms the user can act on.
enum _CameraStatus {
  /// Asking the camera to start.
  starting,

  /// Preview is live and the shutter works.
  ready,

  /// The user (or the platform) has not granted camera access.
  permissionDenied,

  /// No camera, or the camera failed to start.
  unavailable,
}

/// Takes **one** photo for text recognition and returns its path.
///
/// The document-capture screen takes a whole session and returns a list; this
/// one answers a different question — "which image should be read?" — so it
/// takes exactly one picture and leaves. The chrome is deliberately the same
/// language as the multi-page camera: a dark surround, a document guide, a
/// hint pill and a proper shutter, so the two camera experiences do not feel
/// like different apps.
class CameraCaptureScreen extends StatefulWidget {
  const CameraCaptureScreen({super.key});

  @override
  State<CameraCaptureScreen> createState() => _CameraCaptureScreenState();
}

class _CameraCaptureScreenState extends State<CameraCaptureScreen>
    with WidgetsBindingObserver {
  CameraController? _controller;
  _CameraStatus _status = _CameraStatus.starting;
  bool _isCapturing = false;
  bool _torchOn = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_start());
  }

  Future<void> _start() async {
    try {
      final cameras = await availableCameras();
      if (!mounted) return;
      if (cameras.isEmpty) {
        setState(() => _status = _CameraStatus.unavailable);
        return;
      }

      // Prefer the rear camera — best for documents.
      final camera = cameras.firstWhere(
        (c) => c.lensDirection == CameraLensDirection.back,
        orElse: () => cameras.first,
      );

      final controller = CameraController(
        camera,
        ResolutionPreset.high, // good OCR fidelity without max memory cost
        enableAudio: false,
        imageFormatGroup: ImageFormatGroup.jpeg,
      );
      await controller.initialize();
      if (!mounted) {
        await controller.dispose();
        return;
      }
      setState(() {
        _controller = controller;
        _status = _CameraStatus.ready;
      });
    } on CameraException catch (error) {
      if (!mounted) return;
      final denied =
          error.code == 'CameraAccessDenied' ||
          error.code == 'CameraAccessDeniedWithoutPrompt' ||
          error.code == 'CameraAccessRestricted';
      setState(
        () => _status = denied
            ? _CameraStatus.permissionDenied
            : _CameraStatus.unavailable,
      );
    } catch (_) {
      if (!mounted) return;
      setState(() => _status = _CameraStatus.unavailable);
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.inactive) {
      final controller = _controller;
      _controller = null;
      unawaited(controller?.dispose());
    } else if (state == AppLifecycleState.resumed &&
        _status != _CameraStatus.permissionDenied) {
      setState(() => _status = _CameraStatus.starting);
      unawaited(_start());
    }
  }

  Future<void> _toggleTorch() async {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) return;

    final next = !_torchOn;
    try {
      await controller.setFlashMode(next ? FlashMode.torch : FlashMode.off);
      if (mounted) setState(() => _torchOn = next);
    } on CameraException {
      // Some cameras report a torch they cannot actually drive; the flash stays
      // off and the button is left alone rather than lying about the state.
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('This camera has no torch.')),
      );
    }
  }

  Future<void> _capture() async {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized || _isCapturing) {
      return;
    }
    setState(() => _isCapturing = true);
    try {
      final file = await controller.takePicture();
      if (!mounted) return;
      Navigator.of(context).pop(file.path);
    } catch (_) {
      if (!mounted) return;
      setState(() => _isCapturing = false);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Could not take the photo. Please try again.'),
        ),
      );
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        elevation: 0,
        systemOverlayStyle: SystemUiOverlayStyle.light.copyWith(
          statusBarColor: Colors.transparent,
          systemNavigationBarColor: Colors.black,
        ),
        // As on the multi-page camera: the theme's dark title colour must not
        // win over this screen's white-on-black chrome.
        titleTextStyle: Theme.of(
          context,
        ).textTheme.titleMedium?.copyWith(color: Colors.white),
        leading: IconButton(
          tooltip: 'Close',
          onPressed: () => Navigator.of(context).maybePop(),
          icon: const Icon(Icons.close),
        ),
        // The AppBar theme's title style is the brand navy, which disappears
        // against a live camera preview. This screen is dark chrome, so the
        // instruction is set in white here rather than by changing the theme.
        title: const Text(
          'Scan document',
          style: TextStyle(
            color: Colors.white,
            fontSize: 20,
            fontWeight: FontWeight.w600,
          ),
        ),
        actions: [
          IconButton(
            tooltip: _torchOn ? 'Turn off torch' : 'Turn on torch',
            onPressed: _status == _CameraStatus.ready
                ? () => unawaited(_toggleTorch())
                : null,
            icon: Icon(_torchOn ? Icons.flashlight_on : Icons.flashlight_off),
          ),
        ],
      ),
      body: switch (_status) {
        _CameraStatus.starting => const Center(
          child: CircularProgressIndicator(),
        ),
        _CameraStatus.ready => _buildPreview(),
        _CameraStatus.permissionDenied => _CameraProblem(
          permissionDenied: true,
          onRetry: () {
            setState(() => _status = _CameraStatus.starting);
            unawaited(_start());
          },
        ),
        _CameraStatus.unavailable => _CameraProblem(
          permissionDenied: false,
          onRetry: () {
            setState(() => _status = _CameraStatus.starting);
            unawaited(_start());
          },
        ),
      },
    );
  }

  Widget _buildPreview() {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) {
      return const Center(
        child: Text(
          'The camera stopped. Reopen this screen to continue.',
          textAlign: TextAlign.center,
          style: TextStyle(color: Colors.white),
        ),
      );
    }

    return Column(
      children: [
        Expanded(
          child: Stack(
            fit: StackFit.expand,
            children: [
              Center(child: CameraPreview(controller)),
              // The document guide: where to put the page. Decoration only —
              // nothing is cropped, so a page that does not fit is still
              // captured whole.
              const IgnorePointer(
                child: CustomPaint(painter: _CaptureGuides()),
              ),
              Positioned(
                top: 12,
                left: AppSpacing.lg,
                right: AppSpacing.lg,
                child: Center(
                  child: _HintPill(
                    text: _isCapturing
                        ? 'Taking photo…'
                        : 'Align the page inside the frame',
                  ),
                ),
              ),
            ],
          ),
        ),
        Container(
          color: Colors.black,
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.lg,
            AppSpacing.md,
            AppSpacing.lg,
            AppSpacing.xl,
          ),
          child: SafeArea(
            top: false,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text(
                  'The photo is read on this device.',
                  style: TextStyle(color: Colors.white70, fontSize: 12.5),
                ),
                const SizedBox(height: AppSpacing.lg),
                _ShutterButton(
                  enabled: !_isCapturing,
                  capturing: _isCapturing,
                  onPressed: () => unawaited(_capture()),
                ),
                const SizedBox(height: AppSpacing.md),
                const Text(
                  'Centre the page and keep it flat for the best result.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.white70, fontSize: 12.5),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

/// Small pill over the preview: one instruction, no permanent chrome.
class _HintPill extends StatelessWidget {
  const _HintPill({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        text,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 12.5,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

/// Camera-unavailable state: what happened, and the one thing to try.
class _CameraProblem extends StatelessWidget {
  const _CameraProblem({required this.permissionDenied, required this.onRetry});

  final bool permissionDenied;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(AppSpacing.xxl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              permissionDenied
                  ? Icons.no_photography_outlined
                  : Icons.videocam_off_outlined,
              color: Colors.white70,
              size: 40,
            ),
            const SizedBox(height: AppSpacing.lg),
            Text(
              permissionDenied
                  ? 'Camera access is needed to scan a page'
                  : 'The camera could not be started',
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 17,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: AppSpacing.sm),
            Text(
              permissionDenied
                  ? 'Allow camera access for ${AppBrand.name} in Android Settings, '
                        'then try again. You can also choose a photo from your '
                        'gallery instead.'
                  : 'This device reported no usable camera. You can still '
                        'choose a photo from your gallery.',
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white70, fontSize: 13.5),
            ),
            const SizedBox(height: AppSpacing.xl),
            FilledButton.icon(
              onPressed: onRetry,
              icon: const Icon(Icons.refresh, size: 20),
              label: const Text('Try again'),
            ),
            const SizedBox(height: AppSpacing.sm),
            TextButton(
              onPressed: () => Navigator.of(context).maybePop(),
              child: const Text(
                'Go back',
                style: TextStyle(color: Colors.white70),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The shutter: a filled disc inside a ring, dimmed while a capture is running.
class _ShutterButton extends StatelessWidget {
  const _ShutterButton({
    required this.enabled,
    required this.capturing,
    required this.onPressed,
  });

  final bool enabled;
  final bool capturing;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: 'Take photo',
      child: GestureDetector(
        onTap: enabled ? onPressed : null,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          width: 74,
          height: 74,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(
              color: enabled ? Colors.white : Colors.white38,
              width: 4,
            ),
          ),
          child: Padding(
            padding: const EdgeInsets.all(7),
            child: DecoratedBox(
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: enabled ? Colors.white : Colors.white38,
              ),
              child: capturing
                  ? const Padding(
                      padding: EdgeInsets.all(16),
                      child: CircularProgressIndicator(
                        strokeWidth: 2.5,
                        color: AppColors.primary,
                      ),
                    )
                  : const SizedBox.expand(),
            ),
          ),
        ),
      ),
    );
  }
}

/// Four L-shaped corners: a viewfinder, not a crop.
class _CaptureGuides extends CustomPainter {
  const _CaptureGuides();

  @override
  void paint(Canvas canvas, Size size) {
    final inset = size.shortestSide * 0.08;
    final rect = Rect.fromLTRB(
      inset,
      inset * 0.6,
      size.width - inset,
      size.height - inset * 0.6,
    );
    final arm = rect.shortestSide * 0.12;

    final stroke = Paint()
      ..color = Colors.white.withValues(alpha: 0.9)
      ..strokeWidth = 3
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke;

    final path = Path()
      ..moveTo(rect.left, rect.top + arm)
      ..lineTo(rect.left, rect.top)
      ..lineTo(rect.left + arm, rect.top)
      ..moveTo(rect.right - arm, rect.top)
      ..lineTo(rect.right, rect.top)
      ..lineTo(rect.right, rect.top + arm)
      ..moveTo(rect.right, rect.bottom - arm)
      ..lineTo(rect.right, rect.bottom)
      ..lineTo(rect.right - arm, rect.bottom)
      ..moveTo(rect.left + arm, rect.bottom)
      ..lineTo(rect.left, rect.bottom)
      ..lineTo(rect.left, rect.bottom - arm);

    canvas.drawPath(path, stroke);
  }

  @override
  bool shouldRepaint(covariant _CaptureGuides oldDelegate) => false;
}
