import 'package:flutter_test/flutter_test.dart';
import 'package:pdf_utility_flutter/ocr/domain/ocr_rect.dart';
import 'package:pdf_utility_flutter/translation/domain/translated_region.dart';
import 'package:pdf_utility_flutter/translation/domain/translation_exception.dart';
import 'package:pdf_utility_flutter/translation/domain/translation_language.dart';
import 'package:pdf_utility_flutter/translation/domain/translation_model_state.dart';
import 'package:pdf_utility_flutter/translation/domain/translation_request.dart';
import 'package:pdf_utility_flutter/translation/domain/translation_result.dart';
import 'package:pdf_utility_flutter/translation/presentation/translation_controller.dart';
import 'package:pdf_utility_flutter/translation/presentation/translation_ui_state.dart';

import 'support/translation_fakes.dart';

/// A service that blows up with something that is *not* a TranslationException,
/// to prove the controller still shows a friendly message.
class _ExplodingService extends FakeTranslationService {
  @override
  Future<TranslationResult> translate(
    TranslationRequest request, {
    void Function(TranslationProgress progress)? onProgress,
  }) async => throw StateError('platform channel exploded');
}

void main() {
  late FakeTranslationService service;

  TranslationController makeController([FakeTranslationService? fake]) {
    service = fake ?? FakeTranslationService();
    final controller = TranslationController(service: service);
    addTearDown(controller.dispose);
    return controller;
  }

  group('initial state', () {
    test('starts idle with no request', () {
      final controller = makeController();
      expect(controller.state, isA<TranslationIdle>());
      expect(controller.lastRequest, isNull);
    });

    test('defaults to auto-detect source and Hindi target', () {
      final controller = makeController();
      expect(controller.source, TranslationLanguages.auto);
      expect(controller.source.isAuto, isTrue);
      expect(controller.target, TranslationLanguages.hindi);
    });

    test('exposes the language options from the service', () {
      final controller = makeController();
      expect(controller.sourceOptions.first.isAuto, isTrue);
      expect(controller.targetOptions, contains(TranslationLanguages.hindi));
    });
  });

  group('translating', () {
    test('moves to success and exposes the result', () async {
      final controller = makeController();

      await controller.translate(text: 'Hello');

      final state = controller.state;
      expect(state, isA<TranslationSuccess>());
      final result = (state as TranslationSuccess).result;
      expect(result.translatedText, 'अनुवाद: Hello');
      expect(result.targetLanguage, TranslationLanguages.hindi);
      expect(result.sourceLanguage, TranslationLanguages.english);
      expect(result.scope, TranslationScope.selection);
      expect(service.requests.single.text, 'Hello');
      expect(controller.lastRequest, service.requests.single);
    });

    test('passes the whole-page scope through', () async {
      final controller = makeController();
      await controller.translate(
        text: 'Line one\nLine two',
        scope: TranslationScope.wholePage,
      );
      expect(service.requests.single.scope, TranslationScope.wholePage);
      final result = (controller.state as TranslationSuccess).result;
      expect(result.scope, TranslationScope.wholePage);
    });

    test('surfaces every progress phase while it runs', () async {
      final controller = makeController(
        FakeTranslationService(
          delay: const Duration(milliseconds: 5),
          emittedPhases: const [
            TranslationPhase.detectingLanguage,
            TranslationPhase.preparingModel,
            TranslationPhase.translating,
          ],
        ),
      );
      final states = <TranslationUiState>[];
      controller.addListener(() => states.add(controller.state));

      final future = controller.translate(text: 'Hello');
      expect(controller.state, isA<TranslationInProgress>());
      await future;

      final phases = states
          .whereType<TranslationInProgress>()
          .map((state) => state.phase)
          .toList();
      expect(phases, [
        TranslationPhase.starting,
        TranslationPhase.detectingLanguage,
        TranslationPhase.preparingModel,
        TranslationPhase.translating,
      ]);
      expect(states.last, isA<TranslationSuccess>());
    });
  });

  group('failures', () {
    test('shows the user-safe message from the service', () async {
      final controller = makeController(
        FakeTranslationService(
          failure: const TranslationException(
            TranslationErrorKind.engineFailure,
            'Translation failed on this device. Please try again.',
          ),
        ),
      );

      await controller.translate(text: 'Hello');

      final state = controller.state;
      expect(state, isA<TranslationFailure>());
      expect(
        (state as TranslationFailure).message,
        'Translation failed on this device. Please try again.',
      );
      expect(state.retryable, isTrue);
    });

    test('marks unsupported pairs as not retryable', () async {
      final controller = makeController(
        FakeTranslationService(
          failure: const TranslationException(
            TranslationErrorKind.unsupportedPair,
            'Translation into French is not available yet.',
          ),
        ),
      );

      await controller.translate(text: 'Bonjour');

      final state = controller.state;
      expect(state, isA<TranslationFailure>());
      expect((state as TranslationFailure).retryable, isFalse);
    });

    test('never leaks an unexpected exception to the UI', () async {
      final controller = makeController(_ExplodingService());

      await controller.translate(text: 'Hello');

      final state = controller.state;
      expect(state, isA<TranslationFailure>());
      final message = (state as TranslationFailure).message;
      expect(message, contains('Something went wrong'));
      expect(message, isNot(contains('StateError')));
      expect(message, isNot(contains('exploded')));
    });

    test('retry re-runs the same request once the problem clears', () async {
      final controller = makeController(
        FakeTranslationService(
          failure: const TranslationException(
            TranslationErrorKind.modelUnavailable,
            'We could not prepare Hindi on this device.',
          ),
        ),
      );

      await controller.translate(text: 'Hello');
      expect(controller.state, isA<TranslationFailure>());

      service.failure = null;
      await controller.retry();

      expect(service.requests.length, 2);
      expect(service.requests.last.target, TranslationLanguages.hindi);
      expect(controller.state, isA<TranslationSuccess>());
    });

    test('retry without a previous request does nothing', () async {
      final controller = makeController();
      await controller.retry();
      expect(service.requests, isEmpty);
      expect(controller.state, isA<TranslationIdle>());
    });
  });

  group('language selection', () {
    test('changing the target clears a stale result', () async {
      final controller = makeController();
      await controller.translate(text: 'Hello');
      expect(controller.state, isA<TranslationSuccess>());

      controller.selectTarget(TranslationLanguages.tamil);

      expect(controller.target, TranslationLanguages.tamil);
      expect(controller.state, isA<TranslationIdle>());
      expect(controller.lastRequest, isNull);
    });

    test('the new target is used by the next translation', () async {
      final controller = makeController();
      controller.selectTarget(TranslationLanguages.tamil);
      await controller.translate(text: 'Hello');
      expect(service.requests.single.target, TranslationLanguages.tamil);
    });

    test('changing the source clears a stale result', () async {
      final controller = makeController();
      await controller.translate(text: 'Hello');

      controller.selectSource(TranslationLanguages.french);

      expect(controller.source, TranslationLanguages.french);
      expect(controller.state, isA<TranslationIdle>());
    });

    test('re-selecting the same language does not notify', () async {
      final controller = makeController();
      await controller.translate(text: 'Hello');

      var notified = 0;
      controller.addListener(() => notified++);
      controller.selectTarget(TranslationLanguages.hindi);
      controller.selectSource(TranslationLanguages.auto);

      expect(notified, 0);
      expect(controller.state, isA<TranslationSuccess>());
    });
  });

  group('reset and disposal', () {
    test('reset returns to idle and drops the request', () async {
      final controller = makeController();
      await controller.translate(text: 'Hello');

      controller.reset();

      expect(controller.state, isA<TranslationIdle>());
      expect(controller.lastRequest, isNull);
    });

    test('a disposed controller ignores late state updates', () async {
      service = FakeTranslationService(delay: const Duration(milliseconds: 5));
      final controller = TranslationController(service: service);

      final future = controller.translate(text: 'Hello');
      controller.dispose();

      await expectLater(future, completes);
      expect(controller.state, isA<TranslationInProgress>());
    });
  });

  group('region batches and the on-image overlay', () {
    TranslationUnit unit(int id, String text) => TranslationUnit(
      id: id,
      text: text,
      bounds: OcrRect.fromLTRB(0, id * 20, 100, id * 20 + 20),
      kind: TranslatedRegionKind.line,
    );

    test('translateUnits exposes an overlay and a flat result', () async {
      final controller = makeController();

      await controller.translateUnits([
        unit(0, 'Hello'),
        unit(1, 'World'),
      ], scope: TranslationScope.wholePage);

      final overlay = controller.overlay;
      expect(overlay, isNotNull);
      expect(overlay!.regions.length, 2);
      expect(overlay.regions.first.id, 0);
      expect(overlay.regions.first.translatedText, 'अनुवाद: Hello');
      expect(overlay.regions.first.bounds, unit(0, 'Hello').bounds);
      expect(overlay.targetLanguage, TranslationLanguages.hindi);
      expect(overlay.hasRenderableRegions, isTrue);

      final state = controller.state;
      expect(state, isA<TranslationSuccess>());
      final result = (state as TranslationSuccess).result;
      expect(result.scope, TranslationScope.wholePage);
      expect(result.translatedText, 'अनुवाद: Hello\nअनुवाद: World');

      expect(service.regionRequests.length, 1);
      expect(controller.lastUnits, isNotNull);
      // The default target is used for every region.
      expect(service.regionRequests.single.length, 2);
    });

    test('the selection scope is preserved on the flat result', () async {
      final controller = makeController();
      await controller.translateUnits([
        unit(0, 'Hello'),
      ], scope: TranslationScope.selection);

      expect(
        controller.overlay!.regions.single.kind,
        TranslatedRegionKind.line,
      );
      expect(
        (controller.state as TranslationSuccess).result.scope,
        TranslationScope.selection,
      );
    });

    test(
      'a provisioning failure leaves the progress phase and can be retried',
      () async {
        // Mirrors what happens when model provisioning times out instead of
        // hanging: the UI must leave "Preparing Hindi…" and show a retry, never
        // sit in a busy state forever.
        final controller = makeController(
          FakeTranslationService(
            emittedPhases: const [TranslationPhase.preparingModel],
            failure: const TranslationException(
              TranslationErrorKind.modelUnavailable,
              "We couldn't prepare Hindi on this device. "
              'Please check your connection and try again.',
            ),
          ),
        );

        await controller.translateUnits([
          unit(0, 'Hello'),
        ], scope: TranslationScope.wholePage);

        final state = controller.state;
        expect(state, isA<TranslationFailure>());
        expect((state as TranslationFailure).retryable, isTrue);
        expect(controller.isBusy, isFalse);
      },
    );

    test('a failure reports the reason and leaves no overlay', () async {
      final controller = makeController(
        FakeTranslationService(
          failure: const TranslationException(
            TranslationErrorKind.engineFailure,
            'Translation failed on this device. Please try again.',
          ),
        ),
      );

      await controller.translateUnits([
        unit(0, 'Hello'),
      ], scope: TranslationScope.wholePage);

      expect(controller.state, isA<TranslationFailure>());
      expect(controller.overlay, isNull);
    });

    test('progress counters reach the UI state', () async {
      final controller = makeController(
        FakeTranslationService(delay: const Duration(milliseconds: 5)),
      );
      final states = <TranslationUiState>[];
      controller.addListener(() => states.add(controller.state));

      await controller.translateUnits([
        unit(0, 'Hello'),
        unit(1, 'World'),
      ], scope: TranslationScope.wholePage);

      final counted = states
          .whereType<TranslationInProgress>()
          .where((state) => state.hasCounter)
          .toList();
      expect(counted, isNotEmpty);
      // Both regions are done by the last counter tick, so it reports 100%.
      expect(counted.last.message, 'Translating… 100%');
      expect(counted.last.progress, 1.0);
      expect(counted.map((state) => state.percentage).toList(), [50, 100]);
    });

    test('rerun re-translates the same regions in the new language', () async {
      final controller = makeController();
      await controller.translateUnits([
        unit(0, 'Hello'),
      ], scope: TranslationScope.wholePage);

      controller.selectTarget(TranslationLanguages.tamil);
      await controller.rerun();

      expect(service.regionRequests.length, 2);
      expect(service.regionRequests.last.length, 1);
      expect(controller.overlay!.targetLanguage, TranslationLanguages.tamil);
    });

    test('rerun without a previous batch does nothing', () async {
      final controller = makeController();
      await controller.rerun();
      expect(service.regionRequests, isEmpty);
      expect(controller.state, isA<TranslationIdle>());
    });

    test('changing the language keeps the previous overlay visible', () async {
      final controller = makeController();
      await controller.translateUnits([
        unit(0, 'Hello'),
      ], scope: TranslationScope.wholePage);
      final before = controller.overlay;

      controller.selectTarget(TranslationLanguages.tamil);

      expect(controller.state, isA<TranslationIdle>());
      // Still on screen, so the photo never flashes back to the original text
      // while the re-translation runs.
      expect(controller.overlay, same(before));
      expect(controller.lastUnits, isNotNull);
    });

    test('retry re-runs the last regions rather than a text request', () async {
      final controller = makeController(
        FakeTranslationService(
          failure: const TranslationException(
            TranslationErrorKind.modelUnavailable,
            'We could not prepare Hindi on this device.',
          ),
        ),
      );
      await controller.translateUnits([
        unit(0, 'Hello'),
      ], scope: TranslationScope.wholePage);

      service.failure = null;
      await controller.retry();

      expect(service.regionRequests.length, 2);
      expect(service.requests, isEmpty);
      expect(controller.overlay, isNotNull);
    });

    test('reset drops the overlay as well as the state', () async {
      final controller = makeController();
      await controller.translateUnits([
        unit(0, 'Hello'),
      ], scope: TranslationScope.wholePage);

      controller.reset();

      expect(controller.overlay, isNull);
      expect(controller.lastUnits, isNull);
      expect(controller.state, isA<TranslationIdle>());
    });

    test('a text translation clears any previous batch', () async {
      final controller = makeController();
      await controller.translateUnits([
        unit(0, 'Hello'),
      ], scope: TranslationScope.wholePage);

      await controller.translate(text: 'Bonjour');

      // The retry path must not fall back to the stale region batch.
      expect(controller.lastUnits, isNull);
      expect(service.requests.single.text, 'Bonjour');
    });
  });

  group('source detection', () {
    test('preselects the detected source and avoids a no-op pair', () async {
      final fake = FakeTranslationService(
        detectedSource: TranslationLanguages.english,
      );
      final controller = TranslationController(
        service: fake,
        target: TranslationLanguages.english,
      );
      addTearDown(controller.dispose);

      await controller.detectSource('Council approves the budget');

      expect(controller.source, TranslationLanguages.english);
      expect(controller.detectedSource, TranslationLanguages.english);
      // English -> English would translate nothing, so the target moves to the
      // service default instead of leaving a disabled action.
      expect(controller.target, TranslationLanguages.hindi);
      expect(fake.detectionRequests, hasLength(1));
    });

    test('a manual choice is never overridden or re-detected', () async {
      final fake = FakeTranslationService(
        detectedSource: TranslationLanguages.hindi,
      );
      final controller = makeController(fake);

      controller.selectSource(TranslationLanguages.bengali);
      await controller.detectSource('একটি বাংলা সংবাদ');

      expect(controller.source, TranslationLanguages.bengali);
      expect(fake.detectionRequests, isEmpty);
      expect(controller.sourceChosenByUser, isTrue);
    });

    test('choosing auto-detect hands control back to detection', () async {
      final fake = FakeTranslationService(
        detectedSource: TranslationLanguages.hindi,
      );
      final controller = makeController(fake);

      controller.selectSource(TranslationLanguages.bengali);
      controller.selectSource(TranslationLanguages.auto);
      await controller.detectSource('शहर में बारिश');

      expect(controller.source, TranslationLanguages.hindi);
      expect(fake.detectionRequests, hasLength(1));
    });

    test('a failed detection leaves auto-detect selected', () async {
      final fake = FakeTranslationService(detectionFails: true);
      final controller = makeController(fake);

      await controller.detectSource('1234');

      expect(controller.source.isAuto, isTrue);
      expect(controller.detectedSource, isNull);
      expect(controller.detectingSource, isFalse);
      expect(controller.state, isA<TranslationIdle>());
    });

    test('a failure carries its kind so the UI can offer recovery', () async {
      final fake = FakeTranslationService(
        failure: const TranslationException(
          TranslationErrorKind.detectionFailed,
          'Pick a language',
        ),
      );
      final controller = makeController(fake);

      await controller.translateUnits([
        TranslationUnit(
          id: 0,
          text: 'x',
          bounds: OcrRect.fromLTRB(0, 0, 10, 10),
          kind: TranslatedRegionKind.line,
        ),
      ], scope: TranslationScope.wholePage);

      final state = controller.state;
      expect(state, isA<TranslationFailure>());
      expect(
        (state as TranslationFailure).kind,
        TranslationErrorKind.detectionFailed,
      );
    });
  });
}
