import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdf_utility_flutter/diagnostics/device_diagnostics.dart';
import 'package:pdf_utility_flutter/diagnostics/ocr_translation_self_test.dart';
import 'package:pdf_utility_flutter/diagnostics/translation_self_test.dart';
import 'package:pdf_utility_flutter/ocr/domain/ocr_block.dart';
import 'package:pdf_utility_flutter/ocr/domain/ocr_element.dart';
import 'package:pdf_utility_flutter/ocr/domain/ocr_line.dart';
import 'package:pdf_utility_flutter/ocr/domain/ocr_rect.dart';
import 'package:pdf_utility_flutter/ocr/domain/ocr_result.dart';
import 'package:pdf_utility_flutter/ocr/domain/ocr_script_mode.dart';
import 'package:pdf_utility_flutter/ocr/domain/ocr_service.dart';
import 'package:pdf_utility_flutter/screens/translation_diagnostics_screen.dart';
import 'package:pdf_utility_flutter/translation/data/mlkit_translation_engine.dart';
import 'package:pdf_utility_flutter/translation/domain/translation_exception.dart';
import 'package:pdf_utility_flutter/translation/domain/translation_language.dart';
import 'package:pdf_utility_flutter/translation/domain/translation_service.dart';

import 'support/translation_fakes.dart';

/// Stands in for the real OCR engine, so the pipeline can be exercised with no
/// platform channel.
class _FakeOcrService implements OcrService {
  _FakeOcrService({
    this.fullText = 'Hello, how are you?',
    this.error,
    this.hang = false,
  });

  final String fullText;
  final Object? error;
  final bool hang;

  final List<String> paths = <String>[];
  final List<OcrScriptMode> modes = <OcrScriptMode>[];

  @override
  String get engineName => 'Fake OCR';

  @override
  Future<OcrResult> recognizeImage(
    String imagePath, {
    OcrScriptMode mode = OcrScriptMode.defaultMode,
  }) async {
    paths.add(imagePath);
    modes.add(mode);
    if (hang) return Completer<OcrResult>().future;
    final failure = error;
    if (failure != null) throw failure;
    return _ocrResult(fullText, imagePath);
  }

  @override
  Future<void> dispose() async {}
}

OcrResult _ocrResult(String text, String path) {
  final rawLines = [
    for (final line in text.split('\n'))
      if (line.trim().isNotEmpty) line,
  ];
  final lines = <OcrLine>[];
  final allWords = <OcrElement>[];
  for (var i = 0; i < rawLines.length; i++) {
    final words = <OcrElement>[];
    var x = 40.0;
    for (final token in rawLines[i].split(' ')) {
      if (token.isEmpty) continue;
      final word = OcrElement(
        text: token,
        boundingBox: OcrRect.fromLTRB(x, i * 60.0 + 10, x + 50, i * 60.0 + 40),
      );
      words.add(word);
      allWords.add(word);
      x += 56;
    }
    lines.add(
      OcrLine(
        text: rawLines[i],
        boundingBox: OcrRect.fromLTRB(40, i * 60.0 + 10, x, i * 60.0 + 40),
        elements: words,
      ),
    );
  }
  return OcrResult(
    sourceImage: SourceImageInfo(path: path, width: 800, height: 600),
    fullText: text,
    blocks: [
      OcrBlock(
        text: text,
        boundingBox: OcrRect.fromLTRB(0, 0, 800, 600),
        lines: lines,
      ),
    ],
    engineName: 'Fake OCR',
    elapsed: const Duration(milliseconds: 42),
  );
}

OcrTranslationSelfTest _runner({
  required OcrService ocrService,
  required TranslationService service,
  String? picked = '/tmp/photo.jpg',
  Duration? ocrTimeout,
  Duration? translateTimeout,
  int maxTranslateChars = 240,
  List<int>? pickCalls,
}) => OcrTranslationSelfTest(
  ocrService: ocrService,
  translationService: service,
  pickImage: () async {
    pickCalls?.add(1);
    return picked;
  },
  ocrTimeout: ocrTimeout ?? const Duration(seconds: 1),
  translateTimeout: translateTimeout ?? const Duration(seconds: 1),
  maxTranslateChars: maxTranslateChars,
);

void main() {
  group('happy path', () {
    test('a photo of English text is read and translated into Hindi', () async {
      final ocr = _FakeOcrService(fullText: 'Hello, how are you?');
      final translation = FakeTranslationService();

      final report = await _runner(ocrService: ocr, service: translation).run();

      expect(report.passed, isTrue);
      expect(report.cancelled, isFalse);
      expect(report.extractedText, 'Hello, how are you?');
      expect(report.translatedText, 'अनुवाद: Hello, how are you?');
      expect(report.ocrEngineName, 'Fake OCR');
      expect(report.detectedSource, TranslationLanguages.english);
      expect(report.failureHeadline, 'PASS');
    });

    test('runs exactly the four stages, in order, each with timing', () async {
      final ocr = _FakeOcrService();
      final report = await _runner(
        ocrService: ocr,
        service: FakeTranslationService(),
      ).run();

      expect(report.steps.map((step) => step.name).toList(), <String>[
        'pick image',
        'recognizeImage(${OcrScriptMode.defaultMode.name})',
        'extracted text',
        'translate(auto→hi)',
      ]);
      // Every awaited operation reports its own elapsed time — that is what makes
      // a stuck device diagnosable instead of just "waiting".
      for (final step in report.steps) {
        expect(step.status, SelfTestStatus.passed, reason: step.name);
        expect(step.elapsed, isNotNull, reason: step.name);
      }
    });

    test(
      'the photo is read with the script mode the caller asked for',
      () async {
        final ocr = _FakeOcrService();
        await _runner(
          ocrService: ocr,
          service: FakeTranslationService(),
        ).run(mode: OcrScriptMode.latin);

        expect(ocr.modes, <OcrScriptMode>[OcrScriptMode.latin]);
        expect(ocr.paths, <String>['/tmp/photo.jpg']);
      },
    );

    test(
      'the extracted text is whitespace-normalised before translating',
      () async {
        final translation = FakeTranslationService();
        await _runner(
          ocrService: _FakeOcrService(fullText: '  Hello ,\n\n  world  '),
          service: translation,
        ).run();

        expect(translation.requests.single.normalizedText, 'Hello , world');
      },
    );

    test(
      'the text sent for translation is capped and cut at a word boundary',
      () async {
        final longLine = List<String>.filled(60, 'word').join(' ');
        final translation = FakeTranslationService();

        final report = await _runner(
          ocrService: _FakeOcrService(fullText: longLine),
          service: translation,
          maxTranslateChars: 40,
        ).run();

        final sent = translation.requests.single.text;
        expect(sent.length, lessThanOrEqualTo(40));
        // Cut between words, never mid-word.
        expect(sent.endsWith('word'), isTrue);
        expect(longLine, startsWith(sent));
        expect(report.extractedText, sent);
      },
    );
  });

  group('failures name the stage that broke', () {
    test('an unreadable photo fails at the OCR step, and never reaches '
        'translation', () async {
      final translation = FakeTranslationService();
      final report = await _runner(
        ocrService: _FakeOcrService(fullText: ''),
        service: translation,
      ).run();

      expect(report.passed, isFalse);
      expect(report.firstFailure?.name, 'extracted text');
      expect(report.firstFailure?.detail, contains('no usable text'));
      // The translation never ran, and the report says so rather than leaving a
      // gap.
      expect(translation.requests, isEmpty);
      expect(
        report.steps.map((step) => step.name),
        contains('translate(auto→hi)'),
      );
      expect(
        report.steps
            .firstWhere((step) => step.name == 'translate(auto→hi)')
            .status,
        SelfTestStatus.skipped,
      );
      expect(report.failureHeadline, contains('Step: extracted text'));
    });

    test('an OCR engine failure is reported as an OCR failure', () async {
      final translation = FakeTranslationService();
      final report = await _runner(
        ocrService: _FakeOcrService(error: StateError('recognizer exploded')),
        service: translation,
      ).run();

      expect(report.passed, isFalse);
      expect(
        report.firstFailure?.name,
        'recognizeImage(${OcrScriptMode.defaultMode.name})',
      );
      expect(report.firstFailure?.status, SelfTestStatus.failed);
      expect(report.firstFailure?.detail, contains('recognizer exploded'));
      expect(translation.requests, isEmpty);
    });

    test('a hung recognizer times out instead of hanging the test', () async {
      final report = await _runner(
        ocrService: _FakeOcrService(hang: true),
        service: FakeTranslationService(),
        ocrTimeout: const Duration(milliseconds: 60),
      ).run();

      // Timeout is distinct from failure: "never came back" is a different bug
      // from "returned an error".
      expect(report.firstFailure?.status, SelfTestStatus.timeout);
      expect(report.firstFailure?.detail, contains('never returned'));
    });

    test('a translation failure is reported at the translate step with the '
        'raw reason', () async {
      final report = await _runner(
        ocrService: _FakeOcrService(),
        service: FakeTranslationService(
          failure: const TranslationException(
            TranslationErrorKind.modelUnavailable,
            "We couldn't prepare Hindi on this device.",
            details: 'downloadModel(hi) attempt 1/3: timeout',
          ),
        ),
      ).run();

      expect(report.passed, isFalse);
      expect(report.firstFailure?.name, 'translate(auto→hi)');
      expect(report.firstFailure?.detail, contains('downloadModel(hi)'));
      // The OCR half is still reported as working, so the two are separable.
      expect(report.extractedText, 'Hello, how are you?');
    });

    test('a hung translation times out', () async {
      final report = await _runner(
        ocrService: _FakeOcrService(),
        service: FakeTranslationService(delay: const Duration(seconds: 5)),
        translateTimeout: const Duration(milliseconds: 60),
      ).run();

      expect(report.firstFailure?.name, 'translate(auto→hi)');
      expect(report.firstFailure?.status, SelfTestStatus.timeout);
    });

    test(
      'a report names its first failure and a plain-text version exists',
      () async {
        final report = await _runner(
          ocrService: _FakeOcrService(fullText: ''),
          service: FakeTranslationService(),
        ).run();

        final text = report.toPlainText();
        expect(text, contains('OCR → Hindi translation self-test'));
        expect(text, contains('NOT PASSED'));
        expect(text, contains('extracted text'));
      },
    );
  });

  group('no false passes', () {
    test(
      'text already in the target language is NOT PROVEN, not a pass',
      () async {
        // This is the trap: the engine round-trips Hindi to Hindi and reports
        // success. Counting that as a translation would be a false pass.
        final report = await _runner(
          ocrService: _FakeOcrService(fullText: 'यह पहले से हिंदी है'),
          service: FakeTranslationService(
            alreadyInTargetLanguage: true,
            detectedSource: TranslationLanguages.hindi,
          ),
        ).run();

        expect(report.passed, isFalse);
        expect(report.alreadyInTargetLanguage, isTrue);
        expect(report.translatedText, isNull);
        expect(report.failureHeadline, contains('NOT PROVEN'));
        expect(report.failureHeadline, contains('already'));
        // The step is recorded as skipped, never as a passed translation.
        final translateStep = report.steps.firstWhere(
          (step) => step.name == 'translate(auto→hi)',
        );
        expect(translateStep.status, SelfTestStatus.skipped);
        expect(translateStep.detail, contains('nothing was translated'));
        // And there is no "failure" to mislead the reader either.
        expect(report.firstFailure, isNull);
        expect(report.toPlainText(), contains('NOT PASSED'));
      },
    );
  });

  group('the photo step', () {
    test(
      'dismissing the picker reports NOT RUN rather than a failure',
      () async {
        final ocr = _FakeOcrService();
        final report = await _runner(
          ocrService: ocr,
          service: FakeTranslationService(),
          picked: null,
        ).run();

        expect(report.cancelled, isTrue);
        expect(report.passed, isFalse);
        expect(report.firstFailure, isNull);
        expect(report.failureHeadline, contains('NOT RUN'));
        expect(ocr.paths, isEmpty);
        expect(report.steps.single.status, SelfTestStatus.skipped);
      },
    );

    test(
      'a supplied image path skips the picker but is still recorded',
      () async {
        final pickerCalls = <int>[];
        final ocr = _FakeOcrService();
        final report = await _runner(
          ocrService: ocr,
          service: FakeTranslationService(),
          pickCalls: pickerCalls,
          picked: '/tmp/other.jpg',
        ).run(imagePath: '/tmp/reused.jpg');

        expect(report.passed, isTrue);
        expect(pickerCalls, isEmpty, reason: 'the picker must not be opened');
        expect(ocr.paths, <String>['/tmp/reused.jpg']);
        final pickStep = report.steps.first;
        expect(pickStep.name, 'pick image');
        expect(pickStep.status, SelfTestStatus.skipped);
        expect(pickStep.detail, contains('/tmp/reused.jpg'));
      },
    );
  });

  group('screen', () {
    /// Pumps the screen on a tall surface.
    ///
    /// The diagnostics bodies are [ListView]s, which only build their visible
    /// children — on the default 800x600 window Test B would not exist as a
    /// widget at all, and the test would fail for the wrong reason.
    Future<void> pumpScreen(WidgetTester tester, Widget screen) async {
      tester.view.physicalSize = const Size(1200, 4200);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(MaterialApp(home: screen));
    }

    /// Test A's engine, kept trivial so these tests are about Test B.
    TranslationSelfTest fastSelfTest() => TranslationSelfTest(
      engine: _PassingEngine(),
      // The real DeviceDiagnostics arms a 10 s channel timeout that a step
      // budget does not cancel, which would leave a pending timer at the end
      // of the test.
      diagnostics: const _FakeDiagnostics(),
      checkTimeout: const Duration(milliseconds: 5),
      downloadTimeout: const Duration(milliseconds: 5),
      translateTimeout: const Duration(milliseconds: 5),
      environmentTimeout: const Duration(milliseconds: 5),
    );

    testWidgets('Test B runs and shows its verdict', (tester) async {
      final ocr = _FakeOcrService();
      final translation = FakeTranslationService();
      var picks = 0;

      await pumpScreen(
        tester,
        TranslationDiagnosticsScreen(
          selfTest: fastSelfTest(),
          ocrSelfTest: OcrTranslationSelfTest(
            ocrService: ocr,
            translationService: translation,
            pickImage: () async {
              picks++;
              return '/tmp/photo.jpg';
            },
            ocrTimeout: const Duration(seconds: 1),
            translateTimeout: const Duration(seconds: 1),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Test A ran first, on its own.
      expect(find.text('ML Kit standalone translation: PASS'), findsOneWidget);
      // Test B has not been touched yet.
      expect(find.text('Pick a photo & translate'), findsOneWidget);
      expect(picks, 0);

      await tester.tap(find.text('Pick a photo & translate'));
      await tester.pumpAndSettle();

      expect(picks, 1);
      expect(find.text('OCR → Hindi translation: PASS'), findsOneWidget);
      expect(find.text('Extracted:'), findsOneWidget);
      expect(find.text('Hello, how are you?'), findsOneWidget);
      expect(find.text('Hindi: अनुवाद: Hello, how are you?'), findsOneWidget);
    });

    testWidgets('Test B can re-run the same photo without picking again', (
      tester,
    ) async {
      var picks = 0;
      await pumpScreen(
        tester,
        TranslationDiagnosticsScreen(
          selfTest: fastSelfTest(),
          ocrSelfTest: OcrTranslationSelfTest(
            ocrService: _FakeOcrService(),
            translationService: FakeTranslationService(),
            pickImage: () async {
              picks++;
              return '/tmp/photo.jpg';
            },
            ocrTimeout: const Duration(seconds: 1),
            translateTimeout: const Duration(seconds: 1),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('Pick a photo & translate'));
      await tester.pumpAndSettle();
      expect(picks, 1);

      await tester.tap(find.text('Test the same photo again'));
      await tester.pumpAndSettle();

      expect(picks, 1, reason: 're-running must not reopen the picker');
      expect(find.textContaining('reusing the previous photo'), findsOneWidget);
      expect(find.text('OCR → Hindi translation: PASS'), findsOneWidget);
    });

    testWidgets('the two tests can never run at the same time', (tester) async {
      await pumpScreen(
        tester,
        TranslationDiagnosticsScreen(
          // Test A is in flight for the whole assertion below.
          selfTest: TranslationSelfTest(
            engine: _HangingEngine(),
            diagnostics: const _FakeDiagnostics(),
            checkTimeout: const Duration(seconds: 2),
            downloadTimeout: const Duration(seconds: 2),
            translateTimeout: const Duration(seconds: 2),
            environmentTimeout: const Duration(seconds: 2),
          ),
          ocrSelfTest: OcrTranslationSelfTest(
            ocrService: _FakeOcrService(),
            translationService: FakeTranslationService(),
            pickImage: () async => '/tmp/photo.jpg',
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 600));

      final bButton = tester.widget<FilledButton>(
        find.ancestor(
          of: find.text('Pick a photo & translate'),
          matching: find.byType(FilledButton),
        ),
      );
      expect(bButton.onPressed, isNull, reason: 'Test B must wait for Test A');

      // Let Test A's budgets expire so nothing is left pending.
      await tester.pumpAndSettle(const Duration(seconds: 12));
      expect(find.text('Run again'), findsOneWidget);
      expect(find.text('Pick a photo & translate'), findsOneWidget);
    });

    testWidgets('a cancelled pick reports NOT RUN, not a failure', (
      tester,
    ) async {
      await pumpScreen(
        tester,
        TranslationDiagnosticsScreen(
          selfTest: fastSelfTest(),
          ocrSelfTest: OcrTranslationSelfTest(
            ocrService: _FakeOcrService(),
            translationService: FakeTranslationService(),
            pickImage: () async => null,
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('Pick a photo & translate'));
      await tester.pumpAndSettle();

      expect(find.text('OCR → Hindi translation: NOT RUN'), findsOneWidget);
      expect(find.textContaining('no photo was chosen'), findsWidgets);
      expect(find.textContaining('NOT RUN'), findsWidgets);
    });
  });
}

/// Stands in for the native `pdf_utility/diagnostics` channel, so Test A never
/// leaves a platform timer behind.
class _FakeDiagnostics implements DeviceDiagnostics {
  const _FakeDiagnostics();

  @override
  Duration get channelTimeout => Duration.zero;

  @override
  Future<Map<String, Object?>> collect() async => const <String, Object?>{
    'device': 'test',
  };
}

/// A stub engine for Test A in these tests: every step succeeds immediately.
class _PassingEngine extends MlKitTranslationEngine {
  @override
  Future<bool> isModelAvailable(TranslationLanguage language) async => true;

  @override
  Future<TranslatorCallTrace> translateTraced({
    required String text,
    required TranslationLanguage source,
    required TranslationLanguage target,
    Duration? timeout,
  }) async => TranslatorCallTrace(
    sourceCode: source.code,
    targetCode: target.code,
    stages: const <TranslatorStage>[
      TranslatorStage(
        name: 'translateText()',
        elapsed: Duration(milliseconds: 3),
        value: 'result="नमस्ते, आप कैसे हैं?"',
      ),
    ],
    elapsed: const Duration(milliseconds: 4),
    result: 'नमस्ते, आप कैसे हैं?',
  );

  @override
  Future<String> translate({
    required String text,
    required TranslationLanguage source,
    required TranslationLanguage target,
  }) async => 'नमस्ते, आप कैसे हैं?';
}

/// An engine whose model check never resolves — the stall that used to leave the
/// screen spinning.
class _HangingEngine extends _PassingEngine {
  @override
  Future<bool> isModelAvailable(TranslationLanguage language) =>
      Completer<bool>().future;
}
