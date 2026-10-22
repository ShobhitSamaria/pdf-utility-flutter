import '../domain/ocr_engine.dart';
import '../domain/ocr_merge_policy.dart';
import '../domain/ocr_result.dart';

/// Adds the experimental **mixed-script** capability to any single-script
/// [OcrEngine] by reading the image twice and merging the results.
///
/// Composition, not inheritance: [delegate] stays a plain one-script engine
/// (the ML Kit one) and this decorator is the only class that knows the page
/// may need two passes. When [OcrOptions.mixed] is false — which is every run
/// the app makes by default — this is a transparent pass-through with no extra
/// work at all.
///
/// Two passes, run **sequentially**
/// ------------------------------
/// ML Kit's recognizers share native threads and model memory; running the
/// Latin and Devanagari models concurrently on a phone risks memory spikes for
/// no measured gain, and the results have to be collected before they can be
/// merged anyway. Sequential keeps peak memory at one pass plus one retained
/// result, which is the same order as a normal run.
///
/// Both passes always run as Latin-then-Devanagari regardless of
/// [OcrOptions.script]: the merge decision needs a stable identity for "the
/// pass that cannot emit Devanagari", so the roles are fixed rather than
/// derived from whatever the caller asked for.
class MixedScriptOcrEngine implements OcrEngine {
  MixedScriptOcrEngine({
    required this.delegate,
    this.policy = const OcrMergePolicy(),
  });

  /// The single-script engine that actually performs each pass. Its recognizers
  /// are cached inside the delegate, so the second pass reuses the warm
  /// Devanagari recognizer rather than constructing a new one.
  final OcrEngine delegate;

  /// How the two passes are combined.
  final OcrMergePolicy policy;

  @override
  String get name => delegate.name;

  @override
  Future<OcrResult> recognize({
    required String imagePath,
    OcrOptions options = const OcrOptions(),
  }) async {
    if (!options.mixed) {
      return delegate.recognize(imagePath: imagePath, options: options);
    }

    final stopwatch = Stopwatch()..start();
    final latin = await delegate.recognize(
      imagePath: imagePath,
      options: const OcrOptions(script: OcrScript.latin),
    );
    final devanagari = await delegate.recognize(
      imagePath: imagePath,
      options: const OcrOptions(script: OcrScript.devanagari),
    );
    stopwatch.stop();

    return policy.merge(
      primary: latin,
      secondary: devanagari,
      elapsed: stopwatch.elapsed,
    );
  }

  @override
  Future<void> dispose() => delegate.dispose();
}
