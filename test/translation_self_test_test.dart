import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdf_utility_flutter/diagnostics/device_diagnostics.dart';
import 'package:pdf_utility_flutter/diagnostics/translation_self_test.dart';
import 'package:pdf_utility_flutter/screens/translation_diagnostics_screen.dart';
import 'package:pdf_utility_flutter/translation/data/mlkit_translation_engine.dart';
import 'package:pdf_utility_flutter/translation/domain/translation_exception.dart';
import 'package:pdf_utility_flutter/translation/domain/translation_language.dart';
import 'package:pdf_utility_flutter/translation/domain/translation_model_manager.dart';

/// Stands in for the real ML Kit engine so the self-test flow can be exercised
/// with no platform channel.
class _FakeEngine extends MlKitTranslationEngine {
  _FakeEngine({
    Set<String> models = const {'en', 'hi'},
    this.failDownload = false,
    this.failTranslate = false,
  }) : _models = <String>{...models};

  final Set<String> _models;
  final bool failDownload;
  final bool failTranslate;

  final List<String> downloadCalls = <String>[];
  final List<({String text, String source, String target})> translateCalls = [];

  String get _pair =>
      '${TranslationLanguages.english.code}→${TranslationLanguages.hindi.code}';

  @override
  Future<bool> isModelAvailable(TranslationLanguage language) async =>
      _models.contains(language.code);

  @override
  Future<void> downloadModel(TranslationLanguage language) async {
    downloadCalls.add(language.code);
    if (failDownload) {
      throw const TranslationException(
        TranslationErrorKind.modelUnavailable,
        "We couldn't prepare Hindi on this device.",
        details: 'downloadModel(hi) returned false',
      );
    }
    _models.add(language.code);
  }

  /// The self-test drives the traced path, so the fake must model its stages.
  @override
  Future<TranslatorCallTrace> translateTraced({
    required String text,
    required TranslationLanguage source,
    required TranslationLanguage target,
    Duration? timeout,
  }) async {
    translateCalls.add((text: text, source: source.code, target: target.code));

    if (failTranslate) {
      final error = PlatformException(
        code: 'Error building translator',
        message: 'Either source or target models not downloaded',
      );
      return TranslatorCallTrace(
        sourceCode: source.code,
        targetCode: target.code,
        stages: <TranslatorStage>[
          TranslatorStage(
            name: 'create OnDeviceTranslator ${source.code}→${target.code}',
            elapsed: const Duration(milliseconds: 3),
            value: 'created',
          ),
          TranslatorStage(
            name: 'translateText() chars=${text.length} $_pair',
            elapsed: const Duration(milliseconds: 2),
            error: error,
          ),
          const TranslatorStage(
            name: 'close()',
            elapsed: Duration(milliseconds: 1),
            value: 'ok',
          ),
        ],
        elapsed: const Duration(milliseconds: 6),
        error: error,
      );
    }

    return TranslatorCallTrace(
      sourceCode: source.code,
      targetCode: target.code,
      stages: <TranslatorStage>[
        TranslatorStage(
          name: 'create OnDeviceTranslator ${source.code}→${target.code}',
          elapsed: const Duration(milliseconds: 3),
          value: 'created',
        ),
        TranslatorStage(
          name: 'translateText() chars=${text.length} $_pair',
          elapsed: const Duration(milliseconds: 40),
          value: 'result="नमस्ते, आप कैसे हैं?" (19 chars)',
        ),
        const TranslatorStage(
          name: 'close()',
          elapsed: Duration(milliseconds: 1),
          value: 'ok',
        ),
      ],
      elapsed: const Duration(milliseconds: 44),
      result: 'नमस्ते, आप कैसे हैं?',
    );
  }

  @override
  Future<String> translate({
    required String text,
    required TranslationLanguage source,
    required TranslationLanguage target,
  }) async {
    translateCalls.add((text: text, source: source.code, target: target.code));
    if (failTranslate) {
      throw const TranslationException(
        TranslationErrorKind.engineFailure,
        'Translation failed on this device. Please try again.',
      );
    }
    return 'नमस्ते, आप कैसे हैं?';
  }
}

/// An engine whose native call never resolves — the exact behaviour that left the
/// screen spinning. The step budget must break it.
class _HangingEngine extends _FakeEngine {
  @override
  Future<bool> isModelAvailable(TranslationLanguage language) =>
      Completer<bool>().future;
}

/// A self-test that throws *outside* any step, to prove the screen still leaves
/// the Running state.
class _ThrowingSelfTest extends TranslationSelfTest {
  _ThrowingSelfTest()
    : super(engine: _FakeEngine(), diagnostics: const _FakeDiagnostics());

  @override
  Future<TranslationSelfTestReport> run({
    TranslationLanguage source = TranslationLanguages.english,
    TranslationLanguage target = TranslationLanguages.hindi,
    void Function(SelfTestProgress progress)? onProgress,
    bool includeDirectPath = false,
    bool abortOnFailure = true,
  }) async => throw StateError('boom outside any step');
}

class _FakeDiagnostics extends DeviceDiagnostics {
  const _FakeDiagnostics();

  @override
  Future<Map<String, Object?>> collect() async => const {
    'model': 'Test Device',
    'androidRelease': '14',
    'googlePlayServicesVersion': '24.12.34',
  };
}

/// Builds a self-test with budgets short enough for a test to run instantly but
/// long enough to still read as "seconds" in the message.
TranslationSelfTest _fast({
  MlKitTranslationEngine? engine,
  Duration check = const Duration(seconds: 1),
  Duration download = const Duration(seconds: 2),
  Duration translate = const Duration(seconds: 1),
}) => TranslationSelfTest(
  engine: engine ?? _FakeEngine(),
  diagnostics: const _FakeDiagnostics(),
  checkTimeout: check,
  downloadTimeout: download,
  translateTimeout: translate,
  environmentTimeout: const Duration(seconds: 1),
);

/// A model manager that reports both models as already present, so the real
/// engine can be driven straight to its translation stages.
class _PresentModelManager implements TranslationModelManager {
  @override
  Future<bool> isModelDownloaded(String code) async => true;

  @override
  Future<bool> downloadModel(String code) async => true;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'passes end-to-end with a fixed sentence, using the English→Hindi pair',
    () async {
      final engine = _FakeEngine();
      final report = await _fast(engine: engine).run();

      expect(report.passed, isTrue);
      expect(report.explicitPathPassed, isTrue);
      // The optional direct probe is off by default, so nothing has to be
      // attributed to a second flow.
      expect(report.directPathChecked, isFalse);
      expect(report.directPathPassed, isFalse);
      expect(report.translatedText, 'नमस्ते, आप कैसे हैं?');

      // The exact fixed sentence, English → Hindi, nothing else.
      expect(engine.translateCalls.first, (
        text: TranslationSelfTest.sampleText,
        source: 'en',
        target: 'hi',
      ));
      expect(TranslationSelfTest.sampleText, 'Hello, how are you?');

      // No downloads were needed because both models were present.
      expect(engine.downloadCalls, isEmpty);
      expect(report.toPlainText(), contains('standalone: PASS'));
      expect(
        report.toPlainText(),
        contains(
          'direct (plugin-provisioned) '
          'translate: not run',
        ),
      );
    },
  );

  test('reports every native operation as its own step, in order', () async {
    final report = await _fast(engine: _FakeEngine()).run();

    expect(report.steps.map((s) => s.name).toList(), <String>[
      'environment',
      'isModelDownloaded(en)',
      'downloadModel(en)',
      'isModelDownloaded(hi)',
      'downloadModel(hi)',
      'create OnDeviceTranslator en→hi',
      'translateText() chars=19 en→hi',
      'close()',
    ]);
    // Present models are recorded as a skip with a reason, not silently omitted.
    final skipped = report.steps.where(
      (s) => s.status == SelfTestStatus.skipped,
    );
    expect(skipped, hasLength(2));
    expect(skipped.first.detail, contains('already on device'));
  });

  test('downloads a missing model before translating', () async {
    final engine = _FakeEngine(models: const <String>{});
    final report = await _fast(engine: engine).run();

    expect(report.passed, isTrue);
    expect(engine.downloadCalls, ['en', 'hi']);
    final download = report.steps.firstWhere(
      (s) => s.name == 'downloadModel(hi)',
    );
    expect(download.status, SelfTestStatus.passed);
    expect(download.detail, 'downloaded');
  });

  test('reports the EXACT native error, not a generic sentence', () async {
    final report = await _fast(engine: _FakeEngine(failTranslate: true)).run();

    expect(report.passed, isFalse);
    final failure = report.firstFailure!;
    expect(failure.name, 'translateText() chars=19 en→hi');
    expect(failure.detail, contains('Error building translator'));
    expect(
      failure.detail,
      contains('Either source or target models not downloaded'),
    );
    expect(report.toPlainText(), contains('standalone: FAIL'));

    // The headline names the step and the reason.
    expect(report.failureHeadline, contains('FAILED'));
    expect(report.failureHeadline, contains('Step: translateText()'));
    expect(report.failureHeadline, contains('Reason: PlatformException'));
  });

  test('a failed download stops the run and marks the rest skipped', () async {
    final report = await _fast(
      engine: _FakeEngine(models: const <String>{}, failDownload: true),
    ).run();

    expect(report.explicitPathPassed, isFalse);
    expect(report.firstFailure!.name, 'downloadModel(en)');
    expect(report.firstFailure!.detail, contains("couldn't prepare Hindi"));

    // Nothing after the failure was attempted, and that is stated explicitly.
    final skipped = report.steps
        .where((s) => s.status == SelfTestStatus.skipped)
        .toList();
    expect(skipped.map((s) => s.name), contains('downloadModel(hi)'));
    expect(skipped.every((s) => s.detail!.contains('not attempted')), isTrue);
  });

  test(
    'a HANGING native call is reported as a TIMEOUT naming that step',
    () async {
      // A Completer that never completes is exactly what the plugin does when a
      // Play Services Task never finishes.
      final report = await _fast(
        engine: _HangingEngine(),
        check: const Duration(milliseconds: 40),
      ).run();

      expect(report.passed, isFalse);
      final failure = report.firstFailure!;
      expect(failure.name, 'isModelDownloaded(en)');
      expect(failure.status, SelfTestStatus.timeout);
      expect(failure.detail, contains('Timeout after 40 ms'));
      expect(failure.detail, contains('never returned'));
      expect(
        report.failureHeadline,
        'FAILED\n'
        'Step: isModelDownloaded(en)\n'
        'Reason: Timeout after 40 ms (the native call never returned)',
      );
    },
  );

  test(
    'a hanging translateText is attributed to the translateText stage',
    () async {
      // The REAL engine against a native channel that accepts the call and then
      // never answers it — precisely what `downloadModelIfNeeded()` does when a
      // Play Services Task never completes. The engine's per-stage budget must
      // name the exact stage rather than letting the whole call hang.
      const channel = MethodChannel('google_mlkit_on_device_translator');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            if (call.method == 'nlp#startLanguageTranslator') {
              return Completer<Object?>().future;
            }
            return null;
          });
      addTearDown(() {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null);
      });

      final engine = MlKitTranslationEngine(
        modelManager: _PresentModelManager(),
      );
      final report = await _fast(
        engine: engine,
        translate: const Duration(seconds: 3),
      ).run();

      expect(report.passed, isFalse);
      final failure = report.firstFailure!;
      expect(failure.name, startsWith('translateText()'));
      expect(failure.status, SelfTestStatus.timeout);
      expect(failure.detail, contains('Timeout after 3 seconds'));

      // The stages either side of the hang are still reported.
      final names = report.steps.map((s) => s.name).toList();
      expect(
        names.any((n) => n.startsWith('create OnDeviceTranslator')),
        isTrue,
      );
      expect(names.any((n) => n.startsWith('translateText()')), isTrue);
      expect(names, contains('close()'));
    },
  );

  test('the direct path can be run as a separate probe', () async {
    final report = await _fast(
      engine: _FakeEngine(),
    ).run(includeDirectPath: true);

    expect(report.directPathChecked, isTrue);
    expect(report.directPathPassed, isTrue);
    expect(
      report.steps.map((s) => s.name),
      contains('translateText() (direct, plugin-provisioned)'),
    );
  });

  test('logs BEFORE and AFTER around every awaited native operation', () async {
    final lines = <String>[];
    final original = debugPrint;
    debugPrint = (String? message, {int? wrapWidth}) {
      if (message != null) lines.add(message);
    };
    addTearDown(() => debugPrint = original);

    await _fast(engine: _FakeEngine(models: const <String>{})).run();

    for (final step in <String>[
      'isModelDownloaded(en)',
      'downloadModel(en)',
      'isModelDownloaded(hi)',
      'downloadModel(hi)',
    ]) {
      expect(
        lines.any((l) => l.contains('[SELFTEST] $step: BEFORE')),
        isTrue,
        reason: 'missing BEFORE log for $step',
      );
      expect(
        lines.any((l) => l.contains('[SELFTEST] $step: AFTER')),
        isTrue,
        reason: 'missing AFTER log for $step',
      );
    }
    // Everything carries the single grep-able tag.
    expect(
      lines.every((l) => l.startsWith('PDF_UTILITY_TRANSLATION | ')),
      isTrue,
    );
  });

  test('records environment facts', () async {
    final report = await _fast(engine: _FakeEngine()).run();

    final environment = report.steps.firstWhere((s) => s.name == 'environment');
    expect(environment.status, SelfTestStatus.passed);
    expect(environment.detail, contains('Test Device'));
    expect(environment.detail, contains('googlePlayServicesVersion'));
  });

  test('the whole diagnostic is bounded by the sum of its step budgets', () {
    final selfTest = TranslationSelfTest(
      engine: _FakeEngine(),
      diagnostics: const _FakeDiagnostics(),
      checkTimeout: const Duration(seconds: 20),
      downloadTimeout: const Duration(seconds: 120),
      translateTimeout: const Duration(seconds: 30),
      environmentTimeout: const Duration(seconds: 10),
    );

    // 10 + 20 + 120 + 20 + 120 + 3×30 = 380 s. Bounded is the point: no single
    // native call can hold the screen hostage.
    expect(selfTest.worstCaseDuration, const Duration(seconds: 380));
    expect(_fast().worstCaseDuration, lessThan(const Duration(minutes: 1)));
  });

  group('screen', () {
    testWidgets('shows the standalone verdict', (tester) async {
      await tester.pumpWidget(
        MaterialApp(home: TranslationDiagnosticsScreen(selfTest: _fast())),
      );
      await tester.pumpAndSettle();

      expect(find.text('ML Kit standalone translation: PASS'), findsOneWidget);
      expect(find.textContaining('Hindi: नमस्ते'), findsOneWidget);
    });

    testWidgets('shows the exact failing step and reason when it fails', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          home: TranslationDiagnosticsScreen(
            selfTest: _fast(engine: _FakeEngine(failTranslate: true)),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('ML Kit standalone translation: FAIL'), findsOneWidget);
      expect(find.textContaining('Step: translateText()'), findsOneWidget);
      expect(find.textContaining('Reason: PlatformException'), findsOneWidget);
      expect(find.textContaining('Error building translator'), findsWidgets);
    });

    testWidgets('names the in-flight operation instead of spinning blindly', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          home: TranslationDiagnosticsScreen(
            selfTest: _fast(
              engine: _HangingEngine(),
              check: const Duration(seconds: 5),
            ),
          ),
        ),
      );

      // While the hanging call is in flight the screen says exactly what it is
      // waiting on, and for how long.
      await tester.pump(const Duration(milliseconds: 600));
      expect(find.text('Running…'), findsOneWidget);
      expect(find.text('isModelDownloaded(en)'), findsWidgets);
      expect(find.textContaining('checking…'), findsOneWidget);

      // ...and the budget eventually ends it, with the verdict on screen.
      await tester.pumpAndSettle(const Duration(seconds: 6));
      expect(find.text('ML Kit standalone translation: FAIL'), findsOneWidget);
      expect(find.textContaining('Timeout after 5 seconds'), findsWidgets);
      // Never left on the disabled "Running…" button.
      expect(find.text('Run again'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsNothing);
    });

    testWidgets('an error thrown outside any step still ends the run', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          home: TranslationDiagnosticsScreen(selfTest: _ThrowingSelfTest()),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('The diagnostic itself failed'), findsOneWidget);
      expect(find.textContaining('boom outside any step'), findsOneWidget);
      expect(find.text('Run again'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsNothing);
    });
  });
}
