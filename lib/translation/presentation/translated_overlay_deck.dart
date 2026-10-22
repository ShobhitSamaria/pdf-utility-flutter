import 'dart:math' as math;

import 'package:flutter/widgets.dart';

import 'translated_text_layout.dart';

/// One region the overlay has to place: its identity, the text to draw, and the
/// source rectangle it came from — already mapped to screen space by the same
/// `OcrCoordinateMapper` the OCR overlay uses.
class TranslatedDeckItem {
  const TranslatedDeckItem({
    required this.id,
    required this.text,
    required this.sourceRect,
  });

  /// Identity of the translated region this came from.
  final int id;

  /// The translated text to draw.
  final String text;

  /// The OCR box it replaces, in screen (logical-pixel) space.
  final Rect sourceRect;

  @override
  String toString() => 'TranslatedDeckItem($id, $sourceRect, "$text")';
}

/// Where one region's translated text was finally drawn.
class TranslatedDeckPlacement {
  const TranslatedDeckPlacement({
    required this.id,
    required this.text,
    required this.sourceRect,
    required this.layout,
    required this.box,
    required this.constrained,
  });

  final int id;
  final String text;
  final Rect sourceRect;

  /// The fitted layout the box came from — font size, line cap and resolved
  /// style, so the widget paints exactly what was measured.
  final TranslatedTextLayout layout;

  /// The final rectangle. Never intersects another placement's [box], anywhere
  /// on the page, and always contains the text it paints.
  final Rect box;

  /// Whether the flow moved this line or shrank its block: `true` when the box
  /// is not simply the line's own text laid out at its own anchor. A region with
  /// room to spare reports `false`.
  final bool constrained;

  @override
  String toString() =>
      'TranslatedDeckPlacement($id, $box, '
      'constrained: $constrained)';
}

/// One **block**: a vertical run of neighbouring lines that belong together —
/// one paragraph, one column's run of text, one multi-line selection.
///
/// A block is the unit the overlay draws. Its lines flow inside it the way text
/// flows inside a paragraph, and it is bounded by the **next block**, not by its
/// own next line.
class TranslatedBlockPlacement {
  const TranslatedBlockPlacement({
    required this.id,
    required this.lines,
    required this.box,
    required this.coverage,
    required this.constrained,
    this.hiddenRegionIds = const <int>[],
  });

  /// Identity of the block: its first line's region id, so a rebuild keeps the
  /// same backing and tests can address it.
  final int id;

  /// The block's lines, in reading order. They never intersect each other, and
  /// each one's text fits inside its own box.
  final List<TranslatedDeckPlacement> lines;

  /// The unified backing: the union of the lines' boxes. Never intersects
  /// another block's [box].
  final Rect box;

  /// The rectangle the paragraph's **veil** covers: [box] united with the
  /// source OCR rectangles of the lines this block actually draws, clipped to
  /// the photo.
  ///
  /// Why the source rectangles are part of it
  /// ---------------------------------------
  /// Lens replaces a paragraph, it does not paste a floating card over its first
  /// two lines. A translated paragraph is almost always shorter than its source,
  /// so a veil sized to the translation alone left the rest of the Hindi visible
  /// underneath — the reader sees English and Hindi of the same paragraph at
  /// once, which is exactly the "original text remains visible under the
  /// translation" defect. Covering the source rectangles of the lines that were
  /// translated hides that paragraph's source completely, while untranslated
  /// parts of the page stay untouched.
  ///
  /// Only **drawn** lines contribute their source rectangles: a line the page
  /// had no room for must not have its Hindi hidden behind a translation that is
  /// not there.
  ///
  /// The coverage can never cover another block's text: paragraphs' source
  /// rectangles are disjoint, [box] already stops [gap] short of the next block,
  /// and the value is clipped to the page area (so it never intrudes on the
  /// overflow notice's reserved strip).
  final Rect coverage;

  /// Whether anything about this block moved or shrank.
  final bool constrained;

  /// Regions of this block that could not be drawn legibly on the image.
  ///
  /// Only a page with no room left produces these: the alternative — a box
  /// shorter than a line of its own text — paints glyphs over the line below,
  /// which is the defect this deck exists to prevent. Their text is *not* lost:
  /// it is still in the translated overlay and therefore in the full translation
  /// sheet and the Translate tab.
  final List<int> hiddenRegionIds;

  /// Whether every line of the block reached the image.
  bool get isComplete => hiddenRegionIds.isEmpty;

  /// The regions this block draws, in reading order.
  List<int> get regionIds => [for (final line in lines) line.id];

  @override
  String toString() =>
      'TranslatedBlockPlacement($id, ${lines.length} lines, '
      '$box, coverage: $coverage, constrained: $constrained, '
      'hidden: $hiddenRegionIds)';
}

/// One complete placement pass: the blocks to draw, and the regions that could
/// not be drawn at all.
///
/// The second list is what makes "nothing is silently lost" checkable. A region
/// can be dropped before it ever reaches a block — its group may start below the
/// photo, its span may leave no usable width, or there may be no room for one
/// measured line — so relying on each block's tail alone under-reported how much
/// of a dense page was actually hidden.
class TranslatedDeckLayout {
  const TranslatedDeckLayout({
    required this.blocks,
    required this.hiddenRegionIds,
  });

  /// Blocks to paint, in reading order.
  final List<TranslatedBlockPlacement> blocks;

  /// Every input region with text that is not painted anywhere on the image,
  /// whether it was hidden inside a block or dropped before placement.
  final List<int> hiddenRegionIds;

  /// Whether every region reached the image.
  bool get isComplete => hiddenRegionIds.isEmpty;

  /// All drawn lines, in reading order.
  List<TranslatedDeckPlacement> get lines => [
    for (final block in blocks) ...block.lines,
  ];

  /// All drawn region ids, in reading order.
  List<int> get drawnRegionIds => [
    for (final block in blocks) ...block.regionIds,
  ];

  @override
  String toString() =>
      'TranslatedDeckLayout(${blocks.length} blocks, '
      'hidden: $hiddenRegionIds)';
}

/// Places **every** translated region of one image as a page-level layout
/// problem, grouped into blocks that flow like text.
///
/// Why this exists
/// ---------------
/// The first two attempts at this both fitted each region on its own and only
/// later noticed that the boxes collided. They also shared a subtler flaw that
/// made the result *look* fixed in tests while still failing on real pages:
///
/// > Collisions were resolved in the coordinate space of the **OCR boxes**,
/// > while the boxes actually painted are **widened** (to `minWidth`) and
/// > re-centred on those OCR boxes.
///
/// A short OCR line — a word, a page number, a narrow column line — renders up
/// to 56 logical pixels wide from a source that may be ten pixels wide. Two
/// such boxes in neighbouring columns do not overlap in OCR space, so the old
/// deck happily drew them on the same row, and their widened rectangles landed
/// on top of each other. On a 300-page fuzz sweep of realistic geometry, 173
/// pages overlapped for exactly this reason.
///
/// The second flaw was vertical: when a page was too dense, the fallback gave
/// every line an equal slice, including slices shorter than one line of its own
/// font. The *rectangles* did not overlap, but the glyphs painted outside their
/// boxes and over the next line. 983 lines in the same sweep did that.
///
/// Both are fixed here, structurally:
///
/// * [TranslatedTextLayout.spanFor] is the single definition of a rendered
///   box's width, used by the fitter **and** by this deck, so the geometry that
///   is checked is the geometry that is painted. Widths are additionally capped
///   at the gutter between same-row neighbours, so a short line does not widen
///   into the column beside it in the first place.
/// * Room is reserved and collisions are resolved against those **rendered**
///   spans, and each block is pushed below any earlier block whose rendered
///   box it would touch. Overlap is therefore impossible by construction, not
///   by eyeballing.
/// * The legibility floor is one painted line: a slice that cannot hold
///   `minimumLineBox` is never used. When even that is impossible, the tail of
///   the block is left undrawn (and reported in [hiddenRegionIds]) rather than
///   painted over its neighbour; its text remains in the translation sheet.
///
/// The rules, in order
/// -------------------
/// 1. **Grouping** — consecutive regions that share columns and sit within
///    [maxLineGapFactor] of a line of each other are one block. Columns are
///    compared by overlap *ratio*, so a caption that merely touches a column's
///    edge does not merge into it.
/// 2. **Vertical flow** — inside a block, line `N` starts at
///    `top(N-1) + height(N-1) + [lineSpacing]`. A longer translation pushes the
///    rest of its paragraph down rather than growing over it.
/// 3. **Bounded room** — a block may occupy only the space between its own top
///    and the top of the next block whose rendered span it crosses, and never
///    leaves the photo.
/// 4. **Uniform shrink** — when the flowed block does not fit that room, every
///    line in it is refitted with the *same* reduced font ceiling (searched for
///    by bisection, not guessed) until the whole block fits *without any line
///    being squeezed*. One paragraph keeps one text size.
/// 5. **Equal shares** — a page can be dense enough that no legible size lets
///    every line have its natural height. Then each line gets the *same* slice
///    of the room, provided that slice can still hold one line of text. Every
///    line is drawn; longer ones ellipsize, and a tap opens the full text.
/// 6. **Last resort** — when not even a one-line slice fits, as many lines as
///    fit are drawn and the rest are reported as [hiddenRegionIds]. Their text
///    stays available in the translation sheet. Nothing is painted over
///    anything else.
///
/// Guarantees (see `test/translated_overlay_deck_test.dart` and
/// `test/translated_overlay_collision_test.dart`)
/// ----------------------------------------------------------------
/// * two placements never intersect — not within a block, not between blocks;
/// * every drawn line's text is fully inside its box (no glyph bleed);
/// * no block leaves the displayed photo, and none intrudes into another's room;
/// * placements come back in the reading order of their source regions;
/// * the flow formula holds exactly: line `N`'s top is line `N-1`'s bottom plus
///   [lineSpacing];
/// * a region with nothing in its way is placed exactly where
///   [TranslatedTextLayout.fit] puts it — the deck is a no-op when there is no
///   conflict to resolve.
abstract final class TranslatedOverlayDeck {
  /// Clear space kept between two *blocks*.
  static const double gap = 2;

  /// Clear space kept between two *lines of the same block* — the `lineSpacing`
  /// of the flow formula. The same order as a paragraph's leading, deliberately,
  /// rather than the gap you would leave between unrelated boxes.
  static const double lineSpacing = 2;

  /// Smallest height the deck will ask for, so a squeezed line still gets a
  /// measurable box to ellipsize into instead of collapsing to nothing.
  static const double minBoxHeight = 8;

  /// How far apart two lines may be, as a multiple of their own height, and
  /// still count as the same paragraph. Below 1.0 a paragraph breaks at any gap
  /// wider than a line, which is what keeps a heading out of the body text
  /// beneath it and a separate column separate.
  static const double maxLineGapFactor = 0.8;

  /// How much of the narrower box must overlap for two lines to count as the
  /// same column. A caption that only clips the edge of a column is not that
  /// column.
  static const double columnOverlapRatio = 0.45;

  /// Clear space kept between two boxes that share a row while their widths are
  /// resolved, so a widened short line stops at the gutter.
  static const double gutter = 1;

  /// Smallest font scale the block search will try before giving up and
  /// switching to equal slices. Below this the text would not be legible
  /// anyway.
  static const double minBlockScale = 0.55;

  /// How much taller than its source region one item may grow on its own before
  /// the deck starts shrinking instead of pushing later blocks down.
  ///
  /// Without a cap, a short table cell's translation could use all the room to
  /// the bottom of the photo: the box grew, every later block in that column was
  /// pushed below it, and the translation for each cell ended up floating over a
  /// different cell — "the translation is over the wrong text". A modest growth
  /// allowance keeps a wrapped label inside its own neighbourhood while still
  /// letting a paragraph breathe.
  static const double maxNaturalGrowth = 1.6;

  /// Iterations of the shrink search. Six bisections resolve the scale to about
  /// 1.5%, finer than any legibility difference, and they keep a dense page to a
  /// bounded number of text measurements.
  static const int shrinkSteps = 6;

  /// Places [items] inside [imageRect] (the displayed photo), grouped into
  /// blocks that flow.
  ///
  /// [style], [textScaler] and [textDirection] are passed straight through to
  /// [TranslatedTextLayout.fit], so the overlay and this pass can never disagree
  /// about how big a font is or which way it reads.
  ///
  /// [bottomReserve] keeps the bottom of the photo clear for UI the overlay
  /// draws over it (the "did not fit" notice), so that notice can never cover
  /// the last translated line — a collision in a different form.
  static TranslatedDeckLayout layout({
    required List<TranslatedDeckItem> items,
    required Rect imageRect,
    required TextStyle style,
    TextScaler textScaler = TextScaler.noScaling,
    TextDirection textDirection = TextDirection.ltr,
    double minSize = TranslatedTextLayout.defaultMinSize,
    double maxSize = TranslatedTextLayout.defaultMaxSize,
    double minWidth = TranslatedTextLayout.defaultMinWidth,
    int lineCap = TranslatedTextLayout.defaultLineCap,
    double gap = gap,
    double lineSpacing = lineSpacing,
    double bottomReserve = 0,
    double? maxSizeCeiling,
  }) {
    if (items.isEmpty || imageRect.isEmpty) {
      return const TranslatedDeckLayout(
        blocks: <TranslatedBlockPlacement>[],
        hiddenRegionIds: <int>[],
      );
    }

    // Anything undrawable is dropped *before* grouping, so a blank region never
    // splits a paragraph in two.
    final usable = <TranslatedDeckItem>[
      for (final item in items)
        if (!item.sourceRect.isEmpty && item.text.trim().isNotEmpty) item,
    ];
    if (usable.isEmpty) {
      return TranslatedDeckLayout(
        blocks: const <TranslatedBlockPlacement>[],
        hiddenRegionIds: [
          for (final item in items)
            if (item.text.trim().isNotEmpty) item.id,
        ],
      );
    }

    // The rectangle translations may occupy: the photo minus the strip that
    // overlay chrome needs. Width is unchanged, so the mapper still decides
    // every horizontal coordinate.
    final pageRect = bottomReserve <= 0
        ? imageRect
        : Rect.fromLTRB(
            imageRect.left,
            imageRect.top,
            imageRect.right,
            math.max(imageRect.top, imageRect.bottom - bottomReserve),
          );

    final ordered = <TranslatedDeckItem>[...usable]..sort(_readingOrder);
    final spans = _resolveSpans(
      ordered,
      imageRect: pageRect,
      minWidth: minWidth,
    );
    final groups = _group(ordered, gap: gap);
    final groupSpans = <_Span>[
      for (final group in groups)
        _Span.union([for (final item in group) spans[item.id]!]),
    ];
    final anchors = <double>[
      for (final group in groups)
        TranslatedTextLayout.anchoredTop(group.first.sourceRect, pageRect),
    ];

    final placed = <Rect>[];
    final blocks = <TranslatedBlockPlacement>[];
    for (var index = 0; index < groups.length; index++) {
      final group = groups[index];
      final span = groupSpans[index];
      if (group.isEmpty) continue;

      // Rule 3a: no block is drawn over one that is already on the page. This
      // compares *rendered* spans, which is the whole point: an OCR box and the
      // widened box painted over it are not the same rectangle.
      var top = anchors[index];
      for (final box in placed) {
        if (!span.overlapsRect(box, slack: gap)) continue;
        final below = box.bottom + gap;
        if (below > top) top = below;
      }
      if (top >= pageRect.bottom - minBoxHeight) continue;

      // Rule 3b: reserve the room down to the next block that this one could
      // actually touch. Blocks beside it — the other column — must not shorten
      // it, which is why this uses rendered spans rather than "same page".
      var limit = pageRect.bottom;
      for (var other = index + 1; other < groups.length; other++) {
        if (!span.overlaps(groupSpans[other], slack: gap)) continue;
        final candidate = math.max(anchors[other], top) - gap;
        if (candidate < limit) limit = candidate;
      }

      final floor = _minimumLegibleBox(
        group,
        style: style,
        minSize: minSize,
        textScaler: textScaler,
        textDirection: textDirection,
      );
      var room = limit - top;
      if (room < floor) {
        // The reservation is tighter than a single legible line. Rather than
        // paint over the neighbour, let this block use the rest of the photo;
        // blocks below it are pushed by its placed box when their turn comes.
        room = pageRect.bottom - top;
      }
      if (room < floor) continue;

      var chosen = _flow(
        group: group,
        spans: spans,
        imageRect: pageRect,
        style: style,
        textScaler: textScaler,
        textDirection: textDirection,
        minSize: minSize,
        maxSize: maxSize,
        minWidth: minWidth,
        lineCap: lineCap,
        anchor: top,
        room: room,
        lineSpacing: lineSpacing,
        scale: 1,
        budget: _Budget.natural,
        maxSizeCeiling: maxSizeCeiling,
      );

      final complete =
          chosen.lines.length == group.length && chosen.used <= room + 0.01;
      if (!complete) {
        // Rule 4: the whole paragraph shrinks together until it fits as it is.
        final shrunk = _searchScale(
          group: group,
          spans: spans,
          imageRect: pageRect,
          style: style,
          textScaler: textScaler,
          textDirection: textDirection,
          minSize: minSize,
          maxSize: maxSize,
          minWidth: minWidth,
          lineCap: lineCap,
          anchor: top,
          room: room,
          lineSpacing: lineSpacing,
          maxSizeCeiling: maxSizeCeiling,
        );

        if (shrunk != null) {
          chosen = shrunk;
        } else {
          // Rule 5: equal slices, but only slices that can hold a painted line.
          final share =
              (room - lineSpacing * (group.length - 1)) / group.length;
          final sliced = share >= floor
              ? _flow(
                  group: group,
                  spans: spans,
                  imageRect: pageRect,
                  style: style,
                  textScaler: textScaler,
                  textDirection: textDirection,
                  minSize: minSize,
                  maxSize: maxSize,
                  minWidth: minWidth,
                  lineCap: lineCap,
                  anchor: top,
                  room: room,
                  lineSpacing: lineSpacing,
                  scale: 1,
                  budget: _Budget.fixed,
                  fixedBudget: share,
                  maxSizeCeiling: maxSizeCeiling,
                )
              : null;
          // Rule 6: the tail is left undrawn rather than squeezed into a box
          // shorter than its own text.
          chosen = sliced != null && sliced.lines.length == group.length
              ? sliced
              : _flow(
                  group: group,
                  spans: spans,
                  imageRect: pageRect,
                  style: style,
                  textScaler: textScaler,
                  textDirection: textDirection,
                  minSize: minSize,
                  maxSize: maxSize,
                  minWidth: minWidth,
                  lineCap: lineCap,
                  anchor: top,
                  room: room,
                  lineSpacing: lineSpacing,
                  scale: minBlockScale,
                  budget: _Budget.remaining,
                  maxSizeCeiling: maxSizeCeiling,
                );
        }
      }

      if (chosen.lines.isEmpty) continue;
      final box = _unionOf([for (final line in chosen.lines) line.box]);
      // Lens replaces the paragraph it translated: the veil covers the source
      // lines too, so their Hindi cannot show through beside the English. It is
      // clipped to the page area so it can never reach the overflow notice.
      final coverage = _unionOf([
        box,
        for (final line in chosen.lines) line.sourceRect,
      ]).intersect(pageRect);
      placed.add(box);
      blocks.add(
        TranslatedBlockPlacement(
          id: group.first.id,
          lines: chosen.lines,
          box: box,
          coverage: coverage.isEmpty ? box : coverage,
          constrained:
              chosen.lines.any((line) => line.constrained) ||
              chosen.lines.length < group.length,
          hiddenRegionIds: [
            for (var i = chosen.lines.length; i < group.length; i++)
              group[i].id,
          ],
        ),
      );
    }

    // A region can also be dropped *before* it gets a block at all: its group may
    // start below the photo, its single line may have no room for even one
    // measured line, or its span may leave no usable width. Those used to vanish
    // with no record, so a dense page could hide a third of its translation and
    // still claim every region had been placed. They are reported here instead,
    // and the overlay offers the full text for them.
    final drawn = <int>{for (final block in blocks) ...block.regionIds};
    return TranslatedDeckLayout(
      blocks: blocks,
      hiddenRegionIds: [
        for (final item in items)
          if (item.text.trim().isNotEmpty && !drawn.contains(item.id)) item.id,
      ],
    );
  }

  /// The blocks only — see [layout] for the same placement with the list of
  /// regions that could not be drawn.
  static List<TranslatedBlockPlacement> buildBlocks({
    required List<TranslatedDeckItem> items,
    required Rect imageRect,
    required TextStyle style,
    TextScaler textScaler = TextScaler.noScaling,
    TextDirection textDirection = TextDirection.ltr,
    double minSize = TranslatedTextLayout.defaultMinSize,
    double maxSize = TranslatedTextLayout.defaultMaxSize,
    double minWidth = TranslatedTextLayout.defaultMinWidth,
    int lineCap = TranslatedTextLayout.defaultLineCap,
    double gap = gap,
    double lineSpacing = lineSpacing,
    double? maxSizeCeiling,
  }) => layout(
    items: items,
    imageRect: imageRect,
    style: style,
    textScaler: textScaler,
    textDirection: textDirection,
    minSize: minSize,
    maxSize: maxSize,
    minWidth: minWidth,
    lineCap: lineCap,
    gap: gap,
    lineSpacing: lineSpacing,
    maxSizeCeiling: maxSizeCeiling,
  ).blocks;

  /// Places [items] and returns the **lines** flat, in reading order.
  ///
  /// Kept because the contract most callers care about — every region is drawn
  /// once, in reading order, and no two boxes intersect — reads better as a flat
  /// list. The block structure itself is available from [buildBlocks].
  static List<TranslatedDeckPlacement> build({
    required List<TranslatedDeckItem> items,
    required Rect imageRect,
    required TextStyle style,
    TextScaler textScaler = TextScaler.noScaling,
    TextDirection textDirection = TextDirection.ltr,
    double minSize = TranslatedTextLayout.defaultMinSize,
    double maxSize = TranslatedTextLayout.defaultMaxSize,
    double minWidth = TranslatedTextLayout.defaultMinWidth,
    int lineCap = TranslatedTextLayout.defaultLineCap,
    double gap = gap,
    double lineSpacing = lineSpacing,
    double? maxSizeCeiling,
  }) => [
    for (final block in buildBlocks(
      items: items,
      imageRect: imageRect,
      style: style,
      textScaler: textScaler,
      textDirection: textDirection,
      minSize: minSize,
      maxSize: maxSize,
      minWidth: minWidth,
      lineCap: lineCap,
      gap: gap,
      lineSpacing: lineSpacing,
      maxSizeCeiling: maxSizeCeiling,
    ))
      ...block.lines,
  ];

  /// The largest uniform [scale] at which the whole block fits *without any line
  /// being squeezed*, or `null` when even [minBlockScale] cannot manage it.
  ///
  /// Bisection rather than a step-down loop: a smaller font wraps into fewer
  /// lines, so the relationship between scale and height is not linear, and six
  /// bisections land within ~1.5% of the true threshold for a bounded number of
  /// text measurements.
  static _BlockFlow? _searchScale({
    required List<TranslatedDeckItem> group,
    required Map<int, _Span> spans,
    required Rect imageRect,
    required TextStyle style,
    required TextScaler textScaler,
    required TextDirection textDirection,
    required double minSize,
    required double maxSize,
    required double minWidth,
    required int lineCap,
    required double anchor,
    required double room,
    required double lineSpacing,
    double? maxSizeCeiling,
  }) {
    _BlockFlow flowAt(double scale) => _flow(
      group: group,
      spans: spans,
      imageRect: imageRect,
      style: style,
      textScaler: textScaler,
      textDirection: textDirection,
      minSize: minSize,
      maxSize: maxSize,
      minWidth: minWidth,
      lineCap: lineCap,
      anchor: anchor,
      room: room,
      lineSpacing: lineSpacing,
      scale: scale,
      budget: _Budget.natural,
      maxSizeCeiling: maxSizeCeiling,
    );

    bool fits(_BlockFlow flow) =>
        flow.lines.length == group.length && flow.used <= room + 0.01;

    var best = flowAt(minBlockScale);
    if (!fits(best)) {
      // Even the smallest legible size needs more room than the block has.
      return null;
    }

    var low = minBlockScale;
    var high = 1.0;
    for (var step = 0; step < shrinkSteps; step++) {
      final mid = (low + high) / 2;
      final candidate = flowAt(mid);
      if (fits(candidate)) {
        best = candidate;
        low = mid;
      } else {
        high = mid;
      }
    }
    return best;
  }

  /// Flows one block's lines from its anchor down, each fitted at [scale] of its
  /// own natural font ceiling.
  ///
  /// [budget] decides how much height a single line may take:
  /// * [_Budget.natural] — as much as its text needs, so nothing is squeezed.
  ///   The flow stops once [room] is exceeded, which is how the caller learns
  ///   the block does not fit at this size.
  /// * [_Budget.fixed] — [fixedBudget], the same slice for every line.
  /// * [_Budget.remaining] — whatever is left of [room]. Nothing this mode
  ///   returns can intrude on the next block, and every line it does return can
  ///   paint its text inside its own box.
  static _BlockFlow _flow({
    required List<TranslatedDeckItem> group,
    required Map<int, _Span> spans,
    required Rect imageRect,
    required TextStyle style,
    required TextScaler textScaler,
    required TextDirection textDirection,
    required double minSize,
    required double maxSize,
    required double minWidth,
    required int lineCap,
    required double anchor,
    required double room,
    required double lineSpacing,
    required double scale,
    required _Budget budget,
    double? fixedBudget,
    double? maxSizeCeiling,
  }) {
    final lines = <TranslatedDeckPlacement>[];
    var top = anchor;
    var used = 0.0;

    for (final item in group) {
      final floor = _minimumLegibleBoxFor(
        item,
        style: style,
        minSize: minSize,
        textScaler: textScaler,
        textDirection: textDirection,
      );
      final lineBudget = switch (budget) {
        // Natural mode may grow the item to fit its text, but only by a bounded
        // amount around the region it replaces — never to the bottom of the
        // page. The block's own room still bounds it as well.
        _Budget.natural => math.min(
          room - used,
          item.sourceRect.height * maxNaturalGrowth +
              TranslatedTextLayout.insetYFor(item.sourceRect.height) * 2,
        ),
        _Budget.fixed => fixedBudget ?? double.infinity,
        _Budget.remaining => room - used,
      };

      // A slice that cannot hold one line of text cannot be painted without
      // spilling into the next line. Stop instead, and let the caller decide
      // between slicing and hiding the tail.
      if (lineBudget < floor - 0.01) break;
      // Natural mode may be told there is no room left at all.
      if (budget == _Budget.natural && used > room + 0.01) break;

      final ceiling =
          maxSizeCeiling ??
          TranslatedTextLayout.effectiveMaxSize(
            sourceHeight: item.sourceRect.height,
            maxSize: maxSize,
          );
      final span = spans[item.id]!;
      final layout = TranslatedTextLayout.fit(
        text: item.text,
        sourceRect: item.sourceRect,
        imageRect: imageRect,
        style: style,
        textScaler: textScaler,
        textDirection: textDirection,
        minSize: minSize,
        maxSize: math.max(minSize, ceiling * scale),
        minWidth: minWidth,
        // The block decides how tall a line may be, not the line's own source
        // height: inside a paragraph, text takes the room the flow gives it.
        heightGrowth: double.infinity,
        lineCap: lineCap,
        top: top,
        maxHeight: lineBudget.isFinite ? lineBudget : null,
        span: (left: span.left, width: span.width),
        maxSizeCeiling: maxSizeCeiling == null
            ? null
            : math.max(minSize, ceiling * scale),
      );
      if (!layout.paintText || layout.box.isEmpty || layout.box.height <= 0) {
        break;
      }

      lines.add(
        TranslatedDeckPlacement(
          id: item.id,
          text: item.text,
          sourceRect: item.sourceRect,
          layout: layout,
          box: layout.box,
          // Cheap and honest: the line is "constrained" when the flow moved it
          // off its own anchor, or the block had to shrink to make it fit.
          constrained:
              scale < 1 ||
              (layout.box.top -
                          TranslatedTextLayout.anchoredTop(
                            item.sourceRect,
                            imageRect,
                          ))
                      .abs() >
                  0.01,
        ),
      );

      used = layout.box.bottom - anchor;
      top = layout.box.bottom + lineSpacing;
    }

    return _BlockFlow(lines: lines, used: used);
  }

  /// Horizontal spans for every item, widened for legibility but kept clear of
  /// same-row neighbours.
  ///
  /// This is where the "widen a word to `minWidth`" rule meets the rest of the
  /// page. Without the gutter cap, a ten-pixel OCR line could be painted 56
  /// pixels wide, straight across the column beside it, and every collision
  /// check would still say the two OCR boxes were far apart.
  static Map<int, _Span> _resolveSpans(
    List<TranslatedDeckItem> ordered, {
    required Rect imageRect,
    required double minWidth,
  }) {
    final spans = <int, _Span>{};
    final baseSpans = <int, _Span>{};
    for (final item in ordered) {
      final base = TranslatedTextLayout.spanFor(
        sourceRect: item.sourceRect,
        imageRect: imageRect,
        minWidth: minWidth,
      );
      final span = _Span(base.left, base.left + base.width);
      spans[item.id] = span;
      baseSpans[item.id] = _Span(span.left, span.right);
    }

    for (var i = 0; i < ordered.length; i++) {
      final a = ordered[i];
      final spanA = spans[a.id]!;
      for (var j = i + 1; j < ordered.length; j++) {
        final b = ordered[j];
        if (!_shareRow(a.sourceRect, b.sourceRect)) continue;
        final spanB = spans[b.id]!;
        if (!spanA.overlaps(spanB)) continue;

        final centreA = a.sourceRect.center.dx;
        final centreB = b.sourceRect.center.dx;
        if ((centreA - centreB).abs() < 0.5) continue;

        // `mid` is the gutter between the two source centres. The cap can only
        // *narrow* a widened box — never widen it past the span the fitter
        // would draw anyway — and it only aims to keep covering the visible
        // part of the source, so an OCR box that runs past the edge of the
        // displayed photo cannot push the span off the image.
        final mid = (centreA + centreB) / 2;
        final coverA = a.sourceRect.right.clamp(
          baseSpans[a.id]!.left,
          baseSpans[a.id]!.right,
        );
        final coverB = b.sourceRect.left.clamp(
          baseSpans[b.id]!.left,
          baseSpans[b.id]!.right,
        );
        if (centreA < centreB) {
          spanA.right = math.min(
            spanA.right,
            math.max(mid - gutter / 2, coverA),
          );
          spanB.left = math.min(
            math.max(math.min(spanB.left, coverB), mid + gutter / 2),
            spanB.right - 1,
          );
        } else {
          spanB.right = math.min(
            spanB.right,
            math.max(mid - gutter / 2, coverB),
          );
          spanA.left = math.min(
            math.max(math.min(spanA.left, coverA), mid + gutter / 2),
            spanA.right - 1,
          );
        }
      }
    }

    // Final guarantee: capping may only narrow a box, and every box stays
    // inside the displayed photo.
    for (final entry in spans.entries) {
      final base = baseSpans[entry.key]!;
      final span = entry.value;
      span.left = span.left.clamp(
        base.left,
        math.max(base.left, base.right - 1),
      );
      span.right = span.right.clamp(
        math.min(span.left + 1, base.right),
        base.right,
      );
      span.left = span.left.clamp(
        imageRect.left,
        math.max(imageRect.left, imageRect.right - 1),
      );
      span.right = span.right.clamp(
        math.min(span.left + 1, imageRect.right),
        imageRect.right,
      );
    }
    return spans;
  }

  /// Smallest box the whole group can paint one line into.
  static double _minimumLegibleBox(
    List<TranslatedDeckItem> group, {
    required TextStyle style,
    required double minSize,
    required TextScaler textScaler,
    required TextDirection textDirection,
  }) {
    var result = 0.0;
    for (final item in group) {
      final floor = _minimumLegibleBoxFor(
        item,
        style: style,
        minSize: minSize,
        textScaler: textScaler,
        textDirection: textDirection,
      );
      if (floor > result) result = floor;
    }
    return result;
  }

  static double _minimumLegibleBoxFor(
    TranslatedDeckItem item, {
    required TextStyle style,
    required double minSize,
    required TextScaler textScaler,
    required TextDirection textDirection,
  }) => TranslatedTextLayout.minimumLineBox(
    style: style,
    fontSize: minSize,
    textScaler: textScaler,
    textDirection: textDirection,
    insetY: TranslatedTextLayout.insetYFor(item.sourceRect.height),
    // The same script-aware leading the line will be fitted with; a
    // Devanagari line needs a taller slice than a Latin one even at `minSize`.
    lineHeight: TranslatedTextLayout.lineHeightFor(item.text, style),
  );

  /// Groups neighbours into paragraph-like runs.
  ///
  /// A region joins the most recent block it shares columns with and sits within
  /// a line of, else it opens a new block. Scanning backwards is what lets two
  /// columns interleave in reading order and still end up as one block each.
  static List<List<TranslatedDeckItem>> _group(
    List<TranslatedDeckItem> ordered, {
    required double gap,
  }) {
    final blocks = <List<TranslatedDeckItem>>[];
    for (final item in ordered) {
      List<TranslatedDeckItem>? target;
      for (var index = blocks.length - 1; index >= 0; index--) {
        final last = blocks[index].last;
        if (!_sameColumn(last.sourceRect, item.sourceRect)) continue;
        if (!_isAdjacent(last.sourceRect, item.sourceRect, gap: gap)) continue;
        target = blocks[index];
        break;
      }
      if (target == null) {
        blocks.add(<TranslatedDeckItem>[item]);
      } else {
        target.add(item);
      }
    }
    return blocks;
  }

  /// Whether two boxes sit in the same column.
  ///
  /// Overlap *ratio* matters, not just any overlap: a caption that clips the
  /// edge of a column by a pixel is a different block, while an indented
  /// paragraph line is the same one.
  static bool _sameColumn(Rect a, Rect b) {
    final overlap = math.min(a.right, b.right) - math.max(a.left, b.left);
    if (overlap <= 0) return false;
    final narrower = math.min(a.width, b.width);
    if (narrower <= 0) return false;
    return overlap / narrower >= columnOverlapRatio;
  }

  /// Whether two boxes share a row of text, i.e. their vertical extents
  /// overlap. Only same-row neighbours can be widened into each other.
  static bool _shareRow(Rect a, Rect b) => a.top < b.bottom && a.bottom > b.top;

  /// Whether [next] follows [previous] closely enough to be the same paragraph.
  ///
  /// Overlapping source boxes — which real OCR does produce on tight leading —
  /// count as adjacent: the negative tolerance below allows a whole line height
  /// of backwards overlap, so a run of overlapping lines stays one block instead
  /// of being split into one block per line.
  static bool _isAdjacent(Rect previous, Rect next, {required double gap}) {
    final tolerance =
        math.max(previous.height, next.height) * maxLineGapFactor + gap;
    final verticalGap = next.top - previous.bottom;
    return verticalGap <= tolerance &&
        verticalGap >= -math.max(previous.height, next.height);
  }

  /// Reading order: top to bottom, then left to right, then by region id so a
  /// page with two regions in the same place is still deterministic.
  static int _readingOrder(TranslatedDeckItem a, TranslatedDeckItem b) {
    final byTop = a.sourceRect.top.compareTo(b.sourceRect.top);
    if (byTop != 0) return byTop;
    final byLeft = a.sourceRect.left.compareTo(b.sourceRect.left);
    if (byLeft != 0) return byLeft;
    return a.id.compareTo(b.id);
  }

  /// Smallest rectangle containing every box.
  static Rect _unionOf(List<Rect> boxes) {
    var result = boxes.first;
    for (final box in boxes.skip(1)) {
      result = result.expandToInclude(box);
    }
    return result;
  }
}

/// One block's flowed lines, plus how much vertical room they consumed.
class _BlockFlow {
  const _BlockFlow({required this.lines, required this.used});

  final List<TranslatedDeckPlacement> lines;

  /// Height consumed from the block's anchor to the last line's bottom.
  final double used;
}

/// How much height a single line of a block may take. See [_flow].
enum _Budget { natural, fixed, remaining }

/// A horizontal interval: the space a rendered box occupies on the page.
class _Span {
  _Span(this.left, this.right);

  double left;
  double right;

  double get width => right - left;

  bool overlaps(_Span other, {double slack = 0}) =>
      left < other.right + slack && right > other.left - slack;

  bool overlapsRect(Rect rect, {double slack = 0}) =>
      left < rect.right + slack && right > rect.left - slack;

  static _Span union(Iterable<_Span> spans) {
    var result = spans.first;
    var left = result.left;
    var right = result.right;
    for (final span in spans.skip(1)) {
      if (span.left < left) left = span.left;
      if (span.right > right) right = span.right;
    }
    return _Span(left, right);
  }

  @override
  String toString() =>
      '_Span(${left.toStringAsFixed(1)}..${right.toStringAsFixed(1)})';
}
