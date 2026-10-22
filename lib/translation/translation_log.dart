import 'package:flutter/foundation.dart';

/// The single log tag used by **every** translation log line.
///
/// Filter a device with:
///
/// ```
/// adb logcat | grep PDF_UTILITY_TRANSLATION
/// ```
///
/// Every message is prefixed with this tag so a whole run can be captured in one
/// grep, no matter which layer emitted it (engine, detector, service, controller,
/// self-test).
const String kTranslationLogTag = 'PDF_UTILITY_TRANSLATION';

/// Debug-only structured logging for the translation subsystem.
///
/// A no-op in release builds (`kDebugMode` is false), so nothing leaks into a
/// shipped app.
void translationLog(String message) {
  if (kDebugMode) debugPrint('$kTranslationLogTag | $message');
}
