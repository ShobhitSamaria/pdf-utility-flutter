import 'dart:async';

import 'package:flutter/services.dart';

import 'translation_language.dart';

/// Why a translation could not be produced.
enum TranslationErrorKind {
  /// There was no text to translate.
  emptyInput,

  /// The source language could not be determined.
  detectionFailed,

  /// The language is not one this build exposes.
  unsupportedLanguage,

  /// The source → target pair cannot be translated (e.g. target == auto).
  unsupportedPair,

  /// The on-device model could not be checked or provisioned.
  modelUnavailable,

  /// The engine itself failed while translating.
  engineFailure,
}

/// A translation failure with a **user-safe** message.
///
/// Every failure surfaces here with [userMessage] already phrased for a human —
/// no platform exception text, no ML Kit internals, no stack traces. The
/// original error is kept in [cause] for logging only.
class TranslationException implements Exception {
  const TranslationException(
    this.kind,
    this.userMessage, {
    this.cause,
    this.details,
  });

  final TranslationErrorKind kind;

  /// A short, friendly sentence that is safe to show directly in the UI.
  final String userMessage;

  /// The underlying error, for diagnostics. Never shown to the user.
  final Object? cause;

  /// Raw, human-readable diagnostic text (exception type, platform code/
  /// message/details, timing). Deliberately separate from [userMessage]: it is
  /// what gets logged and what a debug-only "Details" view surfaces, so the
  /// real cause is never lost behind a friendly sentence.
  final String? details;

  /// Whether retrying the same request could plausibly succeed.
  bool get isRetryable =>
      kind != TranslationErrorKind.emptyInput &&
      kind != TranslationErrorKind.unsupportedPair &&
      kind != TranslationErrorKind.unsupportedLanguage;

  /// Convenience factory for "we don't know this language".
  factory TranslationException.unsupportedLanguage(
    TranslationLanguage language,
  ) => TranslationException(
    TranslationErrorKind.unsupportedLanguage,
    '${language.englishName} is not available on this device yet.',
  );

  @override
  String toString() =>
      'TranslationException(${kind.name}): $userMessage'
      '${cause == null ? '' : ' [cause: $cause]'}';

  /// Builds diagnostic [details] for [error] (and optional [stack]).
  ///
  /// Kept here so every layer describes a failure the same way — including the
  /// `PlatformException` code/message/details that ML Kit returns, which is the
  /// single most useful thing to see when a model download fails on a device.
  static String describe(Object error, [StackTrace? stack]) {
    final buffer = StringBuffer('${error.runtimeType}: $error');
    final platform = error;
    if (platform is PlatformException) {
      buffer
        ..write('\n  platform.code: ${platform.code}')
        ..write('\n  platform.message: ${platform.message}')
        ..write('\n  platform.details: ${platform.details}');
    }
    if (error is TimeoutException) {
      buffer.write('\n  timed out after ${error.duration}');
    }
    if (error is TranslationException && error.details != null) {
      buffer.write('\n${error.details}');
    }
    if (stack != null) buffer.write('\n$stack');
    return buffer.toString();
  }
}
