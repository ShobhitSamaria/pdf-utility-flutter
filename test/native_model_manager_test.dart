import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdf_utility_flutter/diagnostics/translation_self_test.dart';
import 'package:pdf_utility_flutter/translation/data/native_model_manager.dart';

/// The heart of the downloadModel(hi) fix: every attempt must be bounded, a
/// stalled native Task must be abandoned and retried with a fresh one, the
/// no-Wi-Fi-gating guarantee must be pinned on the wire, and exhaustion must
/// report the per-attempt truth — never hang, never a generic sentence.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const modelChannel = MethodChannel(NativeModelManager.kChannel);
  const pluginChannel = MethodChannel('google_mlkit_on_device_translator');

  final modelCalls = <MethodCall>[];
  Future<Object?> Function(MethodCall call)? onModelCall;

  setUp(() {
    modelCalls.clear();
    onModelCall = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(modelChannel, (call) {
          modelCalls.add(call);
          return onModelCall!(call);
        });
  });

  tearDown(() {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(modelChannel, null);
    messenger.setMockMethodCallHandler(pluginChannel, null);
  });

  /// Short budgets so a "hang" test finishes in milliseconds while still
  /// exercising the exact bounded-retry logic the device runs.
  NativeModelManager manager({int attempts = 3}) => NativeModelManager(
    attemptTimeout: const Duration(milliseconds: 40),
    retryDelay: const Duration(milliseconds: 5),
    checkTimeout: const Duration(milliseconds: 500),
    maxAttempts: attempts,
  );

  Map<Object?, Object?> reply(String status, [String? error]) =>
      <Object?, Object?>{'status': status, 'error': error, 'elapsedMs': 1};

  group('isModelDownloaded', () {
    test('sends the language code and returns the native answer', () async {
      onModelCall = (call) async => call.method == NativeModelManager.kCheck;

      expect(await manager().isModelDownloaded('hi'), isTrue);
      expect(modelCalls, hasLength(1));
      expect(modelCalls.single.method, NativeModelManager.kCheck);
      expect(modelCalls.single.arguments, <String, Object?>{'model': 'hi'});
    });

    test('a native reply of null means "not downloaded"', () async {
      onModelCall = (call) async => null;

      expect(await manager().isModelDownloaded('hi'), isFalse);
    });
  });

  group('downloadModel', () {
    test(
      'first success stops, with wifi:false and the deadline on the wire',
      () async {
        onModelCall = (call) async => reply('success');

        expect(await manager().downloadModel('hi'), isTrue);
        expect(modelCalls, hasLength(1));
        expect(modelCalls.single.method, NativeModelManager.kDownload);
        final args = modelCalls.single.arguments as Map<Object?, Object?>;
        expect(args['model'], 'hi');
        // The no-Wi-Fi-gating guarantee, pinned: the plugin's default would be
        // `requireWifi()` — the "Preparing Hindi…" queue on cellular-only phones.
        expect(args['wifi'], isFalse);
        // The native watchdog deadline for this attempt.
        expect(args['timeoutMs'], 40);
      },
    );

    test('native already-present short-circuit is still a success', () async {
      onModelCall = (call) async => reply('success', 'model already on device');

      expect(await manager().downloadModel('hi'), isTrue);
      expect(modelCalls, hasLength(1));
    });

    test(
      'a timed-out attempt is abandoned and retried, then succeeds',
      () async {
        var attempt = 0;
        onModelCall = (call) async {
          attempt++;
          return attempt < 3
              ? reply(
                  'timeout',
                  'the native download Task did not complete within 40 ms',
                )
              : reply('success');
        };

        expect(await manager().downloadModel('hi'), isTrue);
        expect(
          modelCalls,
          hasLength(3),
          reason: 'each retry must be a FRESH native download attempt',
        );
      },
    );

    test('all attempts failing throws with the per-attempt truth', () async {
      onModelCall = (call) async =>
          reply('failed', 'Exception: TaskScheduler stalled');

      await expectLater(
        manager().downloadModel('hi'),
        throwsA(
          isA<ModelDownloadException>()
              .having((e) => e.code, 'code', 'hi')
              .having((e) => e.attempts, 'attempts', hasLength(3))
              .having((e) => e.summary, 'summary', contains('attempt 1/3'))
              .having((e) => e.summary, 'summary', contains('attempt 3/3'))
              // The raw native error, not a generic sentence.
              .having(
                (e) => e.summary,
                'summary',
                contains('TaskScheduler stalled'),
              ),
        ),
      );
      expect(modelCalls, hasLength(3));
    });

    test('a native call that NEVER answers is bounded and retried — never '
        'hangs', () async {
      // A Completer that never completes is exactly what the plugin's
      // listener-only bridge does when the Play Services Task stalls.
      onModelCall = (call) => Completer<Object?>().future;

      final stopwatch = Stopwatch()..start();
      await expectLater(
        manager().downloadModel('hi'),
        throwsA(
          isA<ModelDownloadException>()
              .having(
                (e) => e.attempts.map((a) => a.status).toList(),
                'statuses',
                <String>['timeout', 'timeout', 'timeout'],
              )
              .having(
                (e) => e.summary,
                'summary',
                contains('the native call never returned'),
              ),
        ),
      );
      stopwatch.stop();

      expect(modelCalls, hasLength(3));
      expect(
        stopwatch.elapsed,
        lessThan(const Duration(seconds: 5)),
        reason:
            'the bounded manager must give up long before any caller '
            'budget (the engine backstop is 150 s, the self-test 120 s)',
      );
    });

    test(
      'a PlatformException from the native side is reported, not swallowed',
      () async {
        onModelCall = (call) async => throw PlatformException(
          code: 'error',
          message: 'Failed to connect to Play Services',
        );

        await expectLater(
          manager(attempts: 2).downloadModel('hi'),
          throwsA(
            isA<ModelDownloadException>()
                .having((e) => e.attempts, 'attempts', hasLength(2))
                .having(
                  (e) => e.summary,
                  'summary',
                  contains('PlatformException(error)'),
                )
                .having(
                  (e) => e.summary,
                  'summary',
                  contains('Failed to connect to Play Services'),
                ),
          ),
        );
        expect(modelCalls, hasLength(2));
      },
    );

    test(
      'an unexpected reply shape is a failure, never a silent success',
      () async {
        onModelCall = (call) async => 'success'; // wrong shape on purpose

        await expectLater(
          manager(attempts: 1).downloadModel('hi'),
          throwsA(
            isA<ModelDownloadException>().having(
              (e) => e.summary,
              'summary',
              contains('unexpected native reply'),
            ),
          ),
        );
      },
    );
  });

  group('plugin fallback', () {
    test('a missing native channel falls back to the plugin manager — still '
        'bounded and still not Wi-Fi-gated', () async {
      // No handler on our own channel → MissingPluginException.
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(modelChannel, null);

      final pluginCalls = <MethodCall>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(pluginChannel, (call) async {
            pluginCalls.add(call);
            final args = call.arguments as Map<Object?, Object?>;
            return switch (args['task']) {
              'check' => false,
              'download' => 'success',
              _ => null,
            };
          });

      final m = manager();
      expect(await m.downloadModel('hi'), isTrue);
      expect(await m.isModelDownloaded('hi'), isFalse);

      expect(pluginCalls, hasLength(2));
      final download = pluginCalls.firstWhere(
        (c) => c.method == 'nlp#manageLanguageModelModels',
      );
      final args = download.arguments as Map<Object?, Object?>;
      expect(args['task'], 'download');
      expect(args['model'], 'hi');
      // The plugin's DEFAULT is wifi: true (requireWifi). We never send that.
      expect(args['wifi'], isFalse);
      expect(pluginCalls.first.method, 'nlp#manageLanguageModelModels');
    });
  });

  group('budgets', () {
    test(
      'the default worst case fits inside the self-test download budget',
      () async {
        // The diagnostic's downloadModel step must outlast the manager's whole
        // retry sequence, so a FAIL shows per-attempt evidence instead of one
        // umbrella step timeout.
        final defaults = NativeModelManager();
        expect(
          defaults.worstCaseDuration,
          lessThan(TranslationSelfTest().downloadTimeout),
        );
        // …and the engine's own backstop outlasts both.
        expect(
          defaults.worstCaseDuration,
          lessThan(const Duration(seconds: 150)),
        );
      },
    );
  });

  group('logging', () {
    test('every attempt logs BEFORE and AFTER with its raw outcome', () async {
      final lines = <String>[];
      final original = debugPrint;
      debugPrint = (String? message, {int? wrapWidth}) {
        if (message != null) lines.add(message);
      };
      addTearDown(() => debugPrint = original);

      onModelCall = (call) async => reply('timeout', 'stalled by watchdog');
      await expectLater(
        manager().downloadModel('hi'),
        throwsA(isA<ModelDownloadException>()),
      );

      String lineWith(String needle) =>
          lines.firstWhere((l) => l.contains(needle), orElse: () => '');
      expect(lineWith('attempt 1/3 BEFORE'), isNot(''));
      expect(lineWith('attempt 1/3 AFTER TIMEOUT'), isNot(''));
      expect(lineWith('attempt 2/3 BEFORE'), isNot(''));
      expect(lineWith('attempt 3/3 BEFORE'), isNot(''));
      expect(lineWith('giving up after 3 attempts'), isNot(''));
      expect(lineWith('stalled by watchdog'), isNot(''));
    });
  });
}
