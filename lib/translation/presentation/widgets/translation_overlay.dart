import 'package:flutter/material.dart';

import '../../../ocr/presentation/ocr_coordinate_mapper.dart';
import '../../domain/translated_region.dart';
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
/// * Each block gets **one** backing — a single subtle, rounded, tinted veil
///   behind all of its lines, so a paragraph reads as one translated unit rather
///   than a stack of separate cards. Nothing is drawn for the image as a whole,
///   no scrim, and never a permanent rectangle around un-translated words.
/// * The backing is **opaque enough to mask the words underneath** (97 %): a
///   translucent veil left the dark source text visible through the translated
///   text, which reads exactly like two strings printed on top of each other.
///   Only the geometry was fixed before; the ghosting had to be fixed here.
/// * The backing is not interactive at all ([IgnorePointer]): every tap that
///   lands on a line's text opens that line's full translation, and every tap
///   that misses falls straight through to the OCR layer, so word selection
///   keeps working and gets the whole surface back when translation is switched
///   off.
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
  /// translated paragraph needs more lines: capping it at five would ellipsize
  /// the middle of every paragraph even when the space is there. The cap is
  /// still finite so a pathological translation cannot be measured forever.
  static const int paragraphLineCap = 16;

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
        // it can never cover the last translated line.
        if (layout.hiddenRegionIds.isNotEmpty) {
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
        if (blocks.isEmpty && layout.hiddenRegionIds.isEmpty) {
          return const SizedBox.shrink();
        }

        final children = <Widget>[];

        // Backings first, so they are always *behind* every line of text even
        // when two blocks are adjacent.
        for (final block in blocks) {
          children.add(
            Positioned.fromRect(
              key: ValueKey<String>('translated-block-${block.id}'),
              // The veil covers the paragraph's **source** lines as well as the
              // translation, so the Hindi it replaces cannot show through around
              // a shorter English text (see `TranslatedBlockPlacement.coverage`).
              rect: block.coverage,
              child: const IgnorePointer(child: TranslatedBlockPill()),
            ),
          );
        }

        // Then the text, one tappable slot per line, positioned by the flow.
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
        if (layout.hiddenRegionIds.isNotEmpty) {
          children.add(
            Positioned(
              left: 8,
              right: 8,
              bottom: 8,
              child: Align(
                alignment: Alignment.bottomCenter,
                child: TranslatedOverflowNotice(
                  count: layout.hiddenRegionIds.length,
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

/// The single backing shared by every line of one translated block.
///
/// This is what makes a paragraph read as one translated unit: one rounded,
/// tinted veil behind the whole run of lines, instead of one card per line with
/// visible seams between them.
///
/// Public so the styling lives in exactly one place, and so a widget test can
/// assert the veil rather than trusting an eyeball.
class TranslatedBlockPill extends StatelessWidget {
  const TranslatedBlockPill({super.key});

  /// Corner radius of the backing. Subtle on purpose: a translated block sits on
  /// a photo and must not read as a button.
  static const double radius = 3;

  /// Opacity of the veil.
  ///
  /// Deliberately close to opaque: the block has to *mask* the original words it
  /// replaces. At the previous 0.9 the dark source text stayed visible as a
  /// grey ghost through the translation, which looks like the two strings were
  /// printed on top of each other even when their rectangles never overlapped.
  static const double backingAlpha = 0.95;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final corners = BorderRadius.circular(radius);

    return DecoratedBox(
      // The shadow is painted *outside* the clip — a ClipRRect above it would
      // clip the blur away and leave the block looking pasted on. It is kept
      // very tight: the veil should read as the page now that it covers the
      // paragraph, not as a floating card.
      decoration: BoxDecoration(
        borderRadius: corners,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.06),
            blurRadius: 2,
            offset: const Offset(0, 0.5),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: corners,
        child: DecoratedBox(
          decoration: BoxDecoration(
            // Lens-like veil: the page's own paper colour rather than a grey app
            // card, dense enough to *mask* the Hindi underneath, and with only a
            // whisper of an edge so adjacent blocks do not read as bubbles.
            //
            // 95 %, not 90 %: measured on a photo, a 90 % veil left dark source
            // words legible through the translation as a grey ghost. The
            // remaining 5 % keeps the block part of the photograph without
            // letting anything beneath show.
            color: scheme.surface.withValues(alpha: backingAlpha),
            border: Border.all(
              color: scheme.outlineVariant.withValues(alpha: 0.28),
              width: 0.5,
            ),
          ),
        ),
      ),
    );
  }
}

/// One translated line: its text, drawn in the slot the flow gave it.
///
/// Deliberately has no backing of its own — the block's [TranslatedBlockPill]
/// is behind it. The padding is the padding its geometry was measured with, so
/// the text sits exactly where [TranslatedTextLayout] placed it.
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
        ? Padding(
            // Minimal and proportional: a tight constant either side, and a
            // vertical inset that grows with the region. This is the same number
            // the fitter measured against, so the text cannot end up padded
            // against a different value than the one its box was sized with.
            padding: EdgeInsets.symmetric(
              horizontal: layout.insetX,
              vertical: layout.insetY,
            ),
            child: Align(
              alignment: AlignmentDirectional.topStart,
              child: Text(
                text,
                // onSurface over the block's surfaceContainerHighest veil is a
                // guaranteed high-contrast pair in both light and dark themes.
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

/// The fallback for a photo too dense to hold every translation.
///
/// A long Hindi sentence can be physically larger than the space between two
/// printed lines; pretending otherwise is what produced the squashed, bleeding
/// boxes this overlay used to draw. The deck therefore leaves the lines that
/// cannot be drawn legibly off the image, and this notice says how many more
/// are available — with one tap to the full translation text, where every line
/// is present in reading order.
class TranslatedOverflowNotice extends StatelessWidget {
  const TranslatedOverflowNotice({super.key, required this.count, this.onTap});

  /// Number of translated regions that had no legible place on the image.
  final int count;

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
    final label = count == 1
        ? '1 more translation available'
        : '$count more translations available';

    final body = Material(
      // A compact Lens-style chip rather than a raised card: flat, hairline-edged
      // and the same radius as the translated blocks, so it belongs to the same
      // visual language as the text it describes.
      color: scheme.surface.withValues(alpha: 0.96),
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(TranslatedBlockPill.radius),
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
