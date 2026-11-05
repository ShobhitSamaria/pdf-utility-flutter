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

  /// How narrow, relative to the line above it, a *shorter* line must be before
  /// it is read as the paragraph's own final line rather than as a change of
  /// type size.
  ///
  /// The height test alone cannot tell these two apart, and on a Devanagari page
  /// it gets the common one wrong: a line whose glyphs have no ascender, matra
  /// or descender ("सकता।") has a genuinely smaller box — 16 px under a 24 px
  /// line on the recorded newspaper page, a ratio of 0.67 — even though it is
  /// the same size as the text above it. What separates it from a byline in
  /// smaller type is **width**: a paragraph's last line is short because it does
  /// not fill the measure, while a line that changes size still fills it.
  ///
  /// The recorded page has exactly one pair below [heightSimilarity] inside a
  /// block, and it is that final line, so this threshold is measured rather than
  /// guessed. It is only consulted between two lines of the *same* ML Kit block;
  /// across blocks the stricter rule in [_mayJoinAcrossBlocks] still applies.
  static const double tailWidthRatio = 0.6;

  /// Fraction of the page width from which a line counts as **wide**: a
  /// headline, a deck, a banner — something that spans the columns rather than
  /// sitting in one.
  ///
  /// Used for one purpose: two wide boxes on the same row are two halves of one
  /// printed line. ML Kit splits long headlines that way, and translating the
  /// halves separately turns one sentence into gibberish — on the recorded page
  /// `…संविदाकर्मियों को राहत, नियम` and `2022 के तहत लाभ मिलेगा` came back as
  /// "Relief, Rule, Rule" and "2022 will get benefit".
  ///
  /// A body column is nowhere near this wide (0.30 of the page on the recorded
  /// page), so three columns on one row are never joined into one sentence.
  static const double wideFragmentRatio = 0.5;

  /// How much taller than the page's median line a box must be to count as
  /// **display type** — a headline rather than body copy.
  ///
  /// The width test alone is not enough: a headline's second line can be split
  /// into a short left half and a long right half, and the short half is no
  /// wider than a column (`राहत, नियम` is 340 px on a 1080 px page). What still
  /// marks both halves as display type is their height — 87 px against a 24 px
  /// body line. Body columns on one row are body-sized, so they never qualify.
  static const double displayTypeFactor = 2;

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
      return _numbered(
        _readOrder(
          lines,
          blockOfLine: const <OcrLine, OcrBlock>{},
          pageWidth: boundsOf(lines).width,
        ),
      );
    }

    // Flatten every block into **one** run of lines and order it from line
    // geometry alone.
    //
    // Ordering whole blocks looked simpler, but a block's *bounding box* is not
    // its content: on a real newspaper page ML Kit returns a headline block
    // whose box spans the full page width, and a sub-heading block that does the
    // same. Those boxes bridge every column gutter, so the whitespace cut saw a
    // single column, could not separate the headline from the body (their boxes
    // are only ~10 px apart), and fell back to sorting by top-then-left — which
    // interleaves the body columns line by line. That is the "middle column is
    // missing" symptom: the text is present, but read as left, middle, right,
    // left, middle, right.
    //
    // Line boxes do not have that problem. A line that really spans the page (a
    // headline) is recognised by its width and treated as an anchor, while the
    // narrow lines form columns. Paragraphs are still formed once, over the
    // whole ordered page, using block membership only to decide whether a join
    // across two blocks is safe — so a paragraph ML Kit split in two still
    // rejoins, while two table cells never merge.
    final allLines = <OcrLine>[];
    final blockOfLine = <OcrLine, OcrBlock>{};
    for (final block in applicable) {
      for (final line in _withoutRepeatedInk(block.lines)) {
        if (!_isUsable(line)) continue;
        allLines.add(line);
        // Identity, not equality: two different blocks can hold identical line
        // objects from synthetic input.
        blockOfLine[line] = block;
      }
    }
    final pageBounds = boundsOf(allLines);
    return _numbered(
      _readOrder(
        allLines,
        blockOfLine: blockOfLine,
        rowMates: _rowMates(allLines, blockOfLine),
        pageWidth: pageBounds.width,
      ),
    );
  }

  /// Drops lines that report the **same ink twice**.
  ///
  /// ML Kit occasionally returns two lines for one printed line on a real photo:
  /// on the second recorded page, `दिल्ली तक चार राज्यों में फैली` came back
  /// together with a 180 px box reading `राज्यों में कैली` sitting inside it, on
  /// the same row. Both boxes cover the same pixels, so only one of them can be
  /// text: keeping both translated the same words twice and drew one of them
  /// over the body of the paragraph.
  ///
  /// The test is deliberately narrow — same block, same row, overlapping boxes,
  /// and *similar text* — because overlapping boxes on one row are also how a
  /// headline line split in two comes back (`… राहत, नियम` + `2022 के तहत लाभ
  /// मिलेगा`), and those hold different words: their character-bigram overlap on
  /// the recorded pages is 0.10, against 0.61 for the repeated ink. A sequential
  /// half is never dropped.
  static List<OcrLine> _withoutRepeatedInk(List<OcrLine> lines) {
    if (lines.length < 2) return lines;
    final dropped = <OcrLine>{};
    for (var i = 0; i < lines.length; i++) {
      for (var j = i + 1; j < lines.length; j++) {
        final a = lines[i];
        final b = lines[j];
        if (dropped.contains(a) || dropped.contains(b)) continue;
        if (!_sameRow(a.boundingBox, b.boundingBox)) continue;
        final overlap = _horizontalOverlap(a.boundingBox, b.boundingBox);
        if (overlap <
            math.min(a.boundingBox.width, b.boundingBox.width) * 0.5) {
          continue;
        }
        if (_textSimilarity(a.text, b.text) < 0.4) continue;
        // Keep the longer reading: it is the one that saw the whole line.
        dropped.add(a.text.trim().length >= b.text.trim().length ? b : a);
      }
    }
    if (dropped.isEmpty) return lines;
    return <OcrLine>[
      for (final line in lines)
        if (!dropped.contains(line)) line,
    ];
  }

  /// Dice coefficient over character bigrams, `0`–`1`, ignoring whitespace.
  static double _textSimilarity(String a, String b) {
    final first = _bigrams(a);
    final second = _bigrams(b);
    if (first.isEmpty || second.isEmpty) return 0;
    var shared = 0;
    for (final gram in first) {
      if (second.contains(gram)) shared++;
    }
    return 2 * shared / (first.length + second.length);
  }

  static Set<String> _bigrams(String text) {
    final buffer = StringBuffer();
    for (final rune in text.runes) {
      if (rune == 0x20 || rune == 0x09 || rune == 0x0A || rune == 0x0D) {
        continue;
      }
      buffer.writeCharCode(rune);
    }
    final stripped = buffer.toString();
    if (stripped.length < 2) return <String>{stripped};
    return <String>{
      for (var index = 0; index + 2 <= stripped.length; index++)
        stripped.substring(index, index + 2),
    };
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
      // A single capital letter at the end of a line followed by lowercase text is
      // the same break without a hyphen: `… First Floor, S` + `ector-76 …` is
      // "Sector-76", not "S ector-76". The space a naive join inserts here is a
      // fabricated word boundary, which then reaches the translator.
      if (_endsWithDanglingLetter(current) && _startsLikeContinuation(text)) {
        buffer
          ..clear()
          ..write(current)
          ..write(text);
        continue;
      }
      buffer
        ..write(separator)
        ..write(text);
    }
    return buffer.toString();
  }

  // --- reading order --------------------------------------------------------

  /// Groups [lines] into paragraphs and returns them in reading order.
  ///
  /// Paragraphs are formed **first**, from local geometry, and ordered
  /// **second**. That separation is the whole point: ordering a page and then
  /// grouping adjacent lines means any ordering mistake also shreds every
  /// paragraph, which is exactly what a real two-region page produced — a
  /// photograph whose upper-right story bridged the gutter between the column
  /// below and the sidebar beside it collapsed the page into "one column", fell
  /// back to top-then-left, and turned 50 recognized lines into 46 one-line
  /// blocks. Grouping first makes the paragraphs immune to that, and gives the
  /// ordering pass tight, content-sized units to reason about instead of ML
  /// Kit's block boxes (which on the same pages are 1000 px wide and bridge every
  /// gutter on the page).
  static List<List<OcrLine>> _readOrder(
    List<OcrLine> lines, {
    required Map<OcrLine, OcrBlock> blockOfLine,
    Set<OcrLine> rowMates = const <OcrLine>{},
    double pageWidth = 0,
  }) {
    if (lines.isEmpty) return const <List<OcrLine>>[];
    final median = _medianHeight(lines.map((line) => line.boundingBox));
    final runs = _runs(
      lines,
      blockOfLine: blockOfLine,
      median: median,
      pageWidth: pageWidth,
    );
    final chains = _chains(
      runs,
      blockOfLine: blockOfLine,
      rowMates: rowMates,
      median: median,
      pageWidth: pageWidth,
    );
    final ordered = _orderRegion(chains, median, 0);
    return <List<OcrLine>>[
      for (final chain in ordered)
        <OcrLine>[for (final run in chain.runs) ...run.lines],
    ];
  }

  /// Groups [lines] into **printed rows**.
  ///
  /// Almost always one line per run. The exception is a line ML Kit split into
  /// two boxes on the same row (`…संविदाकर्मियों को राहत, नियम` +
  /// `2022 के तहत लाभ मिलेगा`): the halves are the two parts of one printed
  /// line, so they are joined left-to-right *before* anything measures
  /// vertical gaps, instead of pretending the second half is a separate line.
  static List<_Run> _runs(
    List<OcrLine> lines, {
    required Map<OcrLine, OcrBlock> blockOfLine,
    required double median,
    required double pageWidth,
  }) {
    final sorted = _byTopThenLeft(lines);
    final taken = <OcrLine>{};
    final runs = <_Run>[];
    for (final line in sorted) {
      if (taken.contains(line)) continue;
      final group = <OcrLine>[line];
      taken.add(line);
      var extended = true;
      while (extended) {
        extended = false;
        for (final other in sorted) {
          if (taken.contains(other)) continue;
          final last = group.last.boundingBox;
          final box = other.boundingBox;
          // Only within one ML Kit region. Two passes over the same photograph —
          // or two blocks that a merge threshold deliberately kept apart — can
          // put two boxes on one row as well, and those are two *readings*, not
          // two halves of one line; joining them would concatenate a Latin and a
          // Devanagari reading of the same ink into one string.
          if (!_sameBlock(group.first, other, blockOfLine)) continue;
          // Two boxes on one row whose spans *overlap* are one printed line the
          // engine cut in two — `पहाड़ियों का समूह` and `मानने के` are the two
          // halves of a single line, and translating them apart produced a
          // two-word paragraph in the middle of a column. Table cells and body
          // columns never overlap horizontally, so this cannot join them.
          final splitLine =
              _sameRow(last, box) && _horizontalOverlap(last, box) > 0;
          // A *wide* pair is the same thing on a bigger scale: a headline line
          // split into a short half and a long one, where the two boxes may sit
          // side by side without overlapping.
          final widePair = _isWideFragmentPair(last, box, pageWidth, median);
          if (!splitLine && !widePair) continue;
          if (box.centerX <= last.centerX) continue;
          group.add(other);
          taken.add(other);
          extended = true;
          break;
        }
      }
      runs.add(_Run(List<OcrLine>.unmodifiable(group), boundsOf(group)));
    }
    return runs;
  }

  /// Links runs into **paragraph chains**.
  ///
  /// Each run claims at most one successor and is claimed by at most one
  /// predecessor: the nearest eligible run below it, in the same column, within
  /// ordinary leading, at the same type size, and not separated by an engine
  /// block boundary that the rules in [_mayJoinAcrossBlocks] refuse to cross
  /// (two single-line blocks side by side twice are table rows; a wrapped
  /// address is not).
  ///
  /// Working from the closest run down keeps a list or a table from being zipped
  /// together: a cell's nearest neighbour below is the cell under it, never the
  /// cell to its right.
  static List<_Chain> _chains(
    List<_Run> runs, {
    required Map<OcrLine, OcrBlock> blockOfLine,
    required Set<OcrLine> rowMates,
    required double median,
    required double pageWidth,
  }) {
    final order = List<int>.generate(runs.length, (index) => index)
      ..sort((a, b) {
        final byTop = runs[a].bounds.top.compareTo(runs[b].bounds.top);
        return byTop != 0
            ? byTop
            : runs[a].bounds.left.compareTo(runs[b].bounds.left);
      });

    final successor = <int, int>{};
    final claimed = <int>{};
    // How many runs the chain that reaches each run is long. A run's predecessor
    // is always above it, and runs are visited top to bottom, so this is known by
    // the time the run is used.
    final chainLength = <int, int>{};
    for (final index in order) {
      final run = runs[index];
      final length = chainLength[index] ?? 1;
      int? best;
      var bestGap = double.infinity;
      for (final other in order) {
        if (other == index || claimed.contains(other)) continue;
        final next = runs[other];
        final gap = next.bounds.top - run.bounds.bottom;
        if (gap > run.bounds.height * paragraphGapFactor + 2) continue;
        if (!_continues(
          run.bounds,
          next.bounds,
          median,
          sameBlock: _sameBlock(run.last, next.first, blockOfLine),
          pageWidth: pageWidth,
        )) {
          continue;
        }
        if (!_mayJoinAcrossBlocks(
          run.last,
          next.first,
          blockOfLine,
          rowMates: rowMates,
          runLength: length,
        )) {
          continue;
        }
        if (gap < bestGap) {
          bestGap = gap;
          best = other;
        }
      }
      if (best != null) {
        successor[index] = best;
        claimed.add(best);
        chainLength[best] = length + 1;
      }
    }

    final chains = <_Chain>[];
    for (final root in order) {
      if (claimed.contains(root)) continue;
      final chain = <_Run>[];
      var cursor = root;
      for (var step = 0; step <= runs.length; step++) {
        chain.add(runs[cursor]);
        final next = successor[cursor];
        if (next == null) break;
        cursor = next;
      }
      chains.add(_Chain(List<_Run>.unmodifiable(chain)));
    }
    return chains;
  }

  /// How much of a region's text may *cross* a cut for it to still count as a
  /// gutter. A headline deliberately spans the columns under it, so refusing
  /// every cut a wide line crosses would make a newspaper unreadable in column
  /// order — the banner is emitted at its own vertical position instead (see
  /// [_mergeWithAnchors]). Past this share, the "gutter" is just a ragged edge
  /// inside one block of text.
  static const double maxCrossingRatio = 0.4;

  /// Share of a region's height a channel must be free for, before it counts as
  /// a column gutter rather than a ragged edge.
  static const double minColumnCoverage = 0.3;

  /// Orders [chains] for reading: columns first, then bands, then top-to-bottom.
  ///
  /// Recursive, and re-measured at every level, because a page is not one layout:
  /// a newspaper has a banner above two or three columns, a letter has a date
  /// block above a body and a signature below, a notice has a centred title above
  /// a full-width paragraph, and a form is a grid. Each level looks for the
  /// strongest structure still present in the region it was given:
  ///
  /// 1. a **vertical gutter** — a free channel with real text on both sides —
  ///    splits the region into columns;
  /// 2. otherwise a **horizontal band** at least a line tall splits it into
  ///    stacked sections, which are read top to bottom;
  /// 3. otherwise the region is one column and is read top to bottom.
  static List<_Chain> _orderRegion(
    List<_Chain> chains,
    double median,
    int depth,
  ) {
    if (chains.length <= 1) return chains;
    if (median <= 0 || depth > 12) return _sortedChains(chains);

    // Display type is a different structural level from the body text around it,
    // so it is placed by its own vertical position rather than being treated as
    // one more item in a column. This is what keeps a headline's two boxes —
    // separate ML Kit blocks, so not one printed row — above the columns they
    // span, instead of letting the left half be read with the left column and the
    // right half with the right one.
    final display = <_Chain>[];
    final body = <_Chain>[];
    for (final chain in chains) {
      final height = chain.runs.first.bounds.height;
      (median > 0 && height >= median * displayLineFactor ? display : body).add(
        chain,
      );
    }
    if (display.isNotEmpty && body.isNotEmpty) {
      return _mergeAnchors(
        <List<_Chain>>[_orderRegion(body, median, depth + 1)],
        _sortedChains(display),
        median,
      );
    }

    final gutter = _gutterSplit(chains, median);
    if (gutter != null) {
      final left = _orderRegion(gutter.left, median, depth + 1);
      final right = _orderRegion(gutter.right, median, depth + 1);
      final anchors = _sortedChains(gutter.crossing);
      if (anchors.isEmpty) return _mergeColumns(left, right, median);
      return _mergeAnchors(<List<_Chain>>[left, right], anchors, median);
    }

    final rows = _rowSplit(chains, median);
    if (rows.length > 1) {
      return <_Chain>[
        for (final row in rows) ..._orderRegion(row, median, depth + 1),
      ];
    }
    return _sortedChains(chains);
  }

  /// The widest free vertical channel in [chains] that really separates columns.
  ///
  /// The channel is measured between chain **bounds**, not ML Kit block boxes,
  /// and a chain that crosses it does not disqualify it — a headline does exactly
  /// that on purpose. It is disqualified when too much of the region crosses it,
  /// which is what a ragged right edge inside one column of text looks like.
  static _Gutter? _gutterSplit(List<_Chain> chains, double median) {
    final edges = <double>{};
    for (final chain in chains) {
      edges
        ..add(chain.bounds.left)
        ..add(chain.bounds.right);
    }
    final sorted = edges.toList()..sort();
    final minimum = math.max(minGutter, median * gutterFactor);
    final region = _regionOf(chains);

    _Gutter? best;
    var bestFree = 0.0;
    var bestWidth = 0.0;
    for (var index = 0; index + 1 < sorted.length; index++) {
      final start = sorted[index];
      final end = sorted[index + 1];
      final width = end - start;
      if (width < minimum) continue;

      final left = <_Chain>[];
      final right = <_Chain>[];
      final crossing = <_Chain>[];
      for (final chain in chains) {
        final box = chain.bounds;
        if (box.right <= start + 0.5) {
          left.add(chain);
        } else if (box.left >= end - 0.5) {
          right.add(chain);
        } else {
          crossing.add(chain);
        }
      }
      if (left.isEmpty || right.isEmpty) continue;
      if (crossing.length > chains.length * maxCrossingRatio) continue;

      // The channel has to be free *vertically* as well as horizontally. Without
      // this, the interval from one chain's own left edge to its own right edge
      // — the middle of a box — looks like a wide free gap with the box itself as
      // the only thing crossing it, and a page whose columns are each a single
      // chain splits down the middle of a column.
      final free = _freeVerticalRun(crossing, region);
      if (free < region.height * minColumnCoverage) continue;

      // The channel that is free for the longest stretch of the page is the real
      // gutter: a ragged right edge leaves a wide gap that exists on one row
      // only, while a column gutter runs beside the whole column.
      final better =
          free > bestFree + 0.5 ||
          ((free - bestFree).abs() <= 0.5 && width > bestWidth);
      if (better) {
        bestFree = free;
        bestWidth = width;
        best = _Gutter(left: left, right: right, crossing: crossing);
      }
    }
    return best;
  }

  /// Bounding box of a region's chains.
  static OcrRect _regionOf(List<_Chain> chains) {
    double? left;
    double? top;
    double? right;
    double? bottom;
    for (final chain in chains) {
      final box = chain.bounds;
      left = left == null ? box.left : math.min(left, box.left);
      top = top == null ? box.top : math.min(top, box.top);
      right = right == null ? box.right : math.max(right, box.right);
      bottom = bottom == null ? box.bottom : math.max(bottom, box.bottom);
    }
    return OcrRect.fromLTRB(left!, top!, right!, bottom!);
  }

  /// Longest vertical stretch of [region] that no chain in [crossing] covers.
  ///
  /// A gutter that is only free for the top tenth of a page is not a column
  /// separator — it is the ragged edge of one line.
  static double _freeVerticalRun(List<_Chain> crossing, OcrRect region) {
    if (crossing.isEmpty) return region.height;
    final spans = <(double, double)>[
      for (final chain in crossing) (chain.bounds.top, chain.bounds.bottom),
    ]..sort((a, b) => a.$1.compareTo(b.$1));
    var best = 0.0;
    var cursor = region.top;
    for (final span in spans) {
      final start = math.max(region.top, span.$1);
      if (start > cursor) best = math.max(best, start - cursor);
      cursor = math.max(cursor, math.min(region.bottom, span.$2));
    }
    if (cursor < region.bottom) best = math.max(best, region.bottom - cursor);
    return best;
  }

  /// Splits [chains] at every horizontal free band at least
  /// [bandGapFactor] of a line tall, top to bottom.
  ///
  /// The threshold is what keeps a column of text in one piece: paragraph gaps
  /// inside a column are two or three pixels, while the space between a headline
  /// and the body under it, or between a body and a footer, is a whole line.
  static List<List<_Chain>> _rowSplit(List<_Chain> chains, double median) {
    final sorted = _sortedChains(chains);
    final minimum = math.max(minGutter, median * bandGapFactor);
    final rows = <List<_Chain>>[];
    var current = <_Chain>[sorted.first];
    var bottom = sorted.first.bounds.bottom;
    for (final chain in sorted.skip(1)) {
      if (chain.bounds.top - bottom >= minimum) {
        rows.add(current);
        current = <_Chain>[chain];
        bottom = chain.bounds.bottom;
        continue;
      }
      current.add(chain);
      bottom = math.max(bottom, chain.bounds.bottom);
    }
    rows.add(current);
    return rows;
  }

  /// Reads two ordered column runs as one sequence.
  ///
  /// The rule is what a person does with a page that has a block on the left and
  /// a block on the right: if one of them finishes above where the other starts,
  /// the upper one is read first (a letter's date, a right-aligned reference, a
  /// signature at the foot); if they overlap, they are parallel columns and the
  /// left one is read to its end before the right one starts.
  ///
  /// Side-by-side *cells* are the exception: a form or table is read row by row,
  /// which [_isGrid] recognises from the shape of the chains (short, single-line,
  /// row-aligned) and never from the text, so prose in two columns is never
  /// mistaken for a table.
  static List<_Chain> _mergeColumns(
    List<_Chain> left,
    List<_Chain> right,
    double median,
  ) {
    if (left.isEmpty) return right;
    if (right.isEmpty) return left;
    if (_isGrid(left, right, median)) {
      return _rowMajor(<_Chain>[...left, ...right]);
    }

    final merged = <_Chain>[];
    var i = 0;
    var j = 0;
    while (i < left.length && j < right.length) {
      final a = left[i];
      final b = right[j];
      if (a.bounds.bottom <= b.bounds.top) {
        merged.add(a);
        i++;
        continue;
      }
      if (b.bounds.bottom <= a.bounds.top) {
        merged.add(b);
        j++;
        continue;
      }
      merged.addAll(left.sublist(i));
      merged.addAll(right.sublist(j));
      return merged;
    }
    merged.addAll(left.sublist(i));
    merged.addAll(right.sublist(j));
    return merged;
  }

  /// Emits the chains that cross the gutter — a spanning headline, a footer
  /// banner — at their own vertical position, with the column text above each of
  /// them read first.
  static List<_Chain> _mergeAnchors(
    List<List<_Chain>> streams,
    List<_Chain> anchors,
    double medianHeight,
  ) {
    final merged = <_Chain>[];
    final consumed = <_Chain>{};
    final slack = medianHeight * 0.5;
    for (final anchor in anchors) {
      // Everything above the anchor is read before it, in the order its own
      // stream already put it. `slack` covers a chain that touches the anchor's
      // top edge by a pixel or two, which is how a heading and the line above it
      // usually sit on a photograph.
      for (final chains in streams) {
        for (final chain in chains) {
          if (consumed.contains(chain)) continue;
          if (chain.bounds.bottom > anchor.bounds.top + slack) continue;
          consumed.add(chain);
          merged.add(chain);
        }
      }
      consumed.add(anchor);
      merged.add(anchor);
    }
    for (final chains in streams) {
      for (final chain in chains) {
        if (consumed.contains(chain)) continue;
        merged.add(chain);
      }
    }
    return merged;
  }

  /// Whether two side-by-side runs of chains are a grid of cells rather than
  /// columns of prose.
  ///
  /// Prose arrives as multi-line paragraphs and stands taller than a line; table
  /// cells are single-line, short, and most of them have a partner on the same
  /// row. Merely aligning rows is not enough on its own — newspaper columns
  /// align line for line — so the paragraph-shape check comes first.
  static bool _isGrid(List<_Chain> left, List<_Chain> right, double median) {
    final chains = <_Chain>[...left, ...right];
    if (chains.length < 4) return false;

    var prose = 0;
    for (final chain in chains) {
      if (chain.runs.length > 1) prose++;
    }
    if (prose > chains.length * 0.2) return false;

    for (final chain in chains) {
      if (median > 0 && chain.bounds.height > median * maxCellHeightFactor) {
        return false;
      }
    }

    var aligned = 0;
    for (final chain in left) {
      if (right.any((other) => _sameRow(chain.bounds, other.bounds))) aligned++;
    }
    for (final chain in right) {
      if (left.any((other) => _sameRow(chain.bounds, other.bounds))) aligned++;
    }
    return aligned / chains.length >= tableRowAlignment;
  }

  /// Row-major order for a grid: one row's cells left to right, then the next.
  static List<_Chain> _rowMajor(List<_Chain> chains) {
    final rows = <List<_Chain>>[];
    for (final chain in _sortedChains(chains)) {
      List<_Chain>? target;
      for (final row in rows) {
        if (_sameRow(chain.bounds, row.first.bounds)) {
          target = row;
          break;
        }
      }
      if (target == null) {
        rows.add(<_Chain>[chain]);
      } else {
        target.add(chain);
      }
    }
    return <_Chain>[
      for (final row in rows)
        for (final chain
            in (row..sort((a, b) => a.bounds.left.compareTo(b.bounds.left))))
          chain,
    ];
  }

  static List<_Chain> _sortedChains(Iterable<_Chain> chains) {
    final sorted = <_Chain>[...chains];
    sorted.sort((a, b) {
      final byTop = a.bounds.top.compareTo(b.bounds.top);
      return byTop != 0 ? byTop : a.bounds.left.compareTo(b.bounds.left);
    });
    return sorted;
  }

  /// Lines that share a row with a line belonging to a **different** block.
  ///
  /// This is the geometric evidence that a row is part of a grid: a table or
  /// form row always has something printed beside it, while a wrapped address
  /// or paragraph line stands alone on its row. Paragraph formation uses it to
  /// decide whether two stacked single-line blocks may be one paragraph (see
  /// [_mayJoinAcrossBlocks]).
  static Set<OcrLine> _rowMates(
    List<OcrLine> lines,
    Map<OcrLine, OcrBlock> blockOfLine,
  ) {
    final mates = <OcrLine>{};
    for (var i = 0; i < lines.length; i++) {
      for (var j = i + 1; j < lines.length; j++) {
        final a = lines[i];
        final b = lines[j];
        if (!_sameRow(a.boundingBox, b.boundingBox)) continue;
        final first = blockOfLine[a];
        final second = blockOfLine[b];
        if (first != null && second != null && identical(first, second)) {
          continue;
        }
        mates
          ..add(a)
          ..add(b);
      }
    }
    return mates;
  }

  /// Whether two boxes occupy the same visual row.
  static bool _sameRow(OcrRect a, OcrRect b) {
    if (a.isEmpty || b.isEmpty) return false;
    final overlap = math.min(a.bottom, b.bottom) - math.max(a.top, b.top);
    return overlap >= math.min(a.height, b.height) * 0.5;
  }

  /// Width of the shared x-range of two boxes, `0` when they do not overlap.
  static double _horizontalOverlap(OcrRect a, OcrRect b) {
    final overlap = math.min(a.right, b.right) - math.max(a.left, b.left);
    return overlap > 0 ? overlap : 0;
  }

  static int _compareTopThenLeft(OcrLine a, OcrLine b) {
    final byTop = a.boundingBox.top.compareTo(b.boundingBox.top);
    if (byTop != 0) return byTop;
    return a.boundingBox.left.compareTo(b.boundingBox.left);
  }

  static List<OcrLine> _byTopThenLeft(Iterable<OcrLine> lines) =>
      <OcrLine>[...lines]..sort(_compareTopThenLeft);

  // --- joining --------------------------------------------------------------

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
  /// * neither line has a **row mate** — a line from another block printed on
  ///   the same row. That is the difference between two stacked table cells (a
  ///   receipt's "Invoice No" beside "Invoice Date", a form's label beside its
  ///   value) and two wrapped lines of one address: the cells have a partner on
  ///   their row, wrapped prose does not. Without this rule an address like
  ///   `Plot No. 31/13, First Floor, S` / `ector-76 …` was kept as two separate
  ///   units and translated as two unrelated fragments, which is what the
  ///   overlay showed as cut-off text on a shipping label.
  /// * the two lines actually read as **one wrapped sentence**: the next line
  ///   starts in lowercase, or the previous one ends mid-word (a hyphen, a
  ///   comma, or a single trailing letter). Two equally wide, capitalised,
  ///   number-terminated rows ("Polling team 1" / "Polling team 2") fail all
  ///   three and stay separate. Scripts without letter case (Devanagari, Tamil,
  ///   Telugu …) have no case cue at all, so they are joined on the geometry
  ///   alone — which is what [_looksWrapped] documents.
  ///
  /// A one-line paragraph that ML Kit split after a single line therefore stays
  /// split unless the text itself shows the wrap, or the script cannot show one
  /// and the geometry is unambiguous.
  static bool _mayJoinAcrossBlocks(
    OcrLine previous,
    OcrLine next,
    Map<OcrLine, OcrBlock>? blockOfLine, {
    Set<OcrLine>? rowMates,
    int runLength = 1,
  }) {
    if (blockOfLine == null) return true;
    final previousBlock = blockOfLine[previous];
    final nextBlock = blockOfLine[next];
    if (previousBlock == null || nextBlock == null) return true;
    if (identical(previousBlock, nextBlock)) return true;
    if (previousBlock.lines.length <= 1 && nextBlock.lines.length <= 1) {
      final mates = rowMates;
      if (mates == null) return false;
      if (mates.contains(previous) || mates.contains(next)) return false;
      if (!_looksWrapped(previous, next)) {
        // Neither the punctuation nor the case says "the sentence continues".
        // Only a short tail of an already multi-line run is still allowed: that
        // is a paragraph's final word or two, not a new row of a list.
        final isTail =
            runLength >= 2 &&
            next.boundingBox.width <
                previous.boundingBox.width * tailWidthRatio;
        if (!isTail) return false;
      }
    }

    final gap = next.boundingBox.top - previous.boundingBox.bottom;
    final tallest = math.max(
      previous.boundingBox.height,
      next.boundingBox.height,
    );
    return gap <= tallest * crossBlockGapFactor;
  }

  /// Whether [next] continues the paragraph that [previous] ends.
  ///
  /// [sameBlock] says whether both lines came out of one ML Kit block, which is
  /// evidence that they are one region and is what makes a short final line
  /// joinable (see [tailWidthRatio]).
  static bool _continues(
    OcrRect a,
    OcrRect b,
    double medianHeight, {
    bool sameBlock = false,
    double pageWidth = 0,
  }) {
    // Two wide boxes on one row are the two halves of one printed line (see
    // [wideFragmentRatio]); the right half continues the left one, so a
    // headline is one unit instead of two untranslatable fragments.
    if (_isWideFragmentPair(a, b, pageWidth, medianHeight)) return true;
    if (!_sameColumn(a, b)) return false;
    if (!_sameIndent(a, b, medianHeight)) return false;
    // Display type (a headline, a pull quote, a sidebar's title) is a different
    // region from body copy even when the two touch: this is the check that
    // keeps a sidebar's heading from being chained onto the end of the headline
    // beside it, or a deck onto the first line of the story under it.
    if (_isDisplayType(a, medianHeight) != _isDisplayType(b, medianHeight)) {
      return false;
    }

    final gap = b.top - a.bottom;
    final tallest = math.max(a.height, b.height);
    if (gap > tallest * paragraphGapFactor + 2) return false;
    // OCR boxes on tight leading can overlap; a whole line of backwards overlap
    // is still the same paragraph, more than that is a different region.
    if (gap < -tallest) return false;

    final shorter = math.min(a.height, b.height);
    if (tallest > 0 && shorter / tallest < heightSimilarity) {
      // A *taller* following line is a heading, a caption or a bigger face under
      // body copy: a different region in every case.
      if (b.height > a.height) return false;
      // A *shorter* following line is one of two things, and width separates
      // them. Inside one block a line that does not fill the measure is the
      // paragraph's final line — including the ordinary Devanagari case where
      // it is simply shorter than the box above. A line that still fills the
      // measure has changed type size, and a byline or caption must stay its own
      // paragraph. Across blocks there is no such evidence, so the strict rule
      // stands.
      if (!sameBlock || b.width > a.width * tailWidthRatio) return false;
    }

    if (medianHeight > 0 && tallest > medianHeight * 3.5) return false;
    return true;
  }

  /// Whether [a] and [b] came out of the same ML Kit block.
  ///
  /// Identity, not equality, and `false` when the block a line belongs to is
  /// unknown — the conservative answer, which keeps the stricter height rule.
  static bool _sameBlock(
    OcrLine a,
    OcrLine b,
    Map<OcrLine, OcrBlock>? blockOfLine,
  ) {
    if (blockOfLine == null) return false;
    final first = blockOfLine[a];
    final second = blockOfLine[b];
    return first != null && second != null && identical(first, second);
  }

  /// Whether [next] looks like the wrapped continuation of [previous].
  ///
  /// For scripts with letter case this is textual, because geometry alone cannot
  /// tell a paragraph that ML Kit split at a block boundary from two rows of a
  /// list: both are stacked, both are tight, and both are single-line blocks. A
  /// wrapped Latin line gives itself away in the text — it starts in lowercase,
  /// or the line above it ends with a hyphen, a comma, a slash or a single
  /// dangling letter (the word was cut by the column edge, e.g.
  /// `… First Floor, S` + `ector-76 …`). A list row starts with a capital or a
  /// digit and ends with a whole word.
  ///
  /// Devanagari, Tamil, Telugu, Kannada and the other caseless scripts have no
  /// such cue, so on those the answer is `true` whenever the text on either side
  /// is caseless: the caller has already required the tight cross-block gap, the
  /// same column and matching type size, and a Hindi paragraph the engine split
  /// at its own block boundary was otherwise impossible to rejoin — every line
  /// became its own translation unit. A row of cells is still protected, because
  /// it is rejected earlier by the row-mate rule, which is a *geometric* fact
  /// about a table and does not depend on the script at all.
  static bool _looksWrapped(OcrLine previous, OcrLine next) {
    final text = next.text.trim();
    if (text.isEmpty) return false;
    final first = text.codeUnitAt(0);
    if (first >= 0x61 && first <= 0x7A) return true; // starts lowercase

    final before = previous.text.trimRight();
    if (before.isEmpty) return false;
    final last = before.codeUnitAt(before.length - 1);
    if (last == 0x2D || last == 0x2C || last == 0x2F) return true; // - , /

    final words = before.split(RegExp(r'\s+'));
    final tail = words.isEmpty ? '' : words.last;
    if (tail.length == 1) {
      final code = tail.codeUnitAt(0);
      if ((code >= 0x41 && code <= 0x5A) || (code >= 0x61 && code <= 0x7A)) {
        return true;
      }
    }

    // No case to read: fall back to the script. A caseless line carries no
    // wrap/no-wrap signal at all, so refusing the join here would guarantee a
    // fragment per engine block boundary.
    return !_hasLetterCase(before) || !_hasLetterCase(text);
  }

  /// Whether [text] contains at least one cased letter (Latin, Greek, Cyrillic).
  ///
  /// Used to decide whether the textual wrap cues in [_looksWrapped] say
  /// anything at all. Devanagari and the other Indic scripts are unicameral, so
  /// "starts with a lowercase letter" is not a question that can be asked of
  /// them.
  static bool _hasLetterCase(String text) {
    for (final rune in text.runes) {
      if (rune >= 0x41 && rune <= 0x5A) return true;
      if (rune >= 0x61 && rune <= 0x7A) return true;
      if (rune >= 0xC0 && rune <= 0x24F && rune != 0xD7 && rune != 0xF7) {
        return true;
      }
      if (rune >= 0x400 && rune <= 0x4FF) return true;
    }
    return false;
  }

  /// Whether [a] and [b] are the two halves of one printed row.
  ///
  /// They must share a row, and both must be either wide for the page or set in
  /// display type ([displayTypeFactor]). Anything less and this is a row of body
  /// columns, which must never be joined into one sentence.
  static bool _isWideFragmentPair(
    OcrRect a,
    OcrRect b,
    double pageWidth,
    double medianHeight,
  ) {
    if (pageWidth <= 0) return false;
    if (!_sameRow(a, b)) return false;

    final wide = pageWidth * wideFragmentRatio;
    if (a.width >= wide && b.width >= wide) return true;

    final display = medianHeight * displayTypeFactor;
    return medianHeight > 0 && a.height >= display && b.height >= display;
  }

  /// How much taller than the page's median line a box must be to count as
  /// display type rather than body copy.
  ///
  /// Lower than [displayTypeFactor], which decides whether a split headline's
  /// halves are *wide enough to be one sentence*: a headline's own lines vary by
  /// 30 % (a matra or a clipped ascender changes the box), while a body line is
  /// within a few percent of its neighbours. 1.4 separates the two on the real
  /// pages this was measured against without needing a guess about font size.
  static const double displayLineFactor = 1.4;

  /// Whether [box] is set in display type, relative to the page's median line.
  static bool _isDisplayType(OcrRect box, double medianHeight) =>
      medianHeight > 0 && box.height >= medianHeight * displayLineFactor;

  /// Whether two boxes share a left margin — or a centre, which is what a
  /// centred heading's own lines share instead.
  ///
  /// This is the guard against chaining two *regions* whose boxes happen to
  /// overlap horizontally: a headline and the sidebar's title beside it start at
  /// margins 400 px apart and are centred on different axes, so neither test
  /// passes. A paragraph passes on the left margin even when its final line is
  /// short, and centred lines pass on their centre.
  static bool _sameIndent(OcrRect a, OcrRect b, double medianHeight) {
    if (medianHeight <= 0) return true;
    final tolerance = medianHeight * 2.5;
    if ((b.left - a.left).abs() <= tolerance) return true;
    return (b.centerX - a.centerX).abs() <= tolerance;
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

  /// Whether [text] ends with a lone capital letter printed after a comma or a
  /// space — the visible half of a word the column cut in two.
  static bool _endsWithDanglingLetter(String text) {
    final trimmed = text.trimRight();
    if (trimmed.length < 2) return false;
    final tail = trimmed.substring(trimmed.length - 1);
    final code = tail.codeUnitAt(0);
    if (code < 0x41 || code > 0x5A) return false;
    final before = trimmed.codeUnitAt(trimmed.length - 2);
    return before == 0x20 || before == 0x2C; // space or comma
  }

  /// Whether [text] looks like the continuation of a hyphenated word rather than
  /// a new sentence after a dash.
  static bool _startsLikeContinuation(String text) {
    if (text.isEmpty) return false;
    final code = text.codeUnitAt(0);
    return code >= 0x61 && code <= 0x7A; // a-z
  }
}

/// One printed row: a single line, or the halves of one line the engine split
/// into two boxes.
class _Run {
  const _Run(this.lines, this.bounds);

  final List<OcrLine> lines;
  final OcrRect bounds;

  OcrLine get first => lines.first;
  OcrLine get last => lines.last;
}

/// One paragraph: runs linked top to bottom, in reading order.
class _Chain {
  _Chain(this.runs)
    : bounds = OcrDocumentLayout.boundsOf(<OcrLine>[
        for (final run in runs) ...run.lines,
      ]);

  final List<_Run> runs;
  final OcrRect bounds;
}

/// A free vertical channel with text on both sides (see [OcrDocumentLayout._gutterSplit]).
class _Gutter {
  const _Gutter({
    required this.left,
    required this.right,
    required this.crossing,
  });

  final List<_Chain> left;
  final List<_Chain> right;
  final List<_Chain> crossing;
}
