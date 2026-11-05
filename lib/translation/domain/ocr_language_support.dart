import '../../ocr/domain/ocr_capabilities.dart';
import 'language_script.dart';
import 'translation_language.dart';

/// Which languages a **photograph** can bring into the translator.
///
/// Translating and reading are two different capabilities, and the app has them
/// in different amounts. The on-device translation models cover every language in
/// `TranslationLanguages.all` (Hindi, Tamil, Telugu, Bengali, Urdu, Thai …), but a
/// photograph can only be *read* by the recognizers actually packaged in the
/// build ([OcrCapabilities.bundledScripts] — Latin and Devanagari today).
///
/// The failure this prevents is a silent one: with the source language set to
/// Tamil, the Latin probe returns character soup, the Devanagari probe returns
/// nothing, and the user is told "no text found" — as if their page were blank or
/// blurred. It was not; its script has no recognizer in the app. Answering
/// [canRead] honestly is what lets the UI say so instead of blaming the photo.
///
/// Nothing here guesses at a language from pixels: an image-level script detector
/// does not exist in ML Kit, so this is a *capability* question about the language
/// the user chose, not a claim that a given page contains it.
abstract final class OcrLanguageSupport {
  /// Whether a photo of [language]'s script can be recognised by this build.
  static bool canRead(TranslationLanguage language) {
    if (!language.isConcrete) return false;
    final family = LanguageScript.groupOf(language);
    if (family == null) return false;
    return OcrCapabilities.canReadFamily(family);
  }

  /// The languages a photo can actually supply, in registry order.
  ///
  /// Deliberately derived, not hand-written: adding the Tamil recognizer artifact
  /// and its [OcrCapabilities] entry makes Tamil appear here with no other edit.
  static List<TranslationLanguage> readableSources() => <TranslationLanguage>[
    for (final language in TranslationLanguages.all)
      if (canRead(language)) language,
  ];

  /// Why [language] cannot be read from a photo, or `null` when it can.
  static String? limitationFor(TranslationLanguage language) {
    if (canRead(language)) return null;
    return '${language.englishName} text cannot be read from a photo in this '
        'build: on-device recognition covers ${OcrCapabilities.bundledLabel} '
        'only. Anything already recognised can still be translated.';
  }
}
