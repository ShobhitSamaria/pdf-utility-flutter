import 'ocr_line.dart';
import 'ocr_rect.dart';

/// A recognized **block** of text — typically a paragraph or a column region —
/// composed of one or more [OcrLine]s.
class OcrBlock {
  const OcrBlock({
    required this.text,
    required this.boundingBox,
    required this.lines,
    this.recognizedLanguages = const <String>[],
  });

  /// Full text of the block.
  final String text;

  /// Block geometry in source-image pixels.
  final OcrRect boundingBox;

  /// The lines that make up this block, top-to-bottom.
  final List<OcrLine> lines;

  final List<String> recognizedLanguages;

  OcrBlock copyWith({
    String? text,
    OcrRect? boundingBox,
    List<OcrLine>? lines,
    List<String>? recognizedLanguages,
  }) => OcrBlock(
    text: text ?? this.text,
    boundingBox: boundingBox ?? this.boundingBox,
    lines: lines ?? this.lines,
    recognizedLanguages: recognizedLanguages ?? this.recognizedLanguages,
  );

  @override
  String toString() => 'OcrBlock("$text", ${lines.length} lines)';
}
