import 'dart:math' as math;

/// The size of one page in a PDF this app creates, in PostScript points
/// (1/72 inch).
///
/// Deliberately a plain value object rather than a `PdfPageFormat`: the rule for
/// "how big is a page for an image of this size" is arithmetic worth testing on
/// its own, and the PDF library that consumes it is an implementation detail of
/// the data layer.
class PdfPageSize {
  const PdfPageSize(this.width, this.height);

  /// Page width in points.
  final double width;

  /// Page height in points.
  final double height;

  double get aspectRatio => height == 0 ? 1 : width / height;

  @override
  bool operator ==(Object other) =>
      other is PdfPageSize && other.width == width && other.height == height;

  @override
  int get hashCode => Object.hash(width, height);

  @override
  String toString() =>
      'PdfPageSize(${width.toStringAsFixed(1)}x${height.toStringAsFixed(1)} pt)';
}

/// How a captured or chosen image becomes a page.
///
/// One rule, in one place: **fit the image inside the page box without changing
/// its shape.** A phone photo is not A4, so a fixed A4 page would either squash
/// the picture or leave bands; instead the page takes the image's own aspect
/// ratio and the longest edge is scaled to [A4]'s longest edge.
///
/// The result is a document that looks like the photos on screen (same
/// proportions, no crops, no stretch) at a sensible printed size — and a page
/// count that matches what the user reviewed.
class PdfPageLayout {
  const PdfPageLayout._();

  /// A4 in points — the reference box every page is fitted into.
  static const double a4Width = 595.276;
  static const double a4Height = 841.89;

  /// The page size for an image of [pixelWidth] × [pixelHeight] pixels.
  ///
  /// Degenerate input (a zero or negative dimension, as a corrupt header can
  /// report) falls back to A4 rather than producing a zero-sized page, which no
  /// viewer accepts.
  static PdfPageSize forPixels(int pixelWidth, int pixelHeight) {
    if (pixelWidth <= 0 || pixelHeight <= 0) {
      return const PdfPageSize(a4Width, a4Height);
    }

    final longestEdge = math.max(pixelWidth, pixelHeight).toDouble();
    final scale = a4Height / longestEdge;
    final width = pixelWidth * scale;
    final height = pixelHeight * scale;

    // A hair-thin edge would round to zero pages in some viewers; keep both
    // dimensions inside the page box at all times.
    return PdfPageSize(
      math.min(math.max(width, 1), a4Height),
      math.min(math.max(height, 1), a4Height),
    );
  }
}
