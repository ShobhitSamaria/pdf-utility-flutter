import '../../ocr/domain/ocr_document_layout.dart';
import '../../ocr/domain/ocr_element.dart';
import '../../ocr/domain/ocr_line.dart';
import '../../ocr/domain/ocr_rect.dart';
import '../../ocr/domain/ocr_result.dart';
import '../../ocr/domain/ocr_selection.dart';
import '../../ocr/domain/ocr_text_utils.dart';
import '../domain/translated_region.dart';
import '../domain/translation_text.dart';

/// Turns OCR output into [TranslationUnit]s — the bridge between the OCR layer
/// and the translation overlay.
///
/// This is the **only** translation file that knows about OCR *result* models
/// (`OcrResult` / `OcrSelection`). It never touches the OCR engine, and it
/// introduces no new coordinate space: each unit carries the source
/// [OcrRect] straight out of the OCR result, so the overlay can map it with the
/// very same `OcrCoordinateMapper` the selection overlay uses.
///
/// Granularity is deliberately **semantic, not word-level**:
/// * whole page → one unit per **paragraph** (a run of neighbouring lines in one
///   column, see [OcrDocumentLayout]), in reading order. Translating a whole
///   line at a time made a page read as disconnected phrases — "Same that their
///   appointment / Advertising not by direct selection" — because no translator
///   can recover a sentence it never sees. Paragraph units also keep tables from
///   being read one column after another.
/// * selection → one unit per line that the selected words touch, with the
///   union of just those words' boxes (so untouched words on the same line are
///   not translated, and a multi-line selection becomes a few regions).
abstract final class OcrTranslationRegions {
  /// Largest amount of text sent in one translation call.
  ///
  /// On-device ML Kit handles a paragraph comfortably; a very long paragraph is
  /// split at its own line boundaries so a single call never carries an unbounded
  /// input. The split never happens mid-line, so no word is cut in half.
  static const int maxUnitCharacters = 900;

  /// One unit per recognized paragraph, in reading order.
  ///
  /// Text that has no usable geometry is appended as a final, unplaceable unit
  /// instead of being dropped: it cannot be drawn on the photo, but it is still
  /// part of the page and must appear in the full translation.
  static List<TranslationUnit> fromPage(OcrResult result) {
    final units = <TranslationUnit>[];
    var id = 0;

    for (final block in OcrDocumentLayout.blocks(result)) {
      for (final chunk in _chunk(block.lines)) {
        final text = OcrDocumentLayout.joinLines(
          chunk.map((line) => line.text),
        );
        if (!TranslationText.isTranslatable(text)) continue;
        units.add(
          TranslationUnit(
            id: id++,
            text: text,
            bounds: OcrDocumentLayout.boundsOf(chunk),
            kind: TranslatedRegionKind.paragraph,
          ),
        );
      }
    }

    final placeless = <String>[
      for (final line in result.lines)
        if (line.boundingBox.isEmpty &&
            TranslationText.isTranslatable(line.text))
          line.text.trim(),
    ];
    final placelessText = TranslationText.aggregate(placeless, separator: ' ');
    if (TranslationText.isTranslatable(placelessText)) {
      units.add(
        TranslationUnit(
          id: id++,
          text: placelessText,
          bounds: const OcrRect(left: 0, top: 0, right: 0, bottom: 0),
          kind: TranslatedRegionKind.paragraph,
        ),
      );
    }
    return units;
  }

  /// Splits [lines] into runs of at most [maxUnitCharacters] characters,
  /// always at a line boundary.
  static List<List<OcrLine>> _chunk(List<OcrLine> lines) {
    final chunks = <List<OcrLine>>[];
    var current = <OcrLine>[];
    var length = 0;
    for (final line in lines) {
      final lineLength = line.text.trim().length + 1;
      if (current.isNotEmpty && length + lineLength > maxUnitCharacters) {
        chunks.add(current);
        current = <OcrLine>[];
        length = 0;
      }
      current.add(line);
      length += lineLength;
    }
    if (current.isNotEmpty) chunks.add(current);
    return chunks;
  }

  /// One unit per line touched by the selection, in reading order.
  ///
  /// Each unit's text is only the *selected* words of that line, and its box is
  /// the union of those words — so the translation is drawn exactly where the
  /// user selected.
  static List<TranslationUnit> fromSelection(OcrSelection selection) {
    if (selection.isEmpty) return const <TranslationUnit>[];

    // Which line each selected word belongs to.
    final lineByElement = <OcrElement, OcrLine>{};
    for (final line in selection.result.lines) {
      for (final element in line.elements) {
        lineByElement.putIfAbsent(element, () => line);
      }
    }

    final byLine = <OcrLine, List<OcrElement>>{};
    final unattached = <OcrElement>[];
    for (final element in selection.elements) {
      if (!OcrTextUtils.isSelectable(element)) continue;
      final line = lineByElement[element];
      if (line == null) {
        // Synthetic/filtered results can hold elements that are not part of any
        // line; treat each as its own region rather than dropping the text.
        unattached.add(element);
        continue;
      }
      (byLine[line] ??= <OcrElement>[]).add(element);
    }

    final units = <TranslationUnit>[];
    var id = 0;

    // Walk the result's lines (not the selection order) so multi-line
    // selections stay in reading order.
    for (final line in selection.result.lines) {
      final elements = byLine[line];
      if (elements == null || elements.isEmpty) continue;
      units.add(
        TranslationUnit(
          id: id++,
          text: TranslationText.aggregate(
            elements.map((element) => element.trimmedText),
            separator: ' ',
          ),
          bounds: _unionOf(elements) ?? line.boundingBox,
          kind: TranslatedRegionKind.selection,
        ),
      );
    }

    for (final element in unattached) {
      units.add(
        TranslationUnit(
          id: id++,
          text: element.trimmedText,
          bounds: element.boundingBox,
          kind: TranslatedRegionKind.selection,
        ),
      );
    }

    return units;
  }

  /// Smallest rectangle containing every element's box, or `null` when none of
  /// them has usable geometry.
  static OcrRect? _unionOf(List<OcrElement> elements) {
    double? left;
    double? top;
    double? right;
    double? bottom;
    for (final element in elements) {
      final box = element.boundingBox;
      if (box.isEmpty) continue;
      left = left == null ? box.left : (box.left < left ? box.left : left);
      top = top == null ? box.top : (box.top < top ? box.top : top);
      right = right == null
          ? box.right
          : (box.right > right ? box.right : right);
      bottom = bottom == null
          ? box.bottom
          : (box.bottom > bottom ? box.bottom : bottom);
    }
    if (left == null || top == null || right == null || bottom == null) {
      return null;
    }
    return OcrRect.fromLTRB(left, top, right, bottom);
  }
}
