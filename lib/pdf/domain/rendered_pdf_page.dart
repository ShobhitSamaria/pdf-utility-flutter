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
    this.pageWidth = 0,
    this.pageHeight = 0,
    this.elapsed,
  });

  /// Page number in the document, 1-based.
  final int pageNumber;

  /// Absolute path of the rasterised PNG.
  final String imagePath;

  /// Pixel width/height of the rasterised image.
  final int width;
  final int height;

  /// The page's own size in PostScript points, as the PDF declares it.
  ///
  /// Carried separately from the pixel size because it is the document's real
  /// geometry: a landscape page stays landscape when the output page is built
  /// from these, not from a pixel count re-fitted to a portrait box.
  final double pageWidth;
  final double pageHeight;

  /// Whether the source declared a usable page size.
  bool get hasPageSize => pageWidth > 0 && pageHeight > 0;

  /// Whether the printed page is wider than it is tall.
  bool get isLandscape => pageWidth > pageHeight;

  /// How long the render took, when measured.
  final Duration? elapsed;

  double get aspectRatio => height == 0 ? 1 : width / height;

  @override
  String toString() =>
      'RenderedPdfPage($pageNumber, ${width}x$height, "$imagePath")';
}
