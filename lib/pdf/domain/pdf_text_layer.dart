import 'dart:math' as math;
import 'dart:ui' show Rect, Size;

/// One run of text read back out of a PDF's **own text layer**.
///
/// Coordinates are normalised to the page (`0..1`, origin top-left), so a
/// viewer can place a highlight over a rendered page without knowing its pixel
/// size. The run is the smallest useful unit: PDF writers emit a line as one or
/// more show-text operations, and a line that mixes scripts is several runs.
class PdfTextRun {
  const PdfTextRun({
    required this.text,
    required this.left,
    required this.top,
    required this.right,
    required this.bottom,
  });

  /// The visible characters, already mapped through the font's ToUnicode CMap.
  final String text;

  /// Normalised bounds, origin top-left, all in `0..1`.
  final double left;
  final double top;
  final double right;
  final double bottom;

  double get width => right - left;
  double get height => bottom - top;

  bool get isEmpty => text.trim().isEmpty;

  /// Whether two runs sit on the same printed line, judged by vertical overlap.
  bool onSameLineAs(PdfTextRun other) {
    final overlap = math.min(bottom, other.bottom) - math.max(top, other.top);
    final shortest = math.min(height, other.height);
    return shortest > 0 && overlap > shortest * 0.5;
  }

  PdfTextRun copyWith({String? text}) => PdfTextRun(
    text: text ?? this.text,
    left: left,
    top: top,
    right: right,
    bottom: bottom,
  );

  @override
  String toString() =>
      'PdfTextRun("${text.length > 24 ? '${text.substring(0, 24)}…' : text}", '
      '${left.toStringAsFixed(3)},${top.toStringAsFixed(3)})';
}

/// A rectangle on a page, normalised the same way as a [PdfTextRun].
class PdfTextBounds {
  const PdfTextBounds({
    required this.left,
    required this.top,
    required this.right,
    required this.bottom,
  });

  final double left;
  final double top;
  final double right;
  final double bottom;

  double get width => right - left;
  double get height => bottom - top;

  /// Smallest box covering both inputs — used to turn the several runs a match
  /// spans into the one rectangle worth highlighting.
  PdfTextBounds union(PdfTextBounds other) => PdfTextBounds(
    left: math.min(left, other.left),
    top: math.min(top, other.top),
    right: math.max(right, other.right),
    bottom: math.max(bottom, other.bottom),
  );

  PdfTextBounds inflate(double amount) => PdfTextBounds(
    left: left - amount,
    top: top - amount,
    right: right + amount,
    bottom: bottom + amount,
  );

  /// These normalised bounds as a rectangle on a page of [pageSize].
  ///
  /// The unit cancels: the layer is stored as fractions, so the same box is
  /// right on a 595 × 842 pt page and on any pixel-sized render of it. Values
  /// are clamped to the page, and the rectangle is normalised so a reader that
  /// returns right < left cannot produce a negative width.
  ///
  /// The page is the coordinate system here — not the screen. A caller that
  /// puts this rectangle inside a widget the size of the page gets a highlight
  /// that follows that widget through scrolling, zooming and panning, because
  /// it is drawn in the page's own space rather than the viewport's.
  Rect rectOn(Size pageSize, {double inflate = 0}) {
    final width = pageSize.width;
    final height = pageSize.height;
    if (width <= 0 || height <= 0) return Rect.zero;

    final boxLeft = math.min(left, right) * width;
    final boxTop = math.min(top, bottom) * height;
    final boxRight = math.max(left, right) * width;
    final boxBottom = math.max(top, bottom) * height;

    return Rect.fromLTRB(
      (boxLeft - inflate).clamp(0.0, width),
      (boxTop - inflate).clamp(0.0, height),
      (boxRight + inflate).clamp(0.0, width),
      (boxBottom + inflate).clamp(0.0, height),
    );
  }

  @override
  String toString() =>
      'PdfTextBounds(${left.toStringAsFixed(3)}, ${top.toStringAsFixed(3)}, '
      '${right.toStringAsFixed(3)}, ${bottom.toStringAsFixed(3)})';
}

/// The text layer of one page, with its page geometry in PostScript points.
///
/// [width] and [height] are the page's own dimensions, so a landscape page in a
/// mixed document stays landscape in the viewer's highlight maths.
class PdfTextPage {
  const PdfTextPage({
    required this.pageNumber,
    required this.width,
    required this.height,
    required this.runs,
  });

  /// 1-based, matching what the rest of the app calls a page number.
  final int pageNumber;

  /// Page width in points, as the PDF declares it.
  final double width;

  /// Page height in points.
  final double height;

  /// Every text run on the page, in the order the content stream draws them.
  final List<PdfTextRun> runs;

  bool get hasText => runs.any((run) => !run.isEmpty);

  /// The page's text, one run after another. Runs are separated by a space so a
  /// phrase split across two runs (a script change mid-line) still reads as one.
  String get text => runs.map((run) => run.text).join(' ');

  double get aspectRatio => height == 0 ? 1 : width / height;

  /// Whether the page is wider than it is tall — the definition of landscape
  /// used for the whole app.
  bool get isLandscape => width > height;

  @override
  String toString() =>
      'PdfTextPage($pageNumber, ${width.toStringAsFixed(1)}x'
      '${height.toStringAsFixed(1)} pt, ${runs.length} runs)';
}

/// A PDF's searchable text, page by page, read from the file itself.
///
/// This is deliberately **not** a cache of the OCR result: it is produced by
/// parsing the generated PDF's content streams and font maps, so what is
/// searched is exactly the layer a desktop viewer would search after the file is
/// shared.
class PdfTextLayer {
  const PdfTextLayer({required this.pages});

  final List<PdfTextPage> pages;

  int get pageCount => pages.length;

  int get runCount => pages.fold(0, (sum, page) => sum + page.runs.length);

  bool get isEmpty => pages.every((page) => !page.hasText);

  PdfTextPage? page(int pageNumber) {
    for (final page in pages) {
      if (page.pageNumber == pageNumber) return page;
    }
    return null;
  }

  /// The whole document's text, pages separated by a newline.
  String get text => pages.map((page) => page.text).join('\n');

  @override
  String toString() => 'PdfTextLayer($pageCount pages, $runCount runs)';
}
