/// One occurrence of a query inside a piece of text.
class OcrTextMatch {
  const OcrTextMatch(this.start, this.end);

  /// Index of the first character, inclusive.
  final int start;

  /// Index just past the last character, exclusive.
  final int end;

  int get length => end - start;

  @override
  bool operator ==(Object other) =>
      other is OcrTextMatch && other.start == start && other.end == end;

  @override
  int get hashCode => Object.hash(start, end);

  @override
  String toString() => 'OcrTextMatch($start..$end)';
}

/// Finds every occurrence of a query in a string, case-insensitively.
///
/// This is the search behind the **readable text view**, which is a different
/// surface from the find-on-photo search in `OcrDocumentSearch`: that one works
/// on words and maps a hit back to a bounding box, this one works on the flat
/// text as text. Keeping them separate is deliberate — a line can be searched
/// here even where OCR produced no usable word geometry.
///
/// Case folding is applied to both sides with `String.toLowerCase`, which is
/// locale-independent simple case mapping — it does not expand a character into
/// several, so offsets from the folded string line up with the rendered text.
/// The check below is the guard for the case where that stops being true: if
/// folding ever changes a string's length, the search matches verbatim instead
/// of reporting offsets that point at the wrong characters. Devanagari has no
/// case, so Hindi is unaffected either way.
///
/// This performs **no Unicode normalization** — there is no normalizer in the
/// Dart core libraries and this phase adds no dependency. A query written with a
/// precomposed character will not match a decomposed one, or vice versa. That is
/// a real limitation, documented rather than papered over.
class OcrTextFinder {
  const OcrTextFinder({this.maxMatches = 500});

  /// Upper bound on matches collected, so a pathological query (a single common
  /// letter on a long page) cannot build an unbounded list on the UI thread.
  final int maxMatches;

  /// All occurrences of [query] in [text], in order. Empty when there is nothing
  /// to find.
  List<OcrTextMatch> findIn(String text, String query) {
    if (text.isEmpty || query.isEmpty) return const <OcrTextMatch>[];

    final foldedText = text.toLowerCase();
    final foldedQuery = query.toLowerCase();
    // Offsets from a length-changing fold would point at the wrong characters
    // in the string we actually render, so match the original in that case.
    final safeToFold =
        foldedText.length == text.length && foldedQuery.length == query.length;
    final haystack = safeToFold ? foldedText : text;
    final needle = safeToFold ? foldedQuery : query;

    final matches = <OcrTextMatch>[];
    var index = haystack.indexOf(needle);
    while (index != -1 && matches.length < maxMatches) {
      matches.add(OcrTextMatch(index, index + needle.length));
      index = haystack.indexOf(needle, index + needle.length);
    }
    return matches;
  }
}
