import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdf_utility_flutter/translation/data/local_mlkit_translation_service.dart';
import 'package:pdf_utility_flutter/translation/data/mlkit_translation_engine.dart';
import 'package:pdf_utility_flutter/translation/domain/translation_exception.dart';
import 'package:pdf_utility_flutter/translation/domain/translation_language.dart';
import 'package:pdf_utility_flutter/translation/domain/translation_model_manager.dart';

/// Records how the model manager was used.
///
/// The Wi-Fi gating itself is pinned where it lives now — in
/// `NativeModelManager`, which sends `wifi: false` to its native channel (see
/// `native_model_manager_test.dart`) — so this fake only records the engine's
/// usage of the [TranslationModelManager] seam.
class _RecordingModelManager implements TranslationModelManager {
  bool modelPresent = false;
  int downloadCount = 0;
  Duration? downloadDelay;
  String? lastDownloadCode;

  @override
  Future<bool> isModelDownloaded(String code) async => modelPresent;

  @override
  Future<bool> downloadModel(String code) async {
    downloadCount++;
    lastDownloadCode = code;
    final delay = downloadDelay;
    if (delay != null) await Future<void>.delayed(delay);
    modelPresent = true;
    return true;
  }
}

/// A model manager whose download never completes — the behaviour that used to
/// leave the UI on "Preparing …" forever.
class _HangingModelManager extends _RecordingModelManager {
  @override
  Future<bool> downloadModel(String code) => Completer<bool>().future;
}

/// Guards the seam between our domain language codes and ML Kit's native
/// language enum: a language offered in the UI that the engine cannot actually
/// translate would fail only at runtime, on a device.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('google_mlkit_on_device_translator');
  final calls = <MethodCall>[];

  void mockNative(Future<Object?> Function(MethodCall call) handler) {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) {
          calls.add(call);
          return handler(call);
        });
  }

  setUp(calls.clear);
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('every offered language has an on-device ML Kit mapping', () {
    for (final language in TranslationLanguages.all) {
      expect(
        MlKitTranslationEngine.supportedCodes,
        contains(language.code),
        reason:
            'no native ML Kit mapping for ${language.code} '
            '(${language.englishName})',
      );
    }
  });

  test('auto-detect is not passed to the native engine', () {
    expect(
      MlKitTranslationEngine.supportedCodes,
      isNot(contains(TranslationLanguage.autoCode)),
    );
  });

  test('the default service targets are all translatable on-device', () async {
    final service = LocalMlKitTranslationService();
    for (final language in service.targetLanguages) {
      expect(
        MlKitTranslationEngine.supportedCodes,
        contains(language.code),
        reason:
            '${language.englishName} is offered as a target but has no '
            'native model mapping',
      );
    }
    // Never actually translate: the service is only inspected here.
    await service.dispose();
  });

  group('translate', () {
    test(
      'maps our codes onto the native translator and returns its output',
      () async {
        mockNative(
          (call) async =>
              call.method == 'nlp#startLanguageTranslator' ? 'नमस्ते' : null,
        );
        final engine = MlKitTranslationEngine();

        final result = await engine.translate(
          text: 'Hello',
          source: TranslationLanguages.english,
          target: TranslationLanguages.hindi,
        );

        expect(result, 'नमस्ते');
        final start = calls.firstWhere(
          (c) => c.method == 'nlp#startLanguageTranslator',
        );
        final args = start.arguments as Map<Object?, Object?>;
        expect(args['text'], 'Hello');
        expect(args['source'], 'en');
        expect(args['target'], 'hi');
      },
    );

    test(
      'surfaces a native failure with its platform code and message',
      () async {
        mockNative((call) async {
          if (call.method == 'nlp#startLanguageTranslator') {
            throw PlatformException(
              code: 'Error building translator',
              message: 'Either source or target models not downloaded',
            );
          }
          return null;
        });
        final engine = MlKitTranslationEngine();

        await expectLater(
          engine.translate(
            text: 'Hello',
            source: TranslationLanguages.english,
            target: TranslationLanguages.hindi,
          ),
          throwsA(
            isA<TranslationException>()
                .having(
                  (e) => e.kind,
                  'kind',
                  TranslationErrorKind.engineFailure,
                )
                .having((e) => e.isRetryable, 'retryable', isTrue)
                // The root cause must not be lost behind the friendly sentence.
                .having(
                  (e) => e.details,
                  'details',
                  contains('Error building translator'),
                )
                .having(
                  (e) => e.details,
                  'details',
                  contains('Either source or target models not downloaded'),
                ),
          ),
        );
      },
    );

    test(
      'a translator call that never resolves times out (never hangs)',
      () async {
        // A native call that never completes is exactly the failure mode that
        // stranded the UI on "Preparing Hindi…".
        mockNative((call) async {
          if (call.method == 'nlp#startLanguageTranslator') {
            return Completer<Object?>().future;
          }
          return null;
        });
        final engine = MlKitTranslationEngine(
          operationTimeout: const Duration(milliseconds: 20),
        );

        await expectLater(
          engine.translate(
            text: 'Hello',
            source: TranslationLanguages.english,
            target: TranslationLanguages.hindi,
          ),
          throwsA(
            isA<TranslationException>()
                .having(
                  (e) => e.kind,
                  'kind',
                  TranslationErrorKind.engineFailure,
                )
                .having((e) => e.isRetryable, 'retryable', isTrue),
          ),
        );
      },
    );
  });

  group('model provisioning', () {
    test(
      'downloads a missing model through the native model manager',
      () async {
        // The documented flow: check → downloadModel before translating.
        final manager = _RecordingModelManager();
        final engine = MlKitTranslationEngine(modelManager: manager);

        await engine.downloadModel(TranslationLanguages.hindi);

        expect(manager.downloadCount, 1);
        expect(manager.lastDownloadCode, 'hi');
      },
    );

    test('a download that never resolves times out as retryable', () async {
      final engine = MlKitTranslationEngine(
        modelManager: _HangingModelManager(),
        operationTimeout: const Duration(milliseconds: 20),
      );

      await expectLater(
        engine.downloadModel(TranslationLanguages.hindi),
        throwsA(
          isA<TranslationException>()
              .having(
                (e) => e.kind,
                'kind',
                TranslationErrorKind.modelUnavailable,
              )
              .having((e) => e.isRetryable, 'retryable', isTrue)
              .having((e) => e.userMessage, 'message', contains('Hindi'))
              // The real cause is captured, not merely the friendly sentence.
              .having(
                (e) => e.details,
                'details',
                contains('TimeoutException'),
              ),
        ),
      );
    });

    test('isModelAvailable reflects the native model manager', () async {
      final manager = _RecordingModelManager();
      final engine = MlKitTranslationEngine(modelManager: manager);

      expect(
        await engine.isModelAvailable(TranslationLanguages.hindi),
        isFalse,
      );
      manager.modelPresent = true;
      expect(await engine.isModelAvailable(TranslationLanguages.hindi), isTrue);
    });

    test('the default operation timeout is generous but bounded', () {
      expect(
        MlKitTranslationEngine().operationTimeout,
        greaterThan(const Duration(seconds: 10)),
      );
    });
  });
}
