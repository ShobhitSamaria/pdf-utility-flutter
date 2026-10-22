import 'translated_region.dart';
import 'translation_language.dart';
import 'translation_model_state.dart';
import 'translation_request.dart';
import 'translation_result.dart';

/// App-facing translation API.
///
/// This is the ONLY translation type the UI layer references. It hides the
/// engine choice, language detection, and model provisioning so screens never
/// import an ML Kit package and swapping engines is a one-line change in the
/// composition root (`lib/main.dart`).
abstract class TranslationService {
  /// Name of the underlying engine (for diagnostics/UI).
  String get engineName;

  /// Source options offered by the UI, including auto-detect.
  List<TranslationLanguage> get sourceLanguages;

  /// Target languages offered by the UI.
  List<TranslationLanguage> get targetLanguages;

  /// The language selected by default for new translations (Hindi).
  TranslationLanguage get defaultTargetLanguage;

  /// Current on-device model availability for a single [language].
  ///
  /// Never throws: unresolved states are reported through
  /// [TranslationModelState.status].
  Future<TranslationModelState> modelState(TranslationLanguage language);

  /// Detects the language of [text] **on the device**, or returns `null` when
  /// there is not enough evidence.
  ///
  /// Used to preselect a source language before the user presses Translate, and
  /// to explain a detection failure without leaving the page. Never throws: a
  /// detector that is unsure, unsupported or unavailable simply answers `null`.
  ///
  /// This is *not* on the translation path when the source is chosen
  /// explicitly — an explicit choice must never be second-guessed by a
  /// classifier.
  Future<TranslationLanguage?> detectSource(String text);

  /// Translates [request] entirely on the device.
  ///
  /// Responsibilities:
  /// * resolves an auto-detect source via language identification,
  /// * reports coarse [TranslationProgress] ticks through [onProgress] (the
  ///   on-device models are fetched by the engine during translation itself,
  ///   so there is no separate, blocking download step),
  /// * throws a `TranslationException` with a user-safe message on failure.
  Future<TranslationResult> translate(
    TranslationRequest request, {
    void Function(TranslationProgress progress)? onProgress,
  });

  /// Translates several image regions in one batch, keeping a strict 1:1
  /// mapping between [units] and the returned regions (ids and order included).
  ///
  /// This is what the on-image overlay uses. Language detection and model
  /// provisioning happen **at most once per batch**, so an entire page costs one
  /// round of each no matter how many lines it has, and each region is
  /// translated on its own so a line's translation can be placed back onto that
  /// line instead of collapsing into one paragraph.
  ///
  /// Units with blank text are skipped (they cannot be translated or drawn).
  /// If every unit is blank this throws a `TranslationException`.
  Future<TranslatedOverlay> translateRegions(
    List<TranslationUnit> units, {
    TranslationLanguage source = TranslationLanguages.defaultSource,
    required TranslationLanguage target,
    void Function(TranslationProgress progress)? onProgress,
  });

  /// Releases native resources.
  Future<void> dispose();
}
