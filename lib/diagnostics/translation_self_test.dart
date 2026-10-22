import 'dart:async';

import '../translation/data/mlkit_translation_engine.dart';
import '../translation/domain/translation_exception.dart';
import '../translation/domain/translation_language.dart';
import '../translation/translation_log.dart';
import 'device_diagnostics.dart';

/// How one self-test step ended.
///
/// [timeout] is deliberately distinct from [failed]: "the native call never came
/// back" and "the native call returned an error" have completely different causes,
/// and telling them apart is the whole point of this diagnostic.
enum SelfTestStatus { passed, failed, timeout, skipped }

/// One completed step of the self-test, with timing and the **raw** error text.
class SelfTestStep {
  const SelfTestStep({
    required this.name,
    required this.status,
    this.detail,
    this.elapsed,
  });

  /// The operation, named after the native call it exercises
  /// (e.g. `downloadModel(hi)`).
  final String name;

  final SelfTestStatus status;

  /// Human-readable detail: a result, or the **exact** raw error.
  final String? detail;

  final Duration? elapsed;

  /// True for anything that stopped the run (error *or* timeout).
  bool get isFailure =>
      status == SelfTestStatus.failed || status == SelfTestStatus.timeout;

  String get label => switch (status) {
    SelfTestStatus.passed => 'PASS',
    SelfTestStatus.failed => 'FAIL',
    SelfTestStatus.timeout => 'TIMEOUT',
    SelfTestStatus.skipped => 'SKIP',
  };

  @override
  String toString() =>
      '[$label] $name'
      '${elapsed == null ? '' : ' (${elapsed!.inMilliseconds} ms)'}'
      '${detail == null ? '' : '\n        $detail'}';
}

/// A live snapshot of a run in progress.
///
/// Emitted after every step *and* on a ticker while a step is in flight, so the
/// screen can always show which operation is currently blocking and for how long —
/// instead of an anonymous spinner.
class SelfTestProgress {
  const SelfTestProgress({
    required this.steps,
    this.currentStep,
    this.activity,
    this.elapsed = Duration.zero,
    this.isRunning = true,
  });

  /// Steps finished so far, in order.
  final List<SelfTestStep> steps;

  /// The step currently in flight, if any.
  final String? currentStep;

  /// What that step is doing, e.g. `downloading…`.
  final String? activity;

  /// How long the in-flight step has been running.
  final Duration elapsed;

  final bool isRunning;
}

/// The full report produced by [TranslationSelfTest.run].
class TranslationSelfTestReport {
  const TranslationSelfTestReport({
    required this.steps,
    required this.translatedText,
    required this.explicitPathPassed,
    required this.directPathPassed,
    required this.directPathChecked,
  });

  final List<SelfTestStep> steps;

  /// The Hindi translation, when a path produced one.
  final String? translatedText;

  /// Whether the explicit check → download → translate flow succeeded.
  final bool explicitPathPassed;

  /// Whether a plain `translateText` (no explicit model management) succeeded.
  final bool directPathPassed;

  /// Whether the direct path was exercised at all.
  final bool directPathChecked;

  bool get passed => translatedText != null;

  /// The step that stopped the run — an error or a timeout.
  SelfTestStep? get firstFailure {
    for (final step in steps) {
      if (step.isFailure) return step;
    }
    return null;
  }

  /// The unambiguous verdict the screen shows on failure, e.g.
  ///
  /// ```
  /// FAILED
  /// Step: downloadModel(hi)
  /// Reason: Timeout after 120 seconds
  /// ```
  String get failureHeadline {
    final failure = firstFailure;
    if (failure == null) return 'FAILED\n(no failing step was recorded)';
    final reason = (failure.detail ?? '(no detail)').split('\n').first;
    return 'FAILED\nStep: ${failure.name}\nReason: $reason';
  }

  /// Plain-text rendering, used both for the on-screen view and to log/copy.
  String toPlainText() {
    final buffer = StringBuffer()
      ..writeln('ML Kit translation self-test')
      ..writeln('standalone: ${passed ? 'PASS' : 'FAIL'}')
      ..writeln(
        'explicit model management: ${explicitPathPassed ? 'PASS' : 'FAIL'}',
      )
      ..writeln(
        'direct (plugin-provisioned) translate: '
        '${directPathChecked ? (directPathPassed ? 'PASS' : 'FAIL') : 'not run'}',
      )
      ..writeln('result: ${translatedText ?? '(none)'}');
    if (!passed) {
      buffer.writeln('---');
      buffer.writeln(failureHeadline);
    }
    buffer
      ..writeln('---')
      ..writeln(steps.join('\n'));
    return buffer.toString();
  }
}

/// A **standalone** ML Kit translation test: fixed text in, Hindi out.
///
/// Deliberately bypasses OCR, language detection, selection, overlays, camera and
/// images. It answers one question on a real device: does Google ML Kit on-device
/// translation itself work here, and if not, at exactly which step does it fail?
///
/// Design rules that make it impossible for this to look hung:
/// * **One step at a time.** Every awaited operation is its own step, so progress
///   is observable after each one — never one opaque future for the whole flow.
/// * **A timeout per operation.** The native plugin bridges Play Services `Task`s
///   onto the platform channel with no timeout of its own: a `Task` that never
///   completes leaves the Dart future pending forever. Each step therefore has its
///   own budget and reports `TIMEOUT` naming that step.
/// * **BEFORE/AFTER logging.** Every operation logs immediately before and after
///   with elapsed milliseconds, under [kTranslationLogTag].
/// * **Stop at the first failure**, marking the rest `SKIP`, so the first blocking
///   operation is unambiguous.
///
/// Defaults to the explicit flow only (check → download → create → translate),
/// because that is the flow the app itself uses.
class TranslationSelfTest {
  TranslationSelfTest({
    MlKitTranslationEngine? engine,
    DeviceDiagnostics? diagnostics,
    Duration? checkTimeout,
    Duration? downloadTimeout,
    Duration? translateTimeout,
    Duration? environmentTimeout,
  }) : _engine = engine ?? MlKitTranslationEngine(),
       _diagnostics = diagnostics ?? const DeviceDiagnostics(),
       checkTimeout = checkTimeout ?? const Duration(seconds: 20),
       downloadTimeout = downloadTimeout ?? const Duration(seconds: 120),
       translateTimeout = translateTimeout ?? const Duration(seconds: 30),
       environmentTimeout = environmentTimeout ?? const Duration(seconds: 10);

  /// Fixed, well-formed English sentence — never OCR text.
  static const String sampleText = 'Hello, how are you?';

  /// Expected Hindi, used only as a sanity hint in the report (never injected).
  static const String expectedHint = 'नमस्ते, आप कैसे हैं?';

  /// Budget for the cheap `isModelDownloaded` probe. On a healthy device this
  /// answers in milliseconds; needing this long means it is wedged.
  final Duration checkTimeout;

  /// Budget for a model download. Deliberately generous: each model is ~30 MB, so
  /// a slow-but-working download must not be misreported as a hang.
  final Duration downloadTimeout;

  /// Budget for the translation call itself.
  final Duration translateTimeout;

  /// Budget for reading device facts over our own platform channel.
  final Duration environmentTimeout;

  final MlKitTranslationEngine _engine;
  final DeviceDiagnostics _diagnostics;

  /// The longest this run can possibly take, from the sum of the per-step
  /// budgets.
  ///
  /// Because every step is individually bounded, the whole diagnostic is bounded
  /// by construction — that is what makes "stuck on Running…" impossible. The
  /// screen uses this to arm an independent watchdog.
  Duration get worstCaseDuration =>
      environmentTimeout +
      checkTimeout * 2 +
      downloadTimeout * 2 +
      // Up to three bounded stages (create, translate, close).
      translateTimeout * 3;

  /// Runs the diagnostic, reporting progress after every step.
  Future<TranslationSelfTestReport> run({
    TranslationLanguage source = TranslationLanguages.english,
    TranslationLanguage target = TranslationLanguages.hindi,
    void Function(SelfTestProgress progress)? onProgress,
    bool includeDirectPath = false,
    bool abortOnFailure = true,
  }) async {
    final steps = <SelfTestStep>[];
    var currentStep = '';
    var activity = '';
    var stepElapsed = Duration.zero;

    void emit() => onProgress?.call(
      SelfTestProgress(
        steps: List<SelfTestStep>.unmodifiable(steps),
        currentStep: currentStep.isEmpty ? null : currentStep,
        activity: activity.isEmpty ? null : activity,
        elapsed: stepElapsed,
      ),
    );

    translationLog('=== self-test start ===');
    translationLog(
      'sample="$sampleText" source=${source.code} '
      'target=${target.code}',
    );

    /// Runs one operation as a single, individually-bounded step: logs
    /// BEFORE/AFTER, times it, and distinguishes an error from a timeout.
    Future<T?> step<T>(
      String name, {
      required String activityLabel,
      required Duration budget,
      required Future<T> Function() body,
      T? fallback,
      String Function(T value)? describe,
    }) async {
      currentStep = name;
      activity = activityLabel;
      stepElapsed = Duration.zero;
      emit();

      final stopwatch = Stopwatch()..start();
      translationLog(
        '[SELFTEST] $name: BEFORE (timeout ${budget.inMilliseconds} ms)',
      );
      final ticker = Timer.periodic(const Duration(milliseconds: 400), (_) {
        stepElapsed = stopwatch.elapsed;
        emit();
      });

      SelfTestStep complete(SelfTestStatus status, String detail) =>
          SelfTestStep(
            name: name,
            status: status,
            detail: detail,
            elapsed: stopwatch.elapsed,
          );

      try {
        final value = await body().timeout(budget);
        stopwatch.stop();
        ticker.cancel();
        final detail = describe?.call(value) ?? '$value';
        steps.add(complete(SelfTestStatus.passed, detail));
        translationLog(
          '[SELFTEST] $name: AFTER OK — $detail '
          '(${stopwatch.elapsedMilliseconds} ms)',
        );
        emit();
        return value;
      } on TimeoutException {
        stopwatch.stop();
        ticker.cancel();
        final detail =
            'Timeout after ${_timeoutLabel(budget)} '
            '(the native call never returned)';
        steps.add(complete(SelfTestStatus.timeout, detail));
        translationLog(
          '[SELFTEST] $name: AFTER TIMEOUT — $detail '
          '(${stopwatch.elapsedMilliseconds} ms)',
        );
        emit();
        return fallback;
      } catch (error, stack) {
        stopwatch.stop();
        ticker.cancel();
        final detail = TranslationException.describe(error, stack);
        steps.add(complete(SelfTestStatus.failed, detail));
        translationLog(
          '[SELFTEST] $name: AFTER FAILED '
          '(${stopwatch.elapsedMilliseconds} ms)\n$detail',
        );
        emit();
        return fallback;
      }
    }

    /// Marks everything not yet attempted after a step has failed.
    void skipRemaining(String reason) {
      final failure = steps.lastWhere((s) => s.isFailure);
      for (final name in _stepsAfter(failure.name, source, target)) {
        steps.add(
          SelfTestStep(
            name: name,
            status: SelfTestStatus.skipped,
            detail: 'not attempted: stopped after "${failure.name}" ($reason)',
          ),
        );
      }
      currentStep = '';
      activity = '';
      emit();
    }

    /// True once a step that actually exercises ML Kit has failed.
    ///
    /// The environment probe is informational, so its failure never blocks the
    /// rest of the test.
    bool blocked() => steps.any((s) => s.isFailure && s.name != 'environment');

    /// `create translator → translateText → close` as three separate rows, using
    /// the engine's per-stage trace. Returns the translated text on success.
    Future<String?> runTracedTranslate() async {
      final trace = await step<TranslatorCallTrace>(
        'translateTraced(${source.code}→${target.code})',
        activityLabel: 'creating translator + translating…',
        // Wider than the per-stage budget on purpose: the engine must be the one
        // to give up first, so the report names the exact stage that failed
        // rather than the umbrella call.
        budget: translateTimeout * 3,
        body: () => _engine.translateTraced(
          text: sampleText,
          source: source,
          target: target,
          timeout: translateTimeout,
        ),
        describe: (value) =>
            'create + translate + close in ${value.elapsedMilliseconds} ms',
      );
      if (trace == null) return null;

      // Replace the umbrella row with the per-stage truth so the report names the
      // exact native operation that failed.
      steps.removeWhere((s) => s.name.startsWith('translateTraced('));
      for (final stage in trace.stages) {
        final timedOut = stage.error is TimeoutException;
        steps.add(
          SelfTestStep(
            name: stage.name,
            status: stage.ok
                ? SelfTestStatus.passed
                : (timedOut ? SelfTestStatus.timeout : SelfTestStatus.failed),
            detail: timedOut
                ? 'Timeout after ${_timeoutLabel(translateTimeout)} '
                      '(the native call never returned)\n${stage.detail}'
                : stage.detail,
            elapsed: stage.elapsed,
          ),
        );
        currentStep = stage.name;
        activity = stage.ok ? 'done' : 'failed';
        emit();
      }

      if (trace.ok) return trace.result;
      translationLog(
        '[SELFTEST] blocked at stage '
        '"${trace.firstFailure?.name}": ${trace.firstFailure?.detail}',
      );
      return null;
    }

    // --- 0. environment -----------------------------------------------------
    // Runs first and is itself bounded: a wedged platform channel here must not
    // stop the diagnostic before it has printed anything.
    final device =
        await step<Map<String, Object?>>(
          'environment',
          activityLabel: 'reading device + Play Services versions…',
          budget: environmentTimeout,
          body: _diagnostics.collect,
          fallback: const <String, Object?>{},
          describe: (value) =>
              value.entries.map((e) => '${e.key}=${e.value}').join(', '),
        ) ??
        const <String, Object?>{};

    // --- 1. explicit flow, ONE native operation at a time -------------------
    String? explicitResult;

    if (abortOnFailure && blocked()) {
      skipRemaining('an earlier step failed');
    } else {
      // isModelDownloaded(en) → downloadModel(en) → isModelDownloaded(hi)
      // → downloadModel(hi) → translator → translateText.
      final sourceCheck = await step<bool>(
        'isModelDownloaded(${source.code})',
        activityLabel: 'checking…',
        budget: checkTimeout,
        body: () => _engine.isModelAvailable(source),
        fallback: false,
      );

      if (abortOnFailure && blocked()) {
        skipRemaining('source model check failed');
      } else {
        if (sourceCheck == true) {
          steps.add(
            SelfTestStep(
              name: 'downloadModel(${source.code})',
              status: SelfTestStatus.skipped,
              detail: 'not needed: model already on device',
            ),
          );
        } else {
          await step<bool>(
            'downloadModel(${source.code})',
            activityLabel: 'downloading…',
            budget: downloadTimeout,
            body: () async {
              await _engine.downloadModel(source);
              return true;
            },
            fallback: false,
            describe: (_) => 'downloaded',
          );
        }
      }

      if (abortOnFailure && blocked()) {
        skipRemaining('source model download failed');
      } else {
        final targetCheck = await step<bool>(
          'isModelDownloaded(${target.code})',
          activityLabel: 'checking…',
          budget: checkTimeout,
          body: () => _engine.isModelAvailable(target),
          fallback: false,
        );

        if (abortOnFailure && blocked()) {
          skipRemaining('target model check failed');
        } else {
          if (targetCheck == true) {
            steps.add(
              SelfTestStep(
                name: 'downloadModel(${target.code})',
                status: SelfTestStatus.skipped,
                detail: 'not needed: model already on device',
              ),
            );
          } else {
            await step<bool>(
              'downloadModel(${target.code})',
              activityLabel: 'downloading…',
              budget: downloadTimeout,
              body: () async {
                await _engine.downloadModel(target);
                return true;
              },
              fallback: false,
              describe: (_) => 'downloaded',
            );
          }

          if (!abortOnFailure || !blocked()) {
            explicitResult = await runTracedTranslate();
          } else {
            skipRemaining('target model download failed');
          }
        }
      }
    }

    final explicitPassed = explicitResult != null;

    // --- 2. optional direct path -------------------------------------------
    String? directResult;
    var directChecked = false;
    if (includeDirectPath && !steps.any((s) => s.isFailure)) {
      directChecked = true;
      directResult = await step<String>(
        'translateText() (direct, plugin-provisioned)',
        activityLabel: 'translating…',
        budget: translateTimeout,
        body: () =>
            _engine.translate(text: sampleText, source: source, target: target),
      );
    }

    final translated = explicitResult ?? directResult;

    currentStep = '';
    activity = '';
    emit();

    translationLog(
      '=== self-test result: ${translated == null ? 'FAIL' : 'PASS'} '
      '(explicit=${explicitPassed ? 'PASS' : 'FAIL'}, '
      'direct=${directChecked ? (directResult != null ? 'PASS' : 'FAIL') : 'not run'}) ===',
    );
    if (translated == null) {
      final failures = steps.where((s) => s.isFailure).toList();
      if (failures.isEmpty) {
        translationLog(
          'no step reported a failure, yet no translation was '
          'produced',
        );
      } else {
        translationLog(
          'blocked at "${failures.first.name}": '
          '${failures.first.detail}',
        );
      }
    } else {
      translationLog('translated: "$translated"');
    }
    if (device.isNotEmpty) {
      translationLog(
        'device: '
        '${device.entries.map((e) => '${e.key}=${e.value}').join(' | ')}',
      );
    }

    return TranslationSelfTestReport(
      steps: steps,
      translatedText: translated,
      explicitPathPassed: explicitPassed,
      directPathPassed: directResult != null,
      directPathChecked: directChecked,
    );
  }

  /// A human timeout label that stays honest below one second.
  static String _timeoutLabel(Duration budget) => budget.inSeconds >= 1
      ? '${budget.inSeconds} seconds'
      : '${budget.inMilliseconds} ms';

  /// The steps that would still have run, used to annotate them as skipped.
  static List<String> _stepsAfter(
    String failedStep,
    TranslationLanguage source,
    TranslationLanguage target,
  ) {
    final order = <String>[
      'environment',
      'isModelDownloaded(${source.code})',
      'downloadModel(${source.code})',
      'isModelDownloaded(${target.code})',
      'downloadModel(${target.code})',
      'translateTraced(${source.code}→${target.code})',
    ];
    final index = order.indexOf(failedStep);
    if (index < 0) return const <String>[];
    return order.sublist(index + 1);
  }
}
