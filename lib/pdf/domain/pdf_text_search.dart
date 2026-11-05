import 'pdf_text_layer.dart';

/// One place a query was found: which page, what it matched, and where.
class PdfTextMatch {
  const PdfTextMatch({
    required this.pageNumber,
    required this.text,
    required this.snippet,
    required this.bounds,
  });

  /// 1-based page number to jump to.
  final int pageNumber;

  /// The matched text exactly as it appears in the document.
  final String text;

  /// A sentence fragment around the match, for the results list.
  final String snippet;

  /// Normalised box to highlight, spanning every run the match touches.
  final PdfTextBounds bounds;

  @override
  String toString() => 'PdfTextMatch(page $pageNumber, "$text")';
}

/// Finds text in a [PdfTextLayer].
///
/// Searching is a case-insensitive substring match over each page's extracted
/// text — the same operation a PDF reader performs on the layer — rather than a
/// lookup in the OCR result, so Hindi, Latin and mixed lines all go through one
/// path. Matches never span a page boundary.
class PdfTextSearch {
  const PdfTextSearch({this.maxMatches = 300});

  /// Upper bound, so a one-letter query on a 200-page scan cannot build an
  /// unbounded list in memory.
  final int maxMatches;

  List<PdfTextMatch> find(PdfTextLayer layer, String query) {
    final needle = query.trim();
    if (needle.isEmpty) return const <PdfTextMatch>[];

    final lowerNeedle = needle.toLowerCase();
    final matches = <PdfTextMatch>[];

    for (final page in layer.pages) {
      if (!page.hasText) continue;
      final text = page.text;
      final haystack = text.toLowerCase();

      var from = 0;
      while (from <= haystack.length - lowerNeedle.length) {
        final index = haystack.indexOf(lowerNeedle, from);
        if (index < 0) break;

        matches.add(
          PdfTextMatch(
            pageNumber: page.pageNumber,
            text: text.substring(index, index + needle.length),
            snippet: _snippet(text, index, needle.length),
            bounds: _boundsFor(page, text, index, needle.length),
          ),
        );
        if (matches.length >= maxMatches) return matches;
        from = index + needle.length;
      }
    }

    return matches;
  }

  /// `…the text around the match…`, with the page's whitespace collapsed so a
  /// multi-line phrase does not produce a snippet full of blank space.
  static String _snippet(String text, int index, int length) {
    const context = 42;
    final start = (index - context).clamp(0, text.length);
    final end = (index + length + context).clamp(0, text.length);
    final raw = text
        .substring(start, end)
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    return '${start > 0 ? '…' : ''}$raw${end < text.length ? '…' : ''}';
  }

  /// The union of every run that overlaps the matched character range.
  ///
  /// Page text is the runs joined by a single space, so run offsets are known
  /// exactly: a match that starts in one run and ends in the next (a Latin word
  /// beside a Devanagari one) still gets one box that covers both.
  static PdfTextBounds _boundsFor(
    PdfTextPage page,
    String pageText,
    int matchStart,
    int matchLength,
  ) {
    final matchEnd = matchStart + matchLength;
    var offset = 0;
    PdfTextBounds? box;

    for (final run in page.runs) {
      final runStart = offset;
      final runEnd = offset + run.text.length;
      // The single separating space belongs to the gap, not to either run.
      offset = runEnd + 1;

      if (runEnd <= matchStart || runStart >= matchEnd) continue;
      final runBox = PdfTextBounds(
        left: run.left,
        top: run.top,
        right: run.right,
        bottom: run.bottom,
      );
      box = box == null ? runBox : box.union(runBox);
    }

    if (box != null) return box;

    // Defensive: a match with no run (only possible if the page text and the
    // runs disagree, which they cannot by construction) highlights the top of
    // the page rather than nothing.
    return const PdfTextBounds(
      left: 0.05,
      top: 0.05,
      right: 0.95,
      bottom: 0.09,
    );
  }
}
