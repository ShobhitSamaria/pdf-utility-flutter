import 'ocr_rect.dart';

/// A single recognized **word** (ML Kit calls this a "text element").
///
/// This is the finest-grained unit the overlay needs. Later features (word
/// selection, copy, search, Hindi translation) will operate on these:
///
/// * **Selection** — hit-test the tap/drag position against [boundingBox] to
///   find the word under the finger.
/// * **Copy** — join selected [text] values.
/// * **Search** — filter elements whose [text] matches a query.
/// * **Translation** — batch the selected [text] values into the translator
///   and render a replacement overlay at the same [boundingBox].
///
/// All geometry is in source-image pixel coordinates (see [OcrRect]).
class OcrElement {
  const OcrElement({
    required this.text,
    required this.boundingBox,
    this.confidence,
    this.recognizedLanguages = const <String>[],
  });

  /// The word text. May contain surrounding whitespace as ML Kit reports it.
  final String text;

  /// Word geometry in source-image pixels.
  final OcrRect boundingBox;

  /// Recognition confidence in `[0, 1]`, or `null` when the platform does not
  /// report it (ML Kit returns `null` for this on iOS).
  final double? confidence;

  /// BCP-47-ish language tags reported for this element (Android only).
  final List<String> recognizedLanguages;

  /// Trimmed text, convenient for copy/search/translation.
  String get trimmedText => text.trim();

  OcrElement copyWith({
    String? text,
    OcrRect? boundingBox,
    double? confidence,
    List<String>? recognizedLanguages,
  }) => OcrElement(
    text: text ?? this.text,
    boundingBox: boundingBox ?? this.boundingBox,
    confidence: confidence ?? this.confidence,
    recognizedLanguages: recognizedLanguages ?? this.recognizedLanguages,
  );

  /// Value equality so selections can use sets/membership safely even when the
  /// same word is referenced through different object instances.
  @override
  bool operator ==(Object other) =>
      other is OcrElement &&
      other.text == text &&
      other.boundingBox == boundingBox;

  @override
  int get hashCode => Object.hash(text, boundingBox);

  @override
  String toString() => 'OcrElement("$text", $boundingBox)';
}
