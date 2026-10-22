import 'ocr_element.dart';
import 'ocr_result.dart';
import 'ocr_result_index.dart';

/// Immutable model of a **multi-word selection** over an [OcrResult].
///
/// Design notes
/// ------------
/// * Selection is defined as an **ordered, de-duplicated list of [OcrElement]s**
///   rather than a text range. This keeps the model aligned with how OCR
///   geometry works (each word owns its own bounding box) and makes a future
///   drag-to-select / handle-adjustment layer a matter of adding/removing
///   elements.
/// * Ordering follows the OCR reading order (the position of each element in
///   [OcrResult.elements]), so concatenated text reads naturally regardless of
///   the order words were tapped in.
/// * "Adjacent" is intentionally NOT enforced here yet. The model can represent
///   any set of words; enforcing adjacency (e.g. a contiguous run within one
///   line) is a policy decision better added when drag selection lands. The
///   `isContiguous` helper is provided so that policy can be applied later
///   without changing the data model.
/// * Membership uses [OcrElement] value equality, so equal words referenced via
///   different instances still compare correctly.
class OcrSelection {
  const OcrSelection._(this.result, this.elements);

  /// An empty selection for [result].
  const OcrSelection.empty(OcrResult result) : this._(result, const []);

  /// The result this selection refers to (needed for ordering + hit-testing).
  final OcrResult result;

  /// Selected words, in OCR reading order.
  final List<OcrElement> elements;

  bool get isEmpty => elements.isEmpty;
  bool get isNotEmpty => elements.isNotEmpty;
  int get length => elements.length;

  /// The selected text, words joined by single spaces.
  ///
  /// Uses each word's *original* OCR text (only trimmed) so copy/search return
  /// exactly what the engine recognized. Empty elements are excluded by
  /// construction (see [OcrResultIndex.selectableElements]).
  String get text =>
      elements.map((e) => e.trimmedText).where((t) => t.isNotEmpty).join(' ');

  /// Whether [element] is part of this selection.
  bool contains(OcrElement element) => elements.contains(element);

  /// Returns a new selection with [element] added (idempotent).
  OcrSelection add(OcrElement element) {
    if (contains(element)) return this;
    final next = [...elements, element]..sort(_byReadingOrder);
    return OcrSelection._(result, next);
  }

  /// Returns a new selection with [element] removed.
  OcrSelection remove(OcrElement element) {
    if (!contains(element)) return this;
    return OcrSelection._(
      result,
      elements.where((e) => e != element).toList(growable: false),
    );
  }

  /// Toggles [element]: adds it if absent, removes it if present.
  OcrSelection toggle(OcrElement element) =>
      contains(element) ? remove(element) : add(element);

  /// Returns a new selection with every element of [elements] added
  /// (idempotent, reading order preserved).
  OcrSelection addAll(Iterable<OcrElement> elements) {
    var next = this;
    for (final element in elements) {
      next = next.add(element);
    }
    return next;
  }

  /// Returns a selection covering every selectable word between [anchor] and
  /// [extent] **inclusive**, in reading order.
  ///
  /// This is what makes a Lens-style drag work: the long-press fixes the
  /// [anchor] and each drag update passes the word under the finger as the
  /// [extent], so sweeping across a line (or several) grows a contiguous run
  /// instead of replacing a single word. Argument order does not matter, so
  /// dragging backwards selects the same words.
  OcrSelection range(OcrElement anchor, OcrElement extent) {
    // Reading order comes from the shared per-result index: this runs on every
    // drag update, so it must not re-flatten the result (and allocate a
    // membership set) per pointer-move event.
    final ordered = OcrResultIndex.of(result).selectableElements;
    final from = ordered.indexOf(anchor);
    final to = ordered.indexOf(extent);
    if (from == -1 && to == -1) return this;
    if (from == -1) return only(extent);
    if (to == -1) return only(anchor);
    final start = from <= to ? from : to;
    final end = from <= to ? to : from;
    return OcrSelection._(result, ordered.sublist(start, end + 1));
  }

  /// Replaces the selection with just [element].
  OcrSelection only(OcrElement element) => OcrSelection._(result, [element]);

  /// Clears the selection.
  OcrSelection clear() => OcrSelection._(result, const []);

  /// Whether the selected words form a contiguous run in reading order.
  ///
  /// Provided for future drag-selection policy; the current UI does not require
  /// adjacency.
  bool get isContiguous {
    if (elements.length < 2) return true;
    final all = result.elements;
    final indices = elements.map(all.indexOf).where((i) => i >= 0).toList()
      ..sort();
    if (indices.length != elements.length) return false;
    for (var i = 1; i < indices.length; i++) {
      if (indices[i] != indices[i - 1] + 1) return false;
    }
    return true;
  }

  int _byReadingOrder(OcrElement a, OcrElement b) {
    // This runs inside a `sort`, so a linear `indexOf` per comparison would be
    // quadratic; the index answers positions in O(1) with the same semantics.
    final positions = OcrResultIndex.of(result);
    final ia = positions.indexOf(a);
    final ib = positions.indexOf(b);
    if (ia == -1 && ib == -1) return 0;
    if (ia == -1) return 1;
    if (ib == -1) return -1;
    return ia.compareTo(ib);
  }

  @override
  String toString() => 'OcrSelection(${elements.length} words: "$text")';
}
