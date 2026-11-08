import 'dart:math' as math;
import 'dart:ui' show Size;

import 'document_orientation.dart';
import 'ocr_line.dart';
import 'ocr_rect.dart';

/// Maps OCR geometry from the **upright** frame it was measured in back to the
/// **stored** image frame the pixels actually live in.
///
/// What went wrong without it
/// --------------------------
/// [OrientationAwareOcrService] turns a sideways page, reads the upright copy,
/// and reports every box in that copy's coordinate space. A PDF converter that
/// then embeds the *original* raster — the page as the file holds it — and draws
/// those boxes over it puts the invisible text on the wrong words: rotated
/// ninety degrees, mirrored, or entirely off the page.
///
/// The turn is the same [DocumentOrientation] the rotator applied, so undoing it
/// is a quarter turn the other way. This class only names that inverse; it does
/// not duplicate the orientation decision, and it reuses the existing
/// [DocumentOrientation.widthOf] / [DocumentOrientation.heightOf] arithmetic so
/// a swapped axis is never re-derived by hand.
class OcrOrientationTransform {
  const OcrOrientationTransform(this.orientation);

  /// The turn that was applied to the pixels before recognition.
  final DocumentOrientation orientation;

  /// The stored size of an image whose upright size is [uprightSize].
  ///
  /// Applying [orientation] to the returned size gives [uprightSize] back.
  Size sourceSizeFor(Size uprightSize) => Size(
    orientation
        .widthOf(uprightSize.width.round(), uprightSize.height.round())
        .toDouble(),
    orientation
        .heightOf(uprightSize.width.round(), uprightSize.height.round())
        .toDouble(),
  );

  /// [uprightBox] expressed in the stored image's pixel frame.
  ///
  /// [uprightSize] is the size of the image the recogniser actually read (which
  /// may have been downscaled); [sourceSize] is the stored image the caller is
  /// drawing on. When they differ the box is scaled first, so the returned
  /// rectangle is in [sourceSize]'s pixels, not the recogniser's.
  ///
  /// All four corners are transformed and the axis-aligned bounding box of the
  /// result is returned. A quarter turn swaps the axes, so treating the box as
  /// a width and a height and swapping those two numbers would be wrong for an
  /// asymmetric box; transforming the corners is right for every quarter turn.
  OcrRect toSourceRect(
    OcrRect uprightBox, {
    required Size uprightSize,
    required Size sourceSize,
  }) {
    if (uprightSize.isEmpty || sourceSize.isEmpty) return uprightBox;

    final expectedUpright = orientation.isUpright
        ? sourceSize
        : Size(
            orientation
                .widthOf(sourceSize.width.round(), sourceSize.height.round())
                .toDouble(),
            orientation
                .heightOf(sourceSize.width.round(), sourceSize.height.round())
                .toDouble(),
          );

    // The recogniser may have read a scaled copy (the rotator caps the long
    // side). Bringing the box into the stored image's resolution first means
    // the inverse turn below is pure geometry, with no hidden scale factor.
    final scaled = uprightBox.scaled(
      expectedUpright.width / uprightSize.width,
      expectedUpright.height / uprightSize.height,
    );

    if (orientation.isUpright) return scaled;

    final width = sourceSize.width;
    final height = sourceSize.height;
    final corners = <(double, double)>[
      _toSource(scaled.left, scaled.top, width, height),
      _toSource(scaled.right, scaled.top, width, height),
      _toSource(scaled.left, scaled.bottom, width, height),
      _toSource(scaled.right, scaled.bottom, width, height),
    ];

    final xs = corners.map((corner) => corner.$1);
    final ys = corners.map((corner) => corner.$2);
    return OcrRect(
      left: xs.reduce(math.min),
      top: ys.reduce(math.min),
      right: xs.reduce(math.max),
      bottom: ys.reduce(math.max),
    );
  }

  /// [line] with its line and word boxes back in the stored image frame.
  OcrLine toSourceLine(
    OcrLine line, {
    required Size uprightSize,
    required Size sourceSize,
  }) => line.copyWith(
    boundingBox: toSourceRect(
      line.boundingBox,
      uprightSize: uprightSize,
      sourceSize: sourceSize,
    ),
    elements: [
      for (final element in line.elements)
        element.copyWith(
          boundingBox: toSourceRect(
            element.boundingBox,
            uprightSize: uprightSize,
            sourceSize: sourceSize,
          ),
        ),
    ],
  );

  /// One upright-frame point in the stored frame.
  ///
  /// These are the inverses of the clockwise turns `UiImageRotator` applies:
  /// * 90° clockwise was `(x, y) → (H - y, x)`, so undo it with
  ///   `(x, y) → (y, H - x)`.
  /// * 180° was `(x, y) → (W - x, H - y)`, its own inverse.
  /// * 270° was `(x, y) → (y, W - x)`, undo with `(x, y) → (W - y, x)`.
  (double, double) _toSource(double x, double y, double width, double height) =>
      switch (orientation.quarterTurnsClockwise) {
        1 => (y, height - x),
        2 => (width - x, height - y),
        3 => (width - y, x),
        _ => (x, y),
      };
}
