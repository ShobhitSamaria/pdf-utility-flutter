import 'dart:math' as math;

import 'package:flutter/widgets.dart';

/// Where one translated region is drawn, and at what size.
///
/// This is the **only** place that decides translation-overlay geometry. It is a
/// pure function of the source rectangle (mapped to screen space by the shared
/// `OcrCoordinateMapper`), the displayed photo rectangle, and the text — so it
/// is unit-testable and can never invent a second coordinate system.
///
/// Two invariants matter more than anything else here, because breaking either
/// one is what makes a translated page look like a pile of clashing cards:
///
/// 1. **[box] contains everything that is painted.** [textHeight] is measured
///    with the exact style, width, line cap and text direction the widget will
///    paint with, and the box is never shorter than `textHeight + 2 × insetY`.
///    A box that is too short for even one line reports [paintText] `false`
///    instead of letting the glyphs spill over the line below it.
/// 2. **The box is in the space it is painted in.** Width and left edge come
///    from [spanFor], the same helper the overlay deck uses to reason about
///    collisions, so the deck's arithmetic and the widget's geometry cannot
///    disagree about how wide a box is.
///
/// Rules (all deliberately Lens-like):
/// * the backing box is anchored on the source text and always at least as tall
///   as the source line, so it **covers the words it replaces**;
/// * it may grow wider than a tiny source word (up to [minWidth]) so a short
///   word does not wrap one character per line;
/// * it may grow vertically up to [heightGrowth]× the source line height to fit
///   a longer translation, but never past the bottom of the photo, and never
///   past a caller-supplied budget (`maxHeight`) — which is how
///   `TranslatedOverlayDeck` keeps stacked translations from overlapping;
/// * a longer translation that cannot fit that budget shrinks its font first
///   and then ellipsizes, so the box never has to grow over its neighbours;
/// * it is clamped inside the displayed photo, so nothing spills into the
///   letterbox bars;
/// * the font is the largest size that fits the box's **width and height**,
///   chosen from a range whose ceiling itself follows the region's height — a
///   heading-sized region gets heading-sized text instead of being capped at
///   body size, while an ordinary text line is unchanged (see
///   [effectiveMaxSize]);
/// * padding is minimal and proportional: a constant [horizontalPadding] on the
///   sides, and a small vertical inset that grows with the region
///   ([insetYFor]) — a paragraph line does not need the same air a heading does;
/// * as a last resort the text is ellipsized rather than overflowing.
class TranslatedTextLayout {
  const TranslatedTextLayout({
    required this.box,
    required this.style,
    required this.maxLines,
    required this.textHeight,
    this.paintText = true,
    required this.shrunk,
    required this.ellipsized,
    this.insetX = horizontalPadding,
    this.insetY = verticalPadding,
  });

  /// The backing rectangle, in the overlay's own (screen/logical) coordinates.
  final Rect box;

  /// Fully resolved style (font size + line height) to render with, so the
  /// widget paints exactly what was measured.
  final TextStyle style;

  /// Line cap the text was measured with.
  final int maxLines;

  /// Height of the text as measured with [style], [maxLines] and the box width.
  ///
  /// The box is guaranteed to be at least `textHeight + 2 × insetY` tall, so
  /// painting at `box.topLeft + (insetX, insetY)` cannot reach another region.
  final double textHeight;

  /// Whether there is enough room to paint even one line of text.
  ///
  /// `false` means the box is shorter than a single line at [defaultMinSize];
  /// the widget paints nothing in it (the tap target still opens the full
  /// translation). The overlay deck does not normally produce such a box: it
  /// prefers to leave a line undrawn (and reachable through the translation
  /// sheet) over drawing a box that cannot hold it.
  final bool paintText;

  /// Whether the font had to shrink below `maxSize`.
  final bool shrunk;

  /// Whether the text still did not fit and will be ellipsized.
  final bool ellipsized;

  /// The horizontal padding this region was actually fitted with, so the widget
  /// that paints it uses the same number the geometry was computed from.
  final double insetX;

  /// The vertical padding this region was actually fitted with — see [insetYFor].
  final double insetY;

  /// Bottom edge of the painted text, in the overlay's coordinates.
  double get textBottom => box.top + insetY + textHeight;

  /// Whether this layout can draw its text without spilling out of [box].
  bool get isContained =>
      !paintText || textHeight + insetY * 2 <= box.height + 0.01;

  /// Padding either side of the text, horizontally.
  ///
  /// Deliberately tight and **constant**: horizontal room is the scarce
  /// resource in a text column, so growing this would either push a box over a
  /// neighbouring column or steal width from the text itself. The separation on
  /// a dense page comes from the gap *between* boxes, not from a fat inset.
  static const double horizontalPadding = 3;

  /// The **minimum** vertical padding above and below the text.
  static const double verticalPadding = 2;

  /// The largest vertical padding any region is given.
  static const double maxVerticalPadding = 4;

  /// How quickly vertical padding grows with the region's height.
  static const double verticalPaddingScale = 0.04;

  /// How tall a region's text may be relative to the region itself.
  static const double heightBasedMaxFactor = 0.72;

  /// Absolute ceiling on the font size, so a region the height of the whole
  /// page cannot render at poster size.
  static const double hardMaxSize = 48;

  /// **Minimum** line height multiplier, applied at measure **and** render
  /// time.
  ///
  /// A constant multiplier is only safe for scripts whose font metrics fit in
  /// it. Devanagari is not one of them: Noto Sans Devanagari's natural line is
  /// about 1.29 × the font size, and forcing 1.15 makes its matras paint **up to
  /// 5 px outside** a 48 px line box (measured — see
  /// `test/translated_overlay_font_metrics_test.dart`). Glyphs that leave their
  /// box are the one kind of overlap a rectangle-based collision check can never
  /// see, which is why the overlay now derives the line height from the font's
  /// own metrics (see [lineHeightFor]) instead of assuming a value.
  static const double lineHeightFactor = 1.15;

  /// Absolute ceiling on the derived line height, so a font with pathological
  /// metrics cannot turn every translation into a one-line paragraph.
  static const double maxLineHeightFactor = 1.9;

  /// Margin added to the measured natural line height.
  ///
  /// Skia rounds each line box to whole logical pixels, and the rounding can go
  /// either way; 3 % covers the residual (its worst measured ink overflow at the
  /// natural factor was 0.47 px) without visibly loosening a paragraph.
  static const double lineHeightSafety = 1.03;

  /// Font size the natural line height is measured at. Line height scales
  /// linearly with font size, so one probe per string is enough.
  static const double lineHeightProbeSize = 100;

  /// Cache of `natural line height / font size` per (font, text).
  ///
  /// The deck re-fits a line up to a dozen times per build (the shrink
  /// bisection), and this overlay rebuilds on every layout, so measuring the
  /// metrics again for each candidate would be wasteful. Keyed by the text
  /// because the fallback font that actually renders a Devanagari string is
  /// chosen per run — the factor is size-independent.
  static final Map<String, double> _lineHeightCache = <String, double>{};
  static const int _lineHeightCacheLimit = 512;

  /// Line height multiplier to measure and paint [text] with.
  ///
  /// Derived from the font metrics Flutter will actually use for this exact
  /// string (including the script fallback), never below [lineHeightFactor] and
  /// never above [maxLineHeightFactor]. Because [fit] measures **and** the
  /// widget paints with the returned value, the box still contains exactly what
  /// is drawn — but the glyphs now stay inside their line boxes too.
  static double lineHeightFor(String text, TextStyle style) {
    if (text.isEmpty) return lineHeightFactor;
    final key =
        '${style.fontFamily ?? ''}|'
        '${style.fontFamilyFallback?.join(',') ?? ''}|$text';
    final cached = _lineHeightCache[key];
    if (cached != null) return cached;

    final factor = _measureLineHeightFactor(text, style);
    if (_lineHeightCache.length >= _lineHeightCacheLimit) {
      _lineHeightCache.clear();
    }
    _lineHeightCache[key] = factor;
    return factor;
  }

  /// Natural line height of [text] at [lineHeightProbeSize], as a multiple of
  /// the font size, plus [lineHeightSafety].
  static double _measureLineHeightFactor(String text, TextStyle style) {
    // A one-line probe of the whole string: the tallest run (the fallback font
    // a Devanagari string is actually shaped with) decides the line height.
    // `copyWith(height: null)` cannot clear `height`, so the probe style is
    // built from the properties that affect metrics.
    final probe = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          fontFamily: style.fontFamily,
          fontFamilyFallback: style.fontFamilyFallback,
          fontSize: lineHeightProbeSize,
          fontWeight: style.fontWeight,
          fontStyle: style.fontStyle,
          locale: style.locale,
          textBaseline: style.textBaseline,
        ),
      ),
      textDirection: TextDirection.ltr,
      textScaler: TextScaler.noScaling,
      maxLines: 1,
    )..layout();
    final natural = probe.height / lineHeightProbeSize;
    probe.dispose();
    if (!natural.isFinite || natural <= 0) return lineHeightFactor;
    return (natural * lineHeightSafety)
        .clamp(lineHeightFactor, maxLineHeightFactor)
        .toDouble();
  }

  static const double defaultMinSize = 7;
  static const double defaultMaxSize = 17;
  static const double defaultMinWidth = 56;
  static const double defaultHeightGrowth = 2;

  /// How many times its own width a single word may overflow the content area
  /// before the region is treated as unpaintable (see [fit]).
  static const double maxWordOverflow = 3;
  static const int defaultLineCap = 5;

  /// Vertical padding for a region whose source box is [sourceHeight] tall.
  ///
  /// Scales with the region — a heading-sized box needs more air than a
  /// two-millimetre line — but never drops below [verticalPadding] or exceeds
  /// [maxVerticalPadding].
  static double insetYFor(double sourceHeight) =>
      (sourceHeight * verticalPaddingScale)
          .clamp(verticalPadding, maxVerticalPadding)
          .toDouble();

  /// The largest font size a region [sourceHeight] tall may use.
  ///
  /// [maxSize] is a **floor** on this, never a ceiling: a region displayed the
  /// size of a heading would otherwise render at body size, which is the
  /// awkward scaling this addresses. A region no taller than an ordinary text
  /// line keeps exactly [maxSize], so typical pages are unaffected — the text
  /// still has to fit the box's width and height, which the caller checks by
  /// measurement.
  static double effectiveMaxSize({
    required double sourceHeight,
    required double maxSize,
  }) {
    final derived = sourceHeight * heightBasedMaxFactor;
    final cap = math.max(maxSize, hardMaxSize);
    return math.min(math.max(maxSize, derived), cap);
  }

  /// The top edge a region is anchored at when nothing else constrains it.
  ///
  /// Shared with `TranslatedOverlayDeck`, which stacks neighbouring regions
  /// against each other starting from exactly this value — so a region that is
  /// not in anyone's way lands precisely where it would have on its own.
  /// [inset] defaults to the region's own [insetYFor] value, which is what
  /// makes the deck's bare call and [fit]'s internal call agree by construction.
  static double anchoredTop(Rect sourceRect, Rect imageRect, {double? inset}) {
    final resolved = inset ?? insetYFor(sourceRect.height);
    return _clamp(
      sourceRect.top - resolved,
      imageRect.top,
      math.max(imageRect.top, imageRect.bottom - resolved * 2 - 1),
    );
  }

  /// The horizontal span (left edge + width) a region's box will occupy.
  ///
  /// This is the single source of truth for **rendered width**: [fit] uses it,
  /// and so does the deck when it decides which translations can collide. Doing
  /// the arithmetic twice is how the previous implementation ended up resolving
  /// collisions between narrow OCR boxes and then drawing boxes widened by
  /// [defaultMinWidth] straight through each other.
  static ({double left, double width}) spanFor({
    required Rect sourceRect,
    required Rect imageRect,
    double minWidth = defaultMinWidth,
  }) {
    if (sourceRect.isEmpty || imageRect.isEmpty) {
      return (left: 0, width: 0);
    }
    final width = math.min(
      math.max(sourceRect.width + horizontalPadding * 2, minWidth),
      imageRect.width,
    );
    final left = _clamp(
      sourceRect.center.dx - width / 2,
      imageRect.left,
      math.max(imageRect.left, imageRect.right - width),
    );
    return (left: left, width: width);
  }

  /// Height of a box that can paint exactly one line of text at [fontSize].
  ///
  /// The deck uses this as its legibility floor: a slice shorter than this can
  /// only produce a box whose glyphs would paint over the next line.
  ///
  /// The line height is **measured**, not derived from `fontSize × height`.
  /// Flutter rounds ascent/descent per line, so the arithmetic value can be half
  /// a pixel short of what [Text] actually paints — enough for a "fitted" line
  /// to bleed into the line below, which is exactly how a de-overlap fix that
  /// only compares rectangles can still leave visible overlap on a device.
  static double minimumLineBox({
    required TextStyle style,
    required double fontSize,
    required TextScaler textScaler,
    TextDirection textDirection = TextDirection.ltr,
    required double insetY,
    double lineHeight = lineHeightFactor,
  }) {
    final resolved = style.copyWith(fontSize: fontSize, height: lineHeight);
    final painter = _measure(
      text: 'Ag',
      style: resolved,
      maxWidth: 10000,
      maxLines: 1,
      textScaler: textScaler,
      textDirection: textDirection,
    );
    final height = painter.height;
    painter.dispose();
    return math.max(height, textScaler.scale(fontSize) * lineHeightFactor) +
        insetY * 2;
  }

  /// Fits [text] into a backing box anchored on [sourceRect].
  ///
  /// [sourceRect] and [imageRect] must already be in the same space (both
  /// produced by `OcrCoordinateMapper`).
  ///
  /// [top] and [maxHeight] are the knobs the overlay deck uses to keep
  /// neighbouring translations from colliding: it pins a box to a specific top
  /// edge and hands it a hard height budget. Left unset, the box anchors on
  /// [sourceRect] and grows up to [heightGrowth]× the source line, which is the
  /// single-region behaviour.
  ///
  /// [span] overrides the horizontal span computed by [spanFor]. The deck passes
  /// the span it resolved against neighbouring boxes, so the box it reserves
  /// room for is exactly the box that gets painted.
  static TranslatedTextLayout fit({
    required String text,
    required Rect sourceRect,
    required Rect imageRect,
    required TextStyle style,
    TextScaler textScaler = TextScaler.noScaling,
    TextDirection textDirection = TextDirection.ltr,
    double minSize = defaultMinSize,
    double maxSize = defaultMaxSize,
    double minWidth = defaultMinWidth,
    double heightGrowth = defaultHeightGrowth,
    int lineCap = defaultLineCap,
    double? top,
    double? maxHeight,
    ({double left, double width})? span,
    double? maxSizeCeiling,
  }) {
    // Resolved once from the real font metrics and reused for every candidate
    // size, the box and the widget — one paragraph never changes leading.
    final lineHeight = lineHeightFor(text, style);
    final fallbackStyle = style.copyWith(fontSize: minSize, height: lineHeight);
    final fallback = TranslatedTextLayout(
      box: Rect.zero,
      style: fallbackStyle,
      maxLines: 1,
      textHeight: 0,
      paintText: false,
      shrunk: false,
      ellipsized: true,
      insetY: insetYFor(sourceRect.height),
    );

    if (text.trim().isEmpty ||
        sourceRect.isEmpty ||
        sourceRect.width <= 0 ||
        sourceRect.height <= 0 ||
        imageRect.isEmpty) {
      return fallback;
    }

    // --- padding --------------------------------------------------------------
    // Resolved once and used for the box, the content area and the growth cap,
    // so the padding can never disagree with the geometry it was fitted against.
    const insetX = horizontalPadding;
    final insetY = insetYFor(sourceRect.height);

    // --- horizontal placement -------------------------------------------------
    final resolved =
        span ??
        spanFor(
          sourceRect: sourceRect,
          imageRect: imageRect,
          minWidth: minWidth,
        );
    final width = resolved.width.clamp(0.0, imageRect.width);
    final left = _clamp(
      resolved.left,
      imageRect.left,
      math.max(imageRect.left, imageRect.right - width),
    );
    if (width <= insetX * 2) return fallback;

    final resolvedTop = top == null
        ? anchoredTop(sourceRect, imageRect, inset: insetY)
        : _clamp(
            top,
            imageRect.top,
            math.max(imageRect.top, imageRect.bottom - 1),
          );

    // --- vertical room -------------------------------------------------------
    // Never more than the image leaves below [resolvedTop], and never more than
    // the caller's budget (which is how the deck stops a box at the next line).
    final availableBoxHeight = imageRect.bottom - resolvedTop;
    // `heightGrowth` may be infinite, which is how the overlay deck asks for a
    // line shaped by its *text* rather than by the OCR line it replaces.
    final grown = sourceRect.height * heightGrowth + insetY * 2;
    final maxBoxHeight = math.min(
      math.min(
        math.max(grown, sourceRect.height + insetY * 2),
        availableBoxHeight,
      ),
      maxHeight ?? double.infinity,
    );
    if (maxBoxHeight <= 0.5) return fallback;

    final maxContentWidth = math.max(1.0, width - insetX * 2);
    final maxContentHeight = math.max(0.0, maxBoxHeight - insetY * 2);

    // Even one line at the smallest legible size does not fit: report an
    // unpaintable box rather than letting the glyphs paint over the next line.
    final smallestLine =
        minimumLineBox(
          style: style,
          fontSize: minSize,
          textScaler: textScaler,
          textDirection: textDirection,
          insetY: insetY,
          lineHeight: lineHeight,
        ) -
        insetY * 2;
    if (maxContentHeight + 0.05 < smallestLine) {
      return TranslatedTextLayout(
        box: Rect.fromLTWH(left, resolvedTop, width, maxBoxHeight),
        style: fallbackStyle,
        maxLines: 1,
        textHeight: 0,
        paintText: false,
        shrunk: true,
        ellipsized: true,
        insetX: insetX,
        insetY: insetY,
      );
    }

    // --- pick the largest font size that fits --------------------------------
    // The ceiling follows the region's height, so a tall region is not stuck at
    // body size; the loop then shrinks until the text actually fits both the
    // available width and the available height.
    //
    // [maxSizeCeiling] bypasses the height boost. A *paragraph* region is tall
    // because it contains many lines, not because it is a heading, so deriving
    // its font from that height would give two paragraphs on one page different
    // text sizes — exactly the arbitrary sizing this overlay must not have. The
    // page translation therefore passes a flat ceiling.
    final ceiling = math.max(
      minSize,
      (maxSizeCeiling ??
              effectiveMaxSize(
                sourceHeight: sourceRect.height,
                maxSize: maxSize,
              ))
          .floorToDouble(),
    );

    // The longest word is measured once per candidate size: a box that is wide
    // enough for the text but not for one of its words would wrap mid-word,
    // which is what turned "Polling team" into "Pollin g team" in a narrow
    // table cell. Whole words are a legibility floor, exactly like the minimum
    // font size.
    final longestWord = _longestWord(text);

    var chosen = fallbackStyle;
    double? chosenHeight;
    var ellipsized = false;

    for (var size = ceiling; size > minSize; size -= 1) {
      final candidate = style.copyWith(fontSize: size, height: lineHeight);
      final measured = _measure(
        text: text,
        style: candidate,
        maxWidth: maxContentWidth,
        maxLines: lineCap,
        textScaler: textScaler,
        textDirection: textDirection,
      );
      final fits =
          !measured.didExceedMaxLines &&
          measured.height <= maxContentHeight + 0.5 &&
          _wordFitsWithin(
            longestWord,
            candidate,
            maxContentWidth,
            textScaler,
            textDirection,
          );
      final height = measured.height;
      measured.dispose();
      if (fits) {
        chosen = candidate;
        chosenHeight = height;
        break;
      }
    }

    if (chosenHeight == null) {
      // Even the smallest size overflows: keep it and let the text ellipsize.
      final measured = _measure(
        text: text,
        style: fallbackStyle,
        maxWidth: maxContentWidth,
        maxLines: lineCap,
        textScaler: textScaler,
        textDirection: textDirection,
      );
      chosenHeight = measured.height;
      ellipsized = measured.didExceedMaxLines;
      measured.dispose();
      chosen = fallbackStyle;
    }

    // A word that would be split into more than [maxWordOverflow] pieces is not
    // text any more: it is a column of letters. That is what a translated label
    // looked like when its source box was a fraction of a line wide, and it is
    // unreadable regardless of how neatly the rectangle fits. Such a region is
    // left to the translation sheet (reported as hidden by the overlay deck)
    // instead of being drawn as a vertical stack.
    //
    // The threshold is deliberately loose — three times the content width, so a
    // word may wrap into at most three fragments. A word a little wider than its
    // box is still legible on two lines, and refusing those would blank out
    // legitimate narrow columns (table cells, captions) that read perfectly well
    // on a real page. A box a fraction of a line wide, by contrast, fragments a
    // word five or ten times: that is the case this exists for, and the sweep in
    // `translated_overlay_collision_test.dart` is what fixes the number — at 2.8
    // a page displayed only a few dozen pixels wide stopped drawing anything at
    // all, which is a worse answer than a wrapped label.
    if (longestWord.isNotEmpty &&
        !_wordFitsWithin(
          longestWord,
          chosen,
          maxContentWidth * maxWordOverflow,
          textScaler,
          textDirection,
        )) {
      return TranslatedTextLayout(
        box: Rect.fromLTWH(left, resolvedTop, width, maxBoxHeight),
        style: chosen,
        maxLines: 1,
        textHeight: 0,
        paintText: false,
        shrunk: true,
        ellipsized: true,
        insetX: insetX,
        insetY: insetY,
      );
    }

    // Cap the lines so the rendered text can never be taller than the box (the
    // widget renders with exactly this line count). The line height is measured
    // from the real font, so the cap matches what [Text] will paint — the
    // arithmetic `fontSize × height` is up to a pixel short because Flutter
    // rounds each line's ascent and descent.
    final oneLine = _measure(
      text: text,
      style: chosen,
      maxWidth: maxContentWidth,
      maxLines: 1,
      textScaler: textScaler,
      textDirection: textDirection,
    ).height;
    var allowedLines = ((maxContentHeight + 0.01) / math.max(1.0, oneLine))
        .floor()
        .clamp(1, lineCap);

    double contentHeight = 0;
    var renderedLines = allowedLines;
    while (true) {
      final rendered = _measure(
        text: text,
        style: chosen,
        maxWidth: maxContentWidth,
        maxLines: renderedLines,
        textScaler: textScaler,
        textDirection: textDirection,
      );
      contentHeight = rendered.height;
      ellipsized = ellipsized || rendered.didExceedMaxLines;
      rendered.dispose();

      if (contentHeight + insetY * 2 <= maxBoxHeight + 0.01) break;
      if (renderedLines == 1) {
        // Not even one line fits the budget. Painting it would put glyphs over
        // the next translation, so draw nothing and let the tap target open the
        // full text instead.
        return TranslatedTextLayout(
          box: Rect.fromLTWH(left, resolvedTop, width, maxBoxHeight),
          style: chosen,
          maxLines: 1,
          textHeight: 0,
          paintText: false,
          shrunk: true,
          ellipsized: true,
          insetX: insetX,
          insetY: insetY,
        );
      }
      renderedLines -= 1;
      allowedLines = renderedLines;
    }

    // The box covers at least the source line and always contains the text.
    final boxHeight = math.min(
      math.max(contentHeight, sourceRect.height) + insetY * 2,
      maxBoxHeight,
    );

    return TranslatedTextLayout(
      box: Rect.fromLTWH(left, resolvedTop, width, boxHeight),
      style: chosen,
      maxLines: allowedLines,
      textHeight: contentHeight,
      paintText: true,
      // Compared against the ceiling actually considered, so "did not shrink"
      // means the first candidate fitted rather than "is below a constant".
      shrunk: (chosen.fontSize ?? minSize) < ceiling,
      ellipsized: ellipsized,
      insetX: insetX,
      insetY: insetY,
    );
  }

  /// Longest whitespace-delimited word in [text].
  ///
  /// Used as the legibility floor: a box must be able to hold this word whole at
  /// the size it draws, or the text is broken mid-word.
  static String _longestWord(String text) {
    var longest = '';
    for (final word in text.split(RegExp(r'\s+'))) {
      if (word.length > longest.length) longest = word;
    }
    return longest;
  }

  /// Whether [word] fits [maxWidth] at [style], measured the same way the widget
  /// paints it.
  static bool _wordFitsWithin(
    String word,
    TextStyle style,
    double maxWidth,
    TextScaler textScaler,
    TextDirection textDirection,
  ) {
    final painter = _measure(
      text: word,
      style: style,
      maxWidth: 10000,
      maxLines: 1,
      textScaler: textScaler,
      textDirection: textDirection,
    );
    final fits = painter.width <= maxWidth + 0.5;
    painter.dispose();
    return fits;
  }

  static TextPainter _measure({
    required String text,
    required TextStyle style,
    required double maxWidth,
    required int maxLines,
    required TextScaler textScaler,
    required TextDirection textDirection,
  }) => TextPainter(
    text: TextSpan(text: text, style: style),
    textDirection: textDirection,
    textScaler: textScaler,
    maxLines: maxLines,
    ellipsis: '…',
  )..layout(maxWidth: maxWidth);

  static double _clamp(double value, double low, double high) =>
      value < low ? low : (value > high ? high : value);
}
