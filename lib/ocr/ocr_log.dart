import 'package:flutter/foundation.dart';

/// The logcat tag the OCR feature writes under.
///
/// Deliberately the same string `MainActivity.kt` uses (`OCR_TAG`), so Dart and
/// native lines interleave in one filter:
///
/// ```
/// adb logcat | grep PDF_UTILITY_OCR
/// ```
///
/// This exists because the app's user-facing OCR error is deliberately vague
/// ("Text recognition failed. Please try again."), and the only way to learn
/// *why* on a real phone is to keep the original exception and stack trace
/// somewhere a developer can read. No path, stack or platform detail is ever
/// shown to a normal user of a release build.
const String ocrLogTag = 'PDF_UTILITY_OCR';

/// Writes a diagnostic line in debug builds only.
void ocrLog(String message) {
  if (!kDebugMode) return;
  debugPrint('$ocrLogTag: $message');
}

/// Writes the **original** error and stack trace, plus a note on where it
/// happened, in debug builds only.
///
/// This is the counterpart of the user-facing message: the message says what
/// the person can do, this says what actually went wrong.
void ocrLogError(String where, Object error, [StackTrace? stackTrace]) {
  if (!kDebugMode) return;
  debugPrint('$ocrLogTag: $where — ${error.runtimeType}: $error');
  if (stackTrace != null) debugPrint('$ocrLogTag: stack:\n$stackTrace');
}

/// Reports one pipeline stage in **every** build, release included.
///
/// Why this is not gated on [kDebugMode]
/// ------------------------------------
/// The failure this was added for only reproduced in the release APK, and the
/// release build logged nothing at all: the only evidence on the phone was the
/// same generic sentence every failure produces. `debugPrint` still reaches
/// logcat in a release build, so a stage log written here survives on the
/// device — which is the difference between diagnosing a shipped build and
/// guessing at it.
///
/// Nothing passed to this function may identify what the document says. Callers
/// log the file *name*, byte size, pixel dimensions, script, counts and timings
/// — never recognised text, translated text, Aadhaar/ID numbers, or other
/// content. An absolute path is avoided for the same reason: it can carry a
/// person's name (e.g. `/…/cache/scan_of_ravi.jpg`).
void ocrDiag(String message) {
  debugPrint('$ocrLogTag: $message');
}

/// Like [ocrDiag], but for a failure: keeps the original error type, message
/// and stack trace so a release-build failure is still traceable.
///
/// Native ML Kit failures frequently arrive as `PlatformException(error, null)`
/// — a null message with the class name lost — so the stack trace is what
/// remains. It is worth the logcat space exactly once per failed run.
void ocrDiagError(String where, Object error, [StackTrace? stackTrace]) {
  debugPrint('$ocrLogTag: $where — ${error.runtimeType}: $error');
  if (stackTrace != null) debugPrint('$ocrLogTag: stack:\n$stackTrace');
}
