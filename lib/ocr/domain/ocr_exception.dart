/// What went wrong with an OCR run.
///
/// An **empty result** — a real `OcrResult` whose blocks are empty — is *not* a
/// failure: the engine answered correctly and found no text, which the UI
/// presents as its own state rather than as an error. These kinds describe the
/// ways a run can fail *before* producing a result.
enum OcrErrorKind {
  /// The recognizer never answered within the app's budget.
  ///
  /// ML Kit's `process` returns a Play Services `Task` that the plugin bridges
  /// with success/failure listeners only — there is no timeout anywhere in the
  /// plugin or in native ML Kit. On a wedged device the Dart future simply never
  /// completes, which is exactly what left the translation model download
  /// hanging. The app therefore bounds every recognition call itself.
  timeout,

  /// The image itself could not be read: missing, empty, unreadable (permission)
  /// or not decodable as an image.
  ///
  /// This is its own kind because it is the one failure the user can fix by
  /// choosing another picture, and it used to be indistinguishable from an
  /// engine fault — both ended up as "Text recognition failed".
  imageUnreadable,

  /// The recognizer could not be created or started at all: a model that is not
  /// packaged in this build, an ML Kit context that was never initialised, a
  /// missing native library, or the plugin not being registered.
  ///
  /// Retrying the same image will not help; this is a build/device problem.
  engineUnavailable,

  /// The recognizer ran and reported a failure (or read the image and something
  /// in the result could not be understood).
  engineFailure,
}

/// A recognition failure that can be shown to the user.
///
/// Carries a message written for a person plus the underlying error, stack trace
/// and a debug-only description, so a real-device failure can be read without
/// guessing — and without ever showing platform noise to a normal user.
class OcrException implements Exception {
  const OcrException(this.kind, this.message, {this.cause, this.stackTrace});

  final OcrErrorKind kind;

  /// User-facing explanation. Never contains raw platform noise, file paths or
  /// stack traces.
  final String message;

  /// The original error/exception, kept for diagnostics.
  final Object? cause;

  /// Where the failure came from, when the layer that caught it had a stack.
  final StackTrace? stackTrace;

  /// Wraps an arbitrary error thrown by the engine into an [OcrException].
  ///
  /// The previous version of this method matched exactly three strings
  /// (`not initialized`, `TextRecognizerError`, `NoClassDefFoundError`) and
  /// dropped [error] entirely. Anything else — an
  /// `InputImageConverterError`, a `PlatformException` whose message was null,
  /// an `UnsatisfiedLinkError`, a decoder failure — became the same generic
  /// sentence, with the real cause thrown away. That is why a device failure
  /// could not be diagnosed from the app at all.
  ///
  /// The mapping below is deliberately by **shape of the failure**, and the
  /// original object is always kept in [cause].
  static OcrException from(Object error, {StackTrace? stackTrace}) {
    if (error is OcrException) return error;

    // The runtime type is included because several native failures carry an
    // empty or null message: `PlatformException(error, null, null)` for a
    // `NoClassDefFoundError` is a real example.
    final raw = '${error.runtimeType}: $error'.toLowerCase();

    bool any(List<String> needles) => needles.any(raw.contains);

    // 1. The recognizer could not be created at all. These are the messages the
    //    ML Kit plugin, Flutter's method-channel wrapper and the Android runtime
    //    actually produce.
    if (any(const <String>[
      'textrecognizer is not initialized',
      'not been initialized',
      'not initialized',
      'mlkitcontext',
      'mlkit is not',
      'missingpluginexception',
      'unsatisfiedlinkerror',
      'noclassdeffounderror',
      'nosuchmethoderror',
      'classnotfoundexception',
      'no implementation found',
    ])) {
      return OcrException(
        OcrErrorKind.engineUnavailable,
        'Text recognition is not available in this build of the app. '
        'Reinstall the app, then try again.',
        cause: error,
        stackTrace: stackTrace,
      );
    }

    // 2. The file was there but ML Kit could not turn it into a bitmap. This is
    //    the `InputImageConverterError` path in google_mlkit_commons, which is
    //    reported separately from a recognition failure.
    if (any(const <String>[
      'inputimageconvertererror',
      'filenotfound',
      'no such file',
      'could not load file',
      'failed to decode',
      'unable to decode',
      'could not decode',
      'invalid image',
      'imageformat',
      'permission denied',
      'eacces',
      'securityexception',
    ])) {
      return OcrException(
        OcrErrorKind.imageUnreadable,
        'That image could not be opened. Please capture or choose it again.',
        cause: error,
        stackTrace: stackTrace,
      );
    }

    // 3. The recognizer ran and failed. The native code reports this as
    //    `TextRecognizerError`; the message is kept in `cause` for the debug
    //    details view. Saying "this script is not available" here would be a
    //    guess — a bad image produces the same code.
    if (any(const <String>['textrecognizererror'])) {
      return OcrException(
        OcrErrorKind.engineFailure,
        'The text recognizer could not read this image. Try again, or take the '
        'photo again in better light.',
        cause: error,
        stackTrace: stackTrace,
      );
    }

    return OcrException(
      OcrErrorKind.engineFailure,
      'Text recognition failed. Please try again.',
      cause: error,
      stackTrace: stackTrace,
    );
  }

  /// Everything a developer needs and a user must never see: the kind, the
  /// original exception and its stack trace.
  String get debugDescription {
    final buffer = StringBuffer('Kind: ${kind.name}\nMessage: $message');
    final original = cause;
    if (original != null) {
      buffer.write('\n\nCause: ${original.runtimeType}\n$original');
    }
    final stack = stackTrace;
    if (stack != null) buffer.write('\n\nStack trace:\n$stack');
    return buffer.toString();
  }

  @override
  String toString() => message;
}
