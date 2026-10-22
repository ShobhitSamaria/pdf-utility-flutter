import 'translation_language.dart';

/// The seam between the app and any concrete **on-device** translation backend.
///
/// Mirrors the OCR layer's `OcrEngine`/`OcrService` split: this is the pluggable
/// algorithm seam (swap ML Kit for another on-device engine), while
/// `TranslationService` is the app-facing API the UI uses.
///
/// Implementations must never contact a cloud service — the whole point is that
/// translation happens locally.
abstract class TranslationEngine {
  /// Stable, human-readable name (e.g. `"Google ML Kit (on-device)"`).
  String get name;

  /// Whether the on-device model for [language] is present and usable.
  Future<bool> isModelAvailable(TranslationLanguage language);

  /// Provisions (downloads and installs) the on-device model for [language].
  ///
  /// Implementations throw a `TranslationException` when provisioning fails so
  /// the UI can present a friendly message instead of a platform error.
  ///
  /// This is **optional**: [translate] provisions whatever it needs on demand,
  /// so callers never have to pre-download before translating. It exists for
  /// eager/warm-up flows only and must never be required for a translation to
  /// succeed.
  Future<void> downloadModel(TranslationLanguage language);

  /// Translates [text] from [source] into [target].
  ///
  /// Both languages must be concrete (no auto-detect) — resolving an unknown
  /// source is a policy decision that lives in the service layer.
  Future<String> translate({
    required String text,
    required TranslationLanguage source,
    required TranslationLanguage target,
  });

  /// Releases any native resources held by the engine.
  Future<void> dispose();
}
