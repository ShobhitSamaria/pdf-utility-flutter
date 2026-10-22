import 'package:flutter_test/flutter_test.dart';
import 'package:pdf_utility_flutter/ocr/domain/ocr_rect.dart';
import 'package:pdf_utility_flutter/translation/data/local_mlkit_translation_service.dart';
import 'package:pdf_utility_flutter/translation/domain/translated_region.dart';
import 'package:pdf_utility_flutter/translation/domain/translation_exception.dart';
import 'package:pdf_utility_flutter/translation/domain/translation_language.dart';
import 'package:pdf_utility_flutter/translation/domain/translation_model_state.dart';
import 'package:pdf_utility_flutter/translation/domain/translation_request.dart';

import 'support/translation_fakes.dart';

/// An engine that cannot provision the target model, so the failure arrives
/// from the translate call (which is now the provisioning point).
class _ModelUnavailableEngine extends FakeTranslationEngine {
  @override
  Future<String> translate({
    required String text,
    required TranslationLanguage source,
    required TranslationLanguage target,
  }) async => throw const TranslationException(
    TranslationErrorKind.modelUnavailable,
    "We couldn't prepare Hindi on this device. "
    'Please check your connection and try again.',
  );
}

/// An engine that answers with an empty string, which is what a confused
/// on-device model can do on odd input.
class _EmptyOutputEngine extends FakeTranslationEngine {
  @override
  Future<String> translate({
    required String text,
    required TranslationLanguage source,
    required TranslationLanguage target,
  }) async => '';
}

void main() {
  late FakeTranslationEngine engine;
  late FakeSourceLanguageDetector detector;

  LocalMlKitTranslationService build({
    Set<String>? availableModels,
    TranslationLanguage? detected,
    bool throwOnDetect = false,
    bool failOnDownload = false,
    bool failOnTranslate = false,
    bool throwOnModelCheck = false,
    List<TranslationLanguage>? targetLanguages,
    List<TranslationLanguage>? sourceLanguages,
    TranslationLanguage? defaultTargetLanguage,
  }) {
    engine = FakeTranslationEngine(
      availableModels: availableModels ?? const {'en', 'hi'},
      failOnDownload: failOnDownload,
      failOnTranslate: failOnTranslate,
      throwOnModelCheck: throwOnModelCheck,
    );
    detector = FakeSourceLanguageDetector(
      detected: detected ?? TranslationLanguages.english,
      throwOnDetect: throwOnDetect,
    );
    return LocalMlKitTranslationService(
      engine: engine,
      detector: detector,
      targetLanguages: targetLanguages,
      sourceLanguages: sourceLanguages,
      defaultTargetLanguage: defaultTargetLanguage,
    );
  }

  group('configuration', () {
    test('defaults to auto-detect source and Hindi target', () {
      final service = build();
      expect(service.defaultTargetLanguage, TranslationLanguages.hindi);
      expect(service.sourceLanguages.first, TranslationLanguages.auto);
      expect(service.targetLanguages, contains(TranslationLanguages.hindi));
      expect(service.engineName, 'Fake engine');
    });

    test('can be limited to a subset of languages', () {
      final service = build(
        targetLanguages: const [TranslationLanguages.tamil],
        defaultTargetLanguage: TranslationLanguages.tamil,
      );
      expect(service.defaultTargetLanguage, TranslationLanguages.tamil);
      expect(service.targetLanguages, [TranslationLanguages.tamil]);
      expect(service.sourceLanguages.first.isAuto, isTrue);
    });
  });

  group('selected text -> Hindi', () {
    test('detects the source, then translates locally', () async {
      final service = build();
      final phases = <TranslationPhase>[];

      final result = await service.translate(
        TranslationRequest.selection(text: 'Hello world'),
        onProgress: (progress) => phases.add(progress.phase),
      );

      expect(detector.detectionRequests, ['Hello world']);
      expect(engine.translateRequests.single, (
        text: 'Hello world',
        source: 'en',
        target: 'hi',
      ));
      expect(result.sourceLanguage, TranslationLanguages.english);
      expect(result.targetLanguage, TranslationLanguages.hindi);
      expect(result.sourceWasAutoDetected, isTrue);
      expect(result.alreadyInTargetLanguage, isFalse);
      expect(result.translatedText, 'अनुवाद: Hello world');
      expect(result.scope, TranslationScope.selection);
      expect(result.elapsed, isNotNull);
      // Both models are already on the device here, so there is no "preparing"
      // tick — just detection then translation.
      expect(phases, [
        TranslationPhase.detectingLanguage,
        TranslationPhase.translating,
      ]);
    });

    test(
      'does not provision when both models are already on the device',
      () async {
        final service = build(availableModels: const {'en', 'hi'});
        await service.translate(TranslationRequest.selection(text: 'Hello'));
        expect(engine.downloadRequests, isEmpty);
      },
    );

    test('normalises the text before it reaches the engine', () async {
      final service = build();
      await service.translate(
        TranslationRequest.selection(text: '  Hello   world \n\n\n\n Again '),
      );
      expect(engine.translateRequests.single.text, 'Hello world\n\nAgain');
    });

    test(
      'skips the engine when the text already is in the target language',
      () async {
        final service = build(detected: TranslationLanguages.hindi);
        final result = await service.translate(
          TranslationRequest.selection(text: 'नमस्ते दुनिया'),
        );

        expect(result.alreadyInTargetLanguage, isTrue);
        expect(result.translatedText, 'नमस्ते दुनिया');
        expect(result.sourceLanguage, TranslationLanguages.hindi);
        expect(result.sourceWasAutoDetected, isTrue);
        expect(engine.translateRequests, isEmpty);
        expect(engine.downloadRequests, isEmpty);
      },
    );

    test('uses an explicit source without running detection', () async {
      final service = build();
      final result = await service.translate(
        TranslationRequest.selection(
          text: 'Bonjour',
          source: TranslationLanguages.french,
        ),
      );
      expect(detector.detectionRequests, isEmpty);
      expect(engine.translateRequests.single, (
        text: 'Bonjour',
        source: 'fr',
        target: 'hi',
      ));
      expect(result.sourceWasAutoDetected, isFalse);
    });
  });

  group('model lifecycle', () {
    test('checks and downloads BOTH models, then translates', () async {
      final service = build(availableModels: const <String>{});
      final phases = <TranslationPhase>[];
      final preparedFor = <String>[];

      final result = await service.translate(
        TranslationRequest.selection(text: 'Hello'),
        onProgress: (progress) {
          phases.add(progress.phase);
          if (progress.phase == TranslationPhase.preparingModel) {
            preparedFor.add(progress.language!.code);
          }
        },
      );

      // ML Kit requires both the source and target models; each missing one is
      // downloaded before translating.
      expect(engine.downloadRequests, ['en', 'hi']);
      expect(preparedFor, ['en', 'hi']);
      expect(phases, [
        TranslationPhase.detectingLanguage,
        TranslationPhase.preparingModel,
        TranslationPhase.preparingModel,
        TranslationPhase.translating,
      ]);
      expect(result.translatedText, 'अनुवाद: Hello');
    });

    test(
      'does not announce preparing for a model already on the device',
      () async {
        final service = build(availableModels: const {'en', 'hi'});
        var preparations = 0;
        await service.translate(
          TranslationRequest.selection(text: 'Hello'),
          onProgress: (progress) {
            if (progress.phase == TranslationPhase.preparingModel) {
              preparations++;
            }
          },
        );
        expect(preparations, 0);
        expect(engine.downloadRequests, isEmpty);
      },
    );

    test('preparation happens only the first time a pair is used', () async {
      final service = build(availableModels: const <String>{});
      var preparations = 0;
      var translating = 0;
      void listen(TranslationProgress progress) {
        if (progress.phase == TranslationPhase.preparingModel) preparations++;
        if (progress.phase == TranslationPhase.translating) translating++;
      }

      await service.translate(
        TranslationRequest.selection(text: 'One'),
        onProgress: listen,
      );
      expect(preparations, 2);
      expect(translating, 1);
      expect(engine.downloadRequests, ['en', 'hi']);

      engine.downloadRequests.clear();
      await service.translate(
        TranslationRequest.selection(text: 'Two'),
        onProgress: listen,
      );
      // Models are on the device now: no "preparing" line, just "translating".
      expect(preparations, 2);
      expect(translating, 2);
      expect(engine.downloadRequests, isEmpty);
    });

    test(
      'a translate failure keeps the already-downloaded models prepared',
      () async {
        final service = build(
          availableModels: const <String>{},
          failOnTranslate: true,
        );
        await expectLater(
          service.translate(TranslationRequest.selection(text: 'One')),
          throwsA(isA<TranslationException>()),
        );
        expect(engine.downloadRequests, ['en', 'hi']);

        // The models themselves are present, so a retry must not download them
        // again — it just retries the translation.
        engine.failOnTranslate = false;
        engine.downloadRequests.clear();
        final phases = <TranslationPhase>[];
        await service.translate(
          TranslationRequest.selection(text: 'Two'),
          onProgress: (progress) => phases.add(progress.phase),
        );
        expect(engine.downloadRequests, isEmpty);
        expect(phases, isNot(contains(TranslationPhase.preparingModel)));
      },
    );

    test('a failed download does not abort the translation attempt', () async {
      // The engine's translate call still runs downloadModelIfNeeded natively,
      // so a preflight download failure must not stop us trying.
      engine = FakeTranslationEngine(
        availableModels: const <String>{},
        failOnDownload: true,
      );
      detector = FakeSourceLanguageDetector();
      final service = LocalMlKitTranslationService(
        engine: engine,
        detector: detector,
      );

      final result = await service.translate(
        TranslationRequest.selection(text: 'Hello'),
      );
      expect(engine.translateRequests.length, 1);
      expect(result.translatedText, 'अनुवाद: Hello');
    });

    test('reports availability per language', () async {
      final service = build(
        availableModels: const {'en'},
        targetLanguages: const [
          TranslationLanguages.english,
          TranslationLanguages.hindi,
        ],
      );

      expect(
        (await service.modelState(TranslationLanguages.english)).status,
        TranslationModelStatus.available,
      );
      expect(
        (await service.modelState(TranslationLanguages.hindi)).status,
        TranslationModelStatus.notAvailable,
      );
      expect(
        (await service.modelState(TranslationLanguages.auto)).status,
        TranslationModelStatus.unsupported,
      );
      // Not offered by this service instance.
      expect(
        (await service.modelState(TranslationLanguages.french)).status,
        TranslationModelStatus.unsupported,
      );
    });

    test('surfaces a failed availability check instead of throwing', () async {
      final service = build(throwOnModelCheck: true);
      final state = await service.modelState(TranslationLanguages.hindi);
      expect(state.status, TranslationModelStatus.failed);
      expect(state.isFailed, isTrue);
    });

    test(
      'surfaces an engine provisioning failure as a friendly retryable error',
      () async {
        // Provisioning now happens inside the engine's translate call, so a
        // failure to fetch a model arrives from there.
        engine = _ModelUnavailableEngine();
        detector = FakeSourceLanguageDetector();
        final service = LocalMlKitTranslationService(
          engine: engine,
          detector: detector,
        );

        await expectLater(
          service.translate(TranslationRequest.selection(text: 'Hello')),
          throwsA(
            isA<TranslationException>()
                .having(
                  (e) => e.kind,
                  'kind',
                  TranslationErrorKind.modelUnavailable,
                )
                .having((e) => e.userMessage, 'message', contains('Hindi'))
                .having((e) => e.isRetryable, 'retryable', isTrue),
          ),
        );
      },
    );
  });

  group('whole page', () {
    test('translates the aggregated page text and keeps line breaks', () async {
      const pageText =
          'Terms and conditions\n\n'
          '1. The agreement starts today.\n'
          '2. Please read carefully.';
      final service = build();

      final result = await service.translate(
        TranslationRequest.wholePage(pageText: pageText),
      );

      expect(result.scope, TranslationScope.wholePage);
      expect(engine.translateRequests.single.text, pageText);
      expect(result.translatedText, 'अनुवाद: $pageText');
      expect(result.alreadyInTargetLanguage, isFalse);
    });
  });

  group('graceful failures', () {
    test('rejects empty input', () async {
      final service = build();
      await expectLater(
        service.translate(TranslationRequest.selection(text: '   \n ')),
        throwsA(
          isA<TranslationException>().having(
            (e) => e.kind,
            'kind',
            TranslationErrorKind.emptyInput,
          ),
        ),
      );
      expect(engine.translateRequests, isEmpty);
    });

    test('rejects an auto-detect target', () async {
      final service = build();
      await expectLater(
        service.translate(
          TranslationRequest(
            text: 'Hello',
            source: TranslationLanguages.auto,
            target: TranslationLanguages.auto,
          ),
        ),
        throwsA(
          isA<TranslationException>().having(
            (e) => e.kind,
            'kind',
            TranslationErrorKind.unsupportedPair,
          ),
        ),
      );
    });

    test('reports a target the app does not offer', () async {
      final service = build(
        targetLanguages: const [TranslationLanguages.hindi],
      );
      await expectLater(
        service.translate(
          TranslationRequest.selection(
            text: 'Hello',
            target: TranslationLanguages.french,
          ),
        ),
        throwsA(
          isA<TranslationException>()
              .having(
                (e) => e.kind,
                'kind',
                TranslationErrorKind.unsupportedPair,
              )
              .having((e) => e.userMessage, 'message', contains('French'))
              .having((e) => e.isRetryable, 'retryable', isFalse),
        ),
      );
    });

    test('reports a source the app does not offer', () async {
      final service = build(
        sourceLanguages: const [
          TranslationLanguages.auto,
          TranslationLanguages.english,
        ],
      );
      await expectLater(
        service.translate(
          TranslationRequest.selection(
            text: 'Bonjour',
            source: TranslationLanguages.french,
          ),
        ),
        throwsA(
          isA<TranslationException>().having(
            (e) => e.kind,
            'kind',
            TranslationErrorKind.unsupportedLanguage,
          ),
        ),
      );
    });

    test('reports an undetectable language without translating', () async {
      // Built directly: `build()` treats a null language as "not specified".
      engine = FakeTranslationEngine();
      detector = FakeSourceLanguageDetector(detected: null);
      final service = LocalMlKitTranslationService(
        engine: engine,
        detector: detector,
      );
      await expectLater(
        service.translate(TranslationRequest.selection(text: '?????((')),
        throwsA(
          isA<TranslationException>()
              .having(
                (e) => e.kind,
                'kind',
                TranslationErrorKind.detectionFailed,
              )
              .having(
                (e) => e.userMessage,
                'message',
                contains('which language'),
              )
              .having((e) => e.isRetryable, 'retryable', isTrue),
        ),
      );
      expect(engine.translateRequests, isEmpty);
    });

    test('treats a detector crash as a detection failure', () async {
      final service = build(throwOnDetect: true);
      await expectLater(
        service.translate(TranslationRequest.selection(text: 'Hello')),
        throwsA(
          isA<TranslationException>().having(
            (e) => e.kind,
            'kind',
            TranslationErrorKind.detectionFailed,
          ),
        ),
      );
    });

    test('propagates an engine failure as a retryable error', () async {
      final service = build(failOnTranslate: true);
      await expectLater(
        service.translate(TranslationRequest.selection(text: 'Hello')),
        throwsA(
          isA<TranslationException>()
              .having((e) => e.kind, 'kind', TranslationErrorKind.engineFailure)
              .having((e) => e.isRetryable, 'retryable', isTrue),
        ),
      );
    });
  });

  group('dispose', () {
    test('releases both collaborators', () async {
      final service = build();
      await service.dispose();
      expect(engine.disposeCount, 1);
      expect(detector.disposeCount, 1);
    });
  });

  // The on-image overlay path: several OCR regions in, the same number of
  // translated regions out, each keeping its own rectangle.
  group('translateRegions', () {
    TranslationUnit unit(int id, String text) => TranslationUnit(
      id: id,
      text: text,
      bounds: OcrRect.fromLTRB(0, id * 20, 100, id * 20 + 20),
      kind: TranslatedRegionKind.line,
    );

    test(
      'maps every unit back to its own region, ids and order preserved',
      () async {
        final service = build();
        final units = [unit(0, 'Hello'), unit(1, 'World'), unit(2, 'Again')];

        final overlay = await service.translateRegions(
          units,
          target: TranslationLanguages.hindi,
        );

        expect(overlay.regions.map((r) => r.id).toList(), [0, 1, 2]);
        expect(overlay.regions.map((r) => r.translatedText).toList(), [
          'अनुवाद: Hello',
          'अनुवाद: World',
          'अनुवाद: Again',
        ]);
        expect(overlay.regions.map((r) => r.sourceText).toList(), [
          'Hello',
          'World',
          'Again',
        ]);
        // Geometry survives verbatim, so the overlay can draw in place.
        expect(overlay.regions[1].bounds, units[1].bounds);
        expect(overlay.regions[1].kind, TranslatedRegionKind.line);
        expect(overlay.targetLanguage, TranslationLanguages.hindi);
        expect(overlay.sourceLanguage, TranslationLanguages.english);
        expect(overlay.sourceWasAutoDetected, isTrue);
        expect(overlay.hasRenderableRegions, isTrue);
        expect(overlay.elapsed, isNotNull);
      },
    );

    test('translates each region on its own engine call', () async {
      final service = build();
      await service.translateRegions([
        unit(0, 'Line one'),
        unit(1, 'Line two'),
      ], target: TranslationLanguages.hindi);

      expect(engine.translateRequests.length, 2);
      expect(engine.translateRequests.map((r) => r.text).toList(), [
        'Line one',
        'Line two',
      ]);
      expect(engine.translateRequests.every((r) => r.target == 'hi'), isTrue);
    });

    test(
      'throws instead of dropping a block whose translation came back blank',
      () async {
        // An empty answer for real text would become an empty region: invisible on
        // the photo and absent from the full text. Failing loudly is the only
        // honest option — a silently lost sentence is worse than an error.
        final service = LocalMlKitTranslationService(
          engine: _EmptyOutputEngine(),
          detector: FakeSourceLanguageDetector(
            detected: TranslationLanguages.english,
          ),
        );

        await expectLater(
          service.translateRegions([
            unit(0, 'A sentence with letters'),
          ], target: TranslationLanguages.hindi),
          throwsA(
            isA<TranslationException>().having(
              (error) => error.userMessage,
              'userMessage',
              contains('could not be translated'),
            ),
          ),
        );
      },
    );

    test('keeps a punctuation-only block instead of translating it', () async {
      // "।।" has nothing to translate, and that is not a loss: the block keeps
      // its place and its original text so the page stays complete.
      final service = LocalMlKitTranslationService(
        engine: _EmptyOutputEngine(),
        detector: FakeSourceLanguageDetector(
          detected: TranslationLanguages.english,
        ),
      );

      final overlay = await service.translateRegions([
        unit(0, '।।'),
      ], target: TranslationLanguages.hindi);

      expect(overlay.regions.single.id, 0);
      expect(overlay.regions.single.sourceText, '।।');
      expect(overlay.regions.single.translatedText, '।।');
    });

    test('detects the language once for the whole batch', () async {
      final service = build();
      await service.translateRegions([
        unit(0, 'Hello'),
        unit(1, 'World'),
      ], target: TranslationLanguages.hindi);

      expect(detector.detectionRequests.length, 1);
      expect(detector.detectionRequests.single, 'Hello\nWorld');
    });

    test('announces each model once for the whole batch', () async {
      final service = build(availableModels: const <String>{});
      final preparedFor = <String>[];
      await service.translateRegions(
        [unit(0, 'One'), unit(1, 'Two'), unit(2, 'Three')],
        target: TranslationLanguages.hindi,
        onProgress: (progress) {
          if (progress.phase == TranslationPhase.preparingModel) {
            preparedFor.add(progress.language!.code);
          }
        },
      );

      expect(preparedFor, ['en', 'hi']);
      expect(engine.downloadRequests, ['en', 'hi']);
    });

    test('reports per-region progress with a counter', () async {
      final service = build();
      final progress = <TranslationProgress>[];

      await service.translateRegions(
        [unit(0, 'One'), unit(1, 'Two')],
        target: TranslationLanguages.hindi,
        onProgress: progress.add,
      );

      final counted = progress
          .where((p) => p.completed != null)
          .toList(growable: false);
      expect(counted.map((p) => p.completed).toList(), [1, 2]);
      expect(counted.every((p) => p.total == 2), isTrue);
      expect(
        counted.every((p) => p.phase == TranslationPhase.translating),
        isTrue,
      );
      // The first tick announces the batch, without a counter.
      expect(progress.first.phase, TranslationPhase.detectingLanguage);
      expect(progress.first.completed, isNull);
    });

    test('skips blank regions but keeps the rest', () async {
      final service = build();
      final overlay = await service.translateRegions([
        unit(0, '   '),
        unit(1, 'Hello'),
      ], target: TranslationLanguages.hindi);

      expect(overlay.regions.length, 1);
      expect(overlay.regions.single.id, 1);
      expect(engine.translateRequests.single.text, 'Hello');
    });

    test('rejects a batch with nothing translatable', () async {
      final service = build();
      await expectLater(
        service.translateRegions([
          unit(0, '   '),
          unit(1, ''),
        ], target: TranslationLanguages.hindi),
        throwsA(
          isA<TranslationException>().having(
            (e) => e.kind,
            'kind',
            TranslationErrorKind.emptyInput,
          ),
        ),
      );
      expect(engine.translateRequests, isEmpty);
    });

    test(
      'echoes every region when the text is already the target language',
      () async {
        final service = build(detected: TranslationLanguages.hindi);

        final overlay = await service.translateRegions([
          unit(0, 'नमस्ते'),
          unit(1, 'दुनिया'),
        ], target: TranslationLanguages.hindi);

        expect(overlay.alreadyInTargetLanguage, isTrue);
        expect(overlay.regions.map((r) => r.translatedText).toList(), [
          'नमस्ते',
          'दुनिया',
        ]);
        expect(engine.translateRequests, isEmpty);
        expect(engine.downloadRequests, isEmpty);
      },
    );

    test('honours an explicit source language without detecting', () async {
      final service = build();
      await service.translateRegions(
        [unit(0, 'Bonjour')],
        source: TranslationLanguages.french,
        target: TranslationLanguages.hindi,
      );

      expect(detector.detectionRequests, isEmpty);
      expect(engine.translateRequests.single.source, 'fr');
    });

    test('rejects a target the app does not offer', () async {
      final service = build(
        targetLanguages: const [TranslationLanguages.hindi],
      );
      await expectLater(
        service.translateRegions([
          unit(0, 'Hello'),
        ], target: TranslationLanguages.french),
        throwsA(
          isA<TranslationException>().having(
            (e) => e.kind,
            'kind',
            TranslationErrorKind.unsupportedPair,
          ),
        ),
      );
    });

    test('reports a detection failure for the whole batch', () async {
      engine = FakeTranslationEngine();
      detector = FakeSourceLanguageDetector(detected: null);
      final service = LocalMlKitTranslationService(
        engine: engine,
        detector: detector,
      );

      await expectLater(
        service.translateRegions([
          unit(0, '????'),
          unit(1, '!!!!'),
        ], target: TranslationLanguages.hindi),
        throwsA(
          isA<TranslationException>().having(
            (e) => e.kind,
            'kind',
            TranslationErrorKind.detectionFailed,
          ),
        ),
      );
      expect(engine.translateRequests, isEmpty);
    });

    test(
      'keeps region order even when the input arrives out of order',
      () async {
        final service = build();
        final overlay = await service.translateRegions([
          unit(2, 'Third'),
          unit(0, 'First'),
          unit(1, 'Second'),
        ], target: TranslationLanguages.hindi);

        // The service preserves the order it was given (the region builder is
        // what sorts into reading order), and ids travel with the text.
        expect(overlay.regions.map((r) => r.id).toList(), [2, 0, 1]);
        expect(overlay.regions.map((r) => r.sourceText).toList(), [
          'Third',
          'First',
          'Second',
        ]);
      },
    );
  });

  group('detection', () {
    test(
      'detectSource asks the detector once and returns its answer',
      () async {
        final service = build(detected: TranslationLanguages.hindi);
        expect(
          await service.detectSource('शहर में भारी बारिश'),
          TranslationLanguages.hindi,
        );
        expect(detector.detectionRequests, hasLength(1));
      },
    );

    test(
      'detectSource answers null for blank text without detection',
      () async {
        final service = build();
        expect(await service.detectSource('   '), isNull);
        expect(detector.detectionRequests, isEmpty);
      },
    );

    test('detectSource never throws when the detector fails', () async {
      final service = build(throwOnDetect: true);
      expect(await service.detectSource('Some text'), isNull);
      expect(detector.detectionRequests, hasLength(1));
    });

    test('an explicit source language never runs auto-detection', () async {
      final service = build(detected: TranslationLanguages.hindi);
      final result = await service.translate(
        TranslationRequest.wholePage(
          pageText: 'Some text',
          source: TranslationLanguages.english,
          target: TranslationLanguages.hindi,
        ),
      );
      expect(detector.detectionRequests, isEmpty);
      expect(result.sourceLanguage, TranslationLanguages.english);
      expect(engine.translateRequests.single.source, 'en');
    });

    test('an automatic source detects exactly once for a batch', () async {
      final service = build(detected: TranslationLanguages.hindi);
      await service.translateRegions([
        TranslationUnit(
          id: 0,
          text: 'एक',
          bounds: OcrRect.fromLTRB(0, 0, 10, 10),
          kind: TranslatedRegionKind.line,
        ),
        TranslationUnit(
          id: 1,
          text: 'दो',
          bounds: OcrRect.fromLTRB(0, 20, 10, 30),
          kind: TranslatedRegionKind.line,
        ),
      ], target: TranslationLanguages.english);
      expect(detector.detectionRequests, hasLength(1));
    });

    test(
      'a model that could not download is a model error, not a crash',
      () async {
        final service = build(
          availableModels: const {'en'},
          failOnDownload: true,
          failOnTranslate: true,
        );
        await expectLater(
          service.translate(
            TranslationRequest.wholePage(
              pageText: 'Hello',
              source: TranslationLanguages.english,
              target: TranslationLanguages.hindi,
            ),
          ),
          throwsA(
            isA<TranslationException>()
                .having(
                  (e) => e.kind,
                  'kind',
                  TranslationErrorKind.modelUnavailable,
                )
                .having(
                  (e) => e.userMessage,
                  'message',
                  contains('offline language model'),
                ),
          ),
        );
      },
    );

    test('a download failure alone does not block a translation', () async {
      final service = build(
        availableModels: const {'en'},
        failOnDownload: true,
      );
      final result = await service.translate(
        TranslationRequest.wholePage(
          pageText: 'Hello',
          source: TranslationLanguages.english,
          target: TranslationLanguages.hindi,
        ),
      );
      expect(result.translatedText, contains('Hello'));
    });
  });
}
