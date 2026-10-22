import 'dart:math' as math;

import 'ocr_block.dart';
import 'ocr_line.dart';
import 'ocr_rect.dart';
import 'ocr_result.dart';

/// One coherent unit of a recognized page: a paragraph, a heading, a caption or
/// a table cell — several neighbouring [OcrLine]s that belong together, with the
/// rectangle that contains them.
///
/// This is the unit translation and the readable text view work on. It is
/// deliberately *not* one line (too small to translate into grammatical text,
/// and it turns a page into a stack of unrelated cards) and *not* the whole page
/// (too large to place back on the photo, and it would mix columns into one
/// string).
class OcrLayoutBlock {
  const OcrLayoutBlock({
    required this.id,
    required this.lines,
    required this.bounds,
  });

  /// Stable identifier: the block's position in reading order.
  final int id;

  /// The block's lines, top-to-bottom.
  final List<OcrLine> lines;

  /// Smallest rectangle containing every line, in source-image pixels.
  final OcrRect bounds;

  /// The block's text on one line, ready to translate.
  ///
  /// Lines are joined with a space, and a line broken by a hyphen continues the
  /// next word (`inter-` + `national` → `international`) instead of turning OCR
  /// line wrapping into a fake compound.
  String get text =>
      OcrDocumentLayout.joinLines(lines.map((line) => line.text));

  /// The block's text as a paragraph: its lines on separate lines, so the
  /// structure survives in copy/read surfaces.
  String get paragraph => OcrDocumentLayout.joinLines(
    lines.map((line) => line.text),
    separator: '\n',
  );

  @override
  String toString() =>
      'OcrLayoutBlock($id, ${lines.length} lines, $bounds, '
      '"${lines.isEmpty ? '' : lines.first.text}")';
}

/// Recovers a document's reading order from OCR geometry.
///
/// Why this exists
/// ---------------
/// ML Kit hands back blocks → lines → words, and block order is *not* a reading
/// order: on a newspaper page it can list a right-hand column before a
/// left-hand one, and a single block can cover a whole multi-column page. Using
/// that order (or raw `fullText`) is what produced translations that jumped
/// between columns sentence by sentence and read like a pile of fragments.
///
/// The layout is computed from geometry alone, so it works for any document
/// type — newspaper, letter, notice, form, table, receipt — and never depends on
/// the text's language, a template or hardcoded coordinates.
///
/// The algorithm is a deterministic recursive whitespace cut:
///
/// 1. **Columns first** — split at vertical free channels (gutters) that run the
///    full height of the region, and read them left to right. Looking for
///    gutters before horizontal splits is what prevents two columns whose
///    paragraph gaps happen to line up from being read row by row.
/// 2. **Then bands** — when no gutter exists (a full-width headline, a full-width
///    caption), split at the largest horizontal free band and recurse, so the
///    headline is read before the body beneath it.
/// 3. **Then top-to-bottom** — a single column with no clear gaps is simply read
///    down.
/// 4. **Tables** — when the gutter-separated bands behave like a grid (short
///    single-line cells that align across columns) the bands are read row by row
///    instead, so a table does not become one column after another. A run of
///    prose in a column is recognised by its tall, multi-line blocks and is
///    never mistaken for a grid.
///
/// Paragraphs are then formed from neighbouring lines of the same column that
/// are vertically tight and typographically alike (similar line height), so a
/// heading or a caption does not get glued onto the body text under it.
abstract final class OcrDocumentLayout {
  /// A gutter must be at least this fraction of the median line height wide to
  /// count as a column separator.
  static const double gutterFactor = 0.3;

  /// Absolute floor for a gutter, in source-image pixels.
  static const double minGutter = 4;

  /// A horizontal free band must be at least this fraction of a line tall to
  /// separate two bands.
  static const double bandGapFactor = 0.9;

  /// Largest vertical gap between two lines of one paragraph, as a fraction of
  /// their height. Paragraph gaps on printed pages are wider than line leading,
  /// which is exactly what makes this work.
  static const double paragraphGapFactor = 0.8;

  /// How much of the narrower line two lines must share horizontally to be in
  /// the same column.
  static const double columnOverlapRatio = 0.5;

  /// Largest vertical gap, as a fraction of the line height, that still counts
  /// as the *same* paragraph across an ML Kit block boundary.
  ///
  /// Stricter than [paragraphGapFactor] on purpose: a block boundary is real
  /// evidence of a new region, so only a gap the width of ordinary leading
  /// (0.45 × a line) is treated as the engine having split one paragraph. A
  /// printed paragraph break — which is what the wide 0.8 threshold is for — is
  /// still respected across blocks.
  static const double crossBlockGapFactor = 0.45;

  /// How different two line heights may be and still be one paragraph. A
  /// headline is noticeably taller than body copy, so this keeps headings out of
  /// the paragraph beneath them. OCR line boxes of one paragraph are uniform to
  /// within a few percent, so this is generous to real variation and still
  /// separates a heading at 1.4× the body size (0.71).
  static const double heightSimilarity = 0.7;

  /// A grid cell is at most this tall (in median line heights). Prose blocks are
  /// many lines tall, which is what separates a table from a column of text.
  static const double maxCellHeightFactor = 1.8;

  /// Mean number of vertically adjacent lines per column band below which the
  /// bands may be a table rather than prose.
  static const double maxTableRunLength = 2.5;

  /// Fraction of lines that must have a same-row partner in another column for
  /// the region to be treated as a grid.
  static const double tableRowAlignment = 0.6;

  /// Groups a recognition result's lines into [OcrLayoutBlock]s in reading
  /// order.
  ///
  /// Lines without usable geometry cannot be placed; they are left out here and
  /// the text-only caller (see `OcrTranslationRegions`) keeps their text. Blank
  /// lines are ignored everywhere — whitespace is not content.
  static List<OcrLayoutBlock> blocks(OcrResult result) {
    final applicable = <OcrBlock>[];
    for (final block in result.blocks) {
      final usable = <OcrLine>[
        for (final line in block.lines)
          if (_isUsable(line)) line,
      ];
      if (usable.isEmpty) continue;
      // A block whose own box is unusable still has line geometry; rebuilding
      // its bounds keeps the block placeable instead of dropping its text.
      final bounds = block.boundingBox.isEmpty
          ? boundsOf(usable)
          : block.boundingBox;
      if (bounds.isEmpty) continue;
      applicable.add(
        block.boundingBox.isEmpty
            ? block.copyWith(boundingBox: bounds, lines: usable)
            : block,
      );
    }

    if (applicable.isEmpty) {
      // No structured blocks: lay the raw lines out instead of giving up.
      final lines = <OcrLine>[
        for (final line in result.lines)
          if (_isUsable(line)) line,
      ];
      if (lines.isEmpty) return const <OcrLayoutBlock>[];
      final median = _medianHeight(lines.map((line) => line.boundingBox));
      final ordered = _orderItems<OcrLine>(
        lines,
        rectOf: (line) => line.boundingBox,
        medianHeight: median,
      );
      return _numbered(_paragraphs(ordered, median));
    }

    if (applicable.length == 1) {
      // One block for the whole page (ML Kit does this on dense pages): lay out
      // its lines, since the block's own order is not a reading order.
      final lines = <OcrLine>[
        for (final line in applicable.single.lines)
          if (_isUsable(line)) line,
      ];
      final median = _medianHeight(lines.map((line) => line.boundingBox));
      final ordered = _orderItems<OcrLine>(
        lines,
        rectOf: (line) => line.boundingBox,
        medianHeight: median,
      );
      return _numbered(_paragraphs(ordered, median));
    }

    final allLines = <OcrLine>[for (final block in applicable) ...block.lines];
    final median = _medianHeight(allLines.map((line) => line.boundingBox));

    // Order the *blocks*. Their boxes are what ML Kit segmented the page into,
    // so this is the coarsest reliable evidence of structure; within a block the
    // lines are already top-to-bottom.
    final orderedBlocks = _orderItems<OcrBlock>(
      applicable,
      rectOf: (block) => block.boundingBox,
      medianHeight: median,
    );

    // Flatten the blocks into **one** ordered run of lines and paragraph it
    // once, rather than paragraphing each block in isolation.
    //
    // ML Kit often splits one printed paragraph across two blocks — a column's
    // last two lines become their own block — and paragraphing per block turned
    // that single paragraph into two translation units. On the photo that read
    // as a sentence cut in half across two boxes, and in the full text as
    // fragments in a new line each. Deciding paragraph boundaries from geometry
    // over the whole ordered page keeps the paragraph whole.
    //
    // The order inside a block is recovered with the same whitespace cut used
    // for the page, because a single block can itself span two columns; sorting
    // its lines by top-then-left would interleave those columns row by row.
    final orderedLines = <OcrLine>[];
    final blockOfLine = <OcrLine, OcrBlock>{};
    for (final block in orderedBlocks) {
      final lines = <OcrLine>[
        for (final line in block.lines)
          if (_isUsable(line)) line,
      ];
      if (lines.isEmpty) continue;
      final ordered = _orderItems<OcrLine>(
        lines,
        rectOf: (line) => line.boundingBox,
        medianHeight: median,
      );
      for (final line in ordered) {
        orderedLines.add(line);
        // Identity, not equality: two different blocks can hold identical line
        // objects from synthetic input.
        blockOfLine[line] = block;
      }
    }
    return _numbered(_paragraphs(orderedLines, median, blockOfLine));
  }

  /// All placeable text in reading order, independent of how the engine
  /// happened to order its blocks.
  static List<OcrLine> lines(OcrResult result) => [
    for (final block in blocks(result)) ...block.lines,
  ];

  /// Smallest rectangle containing [lines], guarding against unusable geometry.
  static OcrRect boundsOf(Iterable<OcrLine> lines) {
    double? left;
    double? top;
    double? right;
    double? bottom;
    for (final line in lines) {
      final box = line.boundingBox;
      if (box.isEmpty) continue;
      left = left == null ? box.left : math.min(left, box.left);
      top = top == null ? box.top : math.min(top, box.top);
      right = right == null ? box.right : math.max(right, box.right);
      bottom = bottom == null ? box.bottom : math.max(bottom, box.bottom);
    }
    if (left == null || top == null || right == null || bottom == null) {
      return const OcrRect(left: 0, top: 0, right: 0, bottom: 0);
    }
    return OcrRect.fromLTRB(left, top, right, bottom);
  }

  /// Joins OCR strings into one run of text.
  ///
  /// The default separator is a space because OCR line breaks are wrapping, not
  /// meaning; [separator] is `'\n'` when the caller wants to keep the physical
  /// lines.
  static String joinLines(Iterable<String> lines, {String separator = ' '}) {
    final buffer = StringBuffer();
    for (final raw in lines) {
      final text = raw.trim();
      if (text.isEmpty) continue;
      if (buffer.isEmpty) {
        buffer.write(text);
        continue;
      }
      final current = buffer.toString();
      // A hyphen at the end of a line is a word broken by the column width.
      // Joining with a space would invent a compound that is not in the source.
      if (current.endsWith('-') && _startsLikeContinuation(text)) {
        buffer
          ..clear()
          ..write(current.substring(0, current.length - 1))
          ..write(text);
        continue;
      }
      buffer
        ..write(separator)
        ..write(text);
    }
    return buffer.toString();
  }

  // --- ordering -------------------------------------------------------------

  /// Deterministic whitespace-cut ordering of [items] using their [rectOf].
  ///
  /// Returns the items in reading order. The recursion always makes progress:
  /// every split produces strictly narrower or shorter regions, and a region
  /// with no usable cut is sorted top-to-bottom, then left-to-right.
  static List<T> _orderItems<T>(
    List<T> items, {
    required OcrRect Function(T) rectOf,
    required double medianHeight,
  }) {
    if (items.length <= 1) return items;

    final bands = _columnBands(items, rectOf, medianHeight);
    if (bands.length > 1) {
      final orderedBands = <List<T>>[
        for (final band in bands)
          _orderItems(band, rectOf: rectOf, medianHeight: medianHeight),
      ];
      if (_looksLikeGrid(orderedBands, rectOf, medianHeight)) {
        return _gridOrder(orderedBands, rectOf, medianHeight);
      }
      return <T>[for (final band in orderedBands) ...band];
    }

    final split = _largestHorizontalGap(items, rectOf, medianHeight);
    if (split != null) {
      final above = <T>[];
      final below = <T>[];
      for (final item in items) {
        final rect = rectOf(item);
        if (rect.centerY < split) {
          above.add(item);
        } else {
          below.add(item);
        }
      }
      if (above.isNotEmpty && below.isNotEmpty) {
        return <T>[
          ..._orderItems(above, rectOf: rectOf, medianHeight: medianHeight),
          ..._orderItems(below, rectOf: rectOf, medianHeight: medianHeight),
        ];
      }
    }

    final sorted = <T>[...items]
      ..sort((a, b) {
        final rectA = rectOf(a);
        final rectB = rectOf(b);
        final byTop = rectA.top.compareTo(rectB.top);
        if (byTop != 0) return byTop;
        return rectA.left.compareTo(rectB.left);
      });
    return sorted;
  }

  /// Splits [items] at every vertical free channel wide enough to be a gutter.
  ///
  /// Bands are returned left to right. A full-width element (a headline) bridges
  /// every gutter, which correctly yields a single band; the horizontal split in
  /// [_orderItems] then separates it from the columns below.
  static List<List<T>> _columnBands<T>(
    List<T> items,
    OcrRect Function(T) rectOf,
    double medianHeight,
  ) {
    final gutter = math.max(minGutter, medianHeight * gutterFactor);
    final sorted = <T>[...items]
      ..sort((a, b) => rectOf(a).left.compareTo(rectOf(b).left));

    final bands = <List<T>>[];
    var current = <T>[sorted.first];
    var right = rectOf(sorted.first).right;

    for (final item in sorted.skip(1)) {
      final rect = rectOf(item);
      if (rect.left - right >= gutter) {
        bands.add(current);
        current = <T>[item];
        right = rect.right;
        continue;
      }
      current.add(item);
      right = math.max(right, rect.right);
    }
    bands.add(current);
    return bands;
  }

  /// The largest horizontal whitespace band that crosses the whole region, or
  /// `null` when there is no gap a line tall.
  static double? _largestHorizontalGap<T>(
    List<T> items,
    OcrRect Function(T) rectOf,
    double medianHeight,
  ) {
    final threshold = math.max(2.0, medianHeight * bandGapFactor);
    final sorted = <T>[...items]
      ..sort((a, b) => rectOf(a).top.compareTo(rectOf(b).top));

    double? best;
    double? split;
    var bottom = rectOf(sorted.first).bottom;
    for (final item in sorted.skip(1)) {
      final rect = rectOf(item);
      final gap = rect.top - bottom;
      if (gap >= threshold && (best == null || gap > best)) {
        best = gap;
        split = (bottom + rect.top) / 2;
      }
      bottom = math.max(bottom, rect.bottom);
    }
    return split;
  }

  /// Whether gutter-separated [bands] behave like a grid of cells rather than
  /// columns of prose.
  ///
  /// The decisive evidence is block shape: prose in a column is a tall,
  /// multi-line block, while a table cell is one short line. Merely having rows
  /// that align is *not* enough — newspaper columns align line for line and must
  /// still be read column by column.
  static bool _looksLikeGrid<T>(
    List<List<T>> bands,
    OcrRect Function(T) rectOf,
    double medianHeight,
  ) {
    final total = bands.fold<int>(0, (sum, band) => sum + band.length);
    if (bands.length < 2 || total < 4) return false;

    for (final band in bands) {
      var runs = 0;
      var previousBottom = double.negativeInfinity;
      for (final item in <T>[
        ...band,
      ]..sort((a, b) => rectOf(a).top.compareTo(rectOf(b).top))) {
        final rect = rectOf(item);
        if (rect.top - previousBottom >=
            math.max(2.0, medianHeight * paragraphGapFactor)) {
          runs++;
        }
        previousBottom = math.max(previousBottom, rect.bottom);
      }
      if (runs == 0) return false;
      if (band.length / runs > maxTableRunLength) return false;
    }

    var tall = 0;
    for (final band in bands) {
      for (final item in band) {
        if (rectOf(item).height > medianHeight * maxCellHeightFactor) tall++;
      }
    }
    if (tall > total * 0.2) return false;

    // Row alignment: most items must have a horizontal partner in another band.
    var aligned = 0;
    for (final band in bands) {
      for (final item in band) {
        final rect = rectOf(item);
        var partner = false;
        for (final other in bands) {
          if (identical(other, band)) continue;
          for (final candidate in other) {
            final otherRect = rectOf(candidate);
            final overlap =
                math.min(rect.bottom, otherRect.bottom) -
                math.max(rect.top, otherRect.top);
            if (overlap >= math.min(rect.height, otherRect.height) * 0.5) {
              partner = true;
              break;
            }
          }
          if (partner) break;
        }
        if (partner) aligned++;
      }
    }
    return aligned / total >= tableRowAlignment;
  }

  /// Reads gutter-separated [bands] row by row: the first cell of every column,
  /// then the second, and so on.
  static List<T> _gridOrder<T>(
    List<List<T>> bands,
    OcrRect Function(T) rectOf,
    double medianHeight,
  ) {
    final rows = <List<T>>[];
    final sorted = <T>[for (final band in bands) ...band]
      ..sort((a, b) {
        final rectA = rectOf(a);
        final rectB = rectOf(b);
        final byTop = rectA.top.compareTo(rectB.top);
        if (byTop != 0) return byTop;
        return rectA.left.compareTo(rectB.left);
      });

    for (final item in sorted) {
      final rect = rectOf(item);
      List<T>? target;
      for (final row in rows) {
        final rowRect = rectOf(row.first);
        final overlap =
            math.min(rect.bottom, rowRect.bottom) -
            math.max(rect.top, rowRect.top);
        if (overlap >= math.min(rect.height, rowRect.height) * 0.5) {
          target = row;
          break;
        }
      }
      if (target == null) {
        rows.add(<T>[item]);
      } else {
        target.add(item);
      }
    }

    return <T>[
      for (final row in rows)
        for (final item
            in (row..sort((a, b) => rectOf(a).left.compareTo(rectOf(b).left))))
          item,
    ];
  }

  // --- paragraphs -----------------------------------------------------------

  /// Splits an already ordered run of lines into paragraphs.
  ///
  /// [blockOfLine] maps each line to the ML Kit block it came from. It is what
  /// makes an across-block join safe: two vertically adjacent **table cells**
  /// are single-line blocks, so they are never glued into one row-spanning
  /// paragraph, while a paragraph the engine split into a multi-line block and
  /// a continuation still rejoins.
  static List<List<OcrLine>> _paragraphs(
    List<OcrLine> ordered,
    double medianHeight, [
    Map<OcrLine, OcrBlock>? blockOfLine,
  ]) {
    if (ordered.isEmpty) return const <List<OcrLine>>[];
    final groups = <List<OcrLine>>[
      <OcrLine>[ordered.first],
    ];
    for (final line in ordered.skip(1)) {
      final previous = groups.last.last;
      if (_continues(previous, line, medianHeight) &&
          _mayJoinAcrossBlocks(previous, line, blockOfLine)) {
        groups.last.add(line);
      } else {
        groups.add(<OcrLine>[line]);
      }
    }
    return groups;
  }

  /// Whether [previous] and [next] may be one paragraph, given which ML Kit
  /// block each came from.
  ///
  /// Inside one block the geometry rules already applied (see [_continues])
  /// decide, because a block is a single OCR region. Across blocks the boundary
  /// itself is evidence, so two extra conditions are required:
  ///
  /// * at least one of the blocks holds several lines — two single-line blocks
  ///   stacked tightly are table cells, receipt rows or list items, and merging
  ///   them would produce a paragraph spanning two rows that, once translated,
  ///   is drawn over the cell below;
  /// * the gap is no wider than ordinary leading ([crossBlockGapFactor]) — a
  ///   printed paragraph break must win even though it is below the looser
  ///   inside-block threshold.
  ///
  /// A one-line paragraph that ML Kit split after a single line therefore stays
  /// split. That is the conservative answer: two honest fragments are better
  /// than a paragraph glued across two table rows.
  static bool _mayJoinAcrossBlocks(
    OcrLine previous,
    OcrLine next,
    Map<OcrLine, OcrBlock>? blockOfLine,
  ) {
    if (blockOfLine == null) return true;
    final previousBlock = blockOfLine[previous];
    final nextBlock = blockOfLine[next];
    if (previousBlock == null || nextBlock == null) return true;
    if (identical(previousBlock, nextBlock)) return true;
    if (previousBlock.lines.length <= 1 && nextBlock.lines.length <= 1) {
      return false;
    }

    final gap = next.boundingBox.top - previous.boundingBox.bottom;
    final tallest = math.max(
      previous.boundingBox.height,
      next.boundingBox.height,
    );
    return gap <= tallest * crossBlockGapFactor;
  }

  /// Whether [next] continues the paragraph that [previous] ends.
  static bool _continues(OcrLine previous, OcrLine next, double medianHeight) {
    final a = previous.boundingBox;
    final b = next.boundingBox;
    if (!_sameColumn(a, b)) return false;

    final gap = b.top - a.bottom;
    final tallest = math.max(a.height, b.height);
    if (gap > tallest * paragraphGapFactor + 2) return false;
    // OCR boxes on tight leading can overlap; a whole line of backwards overlap
    // is still the same paragraph, more than that is a different region.
    if (gap < -tallest) return false;

    final shorter = math.min(a.height, b.height);
    final taller = math.max(a.height, b.height);
    if (taller > 0 && shorter / taller < heightSimilarity) return false;

    if (medianHeight > 0 && tallest > medianHeight * 3.5) return false;
    return true;
  }

  /// Whether two line boxes occupy the same column.
  static bool _sameColumn(OcrRect a, OcrRect b) {
    final overlap = math.min(a.right, b.right) - math.max(a.left, b.left);
    if (overlap <= 0) return false;
    final narrower = math.min(a.width, b.width);
    if (narrower <= 0) return false;
    return overlap / narrower >= columnOverlapRatio;
  }

  // --- helpers --------------------------------------------------------------

  static bool _isUsable(OcrLine line) =>
      line.text.trim().isNotEmpty && !line.boundingBox.isEmpty;

  static double _medianHeight(Iterable<OcrRect> boxes) {
    final heights = <double>[
      for (final box in boxes)
        if (!box.isEmpty) box.height,
    ]..sort();
    if (heights.isEmpty) return 0;
    final middle = heights.length ~/ 2;
    return heights.length.isOdd
        ? heights[middle]
        : (heights[middle - 1] + heights[middle]) / 2;
  }

  static List<OcrLayoutBlock> _numbered(List<List<OcrLine>> groups) => [
    for (var index = 0; index < groups.length; index++)
      OcrLayoutBlock(
        id: index,
        lines: List<OcrLine>.unmodifiable(groups[index]),
        bounds: boundsOf(groups[index]),
      ),
  ];

  /// Whether [text] looks like the continuation of a hyphenated word rather than
  /// a new sentence after a dash.
  static bool _startsLikeContinuation(String text) {
    if (text.isEmpty) return false;
    final code = text.codeUnitAt(0);
    return code >= 0x61 && code <= 0x7A; // a-z
  }
}
