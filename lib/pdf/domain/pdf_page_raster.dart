import 'dart:math' as math;

/// The pixel size a PDF page is rasterised at before OCR.
///
/// This is the only place that decides it, and it is pure arithmetic on purpose:
/// the resolution is what decides whether small print is recognised at all, so it
/// should be inspectable and testable rather than a magic number buried in a
/// platform call.
///
/// The rules come from how ML Kit behaves:
/// * **Width is the target.** Text recognition needs roughly 16–20 px of height
///   per line of text to be reliable, which a page rendered ~1600 px wide gives
///   for normal body text. Rendering at the PDF's native 72 dpi (a 595 × 842
///   point A4 page) is far too coarse — that is the state the PDF arrived in, and
///   is exactly why a page has to be re-rasterised rather than handed over as-is.
/// * **Height is capped.** A page cannot be allowed to run away: a tall page at
///   a fixed width is a large bitmap in memory (4 bytes per pixel before
///   compression), and the OCR engine's own buffers are not free either.
/// * **Aspect ratio is never distorted**, so a page that hits the height cap is
///   scaled uniformly and simply ends up narrower.
class PdfPageRaster {
  const PdfPageRaster(this.width, this.height);

  /// Rasterised width in pixels.
  final int width;

  /// Rasterised height in pixels.
  final int height;

  /// Target width for a normal page: enough resolution for body text, small
  /// enough to stay comfortable on a mid-range device.
  static const int defaultMaxWidth = 1600;

  /// Hard cap on height, so an unusually long page stays affordable.
  static const int defaultMaxHeight = 2400;

  /// The size to rasterise a page that measures [pageWidth] × [pageHeight]
  /// points (the units `PdfPage.width`/`height` are in).
  ///
  /// Degenerate pages fall back to a plain [defaultMaxWidth] square rather than
  /// producing a zero-sized bitmap.
  static PdfPageRaster forPage({
    required double pageWidth,
    required double pageHeight,
    int maxWidth = defaultMaxWidth,
    int maxHeight = defaultMaxHeight,
  }) {
    if (pageWidth <= 0 || pageHeight <= 0 || maxWidth <= 0 || maxHeight <= 0) {
      return const PdfPageRaster(defaultMaxWidth, defaultMaxWidth);
    }

    final scale = math.min(maxWidth / pageWidth, maxHeight / pageHeight);
    return PdfPageRaster(
      math.max(1, (pageWidth * scale).round()),
      math.max(1, (pageHeight * scale).round()),
    );
  }

  /// Width ÷ height, matching the page's own ratio.
  double get aspectRatio => height == 0 ? 1 : width / height;

  /// Rough uncompressed size, for diagnostics and memory-aware decisions.
  int get pixelCount => width * height;

  @override
  bool operator ==(Object other) =>
      other is PdfPageRaster && other.width == width && other.height == height;

  @override
  int get hashCode => Object.hash(width, height);

  @override
  String toString() => 'PdfPageRaster(${width}x$height)';
}
