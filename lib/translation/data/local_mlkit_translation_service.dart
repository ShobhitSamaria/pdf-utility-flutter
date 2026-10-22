import '../domain/source_language_detector.dart';
import '../domain/translated_region.dart';
import '../domain/translation_engine.dart';
import '../domain/translation_exception.dart';
import '../domain/translation_language.dart';
import '../domain/translation_model_state.dart';
import '../domain/translation_request.dart';
import '../domain/translation_result.dart';
import '../domain/translation_service.dart';
import '../domain/translation_text.dart';
import '../translation_log.dart';
import 'mlkit_language_detector.dart';
import 'mlkit_translation_engine.dart';

/// Default [TranslationService]: on-device ML Kit translation plus on-device
/// language identification for auto-detect.
///
/// Orchestration lives here so the UI never has to know about:
/// * resolving an auto-detect source,
/// * checking / provisioning on-device models,
/// * short-circuiting when the text is already in the target language,
/// * turning any engine failure into a friendly, retryable message.
///
/// Both collaborators are injectable, so tests can drive the whole flow with
/// fakes and no platform channels.
class LocalMlKitTranslationService implements TranslationService {
  LocalMlKitTranslationService({
    TranslationEngine? engine,
    SourceLanguageDetector? detector,
    List<TranslationLanguage>? targetLanguages,
    List<TranslationLanguage>? sourceLanguages,
    TranslationLanguage? defaultTargetLanguage,
  }) : _engine = engine ?? MlKitTranslationEngine(),
       _detector = detector ?? MlKitSourceLanguageDetector(),
       _targetLanguages = List<TranslationLanguage>.unmodifiable(
         targetLanguages ?? TranslationLanguages.all,
       ),
       _sourceLanguages = List<TranslationLanguage>.unmodifiable(
         sourceLanguages ?? TranslationLanguages.sources,
       ),
       _defaultTarget =
           defaultTargetLanguage ?? TranslationLanguages.defaultTarget {
    assert(
      _targetLanguages.any((l) => l.code == _defaultTarget.code),
      'The default target language must be one of the offered targets.',
    );
    assert(
      _sourceLanguages.any((l) => l.isAuto),
      'Source languages must include the auto-detect option.',
    );
  }

  final TranslationEngine _engine;
  final SourceLanguageDetector _detector;
  final List<TranslationLanguage> _targetLanguages;
  final List<TranslationLanguage> _sourceLanguages;
  final TranslationLanguage _defaultTarget;

  /// Languages that have been translated successfully at least once this
  /// session, i.e. whose on-device models are known to be present.
  ///
  /// Used only to decide whether to show a "Preparing …" line: the first use of
  /// a language pair fetches its models (inside the translate call), later ones
  /// do not. Nothing blocks on this set, so it can never hang a translation.
  final Set<String> _prepared = <String>{};

  /// Languages whose model was found missing **and** whose download failed.
  ///
  /// Kept so that a later engine failure can be reported as what it actually is
  /// — a model that never arrived — instead of the generic "translation failed"
  /// sentence. It is cleared as soon as the model is known to be present.
  final Set<String> _missingModels = <String>{};

  @override
  String get engineName => _engine.name;

  @override
  List<TranslationLanguage> get sourceLanguages => _sourceLanguages;

  @override
  List<TranslationLanguage> get targetLanguages => _targetLanguages;

  @override
  TranslationLanguage get defaultTargetLanguage => _defaultTarget;

  @override
  Future<TranslationModelState> modelState(TranslationLanguage language) async {
    if (language.isAuto || !_supportsTarget(language)) {
      return TranslationModelState(
        language: language,
        status: TranslationModelStatus.unsupported,
        message: 'Not exposed by this build.',
      );
    }
    try {
      final isDownloaded = await _engine.isModelAvailable(language);
      return TranslationModelState(
        language: language,
        status: isDownloaded
            ? TranslationModelStatus.available
            : TranslationModelStatus.notAvailable,
      );
    } catch (error) {
      return TranslationModelState(
        language: language,
        status: TranslationModelStatus.failed,
        message: error.toString(),
      );
    }
  }

  @override
  Future<TranslationLanguage?> detectSource(String text) async {
    if (!TranslationText.isTranslatable(text)) return null;
    try {
      final detected = await _detector.detect(text);
      _log('detectSource → ${detected?.code ?? '(undetermined)'}');
      return detected;
    } catch (error, stack) {
      // Detection is advisory: the UI falls back to a manual choice, and an
      // explicit choice never calls this at all.
      _log(
        'detectSource FAILED\n${TranslationException.describe(error, stack)}',
      );
      return null;
    }
  }

  @override
  Future<TranslationResult> translate(
    TranslationRequest request, {
    void Function(TranslationProgress progress)? onProgress,
  }) async {
    final stopwatch = Stopwatch()..start();

    final text = request.normalizedText;
    if (!TranslationText.isTranslatable(text)) {
      throw const TranslationException(
        TranslationErrorKind.emptyInput,
        'There is nothing to translate.',
      );
    }

    final target = request.target;
    _validateTarget(target);

    _log(
      'translate request: source=${request.source.code} '
      'target=${target.code} scope=${request.scope.name} '
      'chars=${text.length} text=${_preview(text)}',
    );

    // 1. Resolve the source language (auto-detect when asked).
    final resolution = await _resolveSource(request.source, text, onProgress);

    // 2. Nothing to do when the text already is in the target language.
    if (resolution.language.code == target.code) {
      stopwatch.stop();
      return TranslationResult(
        originalText: text,
        translatedText: text,
        sourceLanguage: resolution.language,
        targetLanguage: target,
        scope: request.scope,
        sourceWasAutoDetected: resolution.autoDetected,
        alreadyInTargetLanguage: true,
        elapsed: stopwatch.elapsed,
      );
    }

    // 3. Ensure BOTH on-device models are present (check, then download the
    //    missing ones) before translating — ML Kit requires both.
    await _ensureModels(
      source: resolution.language,
      target: target,
      onProgress: onProgress,
    );

    // 4. Translate locally.
    _emitProgress(
      onProgress,
      TranslationProgress(TranslationPhase.translating, language: target),
    );
    final translated = await _translateText(
      text: text,
      source: resolution.language,
      target: target,
    );
    _markPrepared([resolution.language, target]);

    stopwatch.stop();
    return TranslationResult(
      originalText: text,
      translatedText: translated,
      sourceLanguage: resolution.language,
      targetLanguage: target,
      scope: request.scope,
      sourceWasAutoDetected: resolution.autoDetected,
      elapsed: stopwatch.elapsed,
    );
  }

  @override
  Future<TranslatedOverlay> translateRegions(
    List<TranslationUnit> units, {
    TranslationLanguage source = TranslationLanguages.defaultSource,
    required TranslationLanguage target,
    void Function(TranslationProgress progress)? onProgress,
  }) async {
    final stopwatch = Stopwatch()..start();

    final usable = <TranslationUnit>[
      for (final unit in units)
        if (TranslationText.isTranslatable(unit.text)) unit,
    ];
    if (usable.isEmpty) {
      throw const TranslationException(
        TranslationErrorKind.emptyInput,
        'There is nothing to translate.',
      );
    }

    _validateTarget(target);

    // Detect once for the whole batch: a page's lines are the same language,
    // and one detection is both faster and more reliable than N.
    final combined = TranslationText.aggregate(usable.map((u) => u.text));
    final resolution = await _resolveSource(source, combined, onProgress);
    final resolved = resolution.language;

    // Already in the target language: echo every region unchanged rather than
    // round-tripping through the engine.
    if (resolved.code == target.code) {
      stopwatch.stop();
      return TranslatedOverlay(
        regions: [
          for (final unit in usable)
            TranslatedRegion(
              id: unit.id,
              sourceText: TranslationText.normalize(unit.text),
              translatedText: TranslationText.normalize(unit.text),
              bounds: unit.bounds,
              kind: unit.kind,
            ),
        ],
        sourceLanguage: resolved,
        targetLanguage: target,
        sourceWasAutoDetected: resolution.autoDetected,
        alreadyInTargetLanguage: true,
        elapsed: stopwatch.elapsed,
      );
    }

    await _ensureModels(
      source: resolved,
      target: target,
      onProgress: onProgress,
    );

    // One engine call per region: the whole point of the overlay is that each
    // region's translation lands back on that region's rectangle, so a single
    // joined call would have to be split again by guesswork.
    _emitProgress(
      onProgress,
      TranslationProgress(
        TranslationPhase.translating,
        language: target,
        total: usable.length,
      ),
    );

    final regions = <TranslatedRegion>[];
    for (var index = 0; index < usable.length; index++) {
      final unit = usable[index];
      final text = TranslationText.normalize(unit.text);
      final translated = await _translateText(
        text: text,
        source: resolved,
        target: target,
      );
      final translatedText = translated.trim();
      if (translatedText.isEmpty) {
        if (_hasLetters(text)) {
          // The engine answered with nothing for a block that does contain
          // text. Reporting success here would put an empty region into the
          // overlay, where it is dropped from both the photo and the full text
          // — a block silently lost, which this service must never do.
          throw const TranslationException(
            TranslationErrorKind.engineFailure,
            'Some text on this page could not be translated. Please try again.',
          );
        }
        // Punctuation, a lone danda, a date separator: nothing to translate, and
        // nothing missing from the page. Echo it so the block keeps its place.
        regions.add(
          TranslatedRegion(
            id: unit.id,
            sourceText: text,
            translatedText: text,
            bounds: unit.bounds,
            kind: unit.kind,
          ),
        );
        _emitProgress(
          onProgress,
          TranslationProgress(
            TranslationPhase.translating,
            language: target,
            completed: index + 1,
            total: usable.length,
          ),
        );
        continue;
      }
      regions.add(
        TranslatedRegion(
          id: unit.id,
          sourceText: text,
          translatedText: translatedText,
          bounds: unit.bounds,
          kind: unit.kind,
        ),
      );
      _prepared
        ..add(resolved.code)
        ..add(target.code);
      _emitProgress(
        onProgress,
        TranslationProgress(
          TranslationPhase.translating,
          language: target,
          completed: index + 1,
          total: usable.length,
        ),
      );
    }

    stopwatch.stop();
    return TranslatedOverlay(
      regions: regions,
      sourceLanguage: resolved,
      targetLanguage: target,
      sourceWasAutoDetected: resolution.autoDetected,
      elapsed: stopwatch.elapsed,
    );
  }

  @override
  Future<void> dispose() async {
    await _detector.dispose();
    await _engine.dispose();
  }

  /// Translates one string, translating a model that never downloaded into a
  /// clear, actionable error instead of a generic engine failure.
  Future<String> _translateText({
    required String text,
    required TranslationLanguage source,
    required TranslationLanguage target,
  }) async {
    try {
      final translated = await _engine.translate(
        text: text,
        source: source,
        target: target,
      );
      _missingModels.remove(source.code);
      _missingModels.remove(target.code);
      return translated;
    } on TranslationException catch (error) {
      if (error.kind != TranslationErrorKind.engineFailure) rethrow;
      final missing = <TranslationLanguage>[
        for (final language in <TranslationLanguage>[source, target])
          if (_missingModels.contains(language.code)) language,
      ];
      if (missing.isEmpty) rethrow;
      final names = missing.map((l) => l.englishName).join(' and ');
      throw TranslationException(
        TranslationErrorKind.modelUnavailable,
        "The $names offline language model couldn't be downloaded. "
        'Check your connection and try again.',
        cause: error.cause ?? error,
        details:
            'model download failed for '
            '${missing.map((l) => l.code).join(', ')}\n${error.details ?? ''}',
      );
    }
  }

  static final RegExp _letters = RegExp(r'\p{L}', unicode: true);

  /// Whether [text] contains any letter at all, in any script.
  ///
  /// Used to tell "the engine had nothing to translate" (punctuation-only) from
  /// "the engine lost real text", which are very different failures.
  static bool _hasLetters(String text) => _letters.hasMatch(text);

  /// Rejects targets the engine cannot translate into, with a user-safe reason.
  void _validateTarget(TranslationLanguage target) {
    if (target.isAuto) {
      throw const TranslationException(
        TranslationErrorKind.unsupportedPair,
        'Pick a language to translate into.',
      );
    }
    if (!_supportsTarget(target)) {
      throw TranslationException(
        TranslationErrorKind.unsupportedPair,
        'Translation into ${target.englishName} is not available yet.',
      );
    }
  }

  /// Turns an auto-detect source into a concrete language, or passes an explicit
  /// source through after validating it.
  Future<({TranslationLanguage language, bool autoDetected})> _resolveSource(
    TranslationLanguage source,
    String text,
    void Function(TranslationProgress progress)? onProgress,
  ) async {
    var resolved = source;
    var autoDetected = false;

    if (resolved.isAuto) {
      _emitProgress(
        onProgress,
        const TranslationProgress(TranslationPhase.detectingLanguage),
      );
      TranslationLanguage? detected;
      try {
        detected = await _detector.detect(text);
      } catch (_) {
        // The detector's contract is "return null when unsure", but a platform
        // hiccup must still become a friendly message rather than a crash.
        detected = null;
      }
      final found = detected;
      if (found == null) {
        throw const TranslationException(
          TranslationErrorKind.detectionFailed,
          "We couldn't tell which language this is. "
          'Pick the source language and try again.',
        );
      }
      resolved = found;
      autoDetected = true;
      _log('detected source → ${resolved.code} (${resolved.englishName})');
    }

    if (!_supportsSource(resolved)) {
      _log('source ${resolved.code} is not offered by this build');
      throw TranslationException(
        TranslationErrorKind.unsupportedLanguage,
        'Translation from ${resolved.englishName} is not supported yet.',
      );
    }

    return (language: resolved, autoDetected: autoDetected);
  }

  /// Makes sure the models for [source] and [target] are on the device.
  ///
  /// ML Kit requires **both** the source and target models before translating,
  /// so each language is checked and, when missing, downloaded — with a
  /// `preparingModel` tick only when a download is actually needed (not for a
  /// model that is already on the device).
  ///
  /// A failed download is **logged but not fatal**: the engine's `translate`
  /// also runs `downloadModelIfNeeded` natively, so we give it that second
  /// chance and let its (more specific) error surface if it fails too. Because
  /// every native call is bounded by a timeout in the engine, this can never
  /// leave the UI spinning forever.
  Future<void> _ensureModels({
    required TranslationLanguage source,
    required TranslationLanguage target,
    required void Function(TranslationProgress progress)? onProgress,
  }) async {
    for (final language in <TranslationLanguage>[source, target]) {
      await _ensureModel(language, onProgress);
    }
  }

  /// Checks one language's model and downloads it if missing, logging each step.
  Future<void> _ensureModel(
    TranslationLanguage language,
    void Function(TranslationProgress progress)? onProgress,
  ) async {
    if (_prepared.contains(language.code)) {
      _log('model ${language.code} already prepared this session');
      return;
    }

    final checkStarted = DateTime.now();
    var available = false;
    try {
      available = await _engine.isModelAvailable(language);
      _log(
        'model ${language.code} (${language.englishName}) downloaded? '
        '$available (${_ms(checkStarted)} ms)',
      );
    } catch (error) {
      _log('model ${language.code} availability check failed: $error');
    }
    if (available) {
      _prepared.add(language.code);
      _missingModels.remove(language.code);
      return;
    }

    _emitProgress(
      onProgress,
      TranslationProgress(TranslationPhase.preparingModel, language: language),
    );
    final downloadStarted = DateTime.now();
    try {
      await _engine.downloadModel(language);
      _log('model ${language.code} downloaded in ${_ms(downloadStarted)} ms');
      _prepared.add(language.code);
      _missingModels.remove(language.code);
    } catch (error, stack) {
      _missingModels.add(language.code);
      _log(
        'model ${language.code} download FAILED after '
        '${_ms(downloadStarted)} ms — continuing to translate anyway\n'
        '${TranslationException.describe(error, stack)}',
      );
    }
  }

  void _markPrepared(Iterable<TranslationLanguage> languages) {
    for (final language in languages) {
      _prepared.add(language.code);
    }
  }

  static int _ms(DateTime started) =>
      DateTime.now().difference(started).inMilliseconds;

  static String _preview(String text) {
    final single = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    return single.length <= 60 ? '"$single"' : '"${single.substring(0, 60)}…"';
  }

  static void _log(String message) => translationLog('service: $message');

  bool _supportsTarget(TranslationLanguage language) =>
      language.isConcrete &&
      _targetLanguages.any((l) => l.code == language.code);

  bool _supportsSource(TranslationLanguage language) =>
      language.isConcrete &&
      _sourceLanguages.any((l) => l.code == language.code);

  void _emitProgress(
    void Function(TranslationProgress progress)? onProgress,
    TranslationProgress progress,
  ) {
    if (onProgress == null) return;
    try {
      onProgress(progress);
    } catch (_) {
      // A misbehaving progress listener must never break the translation.
    }
  }
}
