import 'dart:async';

import 'package:google_mlkit_translation/google_mlkit_translation.dart'
    as mlkit;

import '../domain/translation_engine.dart';
import '../domain/translation_exception.dart';
import '../domain/translation_language.dart';
import '../domain/translation_model_manager.dart';
import '../translation_log.dart';
import 'native_model_manager.dart';

/// One stage of a **traced** translator call — creating the translator, running
/// the translation, or closing it — with its own timing and raw error.
class TranslatorStage {
  const TranslatorStage({
    required this.name,
    required this.elapsed,
    this.value,
    this.error,
    this.stack,
  });

  /// What ran, e.g. `create OnDeviceTranslator en→hi`.
  final String name;

  /// How long this stage took, whether it succeeded or not.
  final Duration elapsed;

  /// Short description of the outcome when the stage succeeded.
  final String? value;

  /// The raw error (e.g. the native `PlatformException`) when it did not.
  final Object? error;
  final StackTrace? stack;

  bool get ok => error == null;

  /// The outcome, or the full description of the failure — never a generic
  /// sentence.
  String get detail =>
      ok ? (value ?? 'ok') : TranslationException.describe(error!, stack);
}

/// Every stage of one `translateText` call, in order, with timings.
///
/// [MlKitTranslationEngine.translate] collapses a failure into one friendly
/// [TranslationException]; this keeps the raw per-stage truth so a diagnostic
/// view (or `adb logcat`) can name the exact call that failed and why.
class TranslatorCallTrace {
  const TranslatorCallTrace({
    required this.sourceCode,
    required this.targetCode,
    required this.stages,
    required this.elapsed,
    this.result,
    this.error,
    this.stack,
  });

  final String sourceCode;
  final String targetCode;
  final List<TranslatorStage> stages;

  /// Total wall-clock time for the whole call.
  final Duration elapsed;

  int get elapsedMilliseconds => elapsed.inMilliseconds;

  /// The translated text, when the call succeeded.
  final String? result;

  final Object? error;
  final StackTrace? stack;

  bool get ok => result != null && error == null;

  /// The first stage that did not succeed, if any.
  TranslatorStage? get firstFailure {
    for (final stage in stages) {
      if (!stage.ok) return stage;
    }
    return null;
  }
}

/// Concrete [TranslationEngine] backed by Google's **on-device** ML Kit
/// Translation.
///
/// Everything runs locally through a platform channel — no cloud API, no Chrome
/// /web translation, no Python backend. This class is the ONLY place that
/// imports the ML Kit translation package, keeping the rest of the app
/// engine-agnostic.
///
/// Model provisioning follows ML Kit's documented flow: check each language with
/// [isModelAvailable] and download the missing ones with [downloadModel]
/// **before** calling `translateText`. `OnDeviceTranslator.translateText` also
/// runs `downloadModelIfNeeded()` natively, so a translation can still succeed
/// if the explicit step was skipped or raced.
///
/// The actual provisioning is delegated to a [TranslationModelManager] — by
/// default [NativeModelManager], whose native channel attaches a per-attempt
/// watchdog and retries a stalled download, so a Play Services `Task` that
/// never calls back surfaces as a bounded, per-attempt failure instead of
/// hanging this engine forever.
///
/// Every step is logged (debug builds) with the exact language codes, results and
/// timings, and any exception is described in full — including the
/// `PlatformException` code/message/details from the native side — so a failure
/// can be diagnosed from `adb logcat` or the debug "Details" view instead of a
/// generic sentence.
class MlKitTranslationEngine implements TranslationEngine {
  MlKitTranslationEngine({
    TranslationModelManager? modelManager,
    this.operationTimeout = const Duration(seconds: 150),
  }) : _modelManager = modelManager ?? NativeModelManager();

  /// Upper bound on any single native ML Kit call.
  ///
  /// The first translation of a language pair includes downloading ~30 MB per
  /// model, so this is deliberately generous. Its job is only to be the
  /// last-resort backstop: if a native call genuinely never resolves, the user
  /// gets a retryable error instead of an eternal "Preparing …".
  final Duration operationTimeout;

  /// Maps our BCP-47 codes onto ML Kit's language enum.
  ///
  /// Explicit (rather than derived from the package's `bcpCode` extension) so
  /// our domain codes are guaranteed to line up with the native enum, and so
  /// anything missing here is reported as unsupported instead of silently
  /// mistranslating.
  static const Map<String, mlkit.TranslateLanguage> _nativeByCode =
      <String, mlkit.TranslateLanguage>{
        'ar': mlkit.TranslateLanguage.arabic,
        'bn': mlkit.TranslateLanguage.bengali,
        'de': mlkit.TranslateLanguage.german,
        'en': mlkit.TranslateLanguage.english,
        'es': mlkit.TranslateLanguage.spanish,
        'fa': mlkit.TranslateLanguage.persian,
        'fr': mlkit.TranslateLanguage.french,
        'gu': mlkit.TranslateLanguage.gujarati,
        'he': mlkit.TranslateLanguage.hebrew,
        'hi': mlkit.TranslateLanguage.hindi,
        'id': mlkit.TranslateLanguage.indonesian,
        'it': mlkit.TranslateLanguage.italian,
        'ja': mlkit.TranslateLanguage.japanese,
        'kn': mlkit.TranslateLanguage.kannada,
        'ko': mlkit.TranslateLanguage.korean,
        'mr': mlkit.TranslateLanguage.marathi,
        'ms': mlkit.TranslateLanguage.malay,
        'nl': mlkit.TranslateLanguage.dutch,
        'pl': mlkit.TranslateLanguage.polish,
        'pt': mlkit.TranslateLanguage.portuguese,
        'ru': mlkit.TranslateLanguage.russian,
        'sw': mlkit.TranslateLanguage.swahili,
        'ta': mlkit.TranslateLanguage.tamil,
        'te': mlkit.TranslateLanguage.telugu,
        'th': mlkit.TranslateLanguage.thai,
        'tr': mlkit.TranslateLanguage.turkish,
        'uk': mlkit.TranslateLanguage.ukrainian,
        'ur': mlkit.TranslateLanguage.urdu,
        'vi': mlkit.TranslateLanguage.vietnamese,
        'zh': mlkit.TranslateLanguage.chinese,
      };

  final TranslationModelManager _modelManager;

  /// BCP-47 codes this engine can translate, i.e. the languages ML Kit ships an
  /// on-device model for. Exposed for diagnostics and tests.
  static Set<String> get supportedCodes => _nativeByCode.keys.toSet();

  @override
  String get name => 'Google ML Kit (on-device)';

  @override
  Future<bool> isModelAvailable(TranslationLanguage language) async {
    final native = _nativeByCode[language.code];
    if (native == null) {
      _log('isModelAvailable(${language.code}): no native mapping → false');
      return false;
    }
    final started = DateTime.now();
    try {
      final downloaded = await _modelManager
          .isModelDownloaded(language.code)
          .timeout(operationTimeout);
      _log(
        'isModelDownloaded(${language.code}) → $downloaded '
        '(${_ms(started)} ms)',
      );
      return downloaded;
    } catch (error, stack) {
      _logError(
        'isModelDownloaded(${language.code}) after '
        '${_ms(started)} ms',
        error,
        stack,
      );
      throw TranslationException(
        TranslationErrorKind.modelUnavailable,
        "We couldn't check the ${language.englishName} translator on this "
        'device. Please try again.',
        cause: error,
        details: TranslationException.describe(error, stack),
      );
    }
  }

  @override
  Future<void> downloadModel(TranslationLanguage language) async {
    final native = _nativeByCode[language.code];
    if (native == null) {
      throw TranslationException.unsupportedLanguage(language);
    }

    final started = DateTime.now();
    _log('downloadModel(${language.code}) starting');
    try {
      // The manager bounds every attempt itself (native watchdog + retry), and
      // this outer timeout is the last-resort backstop above even that — the
      // call can still never hang. The no-Wi-Fi-gating guarantee lives in
      // `NativeModelManager` (`wifi: false` / `isWifiRequired: false`).
      final downloaded = await _modelManager
          .downloadModel(language.code)
          .timeout(operationTimeout);
      _log(
        'downloadModel(${language.code}) → $downloaded '
        '(${_ms(started)} ms)',
      );
      if (!downloaded) {
        throw TranslationException(
          TranslationErrorKind.modelUnavailable,
          "We couldn't prepare ${language.englishName} on this device. "
          'Please check your connection and try again.',
          details: 'downloadModel(${language.code}) returned false',
        );
      }
    } catch (error, stack) {
      _logError(
        'downloadModel(${language.code}) after ${_ms(started)} ms',
        error,
        stack,
      );
      if (error is TranslationException) rethrow;
      if (error is TimeoutException) {
        // The manager normally reports per-attempt failures itself; this only
        // fires when even the whole bounded manager call overran — i.e. the
        // backstop below its own worst case. Keep the timeout visible rather
        // than generic.
        throw TranslationException(
          TranslationErrorKind.modelUnavailable,
          "We couldn't prepare ${language.englishName} on this device. "
          'Please check your connection and try again.',
          cause: error,
          details:
              'downloadModel(${language.code}) exceeded the engine '
              'backstop of ${operationTimeout.inMilliseconds} ms — the native '
              'call never returned\n'
              '${TranslationException.describe(error, stack)}',
        );
      }
      throw TranslationException(
        TranslationErrorKind.modelUnavailable,
        "We couldn't prepare ${language.englishName} on this device. "
        'Please check your connection and try again.',
        cause: error,
        details: TranslationException.describe(error, stack),
      );
    }
  }

  @override
  Future<String> translate({
    required String text,
    required TranslationLanguage source,
    required TranslationLanguage target,
  }) async {
    final trace = await translateTraced(
      text: text,
      source: source,
      target: target,
    );
    final result = trace.result;
    if (result != null) return result;

    // Collapse the trace into the user-facing failure, keeping the raw cause.
    final failed = trace.firstFailure;
    throw TranslationException(
      TranslationErrorKind.engineFailure,
      'Translation failed on this device. Please try again.',
      cause: trace.error,
      details: failed == null
          ? TranslationException.describe(trace.error ?? 'unknown', trace.stack)
          : 'stage "${failed.name}"\n${failed.detail}',
    );
  }

  /// Runs one `translateText` with **per-stage** timing and raw error capture.
  ///
  /// [translate] is the app's path and shows the user one friendly sentence;
  /// this one is for diagnostics and never hides the truth: it reports each
  /// native (or Dart-side) stage separately — create translator, translate, close
  /// — with its own BEFORE/AFTER log line, elapsed milliseconds, and the exact
  /// exception. It does **not** throw for a failed stage; inspect
  /// [TranslatorCallTrace.ok] / [TranslatorCallTrace.firstFailure].
  ///
  /// Each stage is bounded by [timeout] (default [operationTimeout]) because the
  /// native plugin bridges Play Services `Task`s straight onto the platform
  /// channel with no timeout of its own: a `Task` that never completes leaves the
  /// Dart `Future` pending forever. That is the "stuck on Preparing …" mode this
  /// bound exists to break.
  Future<TranslatorCallTrace> translateTraced({
    required String text,
    required TranslationLanguage source,
    required TranslationLanguage target,
    Duration? timeout,
  }) async {
    final nativeSource = _nativeByCode[source.code];
    final nativeTarget = _nativeByCode[target.code];
    if (nativeSource == null) {
      throw TranslationException.unsupportedLanguage(source);
    }
    if (nativeTarget == null) {
      throw TranslationException.unsupportedLanguage(target);
    }

    final budget = timeout ?? operationTimeout;
    final stages = <TranslatorStage>[];
    final overall = Stopwatch()..start();

    // A fresh translator per call: translation here is user-initiated and
    // infrequent, and creating it lazily means a model provisioned during this
    // session is picked up immediately (no stale "model missing" state).
    // Natively this is `Translator.downloadModelIfNeeded().onSuccess {
    // translate(text) }`, so it also provisions as a fallback.
    mlkit.OnDeviceTranslator? translator;
    final create = await _runStage(
      'create OnDeviceTranslator ${source.code}(${nativeSource.bcpCode})'
      '→${target.code}(${nativeTarget.bcpCode})',
      () async {
        translator = mlkit.OnDeviceTranslator(
          sourceLanguage: nativeSource,
          targetLanguage: nativeTarget,
        );
        return 'created (id=${translator!.id})';
      },
      budget: budget,
    );
    stages.add(create);

    Object? error = create.error;
    StackTrace? stack = create.stack;
    String? output;

    if (create.ok) {
      final translate = await _runStage('translateText() chars=${text.length} '
          '${source.code}→${target.code}', () async {
        final out = await translator!.translateText(text);
        output = out;
        return 'result="${out.length > 60 ? '${out.substring(0, 60)}…' : out}" '
            '(${out.length} chars)';
      }, budget: budget);
      stages.add(translate);
      if (!translate.ok) {
        error = translate.error;
        stack = translate.stack;
      }
    }

    if (translator != null) {
      final close = await _runStage('close()', () async {
        await translator!.close();
        return 'ok';
      }, budget: budget);
      stages.add(close);
      // Closing is best-effort: it never decides whether the call succeeded.
      if (!close.ok) _log('close() failed (ignored): ${close.error}');
    }

    overall.stop();
    final trace = TranslatorCallTrace(
      sourceCode: source.code,
      targetCode: target.code,
      stages: stages,
      elapsed: overall.elapsed,
      result: error == null ? output : null,
      error: error,
      stack: stack,
    );
    _log(
      'translateTraced ${source.code}→${target.code}: '
      '${trace.ok ? 'PASS' : 'FAIL'} (${overall.elapsedMilliseconds} ms)',
    );
    return trace;
  }

  /// Runs one stage of a traced call: logs BEFORE/AFTER, bounds it with a
  /// timeout, and captures the raw error instead of throwing.
  Future<TranslatorStage> _runStage(
    String name,
    Future<String> Function() body, {
    required Duration budget,
  }) async {
    final stopwatch = Stopwatch()..start();
    _log('$name: BEFORE (timeout ${budget.inMilliseconds} ms)');
    try {
      final value = await body().timeout(budget);
      stopwatch.stop();
      _log('$name: AFTER OK — $value (${stopwatch.elapsedMilliseconds} ms)');
      return TranslatorStage(
        name: name,
        elapsed: stopwatch.elapsed,
        value: value,
      );
    } catch (error, stack) {
      stopwatch.stop();
      _logError(
        '$name: AFTER FAILED (${stopwatch.elapsedMilliseconds} ms)',
        error,
        stack,
      );
      return TranslatorStage(
        name: name,
        elapsed: stopwatch.elapsed,
        error: error,
        stack: stack,
      );
    }
  }

  @override
  Future<void> dispose() async {
    // Nothing persistent to release: translators are created and closed per
    // call, and ML Kit's model manager holds no Dart-side resources.
  }

  static int _ms(DateTime started) =>
      DateTime.now().difference(started).inMilliseconds;

  static void _log(String message) => translationLog('engine: $message');

  static void _logError(String step, Object error, StackTrace stack) {
    translationLog(
      'engine: $step FAILED\n'
      '${TranslationException.describe(error, stack)}',
    );
  }
}
