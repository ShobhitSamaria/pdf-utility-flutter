import 'ocr_engine.dart';
import 'ocr_result.dart';
import 'ocr_script_mode.dart';

/// App-facing OCR API.
///
/// This is the ONLY OCR type the UI layer references. It intentionally hides
/// both the engine choice ([OcrEngine]) and its configuration, so screens never
/// import ML Kit and swapping engines is a one-line change in the app scope.
///
/// The UI speaks [OcrScriptMode] — the user's choice, "decide for me" by
/// default — rather than [OcrScript], which describes a single recognizer. The
/// service is where one becomes the other, so a screen can offer "mixed" or
/// "auto" without knowing that the first means two passes and a merge, and the
/// second means a probe followed by a decision.
abstract class OcrService {
  /// Recognizes text in the image at [imagePath], returning structured,
  /// geometry-annotated results in image-pixel coordinates.
  ///
  /// [mode] selects which recognizer(s) run; see [OcrScriptMode]. A mixed run is
  /// roughly twice as slow as a single-script one, and an auto run costs one pass
  /// on a clearly Latin page or two on a Devanagari/mixed one.
  Future<OcrResult> recognizeImage(
    String imagePath, {
    OcrScriptMode mode = OcrScriptMode.defaultMode,
  });

  /// Name of the underlying engine (for diagnostics/logging).
  String get engineName;

  /// Releases engine resources.
  Future<void> dispose();
}
