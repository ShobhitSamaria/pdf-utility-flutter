import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';

/// Collects device/environment facts that matter for ML Kit translation.
///
/// The OS/ABI/manufacturer/model and Google Play Services version come from a
/// tiny native channel (`pdf_utility/diagnostics`, implemented in
/// `MainActivity.kt`) rather than a new dependency — no package is added for
/// this. If that channel is unavailable (non-Android, or an older build) the
/// rest of the report still works.
class DeviceDiagnostics {
  const DeviceDiagnostics({this.channelTimeout = const Duration(seconds: 10)});

  static const MethodChannel _channel = MethodChannel(
    'pdf_utility/diagnostics',
  );

  /// Upper bound on our own native `deviceInfo` call. A platform channel whose
  /// handler never calls `result` leaves the Dart future pending forever, and
  /// this step runs first — so an unbounded call here would stall the whole
  /// diagnostic before it printed a single step.
  final Duration channelTimeout;

  // Versions we ship. Kept as constants (with their source) so the report states
  // exactly what was on the device: the Dart plugin versions from `pubspec.yaml`
  // and the native ML Kit Translate version the plugin pulls in (see
  // `google_mlkit_translation-0.15.1/android/build.gradle`).
  static const String mlKitTranslationFlutterVersion = '0.15.1';
  static const String mlKitLanguageIdFlutterVersion = '0.15.1';
  static const String mlKitTranslateAndroidVersion = '17.0.3';

  /// Returns a flat map of environment facts, ready to log/display.
  Future<Map<String, Object?>> collect() async {
    final info = <String, Object?>{
      'dart_os': Platform.operatingSystem,
      'dart_os_version': Platform.operatingSystemVersion,
      'dart_locale': Platform.localeName,
      'google_mlkit_translation (flutter)': mlKitTranslationFlutterVersion,
      'google_mlkit_language_id (flutter)': mlKitLanguageIdFlutterVersion,
      'com.google.mlkit:translate (android)': mlKitTranslateAndroidVersion,
    };

    final started = Stopwatch()..start();
    try {
      final native = await _channel
          .invokeMapMethod<String, Object?>('deviceInfo')
          .timeout(channelTimeout);
      if (native != null) {
        info.addAll(native);
      } else {
        info['native_device_info'] = '(channel returned null)';
      }
    } catch (error) {
      // Reported, never fatal: the rest of the report still works without it.
      info['native_device_info'] = 'unavailable: $error';
    }
    info['native_device_info_elapsed_ms'] = started.elapsedMilliseconds;

    return info;
  }
}
