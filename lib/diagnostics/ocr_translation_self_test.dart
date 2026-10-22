import 'dart:async';

import '../ocr/domain/ocr_result.dart';
import '../ocr/domain/ocr_script_mode.dart';
import '../ocr/domain/ocr_service.dart';
import '../translation/domain/translation_exception.dart';
import '../translation/domain/translation_language.dart';
import '../translation/domain/translation_request.dart';
import '../translation/domain/translation_result.dart';
import '../translation/domain/translation_service.dart';
import '../translation/domain/translation_text.dart';
import '../translation/translation_log.dart';
import 'translation_self_test.dart';

/// The outcome of the **real-pipeline** diagnostic: photo → OCR → Hindi.
///
/// Kept separate from [TranslationSelfTestReport] because it answers a different
/// question. [TranslationSelfTest] asks "does ML Kit translation work on this
/// device at all?"; this asks "does the app's actual photo → text → Hindi path
/// work?", which can fail at the OCR stage, at the text-preparation stage, or at
/// the translation stage — and those must not be confused with each other.
class OcrTranslationSelfTestReport {
  const OcrTranslationSelfTestReport({
    required this.steps,
    required this.imagePath,
    required this.extractedText,
    required this.translatedText,
    required this.ocrEngineName,
    required this.alreadyInTargetLanguage,
    required this.cancelled,
    this.detectedSource,
  });

  final List<SelfTestStep> steps;

  /// The photo that was read, when one was chosen.
  final String? imagePath;

  /// The text OCR produced from the photo.
  final String? extractedText;

  /// The Hindi text, when a real translation happened.
  final String? translatedText;

  /// Which engine read the photo, so an OCR problem is not blamed on translation.
  final String? ocrEngineName;

  /// True when the engine reported the text was *already* the target language.
  ///
  /// This is **not** a pass and must never be shown as one: no translation
  /// happened. It means the photo did not contain the language pair this test
  /// needs (usually an already-Hindi page, or the target set to English).
  final bool alreadyInTargetLanguage;

  /// True when the user dismissed the photo picker — nothing was attempted.
  final bool cancelled;

  /// The language identification resolved the extracted text to, when known.
  final TranslationLanguage? detectedSource;

  /// Whether a real, non-identity translation was produced.
  bool get passed => translatedText != null && !alreadyInTargetLanguage;

  /// The step that stopped the run — an error or a timeout.
  SelfTestStep? get firstFailure {
    for (final step in steps) {
      if (step.isFailure) return step;
    }
    return null;
  }

  /// The unambiguous verdict, naming the exact stage and its raw reason.
  String get failureHeadline {
    if (passed) return 'PASS';
    if (cancelled) {
      return 'NOT RUN\nStep: pick image\n'
          'Reason: no photo was chosen, so nothing was tested.';
    }
    final failure = firstFailure;
    if (failure != null) {
      final reason = (failure.detail ?? '(no detail)').split('\n').first;
      return 'FAILED\nStep: ${failure.name}\nReason: $reason';
    }
    if (alreadyInTargetLanguage) {
      return 'NOT PROVEN\nStep: translate\n'
          'Reason: the extracted text was already '
          '${detectedSource?.englishName ?? 'the target language'}, so nothing '
          'was translated. Use a photo containing English text.';
    }
    return 'FAILED\n(no failing step was recorded)';
  }

  /// Plain-text rendering, used for the on-screen view and for logs/copy.
  String toPlainText() {
    final buffer = StringBuffer()
      ..writeln('OCR → Hindi translation self-test')
      ..writeln(
        'verdict: '
        '${passed ? 'PASS' : (cancelled ? 'NOT RUN' : 'NOT PASSED')}',
      )
      ..writeln('photo: ${imagePath ?? '(none)'}')
      ..writeln('ocr engine: ${ocrEngineName ?? '(not run)'}')
      ..writeln('extracted: ${extractedText ?? '(none)'}')
      ..writeln('translated: ${translatedText ?? '(none)'}');
    if (!passed) {
      buffer
        ..writeln('---')
        ..writeln(failureHeadline);
    }
    buffer
      ..writeln('---')
      ..writeln(steps.join('\n'));
    return buffer.toString();
  }
}

/// **Real-pipeline** translation diagnostic: pick a photo, read it on device,
/// then translate what was read into Hindi.
///
/// Why this is a separate test from [TranslationSelfTest]
/// ------------------------------------------------------
/// [TranslationSelfTest] sends a fixed string straight to ML Kit, which isolates
/// the translator but proves nothing about the app's own path: the photo is never
/// read, the OCR text is never used, and the service layer that resolves the
/// source language and provisions models is bypassed. This one runs the real
/// thing — the injected [OcrService] and [TranslationService] are the app's own
/// instances — so a failure here names *which* half broke.
///
/// The two are never run at the same time, and this one does not import or touch
/// the other's state.
///
/// Design rules mirroring the standalone test
/// ------------------------------------------
/// * **One awaited operation per step**, so progress is observable after each.
/// * **A bound on every step.** The photo picker's bound is deliberately long and
///   named [pickTimeout], because that step waits on the *user* rather than the
///   device — a short bound there would report a slow human as a broken phone.
/// * **BEFORE/AFTER logging** under `PDF_UTILITY_TRANSLATION`, with elapsed ms.
/// * **Stop at the first failure**, marking the rest `SKIP`, so the blocking
///   operation is unambiguous.
/// * **No false pass.** A translation that came back as "already in the target
///   language" is reported as `NOT PROVEN`, not as success.
///
/// The text sent for translation is capped at [maxTranslateChars] so the
/// diagnostic stays bounded on a dense page; the cap is reported.
class OcrTranslationSelfTest {
  OcrTranslationSelfTest({
    required this.ocrService,
    required this.translationService,
    required this.pickImage,
    Duration? pickTimeout,
    Duration? ocrTimeout,
    Duration? translateTimeout,
    this.maxTranslateChars = 240,
  }) : pickTimeout = pickTimeout ?? const Duration(minutes: 5),
       ocrTimeout = ocrTimeout ?? const Duration(seconds: 90),
       translateTimeout = translateTimeout ?? const Duration(seconds: 240);

  /// The OCR service under test. Callers pass the app's **own** instance rather
  /// than a fresh one, so this exercises the real pipeline.
  final OcrService ocrService;

  /// The translation service under test — likewise the app's own.
  final TranslationService translationService;

  /// How a photo is chosen. Injected so tests never open the real picker, and so
  /// a caller can reuse a specific file.
  final Future<String?> Function() pickImage;

  /// Upper bound on the photo-picker step. This waits for a human, not the
  /// device, so it is minutes rather than seconds — and it is reported as its own
  /// step, so a long wait is visible rather than mysterious.
  final Duration pickTimeout;

  /// Upper bound on the on-device recognition call.
  final Duration ocrTimeout;

  /// Upper bound on detect + model provisioning + translation, which can
  /// legitimately include a first-run ~30 MB model download per language.
  final Duration translateTimeout;

  /// Longest prefix of the extracted text that is sent for translation.
  final int maxTranslateChars;

  /// The longest this run can possibly take, from the sum of the per-step
  /// budgets. The screen uses it to arm an independent watchdog.
  Duration get worstCaseDuration =>
      pickTimeout + ocrTimeout + translateTimeout + const Duration(seconds: 20);

  /// Runs the diagnostic, reporting progress after every step.
  ///
  /// Pass [imagePath] to re-run against a photo already chosen — useful when the
  /// first attempt failed on a transient model download and the user does not
  /// want to find the same photo again. The picker step is then recorded as
  /// skipped rather than silently omitted, so the report still accounts for every
  /// stage.
  Future<OcrTranslationSelfTestReport> run({
    OcrScriptMode mode = OcrScriptMode.defaultMode,
    TranslationLanguage target = TranslationLanguages.hindi,
    String? imagePath,
    void Function(SelfTestProgress progress)? onProgress,
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

    translationLog(
      '=== OCR→translate self-test start '
      '(mode=${mode.name}, target=${target.code}) ===',
    );

    /// Runs one operation as a single, individually-bounded step.
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
        '[OCR-SELFTEST] $name: BEFORE '
        '(timeout ${budget.inMilliseconds} ms)',
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
          '[OCR-SELFTEST] $name: AFTER OK — $detail '
          '(${stopwatch.elapsedMilliseconds} ms)',
        );
        emit();
        return value;
      } on TimeoutException {
        stopwatch.stop();
        ticker.cancel();
        final detail =
            'Timeout after ${_timeoutLabel(budget)} '
            '(the call never returned)';
        steps.add(complete(SelfTestStatus.timeout, detail));
        translationLog(
          '[OCR-SELFTEST] $name: AFTER TIMEOUT — $detail '
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
          '[OCR-SELFTEST] $name: AFTER FAILED '
          '(${stopwatch.elapsedMilliseconds} ms)\n$detail',
        );
        emit();
        return fallback;
      }
    }

    /// Marks everything after the failing step as not attempted.
    void skipRemaining(String failedStepName) {
      for (final name in _stepsAfter(failedStepName, mode, target)) {
        steps.add(
          SelfTestStep(
            name: name,
            status: SelfTestStatus.skipped,
            detail: 'not attempted: stopped after "$failedStepName"',
          ),
        );
      }
      currentStep = '';
      activity = '';
      emit();
    }

    OcrTranslationSelfTestReport report({
      String? imagePath,
      String? extracted,
      String? translated,
      String? ocrEngine,
      bool alreadyInTarget = false,
      bool cancelled = false,
      TranslationLanguage? detectedSource,
    }) {
      currentStep = '';
      activity = '';
      emit();
      final result = OcrTranslationSelfTestReport(
        steps: List<SelfTestStep>.unmodifiable(steps),
        imagePath: imagePath,
        extractedText: extracted,
        translatedText: translated,
        ocrEngineName: ocrEngine,
        alreadyInTargetLanguage: alreadyInTarget,
        cancelled: cancelled,
        detectedSource: detectedSource,
      );
      translationLog(
        '=== OCR→translate self-test result: '
        '${result.passed ? 'PASS' : 'NOT PASSED'} ===',
      );
      if (!result.passed) translationLog(result.failureHeadline);
      return result;
    }

    // --- 1. the photo -------------------------------------------------------
    final String picked;
    if (imagePath != null) {
      picked = imagePath;
      steps.add(
        SelfTestStep(
          name: 'pick image',
          status: SelfTestStatus.skipped,
          detail: 'reusing the previous photo: $imagePath',
        ),
      );
      emit();
    } else {
      final chosen = await step<String?>(
        'pick image',
        activityLabel: 'waiting for you to choose a photo…',
        budget: pickTimeout,
        body: pickImage,
        describe: (value) => value ?? '(nothing selected)',
      );

      if (chosen == null) {
        // Distinguish a dismissal (not a failure) from a timeout/error on the
        // picker, which is already recorded as a failing step.
        final last = steps.last;
        if (!last.isFailure) {
          steps[steps.length - 1] = const SelfTestStep(
            name: 'pick image',
            status: SelfTestStatus.skipped,
            detail: 'no photo was chosen',
          );
        }
        return report(cancelled: true);
      }
      picked = chosen;
    }

    // --- 2. read the photo on device ----------------------------------------
    final ocr = await step<OcrResult>(
      'recognizeImage(${mode.name})',
      activityLabel: 'reading the photo on device…',
      budget: ocrTimeout,
      body: () => ocrService.recognizeImage(picked, mode: mode),
      describe: (value) =>
          '${value.engineName} • ${value.blocks.length} blocks '
          '• ${value.elements.length} words • '
          '${value.sourceImage.width}x${value.sourceImage.height}'
          '${value.elapsed == null ? '' : ' • ${value.elapsed!.inMilliseconds} ms'}',
    );

    if (ocr == null) {
      skipRemaining('recognizeImage(${mode.name})');
      return report(imagePath: picked);
    }

    // --- 3. turn the recognition into text to translate ---------------------
    // A separate step so "OCR found nothing" is never mistaken for "translation
    // failed".
    final prepared = await step<({String text, bool truncated})>(
      'extracted text',
      activityLabel: 'preparing the text…',
      budget: const Duration(seconds: 10),
      body: () async {
        final extracted = _extract(ocr.fullText);
        if (extracted.text.isEmpty) {
          throw StateError(
            'OCR returned no usable text for this photo, so there is nothing to '
            'translate. Use a photo with clear, well-lit text.',
          );
        }
        return extracted;
      },
      describe: (value) =>
          '${value.text.length} chars'
          '${value.truncated ? ' (truncated to $maxTranslateChars for a bounded test)' : ''}'
          ': "${_preview(value.text)}"',
    );

    if (prepared == null) {
      skipRemaining('extracted text');
      return report(imagePath: picked, ocrEngine: ocr.engineName);
    }

    // --- 4. translate the extracted text ------------------------------------
    final translateName = 'translate(auto→${target.code})';
    final translated = await step<TranslationResult>(
      translateName,
      activityLabel: 'detecting, preparing models, translating…',
      budget: translateTimeout,
      body: () => translationService.translate(
        TranslationRequest(
          text: prepared.text,
          source: TranslationLanguages.auto,
          target: target,
          scope: TranslationScope.wholePage,
        ),
        onProgress: (progress) {
          // Only the label changes here: the per-step ticker keeps owning the
          // elapsed clock, so the display never jumps back to zero.
          activity =
              '${progress.phase.name}'
              '${progress.language == null ? '' : ' ${progress.language!.code}'}';
          emit();
        },
      ),
      describe: (value) =>
          'translated="${_preview(value.translatedText)}" '
          '(${value.translatedText.length} chars) '
          'source=${value.sourceLanguage.code}'
          '${value.sourceWasAutoDetected ? ' (auto-detected)' : ''} '
          '${value.alreadyInTargetLanguage ? 'ALREADY IN TARGET — nothing was translated' : ''}'
          '${value.elapsed == null ? '' : ' • ${value.elapsed!.inMilliseconds} ms'}',
    );

    if (translated == null) {
      skipRemaining(translateName);
      return report(
        imagePath: picked,
        extracted: prepared.text,
        ocrEngine: ocr.engineName,
      );
    }

    if (translated.alreadyInTargetLanguage) {
      // Recording this as a passed translation step would be a false pass: the
      // engine round-tripped the text unchanged.
      steps[steps.length - 1] = SelfTestStep(
        name: translateName,
        status: SelfTestStatus.skipped,
        detail:
            'not proven: the engine reported the extracted text is already '
            '${target.englishName}, so nothing was translated',
        elapsed: steps.last.elapsed,
      );
      return report(
        imagePath: picked,
        extracted: prepared.text,
        ocrEngine: ocr.engineName,
        alreadyInTarget: true,
        detectedSource: translated.sourceLanguage,
      );
    }

    return report(
      imagePath: picked,
      extracted: prepared.text,
      translated: translated.translatedText,
      ocrEngine: ocr.engineName,
      detectedSource: translated.sourceLanguage,
    );
  }

  /// The text to translate: whitespace-normalised, capped at
  /// [maxTranslateChars] and cut at a word boundary.
  ({String text, bool truncated}) _extract(String fullText) {
    final collapsed = TranslationText.normalize(
      fullText,
    ).replaceAll(RegExp(r'\s+'), ' ').trim();
    if (collapsed.length <= maxTranslateChars) {
      return (text: collapsed, truncated: false);
    }
    var cut = collapsed.substring(0, maxTranslateChars);
    final lastSpace = cut.lastIndexOf(' ');
    if (lastSpace > maxTranslateChars ~/ 2) cut = cut.substring(0, lastSpace);
    return (text: cut.trim(), truncated: true);
  }

  static String _preview(String text) {
    final single = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    return single.length <= 60 ? single : '${single.substring(0, 60)}…';
  }

  static String _timeoutLabel(Duration budget) => budget.inSeconds >= 1
      ? '${budget.inSeconds} seconds'
      : '${budget.inMilliseconds} ms';

  /// The steps that would still have run, used to annotate them as skipped.
  static List<String> _stepsAfter(
    String failedStep,
    OcrScriptMode mode,
    TranslationLanguage target,
  ) {
    final order = <String>[
      'pick image',
      'recognizeImage(${mode.name})',
      'extracted text',
      'translate(auto→${target.code})',
    ];
    final index = order.indexOf(failedStep);
    if (index < 0) return const <String>[];
    return order.sublist(index + 1);
  }
}
