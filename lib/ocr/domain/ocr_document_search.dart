import 'ocr_element.dart';
import 'ocr_result.dart';
import 'ocr_text_utils.dart';

/// One occurrence of a query inside the recognized document.
///
/// A hit is a **range of words**, not just a pair of offsets: the overlay
/// highlights words, and the selection model is word-based, so a match has to
/// resolve to specific [OcrElement]s. That is what lets search reuse the
/// existing selection highlight instead of introducing a second way of drawing
/// over the photo.
class OcrSearchHit {
  const OcrSearchHit({
    required this.elements,
    required this.matchedText,
    required this.start,
    required this.end,
  });

  /// The words the occurrence covers, in reading order. May be a single word
  /// for an intra-word match.
  final List<OcrElement> elements;

  /// The exact text that matched, as it appears in the document.
  final String matchedText;

  /// Inclusive start offset of the match in `documentText`.
  final int start;

  /// Exclusive end offset of the match in `documentText`.
  final int end;

  @override
  String toString() =>
      'OcrSearchHit("$matchedText" @ $start..$end, ${elements.length} words)';
}

/// Case-insensitive search across the words of one [OcrResult].
///
/// What "the document" means here
/// ------------------------------
/// The searched text is the recognized words joined by single spaces — the same
/// rendering `OcrSelection.text` produces and the same collection the overlay
/// renders and hit-tests. That choice is deliberate: it means a match always
/// corresponds to something the user can see and select, and it keeps search,
/// selection and highlighting on one representation. The trade-off is that a
/// phrase will also match across a line break, because block and line structure
/// is not part of the searched text.
///
/// Case folding and Unicode, honestly
/// ----------------------------------
/// Matching lower-cases both sides. For Devanagari that is a no-op, which is
/// correct — the script has no case. Two boundaries are handled explicitly so a
/// match never lands somewhere meaningless:
///
/// * A match may not **begin** on a low surrogate, which would split an astral
///   code point in half. Such a candidate is skipped.
/// * A match is **extended** across trailing combining marks, Devanagari
///   vowel signs/virama/nukta, and variation selectors, so `क` does not match
///   the base of `कि` and leave the matra behind.
///
/// **No Unicode normalization is applied.** Dart's core library ships no
/// normalizer and this phase adds no dependency, so a composed form
/// (`क़` as U+0958) will not match its decomposed form (`क` + U+093C). The
/// matching logic is confined to this one class so adding normalization later
/// is a change here and nowhere else.
class OcrDocumentSearch {
  OcrDocumentSearch(OcrResult result)
    : words = OcrTextUtils.selectableElements(result);

  /// Words eligible for matching, in reading order.
  final List<OcrElement> words;

  /// The searched text: trimmed words joined by single spaces.
  late final String documentText = words
      .map((word) => word.trimmedText)
      .join(' ');

  /// Start offset of each word inside [documentText], index-aligned with
  /// [words]. Precomputed once so a search is a scan of the document text
  /// rather than a re-walk of the word list per candidate.
  late final List<int> _wordStarts = _computeWordStarts();

  List<int> _computeWordStarts() {
    final starts = List<int>.filled(words.length, 0);
    var offset = 0;
    for (var i = 0; i < words.length; i++) {
      starts[i] = offset;
      offset += words[i].trimmedText.length + 1; // + the joining space
    }
    return starts;
  }

  /// All non-overlapping occurrences of [query], in document order.
  ///
  /// An empty or whitespace-only query matches nothing.
  List<OcrSearchHit> find(String query) {
    final needle = query.trim().toLowerCase();
    if (needle.isEmpty || documentText.isEmpty) return const <OcrSearchHit>[];

    final haystack = documentText.toLowerCase();
    if (needle.length > haystack.length) return const <OcrSearchHit>[];

    final hits = <OcrSearchHit>[];
    var from = 0;

    while (from + needle.length <= haystack.length) {
      final index = haystack.indexOf(needle, from);
      if (index < 0) break;

      if (_isLowSurrogate(haystack.codeUnitAt(index))) {
        // The match would start mid-code-point; nothing can legitimately begin
        // there, so step past it.
        from = index + 1;
        continue;
      }

      var end = index + needle.length;
      while (end < haystack.length &&
          _extendsGrapheme(haystack.codeUnitAt(end))) {
        end++;
      }

      final elements = _elementsCovering(index, end);
      if (elements.isEmpty) {
        from = index + 1;
        continue;
      }

      hits.add(
        OcrSearchHit(
          elements: elements,
          matchedText: documentText.substring(index, end),
          start: index,
          end: end,
        ),
      );
      from = end;
    }

    return hits;
  }

  /// Words overlapping the character range `[start, end)`.
  ///
  /// Matches are extended to whole words for highlighting but the *hit* keeps
  /// the exact character range, so a caller can tell an exact word match from a
  /// partial one.
  List<OcrElement> _elementsCovering(int start, int end) {
    final covered = <OcrElement>[];
    for (var i = 0; i < words.length; i++) {
      final wordStart = _wordStarts[i];
      final wordEnd = wordStart + words[i].trimmedText.length;
      if (wordStart < end && wordEnd > start) covered.add(words[i]);
    }
    return covered;
  }

  static bool _isLowSurrogate(int codeUnit) =>
      codeUnit >= 0xDC00 && codeUnit <= 0xDFFF;

  /// Whether [codeUnit] must travel with the character before it.
  ///
  /// Combining marks and script-specific vowel signs carry no standalone
  /// meaning, so a match that stops before one has cut a grapheme in half.
  static bool _extendsGrapheme(int codeUnit) {
    if (codeUnit >= 0x0300 && codeUnit <= 0x036F) return true; // combining
    if (codeUnit >= 0x0900 && codeUnit <= 0x0903) return true; // signs
    if (codeUnit >= 0x093A && codeUnit <= 0x094F) return true; // matras, virama
    if (codeUnit >= 0x0951 && codeUnit <= 0x0957) return true; // accents
    if (codeUnit >= 0x0962 && codeUnit <= 0x0963) return true; // vocalic signs
    if (codeUnit >= 0xFE00 && codeUnit <= 0xFE0F) return true; // variation sel.
    if (codeUnit >= 0x1AB0 && codeUnit <= 0x1AFF) return true; // combining ext.
    return false;
  }
}
