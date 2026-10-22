import 'ocr_element.dart';
import 'ocr_line.dart';
import 'ocr_result.dart';
import 'ocr_text_utils.dart';

/// A lazily built, shared index over one [OcrResult]'s words.
///
/// Why this exists
/// ---------------
/// [OcrResult.lines] and [OcrResult.elements] are *computed* getters: every
/// read rebuilds a fresh flattened list. Several paths read them repeatedly, and
/// the worst of them runs during gestures:
///
/// * `OcrSelection.range` — the drag-selection path — walked the entire element
///   list and allocated a fresh `Set` plus `List` on **every pointer-move
///   event**.
/// * `OcrSelection`'s reading-order comparator called `result.elements` (another
///   new list) and then `indexOf` (a linear scan) **twice per comparison**,
///   inside a `sort`.
/// * `OcrHitTester` rebuilt the selectable-word list on every layout pass.
///
/// None of that is a correctness bug, which is why it survived: it is pure
/// allocation and pointer chasing in the one place where frames are tight.
/// This index computes each of those collections once per result and hands the
/// same instances out afterwards.
///
/// Identity, not value
/// -------------------
/// Cached through an [Expando], so the index lives exactly as long as the
/// result it describes and does not leak: [OcrResult] is immutable and has no
/// value equality, so one instance means one index.
///
/// One caveat worth stating: the index assumes the result's block/line/element
/// lists are never mutated after construction. That is already the contract the
/// whole `lib/ocr` layer relies on (results are built once and passed around
/// read-only).
class OcrResultIndex {
  OcrResultIndex._(this.result)
    : lines = result.lines,
      elements = result.elements;

  /// The index for [result], built on first use and reused for its lifetime.
  static OcrResultIndex of(OcrResult result) =>
      _cache[result] ??= OcrResultIndex._(result);

  static final Expando<OcrResultIndex> _cache = Expando<OcrResultIndex>(
    'OcrResultIndex',
  );

  /// The result this index describes.
  final OcrResult result;

  /// All lines, flattened once.
  final List<OcrLine> lines;

  /// All words in reading order, flattened once.
  final List<OcrElement> elements;

  /// Words eligible for selection and highlighting: non-empty text, usable
  /// geometry, exact duplicates collapsed, in reading order.
  ///
  /// The overlay renders exactly this collection and [OcrHitTester] hit-tests
  /// exactly this collection, so "what you see is what you can hit" holds by
  /// construction rather than by convention.
  late final List<OcrElement> selectableElements =
      OcrTextUtils.selectableElements(result);

  /// Position of [element] in [elements], or `-1` when absent.
  ///
  /// O(1) via a value-keyed map instead of [List.indexOf]'s linear scan.
  /// [OcrElement] has value equality, so this answers identically to `indexOf`,
  /// and the first occurrence wins for duplicate values — matching
  /// `List.indexOf`.
  int indexOf(OcrElement element) => _positions[element] ?? -1;

  late final Map<OcrElement, int> _positions = _computePositions();

  Map<OcrElement, int> _computePositions() {
    final positions = <OcrElement, int>{};
    for (var i = 0; i < elements.length; i++) {
      positions.putIfAbsent(elements[i], () => i);
    }
    return positions;
  }
}
