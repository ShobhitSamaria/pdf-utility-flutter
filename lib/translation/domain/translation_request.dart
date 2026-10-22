import 'translation_language.dart';
import 'translation_text.dart';

/// What the user asked to have translated.
///
/// Knowing the [scope] lets the UI phrase itself correctly ("Translating
/// selection…" vs "Translating page…") without the domain caring about screen
/// layout.
enum TranslationScope {
  /// The text the user selected on the OCR result.
  selection,

  /// The full text of the recognized page.
  wholePage,
}

/// An immutable request to translate [text] from [source] into [target].
///
/// [source] may be [TranslationLanguages.auto]; resolving it is the service's
/// job. [target] must be a concrete language.
class TranslationRequest {
  const TranslationRequest({
    required this.text,
    required this.source,
    required this.target,
    this.scope = TranslationScope.selection,
  });

  /// Translates text the user selected on the OCR result.
  factory TranslationRequest.selection({
    required String text,
    TranslationLanguage source = TranslationLanguages.defaultSource,
    TranslationLanguage target = TranslationLanguages.defaultTarget,
  }) => TranslationRequest(
    text: text,
    source: source,
    target: target,
    scope: TranslationScope.selection,
  );

  /// Translates the whole recognized page.
  factory TranslationRequest.wholePage({
    required String pageText,
    TranslationLanguage source = TranslationLanguages.defaultSource,
    TranslationLanguage target = TranslationLanguages.defaultTarget,
  }) => TranslationRequest(
    text: pageText,
    source: source,
    target: target,
    scope: TranslationScope.wholePage,
  );

  /// Raw text to translate (may contain surrounding whitespace / blank lines).
  final String text;

  /// Where the text came from.
  final TranslationScope scope;

  /// Source language, or [TranslationLanguages.auto] to detect it.
  final TranslationLanguage source;

  /// Target language. Must be concrete.
  final TranslationLanguage target;

  /// The text as it should be handed to the engine.
  String get normalizedText => TranslationText.normalize(text);

  /// Whether there is anything to translate.
  bool get isEmpty => !TranslationText.isTranslatable(text);

  bool get isAutoSource => source.isAuto;

  TranslationRequest copyWith({
    String? text,
    TranslationScope? scope,
    TranslationLanguage? source,
    TranslationLanguage? target,
  }) => TranslationRequest(
    text: text ?? this.text,
    scope: scope ?? this.scope,
    source: source ?? this.source,
    target: target ?? this.target,
  );

  @override
  bool operator ==(Object other) =>
      other is TranslationRequest &&
      other.text == text &&
      other.scope == scope &&
      other.source == source &&
      other.target == target;

  @override
  int get hashCode => Object.hash(text, scope, source, target);

  @override
  String toString() =>
      'TranslationRequest(${scope.name}: '
      '"${source.code}" -> "${target.code}", '
      '${normalizedText.length} chars)';
}
