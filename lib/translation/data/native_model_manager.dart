import 'dart:async';

import 'package:flutter/services.dart';
import 'package:google_mlkit_translation/google_mlkit_translation.dart'
    as mlkit;

import '../domain/translation_model_manager.dart';
import '../translation_log.dart';

/// The method-channel-backed [TranslationModelManager] used on device.
///
/// Why this exists instead of calling
/// `mlkit.OnDeviceTranslatorModelManager.downloadModel` directly:
/// the plugin bridges the Play Services download `Task` straight onto the
/// platform channel with **no timeout and no retry**
/// (`GenericModelManager.kt`: `download(...).addOnSuccessListener{...}
/// .addOnFailureListener{...}`). On some devices the download `Task` simply
/// never calls back — observed on a Nothing phone (Android 16, GMS 26.36.33)
/// as `downloadModel(hi)` never returning within 120 s — and the pending Dart
/// future hangs forever behind it.
///
/// This manager fixes that with three layers:
/// 1. **Its own native channel** (`pdf_utility/model_manager`), implemented in
///    `MainActivity.kt`, which attaches an explicit per-attempt watchdog so the
///    native side answers `success` / `failed` / `timeout` even when the
///    `Task` stalls.
/// 2. **Retry**: a timed-out or failed attempt is abandoned and a *fresh*
///    download `Task` is started (up to [maxAttempts] with [retryDelay]
///    between), because a stall is often transient — and the native side
///    re-checks `isModelDownloaded` first, so an attempt that completed in the
///    background short-circuits to success.
/// 3. **A Dart-side bound** ([_attemptBound]) slightly wider than the native
///    deadline, so even a wedged native handler cannot hang the caller.
///
/// Every attempt is logged BEFORE/AFTER under `PDF_UTILITY_TRANSLATION` with
/// its raw outcome, and exhaustion throws [ModelDownloadException] carrying
/// the per-attempt truth.
///
/// If the native channel is missing (a build without `MainActivity`'s
/// handler), it transparently falls back to the plugin's own
/// `OnDeviceTranslatorModelManager` — still bounded, still no Wi-Fi gating —
/// so provisioning works either way.
class NativeModelManager implements TranslationModelManager {
  NativeModelManager({
    MethodChannel? channel,
    this.attemptTimeout = const Duration(seconds: 30),
    this.maxAttempts = 3,
    this.retryDelay = const Duration(seconds: 1),
    this.checkTimeout = const Duration(seconds: 15),
    mlkit.OnDeviceTranslatorModelManager? pluginManager,
  }) : _channel = channel ?? const MethodChannel(kChannel),
       _pluginManager = pluginManager ?? mlkit.OnDeviceTranslatorModelManager();

  /// Our own channel, implemented in `MainActivity.kt`.
  static const String kChannel = 'pdf_utility/model_manager';

  /// Methods on [kChannel].
  static const String kCheck = 'isModelDownloaded';
  static const String kDownload = 'downloadModel';

  final MethodChannel _channel;

  /// Used only when [kChannel] has no handler.
  final mlkit.OnDeviceTranslatorModelManager _pluginManager;

  /// Native-side deadline for one download attempt. The native watchdog in
  /// `MainActivity.kt` answers `timeout` when the Play Services `Task` has not
  /// completed within this budget.
  ///
  /// Deliberately shorter than the self-test's download step budget: with
  /// [maxAttempts] attempts plus [retryDelay]s, the whole worst case
  /// ([worstCaseDuration]) must fit inside one diagnostic step, so the report
  /// shows per-attempt evidence rather than one umbrella timeout.
  final Duration attemptTimeout;

  /// How many bounded attempts before giving up with [ModelDownloadException].
  final int maxAttempts;

  /// Pause between attempts (a fresh native `Task` each time).
  final Duration retryDelay;

  /// Bound for the cheap `isModelDownloaded` probe.
  final Duration checkTimeout;

  /// True once the native channel turned out to be missing and we switched to
  /// the plugin's model manager for the rest of the session.
  bool _usingPlugin = false;

  /// The Dart-side bound for one attempt: the native watchdog answers at
  /// [attemptTimeout], this extra slack only exists in case the *native
  /// handler itself* is wedged — then Dart abandons the attempt anyway.
  ///
  /// The slack is capped at [attemptTimeout] itself so short budgets (tests,
  /// diagnostics) stay short: the bound can never exceed twice the deadline.
  Duration get _attemptBound {
    const maxSlack = Duration(seconds: 5);
    final slack = attemptTimeout < maxSlack ? attemptTimeout : maxSlack;
    return attemptTimeout + slack;
  }

  /// The longest [downloadModel] can possibly take with these settings.
  Duration get worstCaseDuration =>
      _attemptBound * maxAttempts +
      retryDelay * (maxAttempts > 0 ? maxAttempts - 1 : 0);

  @override
  Future<bool> isModelDownloaded(String code) async {
    final started = DateTime.now();
    _log(
      'isModelDownloaded($code): BEFORE '
      '(timeout ${checkTimeout.inMilliseconds} ms)',
    );
    if (_usingPlugin) {
      final downloaded = await _pluginManager
          .isModelDownloaded(code)
          .timeout(checkTimeout);
      _log(
        'isModelDownloaded($code): AFTER OK → $downloaded '
        '(${_ms(started)} ms, via plugin)',
      );
      return downloaded;
    }
    try {
      final downloaded = await _channel
          .invokeMethod<bool>(kCheck, <String, Object?>{'model': code})
          .timeout(checkTimeout);
      _log(
        'isModelDownloaded($code): AFTER OK → $downloaded '
        '(${_ms(started)} ms)',
      );
      return downloaded ?? false;
    } on MissingPluginException {
      _usingPlugin = true;
      _log(
        'isModelDownloaded($code): native channel missing → '
        'falling back to the plugin model manager',
      );
      final downloaded = await _pluginManager
          .isModelDownloaded(code)
          .timeout(checkTimeout);
      _log(
        'isModelDownloaded($code): AFTER OK → $downloaded '
        '(${_ms(started)} ms, via plugin)',
      );
      return downloaded;
    }
  }

  @override
  Future<bool> downloadModel(String code) async {
    final attempts = <ModelDownloadAttempt>[];

    for (var index = 1; index <= maxAttempts; index++) {
      final stopwatch = Stopwatch()..start();
      _log(
        'downloadModel($code): attempt $index/$maxAttempts BEFORE '
        '(native deadline ${attemptTimeout.inMilliseconds} ms, '
        'bound ${_attemptBound.inMilliseconds} ms)',
      );

      final outcome = await _oneAttempt(code);
      stopwatch.stop();

      final attempt = ModelDownloadAttempt(
        index: index,
        maxAttempts: maxAttempts,
        status: outcome.status,
        error: outcome.error,
        elapsed: stopwatch.elapsed,
      );
      attempts.add(attempt);
      _log(
        'downloadModel($code): attempt $index/$maxAttempts AFTER '
        '${outcome.status.toUpperCase()} — ${attempt.describe()}',
      );

      if (outcome.status == 'success') return true;
      if (index < maxAttempts) {
        _log(
          'downloadModel($code): retrying in '
          '${retryDelay.inMilliseconds} ms…',
        );
        await Future<void>.delayed(retryDelay);
      }
    }

    final failure = ModelDownloadException(code, attempts);
    _log(
      'downloadModel($code): giving up after ${attempts.length} attempts\n'
      '${failure.summary}',
    );
    throw failure;
  }

  /// Runs exactly one bounded attempt and reports how it ended.
  ///
  /// Never throws for an expected failure mode (stall, platform error, missing
  /// channel): those become an outcome status so the retry loop can decide.
  Future<({String status, String? error})> _oneAttempt(String code) async {
    if (_usingPlugin) return _pluginAttempt(code);
    try {
      final response = await _channel
          .invokeMethod<Object?>(kDownload, <String, Object?>{
            'model': code,
            // Native watchdog deadline for this attempt.
            'timeoutMs': attemptTimeout.inMilliseconds,
            // NEVER Wi-Fi-gated (the plugin's default is `requireWifi()`,
            // which queues the download until Wi-Fi — on a cellular-only phone
            // that never proceeds, i.e. the "Preparing Hindi…" hang). The model
            // is ~30 MB and the user asked to translate, so the current
            // connection is used.
            'wifi': false,
          })
          .timeout(_attemptBound);
      if (response is! Map) {
        return (status: 'failed', error: 'unexpected native reply: $response');
      }
      final map = response.cast<Object?, Object?>();
      return (
        status: map['status']?.toString() ?? 'failed',
        error: map['error']?.toString(),
      );
    } on TimeoutException {
      return (
        status: 'timeout',
        error:
            'no answer from the native attempt within '
            '${_attemptBound.inMilliseconds} ms (the native call never '
            'returned)',
      );
    } on MissingPluginException {
      _usingPlugin = true;
      _log(
        'downloadModel($code): native channel missing → '
        'falling back to the plugin model manager',
      );
      return _pluginAttempt(code);
    } on PlatformException catch (error) {
      return (
        status: 'failed',
        error:
            'PlatformException(${error.code}): ${error.message} '
            '${error.details ?? ''}',
      );
    } catch (error) {
      return (status: 'failed', error: error.toString());
    }
  }

  /// The fallback path: the plugin's own bounded `downloadModel`.
  ///
  /// Still no Wi-Fi gating (`isWifiRequired: false` explicitly) and still
  /// bounded — it cannot outlive [attemptTimeout].
  Future<({String status, String? error})> _pluginAttempt(String code) async {
    try {
      final downloaded = await _pluginManager
          .downloadModel(code, isWifiRequired: false)
          .timeout(attemptTimeout);
      return downloaded
          ? (status: 'success', error: null)
          : (status: 'failed', error: 'plugin downloadModel returned false');
    } on TimeoutException {
      return (
        status: 'timeout',
        error:
            'the plugin download call did not return within '
            '${attemptTimeout.inMilliseconds} ms',
      );
    } on MissingPluginException {
      return (
        status: 'failed',
        error: 'no ML Kit model manager available on this device',
      );
    } on PlatformException catch (error) {
      return (
        status: 'failed',
        error:
            'PlatformException(${error.code}): ${error.message} '
            '${error.details ?? ''}',
      );
    } catch (error) {
      return (status: 'failed', error: error.toString());
    }
  }

  static int _ms(DateTime started) =>
      DateTime.now().difference(started).inMilliseconds;

  static void _log(String message) => translationLog('model: $message');
}

/// How one bounded download attempt ended.
class ModelDownloadAttempt {
  const ModelDownloadAttempt({
    required this.index,
    required this.maxAttempts,
    required this.status,
    required this.error,
    required this.elapsed,
  });

  /// 1-based attempt number.
  final int index;
  final int maxAttempts;

  /// `success`, `failed` or `timeout` — exactly what the native watchdog
  /// reported (or Dart's own bound, when the native handler never answered).
  final String status;

  /// The raw native error text (platform code/message, exception, or the
  /// watchdog's explanation). Null on success.
  final String? error;

  final Duration elapsed;

  bool get ok => status == 'success';

  String describe() =>
      'attempt $index/$maxAttempts: $status '
      '(${elapsed.inMilliseconds} ms)'
      '${error == null ? '' : '\n  $error'}';
}

/// Thrown by [NativeModelManager.downloadModel] when every bounded attempt
/// failed. Carries all per-attempt outcomes so the exact native failure (not a
/// generic sentence) reaches logs, the diagnostic screen and the UI details.
class ModelDownloadException implements Exception {
  const ModelDownloadException(this.code, this.attempts);

  /// BCP-47 code of the model that could not be provisioned.
  final String code;

  final List<ModelDownloadAttempt> attempts;

  /// One line per attempt — the per-attempt truth, in order.
  String get summary =>
      'downloadModel($code): all ${attempts.length} attempts failed\n'
      '${attempts.map((a) => a.describe()).join('\n')}';

  @override
  String toString() => 'ModelDownloadException: $summary';
}
