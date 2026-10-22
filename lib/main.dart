import 'package:flutter/material.dart';

import 'app/app_scope.dart';
import 'app/app_theme.dart';
import 'ocr/data/bounded_ocr_service.dart';
import 'ocr/data/local_ocr_service.dart';
import 'ocr/data/mixed_script_ocr_engine.dart';
import 'ocr/data/mlkit_ocr_engine.dart';
import 'ocr/data/orientation_aware_ocr_service.dart';
import 'ocr/domain/ocr_script_mode.dart';
import 'ocr/domain/ocr_service.dart';
import 'screens/home_screen.dart';
import 'translation/data/local_mlkit_translation_service.dart';
import 'translation/domain/translation_service.dart';

/// Composition root.
///
/// This is the single place that picks concrete engines. Swapping engines
/// (or injecting fakes in tests) requires changing only these functions — the
/// UI depends on the [OcrService] / [TranslationService] abstractions, never on
/// ML Kit directly.
///
/// The single-script ML Kit engine is wrapped in [MixedScriptOcrEngine], which
/// adds the experimental two-pass mixed-script mode and is a transparent
/// pass-through otherwise, and then in [BoundedOcrService], which guarantees a
/// recognition call always answers instead of spinning forever.
///
/// [OrientationAwareOcrService] sits on the **outside**, because it needs the
/// finished reading (ML Kit's line angles are the only evidence of which way the
/// page is turned) and because its corrective second pass should get the same
/// timeout guarantee as any other call. The timeout budget is therefore per
/// pass, and a sideways page legitimately uses two of them.
OcrService createOcrService() => OrientationAwareOcrService(
  inner: BoundedOcrService(
    delegate: LocalOcrService(
      engine: MixedScriptOcrEngine(delegate: MlKitOcrEngine()),
    ),
  ),
);

/// On-device translation: ML Kit Translation for the text and ML Kit Language
/// Identification to resolve the "Auto-detect" source. Nothing leaves the
/// device.
TranslationService createTranslationService() => LocalMlKitTranslationService();

void main() {
  runApp(
    PdfUtilityApp(
      ocrService: createOcrService(),
      translationService: createTranslationService(),
    ),
  );
}

class PdfUtilityApp extends StatefulWidget {
  const PdfUtilityApp({
    super.key,
    required this.ocrService,
    required this.translationService,
  });

  final OcrService ocrService;
  final TranslationService translationService;

  @override
  State<PdfUtilityApp> createState() => _PdfUtilityAppState();
}

class _PdfUtilityAppState extends State<PdfUtilityApp> {
  /// Global debug switch for OCR geometry.
  ///
  /// OFF by default by design: the overlay must never show permanent
  /// rectangles/scrim. It exists purely to verify coordinate mapping during
  /// development.
  final ValueNotifier<bool> _debugGeometry = ValueNotifier<bool>(false);

  /// The script chosen for OCR runs, shared across screens so a result screen
  /// can re-run the same image with a different one.
  final ValueNotifier<OcrScriptMode> _ocrScriptMode =
      ValueNotifier<OcrScriptMode>(OcrScriptMode.defaultMode);

  @override
  void dispose() {
    _debugGeometry.dispose();
    _ocrScriptMode.dispose();
    widget.ocrService.dispose();
    widget.translationService.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AppScope(
      ocrService: widget.ocrService,
      translationService: widget.translationService,
      debugGeometry: _debugGeometry,
      ocrScriptMode: _ocrScriptMode,
      // No translation switch is passed, because there isn't one: translation is
      // a permanent feature of the app. It used to be gated behind a
      // `--dart-define=ENABLE_TRANSLATION=true` build flag, which meant the
      // normal build shipped with no way to reach it at all — the whole feature
      // was invisible unless you happened to know the define. The service is
      // always wired here and the UI always offers it.
      child: MaterialApp(
        title: 'PDF Utility',
        debugShowCheckedModeBanner: false,
        // One place defines the app's visual language: see `app_theme.dart`
        // for the tokens read off the approved Figma design.
        theme: buildAppTheme(),
        home: const HomeScreen(),
      ),
    );
  }
}
