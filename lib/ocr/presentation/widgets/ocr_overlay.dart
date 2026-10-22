import 'dart:io';

import 'package:flutter/material.dart';

import '../../domain/ocr_element.dart';
import '../../domain/ocr_result.dart';
import '../../domain/ocr_selection.dart';
import '../ocr_coordinate_mapper.dart';
import '../ocr_hit_tester.dart';

/// Renders the original image as the base layer with OCR word geometry on top,
/// and owns the **single gesture path** for word selection.
///
/// Design rules honoured here
/// --------------------------
/// * The original image is the base; it is never replaced or filtered.
/// * No scrim, no crop/review/filter flow.
/// * **No permanent coloured rectangles.** Unselected words are invisible; only
///   selected words get a subtle Lens-like highlight.
/// * All geometry flows through [OcrCoordinateMapper] — the same mapper used by
///   [OcrHitTester] — so rendering and hit-testing share one transform.
/// * Debug geometry is opt-in and wrapped in [IgnorePointer], so it can never
///   affect hit-testing or normal interaction.
///
/// Gesture handling
/// ----------------
/// A single [GestureDetector] covers the whole viewport (including letterbox
/// bands). A tap is resolved by [OcrHitTester.elementAtScreen]:
/// * over a word → [onElementTap] with that word
/// * over the letterbox / background → [onElementTap] with `null`
///   (the screen interprets this as "clear selection")
///
/// Long-press starts a Lens-style **drag selection**: the word under the finger
/// becomes the range anchor via [onSelectionStart], each drag update reports the
/// word the finger is over via [onSelectionUpdate] (snapping to the nearest word
/// when the finger passes through a gap), and releasing ends the drag via
/// [onSelectionEnd]. A long-press that never moves still reports the anchor, so
/// it selects a single word.
///
/// [onElementLongPress] is retained for callers that only want a per-word
/// toggle; it is used when no drag callbacks are supplied.
class OcrOverlay extends StatelessWidget {
  const OcrOverlay({
    super.key,
    required this.result,
    required this.selection,
    this.onElementTap,
    this.onElementLongPress,
    this.onSelectionStart,
    this.onSelectionUpdate,
    this.onSelectionEnd,
    this.debugGeometry = false,
  });

  /// OCR output whose coordinates are in source-image pixels.
  final OcrResult result;

  /// Current multi-word selection (drives highlighting).
  final OcrSelection selection;

  /// Called with the word under a tap, or `null` when the tap missed every word
  /// (letterbox/background). The screen clears the selection on `null`.
  final ValueChanged<OcrElement?>? onElementTap;

  /// Called with the word under a long-press, to toggle it in the selection.
  ///
  /// Only used when [onSelectionStart] is not supplied.
  final ValueChanged<OcrElement>? onElementLongPress;

  /// Called once when a long-press-drag begins over a word: the range anchor.
  final ValueChanged<OcrElement>? onSelectionStart;

  /// Called on every drag update with the word under the finger, or `null` when
  /// the finger leaves the image entirely. The screen turns this into a range
  /// from the anchor to this word.
  final ValueChanged<OcrElement?>? onSelectionUpdate;

  /// Called when the long-press-drag is released.
  final VoidCallback? onSelectionEnd;

  /// Development toggle: draws bounding boxes and word labels. Off by default.
  final bool debugGeometry;

  @override
  Widget build(BuildContext context) {
    final source = result.sourceImage;

    return LayoutBuilder(
      builder: (context, constraints) {
        final viewport = Size(constraints.maxWidth, constraints.maxHeight);
        final mapper = OcrCoordinateMapper(
          imageWidth: source.width,
          imageHeight: source.height,
          viewportSize: viewport,
        );
        final hitTester = OcrHitTester(result: result, mapper: mapper);

        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapUp: (details) => onElementTap?.call(
            hitTester.elementAtScreen(details.localPosition),
          ),
          onLongPressStart: (details) {
            final element = hitTester.elementAtScreen(details.localPosition);
            if (element == null) return;
            final start = onSelectionStart;
            if (start != null) {
              start(element);
            } else {
              onElementLongPress?.call(element);
            }
          },
          onLongPressMoveUpdate: (details) => onSelectionUpdate?.call(
            hitTester.nearestElementAtScreen(details.localPosition),
          ),
          onLongPressEnd: (_) => onSelectionEnd?.call(),
          child: Stack(
            children: [
              // --- base: the original image, centered via the mapper's letterbox
              Positioned.fromRect(
                rect: mapper.displayedOffset & mapper.displayedSize,
                child: Image.file(
                  File(source.path),
                  fit: BoxFit.fill, // rect already encodes the contain aspect
                  gaplessPlayback: true,
                  // Decode at the size actually drawn rather than at full sensor
                  // resolution. A 12 MP photo is roughly 48 MB as RGBA, and this
                  // layer is rebuilt on every selection change, so decoding it
                  // for a box a few hundred logical pixels wide wastes memory
                  // and time on the frame path. Layout cannot shift: the rect
                  // above comes from the mapper, not from the image's intrinsic
                  // size, and `cacheWidth` never upscales past the source.
                  cacheWidth: _decodeWidth(
                    mapper.displayedSize.width,
                    MediaQuery.devicePixelRatioOf(context),
                  ),
                  errorBuilder: (_, _, _) => const _ImageErrorPlaceholder(),
                ),
              ),

              // --- selection highlights (subtle, only for selected words) -----
              for (final element in hitTester.selectableElements)
                if (selection.contains(element))
                  Positioned.fromRect(
                    rect: mapper.rectToScreen(element.boundingBox),
                    child: const _SelectionHighlight(),
                  ),

              // --- optional dev-only geometry (never hit-testable) -----------
              if (debugGeometry)
                Positioned.fill(
                  child: IgnorePointer(
                    child: CustomPaint(
                      painter: OcrDebugPainter(result: result, mapper: mapper),
                    ),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}

/// Physical pixel width to decode the photo at, or `null` to decode at native
/// resolution when layout has not produced a usable width yet.
int? _decodeWidth(double displayedWidth, double devicePixelRatio) {
  if (displayedWidth <= 0 || devicePixelRatio <= 0) return null;
  final pixels = (displayedWidth * devicePixelRatio).round();
  return pixels < 1 ? 1 : pixels;
}

/// A subtle, Lens-like highlight for a selected word.
///
/// Deliberately understated: a low-opacity tint plus a thin rounded outline.
/// It is only ever built for selected words, so nothing permanent is drawn over
/// the photo.
class _SelectionHighlight extends StatelessWidget {
  const _SelectionHighlight();

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.primary;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.22),
        borderRadius: BorderRadius.circular(3),
        border: Border.all(color: color.withValues(alpha: 0.85), width: 1.2),
      ),
    );
  }
}

/// Paints all bounding boxes (blocks/lines/words) for debugging the mapping.
///
/// Only attached when `debugGeometry` is true, and always wrapped in an
/// [IgnorePointer] by the caller. This is the single place where "blue debug
/// rectangles" can ever appear.
class OcrDebugPainter extends CustomPainter {
  OcrDebugPainter({required this.result, required this.mapper});

  final OcrResult result;
  final OcrCoordinateMapper mapper;

  @override
  void paint(Canvas canvas, Size size) {
    final blockPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5
      ..color = Colors.blue.withValues(alpha: 0.8);
    final linePaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.0
      ..color = Colors.green.withValues(alpha: 0.8);
    final wordPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.75
      ..color = Colors.red.withValues(alpha: 0.8);

    for (final block in result.blocks) {
      canvas.drawRect(mapper.rectToScreen(block.boundingBox), blockPaint);
      for (final line in block.lines) {
        canvas.drawRect(mapper.rectToScreen(line.boundingBox), linePaint);
        for (final element in line.elements) {
          canvas.drawRect(mapper.rectToScreen(element.boundingBox), wordPaint);
        }
      }
    }
  }

  @override
  bool shouldRepaint(OcrDebugPainter oldDelegate) =>
      oldDelegate.result != result || oldDelegate.mapper != mapper;
}

class _ImageErrorPlaceholder extends StatelessWidget {
  const _ImageErrorPlaceholder();

  @override
  Widget build(BuildContext context) => const ColoredBox(
    color: Color(0xFFEEEEEE),
    child: Center(child: Icon(Icons.broken_image_outlined)),
  );
}
