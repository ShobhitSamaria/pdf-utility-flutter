import 'translation_language.dart';

/// Identifies the language of a piece of text **on the device**.
///
/// Needed because on-device translation requires an explicit source language;
/// "Auto-detect" is implemented by resolving the source here first.
///
/// Kept as its own abstraction (rather than folded into `TranslationEngine`)
/// because identification and translation are independent ML Kit models and can
/// be faked separately in tests.
abstract class SourceLanguageDetector {
  /// Detects the dominant language of [text].
  ///
  /// Returns `null` when the language cannot be determined, or when it is not a
  /// language this app exposes. Callers decide how to report that.
  Future<TranslationLanguage?> detect(String text);

  /// Releases any native resources held by the detector.
  Future<void> dispose();
}
