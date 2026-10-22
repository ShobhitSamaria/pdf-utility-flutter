import 'package:pdf_utility_flutter/translation/domain/source_language_detector.dart';
import 'package:pdf_utility_flutter/translation/domain/translated_region.dart';
import 'package:pdf_utility_flutter/translation/domain/translation_engine.dart';
import 'package:pdf_utility_flutter/translation/domain/translation_exception.dart';
import 'package:pdf_utility_flutter/translation/domain/translation_language.dart';
import 'package:pdf_utility_flutter/translation/domain/translation_model_state.dart';
import 'package:pdf_utility_flutter/translation/domain/translation_request.dart';
import 'package:pdf_utility_flutter/translation/domain/translation_result.dart';
import 'package:pdf_utility_flutter/translation/domain/translation_service.dart';

/// In-memory [TranslationEngine] that records everything it is asked to do.
///
/// Downloading "succeeds" by adding the code to [availableModels], so a
/// provision-then-translate flow can be exercised end to end.
class FakeTranslationEngine implements TranslationEngine {
  FakeTranslationEngine({
    this.name = 'Fake engine',
    Set<String> availableModels = const <String>{'en', 'hi'},
    this.translatedPrefix = 'अनुवाद: ',
    this.failOnDownload = false,
    this.failOnTranslate = false,
    this.throwOnModelCheck = false,
  }) : availableModels = <String>{...availableModels};

  @override
  final String name;

  final String translatedPrefix;
  final bool failOnDownload;

  /// Mutable so a test can clear a failure and exercise a retry.
  bool failOnTranslate;
  final bool throwOnModelCheck;

  /// Codes whose model is "already on the device".
  final Set<String> availableModels;

  final List<String> downloadRequests = <String>[];
  final List<({String text, String source, String target})> translateRequests =
      <({String text, String source, String target})>[];
  final List<String> modelChecks = <String>[];
  int disposeCount = 0;

  @override
  Future<bool> isModelAvailable(TranslationLanguage language) async {
    modelChecks.add(language.code);
    if (throwOnModelCheck) {
      throw TranslationException(
        TranslationErrorKind.modelUnavailable,
        'model check exploded',
      );
    }
    return availableModels.contains(language.code);
  }

  @override
  Future<void> downloadModel(TranslationLanguage language) async {
    downloadRequests.add(language.code);
    if (failOnDownload) {
      throw TranslationException(
        TranslationErrorKind.modelUnavailable,
        "We couldn't prepare ${language.englishName} on this device.",
      );
    }
    availableModels.add(language.code);
  }

  @override
  Future<String> translate({
    required String text,
    required TranslationLanguage source,
    required TranslationLanguage target,
  }) async {
    translateRequests.add((
      text: text,
      source: source.code,
      target: target.code,
    ));
    if (failOnTranslate) {
      throw TranslationException(
        TranslationErrorKind.engineFailure,
        'Translation failed on this device. Please try again.',
      );
    }
    return '$translatedPrefix$text';
  }

  @override
  Future<void> dispose() async => disposeCount++;
}

/// In-memory [SourceLanguageDetector].
class FakeSourceLanguageDetector implements SourceLanguageDetector {
  FakeSourceLanguageDetector({
    this.detected = TranslationLanguages.english,
    this.throwOnDetect = false,
  });

  final TranslationLanguage? detected;
  final bool throwOnDetect;
  final List<String> detectionRequests = <String>[];
  int disposeCount = 0;

  @override
  Future<TranslationLanguage?> detect(String text) async {
    detectionRequests.add(text);
    if (throwOnDetect) throw StateError('detector exploded');
    return detected;
  }

  @override
  Future<void> dispose() async => disposeCount++;
}

/// In-memory [TranslationService] for controller / widget tests.
///
/// [failure] is mutable so a test can clear it and exercise a retry.
class FakeTranslationService implements TranslationService {
  FakeTranslationService({
    this.engineName = 'Fake service',
    List<TranslationLanguage>? targetLanguages,
    List<TranslationLanguage>? sourceLanguages,
    TranslationLanguage? defaultTargetLanguage,
    this.failure,
    this.delay = Duration.zero,
    this.tickDelay = Duration.zero,
    this.emittedPhases = const <TranslationPhase>[TranslationPhase.translating],
    this.detectedSource = TranslationLanguages.english,
    this.alreadyInTargetLanguage = false,
    this.detectionFails = false,
    this.detectionDelay = Duration.zero,
  }) : targetLanguages = List<TranslationLanguage>.unmodifiable(
         targetLanguages ?? TranslationLanguages.all,
       ),
       sourceLanguages = List<TranslationLanguage>.unmodifiable(
         sourceLanguages ?? TranslationLanguages.sources,
       ),
       defaultTargetLanguage =
           defaultTargetLanguage ?? TranslationLanguages.hindi;

  @override
  final String engineName;
  @override
  final List<TranslationLanguage> targetLanguages;
  @override
  final List<TranslationLanguage> sourceLanguages;
  @override
  final TranslationLanguage defaultTargetLanguage;

  /// When set, [translate] throws it.
  TranslationException? failure;

  /// How long [translate] takes (a real timer, so widget tests can pump it).
  final Duration delay;

  /// Pause between the per-region counter ticks of [translateRegions].
  ///
  /// Zero by default, which emits every tick in one go — enough for tests that
  /// only care about the finished result. A non-zero value spreads them out so a
  /// test can observe a batch **partway through** and assert the partial
  /// percentage the banner shows.
  final Duration tickDelay;

  /// Phases reported through `onProgress`, in order.
  final List<TranslationPhase> emittedPhases;

  /// Language used as the resolved source when the request asked for auto.
  final TranslationLanguage detectedSource;

  /// When `true`, reports that the text was already in the target language, so
  /// no translation happened. Lets a test prove that such a result is never
  /// counted as a successful translation.
  final bool alreadyInTargetLanguage;

  /// When `true`, [detectSource] answers `null`, like a page the on-device
  /// identifier cannot classify.
  bool detectionFails;

  /// How long [detectSource] takes (a real timer, so widget tests can observe
  /// the "Detecting language…" state).
  final Duration detectionDelay;

  final List<TranslationRequest> requests = <TranslationRequest>[];

  /// Every text passed to [detectSource]. Lets a test prove that an explicit
  /// source language never triggers auto-detection.
  final List<String> detectionRequests = <String>[];

  /// Units passed to [translateRegions], one entry per call.
  final List<List<TranslationUnit>> regionRequests = <List<TranslationUnit>>[];

  /// The language pair sent with each [translateRegions] call.
  final List<({String source, String target})> regionLanguages =
      <({String source, String target})>[];
  int disposeCount = 0;

  @override
  Future<TranslationModelState> modelState(
    TranslationLanguage language,
  ) async => TranslationModelState.available(language);

  @override
  Future<TranslationLanguage?> detectSource(String text) async {
    detectionRequests.add(text);
    if (detectionDelay > Duration.zero) {
      await Future<void>.delayed(detectionDelay);
    }
    if (detectionFails) return null;
    return detectedSource;
  }

  @override
  Future<TranslationResult> translate(
    TranslationRequest request, {
    void Function(TranslationProgress progress)? onProgress,
  }) async {
    requests.add(request);
    for (final phase in emittedPhases) {
      onProgress?.call(TranslationProgress(phase, language: request.target));
    }
    await Future<void>.delayed(delay);

    final error = failure;
    if (error != null) throw error;

    return TranslationResult(
      originalText: request.normalizedText,
      translatedText: alreadyInTargetLanguage
          ? request.normalizedText
          : 'अनुवाद: ${request.normalizedText}',
      sourceLanguage: request.source.isAuto ? detectedSource : request.source,
      targetLanguage: request.target,
      scope: request.scope,
      sourceWasAutoDetected: request.source.isAuto,
      alreadyInTargetLanguage: alreadyInTargetLanguage,
    );
  }

  @override
  Future<TranslatedOverlay> translateRegions(
    List<TranslationUnit> units, {
    TranslationLanguage source = TranslationLanguages.defaultSource,
    required TranslationLanguage target,
    void Function(TranslationProgress progress)? onProgress,
  }) async {
    regionRequests.add(units);
    regionLanguages.add((source: source.code, target: target.code));
    for (final phase in emittedPhases) {
      onProgress?.call(
        TranslationProgress(phase, language: target, total: units.length),
      );
    }
    // Mirror the real service: one counter tick per region, so the UI's
    // "Translating… 25%" progress path is exercised.
    for (var index = 0; index < units.length; index++) {
      onProgress?.call(
        TranslationProgress(
          TranslationPhase.translating,
          language: target,
          completed: index + 1,
          total: units.length,
        ),
      );
      if (tickDelay > Duration.zero) await Future<void>.delayed(tickDelay);
    }
    await Future<void>.delayed(delay);

    final error = failure;
    if (error != null) throw error;

    return TranslatedOverlay(
      regions: [
        for (final unit in units)
          TranslatedRegion(
            id: unit.id,
            sourceText: unit.text,
            translatedText: 'अनुवाद: ${unit.text}',
            bounds: unit.bounds,
            kind: unit.kind,
          ),
      ],
      sourceLanguage: source.isAuto ? detectedSource : source,
      targetLanguage: target,
      sourceWasAutoDetected: source.isAuto,
    );
  }

  @override
  Future<void> dispose() async => disposeCount++;
}
