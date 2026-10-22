import 'ocr_element.dart';
import 'ocr_result.dart';

/// Helpers that clean up raw engine output without losing the original text.
///
/// OCR engines sometimes emit whitespace-only or otherwise empty elements, and
/// occasionally repeat the same word across overlapping regions. We filter and
/// de-duplicate for **hit-testing / display**, but always keep each element's
/// original `text` intact (only trimmed when displayed/copied) so nothing is
/// silently rewritten.
class OcrTextUtils {
  const OcrTextUtils._();

  /// Whether an element carries any usable text.
  static bool hasText(OcrElement element) => element.trimmedText.isNotEmpty;

  /// Whether an element is geometrically usable (non-degenerate box).
  static bool hasGeometry(OcrElement element) => !element.boundingBox.isEmpty;

  /// An element is "selectable" when it has both text and geometry.
  static bool isSelectable(OcrElement element) =>
      hasText(element) && hasGeometry(element);

  /// Returns the selectable elements of [result] in reading order, with empty
  /// elements removed and exact duplicates (same text AND same bounding box)
  /// collapsed. Ordering is preserved.
  ///
  /// De-duplication keys on text + geometry, so genuinely repeated words at
  /// *different* positions are both kept.
  static List<OcrElement> selectableElements(OcrResult result) {
    final seen = <OcrElement>{};
    final out = <OcrElement>[];
    for (final element in result.elements) {
      if (!isSelectable(element)) continue;
      if (seen.add(element)) out.add(element);
    }
    return out;
  }

  /// Whether [text] contains at least one Devanagari code point.
  ///
  /// Covers the Devanagari block (U+0900–U+097F, which includes the matras,
  /// virama, nukta and the `।`/`॥` dandas) and Devanagari Extended
  /// (U+A8E0–U+A8FF).
  ///
  /// This is deliberately a *presence* test, not a language detector. It is used
  /// for two narrow jobs:
  ///
  /// * Deciding which of two recognition passes owns a text region when their
  ///   bounding boxes collide (see `OcrMergePolicy`) — only the Devanagari model
  ///   emits Devanagari code points, so their presence is strong evidence about
  ///   which pass read the region.
  /// * Grouping benchmark samples into Hindi vs English buckets.
  ///
  /// Devanagari Extended-A (U+11B00+) lives outside the Basic Multilingual
  /// Plane and is not checked; it does not occur in printed Hindi text.
  static bool containsDevanagari(String text) {
    for (final rune in text.runes) {
      if ((rune >= 0x0900 && rune <= 0x097F) ||
          (rune >= 0xA8E0 && rune <= 0xA8FF)) {
        return true;
      }
    }
    return false;
  }

  /// Whether [text] contains at least one ASCII letter.
  ///
  /// Used by the benchmark harness to describe a sample, never to score one.
  static bool containsAsciiLetter(String text) {
    for (final rune in text.runes) {
      final isUpper = rune >= 0x41 && rune <= 0x5A;
      final isLower = rune >= 0x61 && rune <= 0x7A;
      if (isUpper || isLower) return true;
    }
    return false;
  }
}
