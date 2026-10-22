import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdf_utility_flutter/ocr/domain/ocr_exception.dart';

/// The classification is the difference between a user being told to try again
/// (useless when the app cannot start ML Kit at all) and being told to reinstall
/// or re-take the photo. These tests pin the real error shapes each message is
/// for.
void main() {
  group('classifying a failure', () {
    test('an uninitialised ML Kit context is an unavailable engine', () {
      // This is what the plugin reports when `TextRecognition.getClient` throws
      // inside the native method-call handler: Flutter wraps it with the code
      // `error` and the exception's message, so the *message* is the only
      // evidence. Matching on "not initialized" alone missed it, because the
      // real wording is "has not been initialized".
      final failure = OcrException.from(
        PlatformException(
          code: 'error',
          message: 'MlKitContext has not been initialized',
        ),
      );

      expect(failure.kind, OcrErrorKind.engineUnavailable);
      expect(failure.message, contains('not available'));
      expect(failure.message, isNot(contains('MlKit')));
      expect(failure.cause, isA<PlatformException>());
    });

    test('a missing plugin is an unavailable engine, not a bad photo', () {
      final failure = OcrException.from(
        MissingPluginException('No implementation found for method vision'),
      );

      expect(failure.kind, OcrErrorKind.engineUnavailable);
    });

    test('a missing native library is an unavailable engine', () {
      final failure = OcrException.from(
        PlatformException(
          code: 'error',
          message: 'java.lang.UnsatisfiedLinkError: dlopen failed',
        ),
      );

      expect(failure.kind, OcrErrorKind.engineUnavailable);
    });

    test('a file the converter cannot open is an unreadable image', () {
      // google_mlkit_commons reports its own input-image failures separately
      // from recognition failures; they are the user's to fix.
      final failure = OcrException.from(
        PlatformException(
          code: 'InputImageConverterError',
          message: 'java.io.FileNotFoundException: /x.jpg (No such file)',
        ),
      );

      expect(failure.kind, OcrErrorKind.imageUnreadable);
      expect(failure.message, contains('could not be opened'));
    });

    test('a recognizer failure keeps its own message, not the generic one', () {
      final failure = OcrException.from(
        PlatformException(
          code: 'TextRecognizerError',
          message: 'java.lang.IllegalStateException: bad image',
        ),
      );

      expect(failure.kind, OcrErrorKind.engineFailure);
      expect(failure.message, contains('could not read this image'));
    });

    // The release-APK OCR failure of 2026-10-20 arrived in exactly this shape:
    // an uncaught native NullPointerException in ML Kit came back through the
    // method channel as `PlatformException(error, null, null)`. There is no
    // message to classify, so the app has to keep the platform code and the
    // original object — that is what makes the failure diagnosable from logs —
    // while still showing one calm sentence to the person.
    test('a message-less platform failure keeps its cause for diagnostics', () {
      final failure = OcrException.from(
        PlatformException(code: 'error'),
        stackTrace: StackTrace.current,
      );

      expect(failure.message, 'Text recognition failed. Please try again.');
      expect(failure.cause, isA<PlatformException>());
      expect(
        (failure.cause! as PlatformException).code,
        'error',
        reason: 'the platform error code is the only native clue left',
      );
      expect(failure.stackTrace, isNotNull);
      expect(failure.debugDescription, contains('PlatformException'));
    });

    test('an unknown failure keeps the generic sentence but the cause', () {
      final failure = OcrException.from(StateError('something new'));

      expect(failure.kind, OcrErrorKind.engineFailure);
      expect(failure.message, 'Text recognition failed. Please try again.');
      expect(failure.cause, isA<StateError>());
    });

    test('an OcrException passes through untouched', () {
      const original = OcrException(
        OcrErrorKind.timeout,
        'Reading the image took too long.',
      );
      expect(identical(OcrException.from(original), original), isTrue);
    });
  });

  group('debug details', () {
    test('include the kind, the cause and the stack trace', () {
      final failure = OcrException.from(
        PlatformException(code: 'TextRecognizerError', message: 'boom'),
        stackTrace: StackTrace.current,
      );

      final description = failure.debugDescription;
      expect(description, contains('engineFailure'));
      expect(description, contains('PlatformException'));
      expect(description, contains('Stack trace'));
    });

    test('a user-facing message never contains the raw error', () {
      final failure = OcrException.from(
        PlatformException(
          code: 'TextRecognizerError',
          message: 'java.io.IOException: /data/user/0/private/path.jpg',
        ),
      );

      expect(failure.message, isNot(contains('/data/user')));
      expect(failure.message, isNot(contains('java.io')));
    });
  });
}
