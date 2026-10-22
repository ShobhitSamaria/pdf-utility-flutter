/// One PDF page, rasterised to an image file the OCR layer can read.
///
/// [imagePath] is a real image on disk rather than an in-memory bitmap: the OCR
/// engine takes a file path, and the result screen re-reads the same file when
/// the user re-runs with another script.
class RenderedPdfPage {
  const RenderedPdfPage({
    required this.pageNumber,
    required this.imagePath,
    required this.width,
    required this.height,
    this.elapsed,
  });

  /// Page number in the document, 1-based.
  final int pageNumber;

  /// Absolute path of the rasterised PNG.
  final String imagePath;

  /// Pixel width/height of the rasterised image.
  final int width;
  final int height;

  /// How long the render took, when measured.
  final Duration? elapsed;

  double get aspectRatio => height == 0 ? 1 : width / height;

  @override
  String toString() =>
      'RenderedPdfPage($pageNumber, ${width}x$height, "$imagePath")';
}
