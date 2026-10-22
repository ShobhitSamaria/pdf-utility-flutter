import '../domain/ocr_engine.dart';
import '../domain/ocr_merge_policy.dart';
import '../domain/ocr_result.dart';
import '../domain/ocr_script_detector.dart';
import '../domain/ocr_script_mode.dart';
import '../domain/ocr_service.dart';
import '../ocr_log.dart';

/// Default [OcrService]: runs fully on-device by delegating to an [OcrEngine].
///
/// The engine is injected, so this service is agnostic to whether ML Kit (or
/// something else) is underneath. It exists to give the UI a stable seam, to
/// translate the user's [OcrScriptMode] into engine-level [OcrOptions], and to
/// own the cross-cutting concern of **script routing** as the app grows.
///
/// Script routing ([OcrScriptMode.auto])
/// ------------------------------------
/// A single-script mode is a straight pass-through: one recognizer, one pass.
/// Auto is not, and deliberately so. It runs the Latin recognizer first as a
/// probe, asks [OcrScriptDetector] what the returned text looks like, and then:
///
/// * **Confident Latin read → done.** One pass, byte-identical to what the old
///   default did. A well-read English page pays nothing for Auto.
/// * **Anything else → run the Devanagari pass too.** If that found real
///   Devanagari and the probe found real Latin, the page is genuinely mixed and
///   the two readings are merged by [OcrMergePolicy] (region-by-region, never
///   character-level fusion). If the probe found nothing usable, the Devanagari
///   result is returned as-is rather than dressed up as a merge.
///
/// The cost of Auto is therefore **one wasted probe on every Devanagari page**
/// — the honest price of not asking the user which script their document is in.
/// It is bounded, not hidden: [BoundedOcrService] gives Auto a two-pass time
/// budget, and the result's `elapsed` is the wall-clock time of *both* passes so
/// the latency is visible in the summary strip.
class LocalOcrService implements OcrService {
  LocalOcrService({
    required this.engine,
    this.detector = const OcrScriptDetector(),
    this.mergePolicy = const OcrMergePolicy(),
  });

  /// The injected engine implementation.
  final OcrEngine engine;

  /// Decides which recognizer an Auto run needs, from the probe's text.
  final OcrScriptDetector detector;

  /// Combines the Latin and Devanagari passes when a page is genuinely mixed.
  final OcrMergePolicy mergePolicy;

  /// Labels that record **which recognizer Auto chose**, so the summary strip
  /// explains the read instead of hiding the decision behind a generic engine
  /// name. Built from [engineName] rather than hard-coded, so swapping the
  /// engine does not leave a lie in the UI.
  String get _autoLatinName => '$engineName (Auto → Latin)';
  String get _autoDevanagariName => '$engineName (Auto → Devanagari)';
  String get _autoMixedName => '$engineName (Auto → Latin + Devanagari)';

  @override
  String get engineName => engine.name;

  @override
  Future<OcrResult> recognizeImage(
    String imagePath, {
    OcrScriptMode mode = OcrScriptMode.defaultMode,
  }) {
    if (mode.isAuto) return _recognizeAuto(imagePath);
    return engine.recognize(
      imagePath: imagePath,
      options: OcrOptions(script: mode.primaryScript, mixed: mode.isMixed),
    );
  }

  /// The Auto path: probe, assess, and pay for a second pass only when the probe
  /// could not settle the question.
  Future<OcrResult> _recognizeAuto(String imagePath) async {
    final stopwatch = Stopwatch()..start();

    final probe = await engine.recognize(
      imagePath: imagePath,
      options: const OcrOptions(script: OcrScript.latin),
    );
    final probeAssessment = detector.assess(probe);
    final decisive = detector.probeIsDecisive(probeAssessment);
    ocrDiag(
      'auto: latin probe blocks=${probe.blocks.length} '
      'words=${probe.elements.length} textLength=${probe.fullText.length} '
      'decisive=$decisive (${stopwatch.elapsedMilliseconds} ms)',
    );

    if (decisive) {
      ocrDiag('auto: latin read accepted');
      return probe.copyWith(engineName: _autoLatinName);
    }

    ocrDiag('auto: probe inconclusive — running the devanagari pass');

    final OcrResult secondary;
    try {
      secondary = await engine.recognize(
        imagePath: imagePath,
        options: const OcrOptions(script: OcrScript.devanagari),
      );
    } catch (error, stackTrace) {
      // The probe may already have read real text off this page. Discarding it
      // because the *second* recognizer is unavailable would turn a working read
      // into "Text recognition failed" — and, because Auto runs the Devanagari
      // pass on every page the Latin probe cannot settle, one unavailable model
      // would break every such page from every entry point.
      //
      // Falling back to the probe is not a fake success: the returned text is
      // exactly what the Latin recognizer read, and the result is labelled
      // `Auto → Latin`. When the probe read nothing there is nothing to keep, so
      // the failure is reported.
      ocrDiagError(
        probeAssessment.hasAnyLetters
            ? 'auto: devanagari pass FAILED — keeping the latin probe result'
            : 'auto: devanagari pass FAILED and the latin probe read nothing',
        error,
        stackTrace,
      );
      if (probeAssessment.hasAnyLetters) {
        stopwatch.stop();
        return probe.copyWith(
          engineName: _autoLatinName,
          elapsed: stopwatch.elapsed,
        );
      }
      // Nothing usable came back from either pass, so this is a real failure.
      // The original error is rethrown with its own stack trace, not a copy.
      Error.throwWithStackTrace(error, stackTrace);
    }
    stopwatch.stop();

    final secondaryAssessment = detector.assess(secondary);
    final decision = detector.resolve(
      probe: probeAssessment,
      secondary: secondaryAssessment,
    );

    ocrDiag(
      'auto: decision=${decision.outcome.name} '
      'devanagariWords=${secondary.elements.length} '
      'devanagariTextLength=${secondary.fullText.length}',
    );

    switch (decision.outcome) {
      case AutoScriptOutcome.useProbe:
        return probe.copyWith(
          engineName: _autoLatinName,
          elapsed: stopwatch.elapsed,
        );
      case AutoScriptOutcome.useSecondary:
        return secondary.copyWith(
          engineName: _autoDevanagariName,
          elapsed: stopwatch.elapsed,
        );
      case AutoScriptOutcome.merge:
        return mergePolicy
            .merge(
              primary: probe,
              secondary: secondary,
              elapsed: stopwatch.elapsed,
            )
            .copyWith(engineName: _autoMixedName);
    }
  }

  @override
  Future<void> dispose() => engine.dispose();
}
