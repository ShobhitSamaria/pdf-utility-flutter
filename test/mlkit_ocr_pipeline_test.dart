import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdf_utility_flutter/ocr/data/mlkit_ocr_engine.dart';
import 'package:pdf_utility_flutter/ocr/domain/ocr_engine.dart';
import 'package:pdf_utility_flutter/ocr/domain/ocr_exception.dart';

import 'support/pdf_test_images.dart';

/// The channel the ML Kit plugin serves. Mocking it runs the app's **real**
/// engine code — preflight, decoding, mapping, error translation — against the
/// exact payload shape the Android plugin returns, without a device.
const MethodChannel _mlKitChannel = MethodChannel(
  'google_mlkit_text_recognizer',
);

/// One block, one line, two words — the smallest realistic native response.
Map<String, dynamic> _nativePayload({String text = 'Hello world'}) {
  Map<String, dynamic> rect(double l, double t, double r, double b) => {
    'left': l,
    'top': t,
    'right': r,
    'bottom': b,
  };

  return {
    'text': text,
    'blocks': [
      {
        'text': text,
        'rect': rect(10, 20, 210, 60),
        'points': [
          {'x': 10, 'y': 20},
        ],
        'recognizedLanguages': ['en'],
        'lines': [
          {
            'text': text,
            'rect': rect(10, 20, 210, 60),
            'points': [
              {'x': 10, 'y': 20},
            ],
            'recognizedLanguages': ['en'],
            'confidence': 0.91,
            'angle': 0.0,
            'elements': [
              {
                'text': 'Hello',
                'rect': rect(10, 20, 100, 60),
                'points': const <Map<String, int>>[],
                'recognizedLanguages': ['en'],
                'confidence': 0.94,
                'angle': 0.0,
                'symbols': [
                  {
                    'text': 'H',
                    'rect': rect(10, 20, 30, 60),
                    'points': const <Map<String, int>>[],
                    'recognizedLanguages': ['en'],
                    'confidence': 0.97,
                    'angle': 0.0,
                  },
                ],
              },
              {
                'text': 'world',
                'rect': rect(110, 20, 210, 60),
                'points': const <Map<String, int>>[],
                'recognizedLanguages': ['en'],
                'confidence': 0.88,
                'angle': 0.0,
                'symbols': const <Map<String, dynamic>>[],
              },
            ],
          },
        ],
      },
    ],
  };
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory root;
  late String png;

  /// Every platform call the engine made, in order.
  late List<MethodCall> calls;

  /// Answers the recognizer channel. Replaced per test when a test needs the
  /// native side to fail.
  void mockChannel(Future<Object?> Function(MethodCall call) handler) {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_mlKitChannel, handler);
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(_mlKitChannel, null),
    );
  }

  setUp(() async {
    calls = <MethodCall>[];
    root = await Directory.systemTemp.createTemp('mlkit_ocr_test');
    // A real PNG: the engine reads its header to report upright dimensions.
    png = await writeTestPng(
      directory: root,
      name: 'page.png',
      width: 120,
      height: 160,
    );
    mockChannel((call) async {
      calls.add(call);
      return call.method == 'vision#startTextRecognizer'
          ? _nativePayload()
          : null;
    });
  });

  tearDown(() async {
    if (root.existsSync()) await root.delete(recursive: true);
  });

  group('a successful read', () {
    test('maps the native tree into the app domain', () async {
      final engine = MlKitOcrEngine();
      addTearDown(engine.dispose);

      final result = await engine.recognize(
        imagePath: png,
        options: const OcrOptions(script: OcrScript.latin),
      );

      expect(result.fullText, 'Hello world');
      expect(result.blocks, hasLength(1));
      expect(result.lines.single.text, 'Hello world');
      expect(result.elements.map((element) => element.text), <String>[
        'Hello',
        'world',
      ]);
      // Coordinates are in source-image pixels, exactly as ML Kit reported them.
      expect(result.lines.single.boundingBox.left, 10);
      expect(result.lines.single.boundingBox.right, 210);
      expect(result.lines.single.confidence, closeTo(0.91, 0.001));
      // Dimensions come from the decoded image, which is the coordinate space
      // the overlay maps from.
      expect(result.sourceImage.width, 120);
      expect(result.sourceImage.height, 160);
      expect(result.sourceImage.path, png);
      expect(result.engineName, 'Google ML Kit');

      // One recognizer call, and the file path was what we passed in.
      final start = calls.singleWhere(
        (call) => call.method == 'vision#startTextRecognizer',
      );
      expect((start.arguments as Map)['imageData']['path'], png);
    });

    test('reuses the recognizer for the next image', () async {
      final engine = MlKitOcrEngine();
      addTearDown(engine.dispose);

      await engine.recognize(imagePath: png);
      await engine.recognize(imagePath: png);

      // Native model creation is expensive; a second photo must not pay for it.
      expect(
        calls.where((call) => call.method == 'vision#startTextRecognizer'),
        hasLength(2),
      );
      final ids = calls
          .where((call) => call.method == 'vision#startTextRecognizer')
          .map((call) => (call.arguments as Map)['id'])
          .toSet();
      expect(ids, hasLength(1));
    });
  });

  group('failures before the recognizer', () {
    test(
      'a missing file is an unreadable image and never calls ML Kit',
      () async {
        final engine = MlKitOcrEngine();
        addTearDown(engine.dispose);

        await expectLater(
          engine.recognize(imagePath: '${root.path}/gone.jpg'),
          throwsA(
            isA<OcrException>()
                .having((e) => e.kind, 'kind', OcrErrorKind.imageUnreadable)
                .having(
                  (e) => e.message,
                  'message',
                  contains('no longer available'),
                ),
          ),
        );
        expect(calls, isEmpty);
      },
    );

    test(
      'an empty file is reported as unreadable, not as a recognizer fault',
      () async {
        final empty = File('${root.path}/empty.jpg');
        await empty.writeAsBytes(const <int>[]);

        final engine = MlKitOcrEngine();
        addTearDown(engine.dispose);

        await expectLater(
          engine.recognize(imagePath: empty.path),
          throwsA(
            isA<OcrException>()
                .having((e) => e.kind, 'kind', OcrErrorKind.imageUnreadable)
                .having((e) => e.message, 'message', contains('empty')),
          ),
        );
        expect(calls, isEmpty);
      },
    );

    test(
      'a file that is not an image fails in the decoder, with its cause',
      () async {
        final notAnImage = File('${root.path}/notes.jpg');
        await notAnImage.writeAsString('this is not a PNG');

        final engine = MlKitOcrEngine();
        addTearDown(engine.dispose);

        await expectLater(
          engine.recognize(imagePath: notAnImage.path),
          throwsA(
            isA<OcrException>()
                .having((e) => e.kind, 'kind', OcrErrorKind.imageUnreadable)
                .having((e) => e.cause, 'cause', isNotNull),
          ),
        );
        expect(calls, isEmpty);
      },
    );
  });

  group('failures from ML Kit', () {
    test(
      'an uninitialised context is reported as an unavailable engine',
      () async {
        mockChannel((call) async {
          calls.add(call);
          throw PlatformException(
            code: 'error',
            message: 'MlKitContext has not been initialized',
          );
        });

        final engine = MlKitOcrEngine();
        addTearDown(engine.dispose);

        await expectLater(
          engine.recognize(imagePath: png),
          throwsA(
            isA<OcrException>()
                .having((e) => e.kind, 'kind', OcrErrorKind.engineUnavailable)
                .having((e) => e.cause, 'cause', isNotNull),
          ),
        );
      },
    );

    test('a converter failure is an unreadable image', () async {
      mockChannel((call) async {
        calls.add(call);
        throw PlatformException(
          code: 'InputImageConverterError',
          message: 'java.io.FileNotFoundException: $png',
        );
      });

      final engine = MlKitOcrEngine();
      addTearDown(engine.dispose);

      await expectLater(
        engine.recognize(imagePath: png),
        throwsA(
          isA<OcrException>().having(
            (e) => e.kind,
            'kind',
            OcrErrorKind.imageUnreadable,
          ),
        ),
      );
    });

    test('a failed recognizer is closed and replaced, not reused', () async {
      var failNext = true;
      mockChannel((call) async {
        calls.add(call);
        if (call.method != 'vision#startTextRecognizer') return null;
        if (failNext) {
          failNext = false;
          throw PlatformException(
            code: 'TextRecognizerError',
            message: 'java.lang.IllegalStateException: recognizer wedged',
          );
        }
        return _nativePayload();
      });

      final engine = MlKitOcrEngine();
      addTearDown(engine.dispose);

      await expectLater(
        engine.recognize(imagePath: png),
        throwsA(isA<OcrException>()),
      );

      // The next image must not inherit the broken native instance: every later
      // run used to reuse it, so one failure repeated forever, from every entry
      // point.
      final recovered = await engine.recognize(imagePath: png);
      expect(recovered.fullText, 'Hello world');

      // The plugin sends `vision#startTextRecognizer` for *every* image; the
      // recognizer's identity is the `id` it carries, not the call count.
      // Third call: same image again, to show the replacement is cached.
      await engine.recognize(imagePath: png);

      final ids = calls
          .where((call) => call.method == 'vision#startTextRecognizer')
          .map((call) => (call.arguments as Map)['id'])
          .toList();
      expect(ids, hasLength(3));

      final failedId = ids[0];
      final replacementId = ids[1];
      expect(replacementId, isNot(failedId));
      // The healthy replacement is reused rather than rebuilt per image.
      expect(ids[2], replacementId);

      // The failed instance was closed rather than leaked.
      expect(
        calls
            .where((call) => call.method == 'vision#closeTextRecognizer')
            .map((call) => (call.arguments as Map)['id']),
        contains(failedId),
      );
    });
  });

  group('manual scripts', () {
    test('asking for Devanagari sends the plugin its script index', () async {
      final engine = MlKitOcrEngine();
      addTearDown(engine.dispose);

      await engine.recognize(
        imagePath: png,
        options: const OcrOptions(script: OcrScript.devanagari),
      );

      final start = calls.singleWhere(
        (call) => call.method == 'vision#startTextRecognizer',
      );
      // The plugin's enum order is latin, chinese, devanagiri, japanese,
      // korean — the index is the contract with the native side.
      expect((start.arguments as Map)['script'], 2);
    });
  });
}
