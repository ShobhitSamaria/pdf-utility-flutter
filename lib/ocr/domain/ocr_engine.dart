import 'ocr_result.dart';

/// Languages/scripts an OCR engine can be configured for.
///
/// ML Kit ships separate native models per script. Only [latin] is bundled by
/// default; the others require adding the corresponding Gradle dependency
/// (`com.google.mlkit:text-recognition-devanagari`, etc.) — see the Android
/// README note in `docs/OCR_ARCHITECTURE.md`. Keeping this enum engine-agnostic
/// lets the UI request a script without importing any ML Kit type.
enum OcrScript { latin, devanagari, chinese, japanese, korean }

/// Engine-independent configuration for an OCR run.
class OcrOptions {
  const OcrOptions({this.script = OcrScript.latin, this.mixed = false});

  /// The script the recognizer is configured with.
  ///
  /// For a [mixed] run this is the **first** of the two passes; the second is
  /// always [OcrScript.devanagari], since only that model can emit Devanagari
  /// code points.
  final OcrScript script;

  /// Whether to read the image a second time with another script's recognizer
  /// and merge the results (see `OcrMergePolicy`).
  ///
  /// A plain single-script engine ignores this; `MixedScriptOcrEngine` honours
  /// it. Costs roughly double the latency, so it is opt-in.
  final bool mixed;

  OcrOptions copyWith({OcrScript? script, bool? mixed}) =>
      OcrOptions(script: script ?? this.script, mixed: mixed ?? this.mixed);
}

/// The seam between the app and any concrete OCR implementation.
///
/// The UI and services depend only on this interface, so swapping ML Kit for
/// another on-device engine later requires no UI changes. The concrete
/// implementation lives in `lib/ocr/data/mlkit_ocr_engine.dart`.
abstract class OcrEngine {
  /// Recognizes text in the image at [imagePath] and returns structured,
  /// geometry-annotated results in image-pixel coordinates.
  ///
  /// Implementations must decode the image themselves (or reuse a decoder) so
  /// they can report accurate [SourceImageInfo] dimensions.
  Future<OcrResult> recognize({
    required String imagePath,
    OcrOptions options = const OcrOptions(),
  });

  /// Stable, human-readable name (e.g. `"Google ML Kit"`).
  String get name;

  /// Releases any native resources held by the engine.
  Future<void> dispose();
}
