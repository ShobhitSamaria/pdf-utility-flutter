import 'document_orientation.dart';
import 'ocr_block.dart';
import 'ocr_element.dart';
import 'ocr_line.dart';

/// Immutable description of the image that was recognized.
///
/// [width] / [height] are the **decoded, upright** pixel dimensions of the
/// image. Every rectangle in an [OcrResult] is expressed in this coordinate
/// space, so the UI can map image pixels → screen pixels with a single uniform
/// scale factor (see `OcrCoordinateMapper`).
class SourceImageInfo {
  const SourceImageInfo({
    required this.path,
    required this.width,
    required this.height,
  });

  /// Absolute file path of the (possibly temporarily copied) image on disk.
  final String path;

  /// Upright pixel width of the source image.
  final int width;

  /// Upright pixel height of the source image.
  final int height;

  double get aspectRatio => height == 0 ? 1 : width / height;

  @override
  String toString() => 'SourceImageInfo($width x $height, "$path")';
}

/// The complete, engine-agnostic result of an OCR run.
class OcrResult {
  const OcrResult({
    required this.sourceImage,
    required this.fullText,
    required this.blocks,
    this.engineName = 'unknown',
    this.elapsed,
    this.orientation = DocumentOrientation.upright,
  });

  /// The image these coordinates belong to.
  final SourceImageInfo sourceImage;

  /// All recognized text joined by the engine (blocks separated by newlines).
  final String fullText;

  /// Structured results: blocks → lines → elements (words).
  final List<OcrBlock> blocks;

  /// Human-readable engine identifier, handy for debugging/logging.
  final String engineName;

  /// How long recognition took, if measured.
  final Duration? elapsed;

  /// How far the page was turned before it was read.
  ///
  /// Reported so the UI and tests can tell a straight read from a corrected
  /// one. [sourceImage] always describes the **upright** image that was read and
  /// is shown, so every rectangle here is already in an upright frame — this is
  /// history, not a transform waiting to be applied.
  final DocumentOrientation orientation;

  /// Whether the pixels had to be turned to read the page.
  bool get wasRotated => !orientation.isUpright;

  /// Convenience: all lines across all blocks.
  List<OcrLine> get lines => [for (final block in blocks) ...block.lines];

  /// Copy with selected fields replaced.
  ///
  /// Used by the Auto script router, which has to relabel a result it accepted
  /// unchanged (so the summary strip can say which recognizer Auto picked) and
  /// stamp the **total** wall-clock time onto a pass that only measured itself.
  OcrResult copyWith({
    SourceImageInfo? sourceImage,
    String? fullText,
    List<OcrBlock>? blocks,
    String? engineName,
    Duration? elapsed,
    DocumentOrientation? orientation,
  }) => OcrResult(
    sourceImage: sourceImage ?? this.sourceImage,
    fullText: fullText ?? this.fullText,
    blocks: blocks ?? this.blocks,
    engineName: engineName ?? this.engineName,
    elapsed: elapsed ?? this.elapsed,
    orientation: orientation ?? this.orientation,
  );

  /// Convenience: all words across all blocks, in reading order. This is the
  /// primary collection future features (selection/copy/search/translate) use.
  List<OcrElement> get elements => [for (final line in lines) ...line.elements];

  bool get isEmpty => blocks.isEmpty;

  /// Returns the top-most word whose bounding box contains [point] (image
  /// coordinates). Returns `null` when the point is not over any word.
  ///
  /// Ties are broken by preferring the smallest matching box, which keeps
  /// hit-testing accurate where words overlap.
  OcrElement? elementAt(OffsetInImage point) {
    OcrElement? best;
    double? bestArea;
    for (final element in elements) {
      final box = element.boundingBox;
      if (point.dx < box.left ||
          point.dx > box.right ||
          point.dy < box.top ||
          point.dy > box.bottom) {
        continue;
      }
      final area = box.width * box.height;
      if (bestArea == null || area < bestArea) {
        best = element;
        bestArea = area;
      }
    }
    return best;
  }

  @override
  String toString() =>
      'OcrResult(engine: $engineName, ${blocks.length} blocks, '
      '${elements.length} words, ${sourceImage.width}x${sourceImage.height})';
}

/// Minimal image-space point, decoupled from Flutter's `Offset` so the domain
/// layer stays framework-free and unit-testable.
class OffsetInImage {
  const OffsetInImage(this.dx, this.dy);

  final double dx;
  final double dy;

  @override
  String toString() => 'OffsetInImage($dx, $dy)';
}
