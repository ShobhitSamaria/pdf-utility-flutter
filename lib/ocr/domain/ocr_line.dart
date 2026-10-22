import 'ocr_element.dart';
import 'ocr_rect.dart';

/// A recognized **line** of text composed of one or more [OcrElement]s.
class OcrLine {
  const OcrLine({
    required this.text,
    required this.boundingBox,
    required this.elements,
    this.confidence,
    this.angle,
    this.recognizedLanguages = const <String>[],
  });

  /// Full text of the line as reported by the engine.
  final String text;

  /// Line geometry in source-image pixels.
  final OcrRect boundingBox;

  /// The words that make up this line, left-to-right.
  final List<OcrElement> elements;

  /// Confidence in `[0, 1]`, or `null` when unavailable.
  final double? confidence;

  /// Baseline rotation of the line in degrees (Android only), or `null`.
  final double? angle;

  final List<String> recognizedLanguages;

  OcrLine copyWith({
    String? text,
    OcrRect? boundingBox,
    List<OcrElement>? elements,
    double? confidence,
    double? angle,
    List<String>? recognizedLanguages,
  }) => OcrLine(
    text: text ?? this.text,
    boundingBox: boundingBox ?? this.boundingBox,
    elements: elements ?? this.elements,
    confidence: confidence ?? this.confidence,
    angle: angle ?? this.angle,
    recognizedLanguages: recognizedLanguages ?? this.recognizedLanguages,
  );

  @override
  String toString() => 'OcrLine("$text", ${elements.length} words)';
}
