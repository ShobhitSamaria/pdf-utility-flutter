import 'package:flutter/widgets.dart';

import '../ocr/domain/ocr_script_mode.dart';
import '../ocr/domain/ocr_service.dart';
import '../translation/domain/translation_service.dart';

/// Minimal dependency scope — no third-party state-management package.
///
/// Exposes the [OcrService] and [TranslationService] plus the two small pieces
/// of session state the UI shares: a global [debugGeometry] flag and the
/// [ocrScriptMode] the user has chosen for OCR runs. This keeps screens
/// decoupled from both implementations (they never import ML Kit or the
/// translation engine) while staying lightweight, which matters on a
/// memory-constrained device.
///
/// The two features are siblings on purpose: neither service knows about the
/// other, and `lib/ocr/**` never imports `lib/translation/**`.
///
/// Translation is a **permanent, always-available** feature of the app: there is
/// no build flag, `dart-define` or debug switch that decides whether it exists.
/// The scope always carries the service, and every screen renders its translation
/// UI unconditionally.
class AppScope extends InheritedWidget {
  const AppScope({
    super.key,
    required this.ocrService,
    required this.translationService,
    required this.debugGeometry,
    required this.ocrScriptMode,
    required super.child,
  });

  final OcrService ocrService;

  final TranslationService translationService;

  /// When `true`, OCR overlay widgets paint bounding boxes and word labels to
  /// help verify coordinate mapping. **Defaults to false** and must never be
  /// enabled in a shipped build.
  final ValueNotifier<bool> debugGeometry;

  /// The script the next OCR run uses.
  ///
  /// Session state rather than per-screen state, so a choice made on the home
  /// screen still applies when a result screen re-runs the same image with a
  /// different script.
  final ValueNotifier<OcrScriptMode> ocrScriptMode;

  static AppScope of(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<AppScope>();
    assert(scope != null, 'AppScope was not found in the widget tree.');
    return scope!;
  }

  @override
  bool updateShouldNotify(AppScope oldWidget) =>
      ocrService != oldWidget.ocrService ||
      translationService != oldWidget.translationService ||
      debugGeometry != oldWidget.debugGeometry ||
      ocrScriptMode != oldWidget.ocrScriptMode;
}
