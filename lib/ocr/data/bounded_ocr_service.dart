import 'dart:async';

import '../domain/ocr_exception.dart';
import '../domain/ocr_result.dart';
import '../domain/ocr_script_mode.dart';
import '../domain/ocr_service.dart';
import '../ocr_log.dart';

/// Wraps an [OcrService] so a recognition call can never leave the UI waiting
/// forever.
///
/// Why this is necessary rather than defensive
/// -------------------------------------------
/// `google_mlkit_text_recognition` bridges a native Play Services `Task` with
/// success/failure listeners only: neither the plugin nor ML Kit itself ever
/// gives up. If the native task never calls back, the Dart future never
/// completes, the progress indicator spins indefinitely, and the user has no way
/// to tell a slow page from a dead one. This is the same failure class as the
/// translation model download that stalled for 120 s without returning, so the
/// app bounds the call itself and reports a real outcome.
///
/// The bound is applied in Dart, which means a timed-out call is *abandoned*
/// rather than cancelled — ML Kit's `process` exposes no cancellation, so the
/// native work may still finish and be discarded. That is safe (the recognizer
/// instance is reused only after its own call returns) but it is a real
/// limitation, documented rather than hidden.
class BoundedOcrService implements OcrService {
  BoundedOcrService({
    required this.delegate,
    this.timeout = const Duration(seconds: 60),
  });

  final OcrService delegate;

  /// Budget for **one** recognition pass.
  final Duration timeout;

  /// Any run that **may** perform two passes gets two budgets instead of
  /// squeezing both into one — otherwise a two-pass mode would turn a healthy
  /// page into a timeout.
  ///
  /// This covers [OcrScriptMode.auto] as well as [OcrScriptMode.mixed]: Auto
  /// probes with the Latin recognizer first and then runs the Devanagari one
  /// when the probe is inconclusive, so one budget for two passes would make
  /// every Hindi page time out. See [OcrScriptMode.mayReadTwice].
  Duration budgetFor(OcrScriptMode mode) =>
      mode.mayReadTwice ? timeout * 2 : timeout;

  @override
  String get engineName => delegate.engineName;

  @override
  Future<OcrResult> recognizeImage(
    String imagePath, {
    OcrScriptMode mode = OcrScriptMode.defaultMode,
  }) async {
    final budget = budgetFor(mode);
    try {
      return await delegate
          .recognizeImage(imagePath, mode: mode)
          .timeout(budget);
    } on TimeoutException catch (error, stackTrace) {
      // The abandoned call may still complete natively; the recognizer is reused
      // only after its own call returns, so this is safe but worth recording.
      ocrLogError(
        'Recognition timed out after ${budget.inSeconds} s '
        '(mode ${mode.name})',
        error,
        stackTrace,
      );
      throw OcrException(
        OcrErrorKind.timeout,
        'Reading the image took longer than ${budget.inSeconds} seconds, so it '
        'was stopped. Try again, or use a simpler photo.',
        cause: error,
      );
    }
  }

  @override
  Future<void> dispose() => delegate.dispose();
}
