import 'dart:async';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';

import '../../app/app_theme.dart';

/// Why the camera is not usable, in terms the user can act on.
enum _CaptureStatus {
  /// Asking the camera to start.
  starting,

  /// Preview is live and the shutter works.
  ready,

  /// The user (or the platform) has not granted camera access.
  permissionDenied,

  /// No camera, or the camera failed to start.
  unavailable,
}

/// Captures **several pages** for a new PDF, in one session.
///
/// The Figma capture frame, made to work: a live preview with a document guide,
/// a shutter that keeps what it takes, a running page count, and one way out —
/// **Review** — which hands the captured pages to the review screen.
///
/// Why this is a separate screen from `CameraCaptureScreen`
/// -------------------------------------------------------
/// The OCR camera answers a different question. It takes exactly one picture
/// and returns its path, and its caller immediately leaves to run recognition.
/// This one takes many, keeps them, and lets the user carry on shooting until
/// they are done. Sharing one widget would mean a mode flag in every branch —
/// and the OCR path, which is the app's most-used route, would be the one
/// paying the complexity cost.
///
/// Memory: only **paths** are kept. Each capture is written to a file by the
/// camera plugin and never decoded here, so a ten-page session holds ten
/// strings and no bitmaps.
/// Opens the document camera and returns it ready to take pictures.
///
/// Answering `null` means "this device has no camera"; throwing a
/// `CameraException` reports whatever went wrong (including a refused
/// permission). Injectable so the two states a user actually gets stuck on —
/// no camera, and permission denied — can be tested without hardware; the
/// preview itself cannot be, which is why the ready state is device-only.
typedef PdfCameraStarter = Future<CameraController?> Function();

class PdfCaptureScreen extends StatefulWidget {
  const PdfCaptureScreen({super.key, this.pageLimit = 50, this.startCamera});

  /// Upper bound on pages in one session.
  ///
  /// Not a technical limit — a guard against a stuck shutter (or a child with a
  /// phone) turning into an unbounded number of temporary files.
  final int pageLimit;

  /// Camera seam (see [PdfCameraStarter]).
  final PdfCameraStarter? startCamera;

  @override
  State<PdfCaptureScreen> createState() => _PdfCaptureScreenState();
}

class _PdfCaptureScreenState extends State<PdfCaptureScreen>
    with WidgetsBindingObserver {
  CameraController? _controller;
  Future<void>? _initializeFuture;

  /// Paths of the pages captured so far, in capture order.
  final List<String> _pages = <String>[];

  _CaptureStatus _status = _CaptureStatus.starting;
  String? _statusDetail;
  bool _capturing = false;
  bool _torchOn = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _initializeFuture = _start();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final controller = _controller;
    if (controller == null) return;

    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused) {
      // The camera plugin requires the controller to be released when the app
      // is no longer in the foreground: holding it leaves the camera claimed by
      // a background app, and on some devices the preview never comes back.
      final current = _controller;
      _controller = null;
      current?.dispose();
    } else if (state == AppLifecycleState.resumed) {
      if (mounted) {
        setState(() {
          _status = _CaptureStatus.starting;
          _initializeFuture = _start();
        });
      } else {
        _initializeFuture = _start();
      }
    }
  }

  /// The real camera: the rear lens, if the device has one, at the highest
  /// resolution the plugin offers that is still safe for OCR-sized photos.
  Future<CameraController?> _openRearCamera() async {
    final cameras = await availableCameras();
    if (cameras.isEmpty) return null;

    // Rear camera first: it is the one that can see a document lying on a
    // table.
    final camera = cameras.firstWhere(
      (description) => description.lensDirection == CameraLensDirection.back,
      orElse: () => cameras.first,
    );

    final controller = CameraController(
      camera,
      ResolutionPreset.high,
      enableAudio: false,
      imageFormatGroup: ImageFormatGroup.jpeg,
    );
    await controller.initialize();
    return controller;
  }

  /// Starts the camera, turning every failure into a state the screen can
  /// explain — never an unhandled exception behind a spinner.
  Future<void> _start() async {
    try {
      final controller = await (widget.startCamera ?? _openRearCamera)();
      if (!mounted) return;
      if (controller == null) {
        _setStatus(_CaptureStatus.unavailable, 'No camera was found.');
        return;
      }

      setState(() {
        _controller = controller;
        _status = _CaptureStatus.ready;
        _statusDetail = null;
      });
    } on CameraException catch (error) {
      // The plugin reports a denied permission as its own code, which is the
      // difference between \"allow the camera\" and \"this device has no
      // camera\" — two messages the user acts on very differently.
      final denied =
          (error.code == 'CameraAccessDenied' ||
          error.code == 'CameraAccessDeniedWithoutPrompt' ||
          error.code == 'CameraAccessRestricted');
      _setStatus(
        denied ? _CaptureStatus.permissionDenied : _CaptureStatus.unavailable,
        error.description,
      );
    } catch (error) {
      _setStatus(_CaptureStatus.unavailable, '$error');
    }
  }

  void _setStatus(_CaptureStatus status, String? detail) {
    if (!mounted) return;
    setState(() {
      _status = status;
      _statusDetail = detail;
    });
  }

  Future<void> _capture() async {
    final controller = _controller;
    if (controller == null ||
        !controller.value.isInitialized ||
        _capturing ||
        _pages.length >= widget.pageLimit) {
      return;
    }

    setState(() => _capturing = true);
    try {
      final file = await controller.takePicture();
      if (!mounted) return;
      setState(() {
        _pages.add(file.path);
        _capturing = false;
      });
    } on CameraException catch (error) {
      if (!mounted) return;
      setState(() => _capturing = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'That page was not captured: ${error.description ?? error.code}',
          ),
        ),
      );
    } catch (error) {
      if (!mounted) return;
      setState(() => _capturing = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('That page was not captured. Please try again.'),
        ),
      );
    }
  }

  Future<void> _toggleTorch() async {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) return;
    final next = !_torchOn;
    try {
      await controller.setFlashMode(next ? FlashMode.torch : FlashMode.off);
      if (!mounted) return;
      setState(() => _torchOn = next);
    } on CameraException {
      // Some cameras report a torch they cannot actually drive; the flash stays
      // off and the button is left alone rather than lying about the state.
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('This camera has no torch.')),
      );
    }
  }

  /// Removes the most recent page — the recovery for a shot taken by accident,
  /// without leaving for the review screen.
  void _undoLast() {
    if (_pages.isEmpty) return;
    setState(() => _pages.removeLast());
  }

  Future<void> _review() async {
    if (_pages.isEmpty) return;
    Navigator.of(context).pop(List<String>.unmodifiable(_pages));
  }

  /// Asks before throwing away captured pages.
  ///
  /// Closing with pages in hand is the one destructive action on this screen,
  /// so it is the one that asks — and it says how many pages are at stake.
  Future<void> _close() async {
    if (_pages.isEmpty) {
      Navigator.of(context).pop();
      return;
    }

    final keep = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Discard these pages?'),
        content: Text(
          _pages.length == 1
              ? 'The page you captured will be discarded.'
              : 'The ${_pages.length} pages you captured will be discarded.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Keep capturing'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Discard'),
          ),
        ],
      ),
    );

    if (!mounted || keep != true) return;
    Navigator.of(context).pop();
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
        leading: IconButton(
          tooltip: 'Close',
          onPressed: () => unawaited(_close()),
          icon: const Icon(Icons.close),
        ),
        title: const Text('Capture pages'),
        actions: [
          IconButton(
            tooltip: _torchOn ? 'Turn off torch' : 'Turn on torch',
            onPressed: _status == _CaptureStatus.ready
                ? () => unawaited(_toggleTorch())
                : null,
            icon: Icon(_torchOn ? Icons.flashlight_on : Icons.flashlight_off),
          ),
        ],
      ),
      body: FutureBuilder<void>(
        future: _initializeFuture,
        builder: (context, snapshot) {
          if (_status == _CaptureStatus.starting) {
            return const Center(child: CircularProgressIndicator());
          }
          if (_status != _CaptureStatus.ready) {
            return _CameraProblem(
              permissionDenied: _status == _CaptureStatus.permissionDenied,
              detail: _statusDetail,
              onRetry: () => setState(() {
                _status = _CaptureStatus.starting;
                _initializeFuture = _start();
              }),
            );
          }

          final controller = _controller;
          if (controller == null || !controller.value.isInitialized) {
            return const Center(
              child: Text(
                'The camera stopped. Reopen this screen to continue.',
                style: TextStyle(color: Colors.white),
                textAlign: TextAlign.center,
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
                    // The document guide: where to put the page. Decoration
                    // only — nothing is cropped, so a page that does not fit
                    // inside it is still captured whole.
                    const IgnorePointer(
                      child: CustomPaint(painter: _CaptureGuides()),
                    ),
                    Positioned(
                      top: 12,
                      left: 0,
                      right: 0,
                      child: Center(child: _PageCounter(count: _pages.length)),
                    ),
                  ],
                ),
              ),
              _CaptureControls(
                pageCount: _pages.length,
                canCapture: _pages.length < widget.pageLimit,
                capturing: _capturing,
                onCapture: () => unawaited(_capture()),
                onUndo: _pages.isEmpty ? null : _undoLast,
                onReview: _pages.isEmpty ? null : () => unawaited(_review()),
              ),
            ],
          );
        },
      ),
    );
  }
}

/// Small pill showing how many pages have been captured so far.
class _PageCounter extends StatelessWidget {
  const _PageCounter({required this.count});

  final int count;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        count == 0
            ? 'Align the page inside the frame'
            : (count == 1 ? '1 page captured' : '$count pages captured'),
        style: const TextStyle(
          color: Colors.white,
          fontSize: 12.5,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

/// Shutter, undo and the **Review** action.
class _CaptureControls extends StatelessWidget {
  const _CaptureControls({
    required this.pageCount,
    required this.canCapture,
    required this.capturing,
    required this.onCapture,
    required this.onUndo,
    required this.onReview,
  });

  final int pageCount;
  final bool canCapture;
  final bool capturing;
  final VoidCallback onCapture;
  final VoidCallback? onUndo;
  final VoidCallback? onReview;

  @override
  Widget build(BuildContext context) {
    return Container(
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
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: onReview,
                icon: const Icon(Icons.fact_check_outlined, size: 20),
                label: const Text('Review pages'),
              ),
            ),
            const SizedBox(height: AppSpacing.md),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                // Undo mirrors the shutter rather than sitting beside it, so
                // the shutter stays the centre of the row.
                IconButton(
                  tooltip: 'Delete the last page',
                  onPressed: onUndo,
                  iconSize: 26,
                  color: Colors.white,
                  disabledColor: Colors.white24,
                  icon: const Icon(Icons.undo),
                ),
                _ShutterButton(
                  enabled: canCapture && !capturing,
                  capturing: capturing,
                  onPressed: onCapture,
                ),
                // Counts the pages, so the two ends of the row are the two
                // pieces of state: what I can undo, and what I have.
                SizedBox(
                  width: 48,
                  child: Center(
                    child: Text(
                      pageCount == 0 ? '' : '$pageCount',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 18,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ),
              ],
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
      label: 'Capture page',
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
                      padding: EdgeInsets.all(14),
                      child: CircularProgressIndicator(strokeWidth: 3),
                    )
                  : null,
            ),
          ),
        ),
      ),
    );
  }
}

/// Corner brackets showing where to put the page.
///
/// Purely a guide: the capture is the camera's own full frame, so a document
/// that spills outside the brackets is still recorded whole. That is the honest
/// choice — a guide that cropped would silently cut off the edges of a page the
/// user then could not get back.
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

    // Four L-shaped corners rather than a full rectangle: the frame reads as a
    // viewfinder and does not fight the document's own edges.
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

/// Camera-unavailable state: what happened, and the one thing to try.
class _CameraProblem extends StatelessWidget {
  const _CameraProblem({
    required this.permissionDenied,
    required this.detail,
    required this.onRetry,
  });

  final bool permissionDenied;
  final String? detail;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
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
                  ? 'Camera access is needed to capture pages'
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
                  ? 'Allow camera access for PDF Utility in Android Settings, then '
                        'try again. You can also add pages from your gallery instead.'
                  : (detail == null
                        ? 'This device reported no usable camera.'
                        : detail!),
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
