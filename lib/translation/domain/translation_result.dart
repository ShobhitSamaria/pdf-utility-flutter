import 'translation_language.dart';
import 'translation_request.dart';

/// The outcome of a successful translation.
class TranslationResult {
  const TranslationResult({
    required this.originalText,
    required this.translatedText,
    required this.sourceLanguage,
    required this.targetLanguage,
    required this.scope,
    this.sourceWasAutoDetected = false,
    this.alreadyInTargetLanguage = false,
    this.elapsed,
  });

  /// The (normalized) text that was translated.
  final String originalText;

  /// The translated text, or [originalText] when nothing needed translating.
  final String translatedText;

  /// The language the text actually was — always concrete, even when the
  /// caller asked for auto-detection.
  final TranslationLanguage sourceLanguage;

  /// The language translated into.
  final TranslationLanguage targetLanguage;

  /// What was translated (selection or whole page).
  final TranslationScope scope;

  /// Whether [sourceLanguage] came from on-device language identification
  /// rather than an explicit choice.
  final bool sourceWasAutoDetected;

  /// `true` when the detected source already *was* the target language, so the
  /// text was returned unchanged instead of round-tripping through the engine.
  final bool alreadyInTargetLanguage;

  /// How long the whole operation took, if measured.
  final Duration? elapsed;

  bool get isEmpty => translatedText.trim().isEmpty;

  @override
  String toString() =>
      'TranslationResult(${sourceLanguage.code} -> '
      '${targetLanguage.code}, ${translatedText.length} chars'
      '${alreadyInTargetLanguage ? ', already target' : ''})';
}
