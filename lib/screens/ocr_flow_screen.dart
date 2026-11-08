import 'dart:async';

import 'package:flutter/material.dart';

import '../app/app_scope.dart';
import '../app/app_theme.dart';
import '../ocr/data/image_source_service.dart';
import '../ocr/presentation/ocr_failure_notice.dart';
import 'camera_capture_screen.dart';
import 'extract_text_screen.dart';
import 'ocr_result_screen.dart';

/// Owns one OCR run from source selection to the result screen.
///
/// Why this screen exists
/// ----------------------
/// The camera and the gallery picker both used to return to Home, and Home then
/// ran the recogniser while it was the visible route. Recognition takes seconds,
/// so the user saw Home flash between the picker/camera and the result. This
/// route stays above Home for the whole operation: the camera/picker is pushed
/// on top of it, its progress state is what the user sees while the text is
/// read, and it is replaced by the result. Home is never revealed in between.
///
/// It is also the single place that runs OCR for both image sources, so their
/// failure handling and progress reporting stay identical.
class OcrFlowScreen extends StatefulWidget {
  const OcrFlowScreen({
    super.key,
    required this.source,
    this.capturePage,
    this.pickFromGallery,
  });

  /// Camera or gallery. PDF import has its own screen and never comes here.
  final ExtractTextSource source;

  /// Injectable camera capture, for widget tests.
  final Future<String?> Function(BuildContext context)? capturePage;

  /// Injectable gallery picker, for widget tests.
  final Future<String?> Function()? pickFromGallery;

  @override
  State<OcrFlowScreen> createState() => _OcrFlowScreenState();
}

class _OcrFlowScreenState extends State<OcrFlowScreen> {
  final ImageSourceService _imageSource = ImageSourceService();

  bool _reading = false;
  Timer? _ticker;
  Duration _elapsed = Duration.zero;
  static const Duration _tick = Duration(milliseconds: 200);

  @override
  void initState() {
    super.initState();
    // Navigation is not allowed during initState; start on the first frame.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_begin());
    });
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  Future<void> _begin() async {
    String? path;
    try {
      switch (widget.source) {
        case ExtractTextSource.camera:
          final capture =
              widget.capturePage ??
              (BuildContext context) => Navigator.of(context).push<String>(
                MaterialPageRoute<String>(
                  builder: (_) => const CameraCaptureScreen(),
                ),
              );
          path = await capture(context);
        case ExtractTextSource.gallery:
          final pick = widget.pickFromGallery ?? _imageSource.pickFromGallery;
          path = await pick();
        case ExtractTextSource.importPdf:
          // Unreachable from the OCR Scanner wiring: PDF import goes straight
          // to PdfImportScreen. Close rather than pretend to handle it here.
          if (mounted) Navigator.of(context).pop();
          return;
      }
    } catch (error, stackTrace) {
      if (!mounted) return;
      showOcrFailure(
        context,
        error,
        stackTrace: stackTrace,
        where: 'Image selection',
      );
      Navigator.of(context).pop();
      return;
    }

    if (!mounted) return;
    if (path == null) {
      // Cancel is a normal outcome: leave without reading anything.
      Navigator.of(context).pop();
      return;
    }
    await _recognize(path);
  }

  Future<void> _recognize(String path) async {
    final scope = AppScope.of(context);
    final navigator = Navigator.of(context);
    final mode = scope.ocrScriptMode.value;

    setState(() => _reading = true);
    _ticker?.cancel();
    _ticker = Timer.periodic(_tick, (_) {
      if (!mounted) return;
      setState(() => _elapsed += _tick);
    });

    try {
      final result = await scope.ocrService.recognizeImage(path, mode: mode);
      _ticker?.cancel();
      _ticker = null;
      if (!mounted) return;
      // Replace progress with the result: Back from the result goes Home, not
      // back to a progress screen for work that already finished.
      navigator.pushReplacement(
        MaterialPageRoute<void>(
          builder: (_) => OcrResultScreen(result: result),
        ),
      );
    } catch (error, stackTrace) {
      _ticker?.cancel();
      _ticker = null;
      if (!mounted) return;
      setState(() => _reading = false);
      // Same reporter as every other OCR entry point.
      showOcrFailure(context, error, stackTrace: stackTrace);
      navigator.pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      backgroundColor: AppColors.page,
      appBar: AppBar(
        backgroundColor: AppColors.page,
        surfaceTintColor: Colors.transparent,
        title: const Text('Reading text'),
        automaticallyImplyLeading: false,
      ),
      body: SafeArea(
        top: false,
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(AppSpacing.xxl),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const CircularProgressIndicator(),
                const SizedBox(height: AppSpacing.xl),
                Text(
                  _reading ? 'Reading text…' : 'Preparing the scan…',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.titleMedium?.copyWith(
                    color: AppColors.ink,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                if (_reading) ...[
                  const SizedBox(height: AppSpacing.sm),
                  Text(
                    '${(_elapsed.inMilliseconds / 1000).toStringAsFixed(1)} s',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: AppColors.muted,
                    ),
                  ),
                ],
                const SizedBox(height: AppSpacing.md),
                Text(
                  'The page is being read on this device. Nothing is uploaded.',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: AppColors.muted,
                    height: 1.4,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
