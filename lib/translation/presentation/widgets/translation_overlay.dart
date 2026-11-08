import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../../ocr/presentation/ocr_coordinate_mapper.dart';
import '../../domain/translated_region.dart';
import '../../translation_log.dart';
import '../translated_overlay_deck.dart';
import '../translated_text_layout.dart';

/// Paints translated text **on top of the original photo**, each region sitting
/// on the OCR rectangle it came from — the Google-Lens effect.
///
/// Design rules
/// ------------
/// * The photo is untouched underneath; no image is replaced, filtered or
///   scaled here. This widget only *adds* text.
/// * Geometry comes from [OcrCoordinateMapper] built from the **same**
///   `viewportSize` / image size the OCR overlay uses, so translation and
///   selection can never disagree about where a word is.
/// * Placement is decided by [TranslatedOverlayDeck], never per region, and it
///   is decided per **block** rather than per line: neighbouring lines that
///   belong together flow as one paragraph, so a translation longer than its own
///   line pushes the rest of its paragraph down instead of growing over it or
///   being flattened to fit one line height.
/// * Each translated line is drawn on a light, near-opaque backing sized to its
///   own text box. The backing **masks the printed words underneath**, so the
///   source language and the translation no longer compete on the same pixels —
///   the readability problem with drawing directly on the photo. It is a tight
///   per-line surface, not a panel: it never extends past the OCR box it came
///   from, and un-translated areas keep the photograph untouched.
/// * Text is dark navy on that backing, with the padding the fitter measured,
///   so it reads like ink on paper instead of white-on-photo decoration.
/// * The text layer is the only thing that takes input: every tap that lands on
///   a line's text opens that line's full translation, and every tap that misses
///   falls straight through to the OCR layer, so word selection keeps working and
///   gets the whole surface back when translation is switched off.
/// * When the page is too dense to hold every translation legibly, the deck
///   draws what fits and this widget shows a small notice with the number that
///   did not fit — tappable through [onOverflowTap], which opens the full text.
///   Nothing disappears without a way to read it.
class TranslationOverlay extends StatelessWidget {
  const TranslationOverlay({
    super.key,
    required this.overlay,
    required this.imageWidth,
    required this.imageHeight,
    this.onRegionTap,
    this.onOverflowTap,
  });

  /// The translated regions, in reading order.
  final TranslatedOverlay overlay;

  /// Source image pixel dimensions — the space `region.bounds` lives in.
  final int imageWidth;
  final int imageHeight;

  /// Called with the region under the finger. `null` leaves the overlay
  /// non-interactive (its lines let taps through to the OCR layer).
  final ValueChanged<TranslatedRegion>? onRegionTap;

  /// Opens the full translation text when some translations had no room on the
  /// image. `null` renders the notice as a plain, non-interactive label.
  final VoidCallback? onOverflowTap;

  /// Height kept clear at the bottom of the photo for
  /// [TranslatedOverflowNotice]: its own height, the 8 px inset and a gap.
  static const double overflowNoticeReserve = 36;

  /// Line cap used when the overlay carries paragraph units.
  ///
  /// The fitter's default cap (5) is right for a single source line, but a
  /// translated paragraph genuinely runs to dozens of lines: one column of a
  /// Hindi newspaper is ~700 characters, which is 20–30 lines of English at a
  /// legible size inside a phone-width column. The cap is what the fitter
  /// measures against, so too small a value makes every paragraph look like it
  /// "does not fit" at every font size — the font then collapses to the 7 px
  /// floor and the text ellipsizes, which is what the overlay used to do on a
  /// dense page. 48 leaves room for the longest paragraph this app can meet
  /// while still bounding the measurement work.
  static const int paragraphLineCap = 48;

  @override
  Widget build(BuildContext context) {
    final regions = overlay.renderableRegions;
    if (regions.isEmpty || imageWidth <= 0 || imageHeight <= 0) {
      return const SizedBox.shrink();
    }

    final baseStyle = DefaultTextStyle.of(context).style;
    final textScaler = MediaQuery.textScalerOf(context);
    // The translation decides the paragraph direction: a Hindi target reads
    // left-to-right, an Urdu or Arabic one right-to-left. Measuring and painting
    // in the same direction is what keeps the fitted width honest.
    final textDirection = overlay.targetLanguage.isRtl
        ? TextDirection.rtl
        : TextDirection.ltr;

    return LayoutBuilder(
      builder: (context, constraints) {
        final viewport = Size(constraints.maxWidth, constraints.maxHeight);
        if (viewport.isEmpty) return const SizedBox.shrink();

        // Identical transform to the OCR overlay: same mapper, same inputs.
        final mapper = OcrCoordinateMapper(
          imageWidth: imageWidth,
          imageHeight: imageHeight,
          viewportSize: viewport,
        );
        final imageRect = mapper.displayedOffset & mapper.displayedSize;

        final regionById = <int, TranslatedRegion>{};
        final items = <TranslatedDeckItem>[];
        for (final region in regions) {
          final sourceRect = mapper.rectToScreen(region.bounds);
          if (sourceRect.isEmpty) continue;
          regionById[region.id] = region;
          items.add(
            TranslatedDeckItem(
              id: region.id,
              text: region.translatedText,
              sourceRect: sourceRect,
              // Whole-page translation produces paragraph units, and a
              // paragraph is placed inside its own region rather than flowed
              // into a slice of the page. See [TranslatedDeckItem.isParagraph].
              isParagraph: region.kind == TranslatedRegionKind.paragraph,
              // The number of printed lines the region covers, which is what
              // keeps a one-row label field from being set in body-sized type.
              sourceLines: region.sourceLines,
            ),
          );
        }
        if (items.isEmpty) return const SizedBox.shrink();

        // Paragraph units are laid out as text blocks, not single lines, so
        // they are allowed the extra line room the fitter's line cap controls.
        final hasParagraphs = regions.any(
          (region) => region.kind == TranslatedRegionKind.paragraph,
        );
        final lineCap = hasParagraphs
            ? paragraphLineCap
            : TranslatedTextLayout.defaultLineCap;

        // One flat font ceiling for a paragraph page. A paragraph region is
        // tall because it holds many lines, not because it is a heading; letting
        // the height boost the font would give each paragraph its own size.
        //
        // The deck still lowers this per region, to the height of *one* printed
        // line (`sourceLines`), because on a form the two are the same region
        // and a single-row field must not be set larger than its own row.
        final maxSizeCeiling = hasParagraphs
            ? TranslatedTextLayout.defaultMaxSize
            : null;

        var layout = TranslatedOverlayDeck.layout(
          items: items,
          imageRect: imageRect,
          style: baseStyle,
          textScaler: textScaler,
          textDirection: textDirection,
          lineCap: lineCap,
          maxSizeCeiling: maxSizeCeiling,
        );
        // The notice is part of the layout problem, not something painted on
        // top of the answer: reserve its strip and lay the page out again, so
        // it can never cover the last translated line. A page whose blocks were
        // cut short needs the notice just as much as one that hid a region.
        if (layout.hasOverflow) {
          layout = TranslatedOverlayDeck.layout(
            items: items,
            imageRect: imageRect,
            style: baseStyle,
            textScaler: textScaler,
            textDirection: textDirection,
            lineCap: lineCap,
            bottomReserve: overflowNoticeReserve,
            maxSizeCeiling: maxSizeCeiling,
          );
        }
        final blocks = layout.blocks;
        if (blocks.isEmpty && !layout.hasOverflow) {
          return const SizedBox.shrink();
        }
        _logLayout(layout, viewport);

        // Text only: the translation is painted straight onto the photo, so the
        // image keeps its own paper, borders and barcodes instead of acquiring a
        // grid of white cards.
        final children = <Widget>[];
        for (final block in blocks) {
          for (final line in block.lines) {
            final region = regionById[line.id];
            if (region == null) continue;

            final onTap = onRegionTap;
            final isLast = identical(line, block.lines.last);
            children.add(
              Positioned.fromRect(
                // Stable identity per region: keeps rebuilds cheap and lets
                // tests assert exactly where each region landed.
                key: ValueKey<String>('translated-region-${line.id}'),
                rect: line.box,
                child: TranslatedRegionBox(
                  layout: line.layout,
                  text: line.text,
                  textScaler: textScaler,
                  textDirection: textDirection,
                  // Only a page with no room left hides lines. The last drawn
                  // line of such a block says so to screen readers; the text
                  // itself is still in the translation sheet.
                  hiddenBelow: isLast ? block.hiddenRegionIds.length : 0,
                  onTap: onTap == null ? null : () => onTap(region),
                ),
              ),
            );
          }
        }

        // Anything the page could not hold is reachable here instead of just
        // missing: the number is honest, and the action opens the full text.
        // A block that was cut short to fit is named here too — otherwise its
        // ellipsis would be the only evidence that something is missing.
        if (layout.hasOverflow) {
          children.add(
            Positioned(
              left: 8,
              right: 8,
              bottom: 8,
              child: Align(
                alignment: Alignment.bottomCenter,
                child: TranslatedOverflowNotice(
                  count: layout.hiddenRegionIds.length,
                  shortened: layout.shortenedRegionIds.length,
                  onTap: onOverflowTap,
                ),
              ),
            ),
          );
        }

        if (children.isEmpty) return const SizedBox.shrink();
        return Stack(children: children);
      },
    );
  }
}

/// Debug-only summary of one fitted page, so a device run answers *why* a page
/// looks the way it does instead of leaving it to a screenshot.
///
/// Filter a phone with `adb logcat | grep PDF_UTILITY_TRANSLATION`. Each block
/// line reports the box it was given, the source box it came from, how many
/// characters it holds and whether the fitter had to ellipsize it — a block
/// whose text is longer than its room shows `ellipsized=true`, which is the
/// difference between "the translation is short" and "the translation is
/// clipped".
void _logLayout(TranslatedDeckLayout layout, Size viewport) {
  if (!kDebugMode) return;
  final shortened = layout.blocks
      .where((block) => block.lines.any((line) => line.layout.ellipsized))
      .length;
  translationLog(
    'overlay: viewport=${viewport.width.toStringAsFixed(0)}x'
    '${viewport.height.toStringAsFixed(0)} blocks=${layout.blocks.length} '
    'hidden=${layout.hiddenRegionIds.length} shortened=$shortened',
  );
  for (final block in layout.blocks) {
    final first = block.lines.first;
    final chars = block.lines.fold<int>(0, (n, line) => n + line.text.length);
    translationLog(
      'overlay: #${block.id} '
      'size=${first.layout.style.fontSize?.toStringAsFixed(1)} '
      'box=${first.box.left.toStringAsFixed(0)},'
      '${first.box.top.toStringAsFixed(0)} '
      'w=${block.box.width.toStringAsFixed(0)} '
      'h=${block.box.height.toStringAsFixed(0)} '
      'src=${first.sourceRect.width.toStringAsFixed(0)}x'
      '${first.sourceRect.height.toStringAsFixed(0)} '
      'chars=$chars '
      'ellipsized=${block.lines.any((line) => line.layout.ellipsized)}',
    );
  }
}

/// The surface painted behind one translated line.
///
/// 94 % opaque warm white: it hides the source text well enough to read the
/// translation, while the remaining 6 % keeps a trace of the page's tone so the
/// overlay still feels printed on the photo.
const Color translatedTextBacking = Color(0xF0FBFAF7);

/// Radius of that surface — a hair of rounding, not a card.
const double translatedRegionRadius = 3;

/// One translated line: its text, drawn in the slot the flow gave it.
///
/// The slot fills the line's measured box with a light, near-opaque backing so
/// the original print underneath cannot show through the translation. The
/// padding is the padding its geometry was measured with, so the text sits
/// exactly where [TranslatedTextLayout] placed it.
class TranslatedRegionBox extends StatelessWidget {
  const TranslatedRegionBox({
    super.key,
    required this.layout,
    required this.text,
    required this.textScaler,
    this.textDirection = TextDirection.ltr,
    this.hiddenBelow = 0,
    this.onTap,
  });

  /// Fitted geometry — resolved style, line cap and the slot to draw in.
  final TranslatedTextLayout layout;

  final String text;
  final TextScaler textScaler;

  /// Direction the translation is measured and painted in.
  final TextDirection textDirection;

  /// Number of further lines of this paragraph that had no room on the image.
  /// Only used for the accessibility hint; the text stays in the sheet.
  final int hiddenBelow;

  /// Opens the full translation. `null` renders a plain, non-interactive line.
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    // A box the fitter could not give a full line to paints nothing. That is a
    // deliberate last resort: the alternative is glyphs bleeding over the next
    // translated line, which is the defect this overlay had.
    final slot = layout.paintText
        ? DecoratedBox(
            // A translucent paper surface: enough opacity to hide the source
            // print under this line, enough transparency that it still belongs
            // to the photograph rather than looking like a pasted card.
            decoration: BoxDecoration(
              color: translatedTextBacking,
              borderRadius: BorderRadius.circular(translatedRegionRadius),
            ),
            child: Padding(
              // Minimal and proportional: a tight constant either side, and a
              // vertical inset that grows with the region. This is the same
              // number the fitter measured against, so the text cannot end up
              // padded against a different value than its box was sized with.
              padding: EdgeInsets.symmetric(
                horizontal: layout.insetX,
                vertical: layout.insetY,
              ),
              child: Align(
                alignment: AlignmentDirectional.topStart,
                child: Text(
                  text,
                  // Dark ink on the light backing. No halo is needed now that
                  // the backing separates the glyphs from the print below.
                  style: layout.style.copyWith(color: scheme.onSurface),
                  maxLines: layout.maxLines,
                  overflow: TextOverflow.ellipsis,
                  textScaler: textScaler,
                  textDirection: textDirection,
                  textAlign: TextAlign.start,
                  // The fitter measured with the same wrapping rules.
                  softWrap: true,
                ),
              ),
            ),
          )
        : const SizedBox.shrink();

    if (onTap == null) return slot;

    final hidden = hiddenBelow > 0
        ? ' $hiddenBelow more part${hiddenBelow == 1 ? '' : 's'} of this '
              'translation had no room on the image; open the translation text '
              'to read the whole paragraph.'
        : '';

    return GestureDetector(
      // The whole slot is the target, so a translated line that was squeezed
      // into one ellipsized line is still easy to hit.
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Semantics(
        button: true,
        label: 'Translation: $text. Tap for the full text.$hidden',
        child: slot,
      ),
    );
  }
}

/// Corner radius of the overflow notice — the only rounded surface left in the
/// overlay, because it is a control rather than part of the photograph.
const double _noticeRadius = 3;

/// The fallback for a photo too dense to hold every translation.
///
/// A long Hindi sentence can be physically larger than the space between two
/// printed lines; pretending otherwise is what produced the squashed, bleeding
/// boxes this overlay used to draw. The deck therefore leaves the lines that
/// cannot be drawn legibly off the image, and this notice says how many more
/// are available — with one tap to the full translation text, where every line
/// is present in reading order.
class TranslatedOverflowNotice extends StatelessWidget {
  const TranslatedOverflowNotice({
    super.key,
    required this.count,
    this.shortened = 0,
    this.onTap,
  });

  /// Number of translated regions that had no legible place on the image.
  final int count;

  /// Regions that were drawn but cut short to fit, so part of what they say is
  /// only in the full translation.
  final int shortened;

  /// Opens the full translation. `null` renders a non-interactive label.
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    // Calm, destination-first wording: the point is that the rest of the
    // translation is one tap away, not that the page "failed" to hold it.
    // "Translation", not "line": since whole-page translation works on
    // paragraphs, a count of lines would be wrong — and it is the translations
    // that are one tap away.
    final parts = <String>[
      if (count == 1)
        '1 more translation'
      else if (count > 1)
        '$count more translations',
      if (shortened == 1)
        '1 shortened'
      else if (shortened > 1)
        '$shortened shortened',
    ];
    final label = [parts.join(' · '), if (count > 0) 'available'].join(' ');

    final body = Material(
      // A compact Lens-style chip rather than a raised card: flat, hairline-edged
      // and the same radius as the translated blocks, so it belongs to the same
      // visual language as the text it describes.
      color: scheme.surface.withValues(alpha: 0.96),
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(_noticeRadius),
        side: BorderSide(
          color: scheme.outlineVariant.withValues(alpha: 0.5),
          width: 0.5,
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Flexible(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: scheme.onSurface,
                  ),
                ),
              ),
              if (onTap != null) ...[
                const SizedBox(width: 8),
                Text(
                  'Full text',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: scheme.primary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );

    if (onTap == null) return IgnorePointer(child: body);
    return Semantics(
      button: true,
      label: '$label. Open the full translation text.',
      child: body,
    );
  }
}
