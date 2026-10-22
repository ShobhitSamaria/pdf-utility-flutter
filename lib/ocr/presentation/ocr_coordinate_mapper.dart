import 'package:flutter/widgets.dart';

import '../domain/ocr_rect.dart';
import '../domain/ocr_result.dart';

/// Maps OCR geometry from **source-image pixel space** to **screen (widget)
/// logical-pixel space**.
///
/// Why this exists
/// ---------------
/// ML Kit returns rectangles in the pixel coordinate system of the decoded
/// image (e.g. a 4000×3000 photo). The on-screen image is usually drawn much
/// smaller, inside a `BoxFit.contain` box that letterboxes to preserve aspect
/// ratio. To draw text exactly on top of the image we must apply the *same*
/// transform the image itself undergoes.
///
/// Assumptions (documented so the overlay stays correct)
/// ----------------------------------------------------
/// 1. The image is rendered with [BoxFit.contain] and **no rotation/flip** by
///    the widget layer. If the image is ever rotated on screen, this mapper
///    must be extended with a rotation term.
/// 2. The source image is *upright*: any EXIF orientation has already been
///    normalized when the image was decoded (ML Kit and the decoder both
///    operate on upright pixels). Therefore no EXIF handling is needed here.
/// 3. Scaling is **uniform** on both axes (`scale == scaleX == scaleY`), which
///    `BoxFit.contain` guarantees. Non-uniform stretching would distort text.
/// 4. Coordinates are logical (device-independent) pixels, matching Flutter's
///    layout system — the device pixel ratio is intentionally NOT applied here,
///    because `RenderBox` sizes are already in logical pixels.
///
/// The math
/// --------
/// ```
/// scale = min(boxWidth / imageWidth, boxHeight / imageHeight)   // contain
/// displayedW = imageWidth  * scale
/// displayedH = imageHeight * scale
/// dx = (boxWidth  - displayedW) / 2    // horizontal letterbox offset
/// dy = (boxHeight - displayedH) / 2    // vertical letterbox offset
///
/// screenX = imageX * scale + dx
/// screenY = imageY * scale + dy
/// ```
class OcrCoordinateMapper {
  OcrCoordinateMapper({
    required this.imageWidth,
    required this.imageHeight,
    required this.viewportSize,
  });

  /// Upright pixel width of the source image.
  final int imageWidth;

  /// Upright pixel height of the source image.
  final int imageHeight;

  /// Size of the widget box that displays the image, in logical pixels.
  final Size viewportSize;

  /// Uniform image→screen scale factor (`BoxFit.contain`).
  late final double scale = _computeScale();

  /// The on-screen size the image occupies after `contain` fitting.
  late final Size displayedSize = Size(imageWidth * scale, imageHeight * scale);

  /// Top-left offset of the fitted image inside [viewportSize] (letterbox).
  late final Offset displayedOffset = Offset(
    (viewportSize.width - displayedSize.width) / 2,
    (viewportSize.height - displayedSize.height) / 2,
  );

  double _computeScale() {
    if (imageWidth <= 0 || imageHeight <= 0) return 1;
    final sx = viewportSize.width / imageWidth;
    final sy = viewportSize.height / imageHeight;
    return sx < sy ? sx : sy;
  }

  /// Maps a single image-space point to screen space.
  Offset imageToScreen(double x, double y) =>
      Offset(x * scale + displayedOffset.dx, y * scale + displayedOffset.dy);

  /// Maps a domain image-space point to screen space.
  Offset pointToScreen(OffsetInImage point) =>
      imageToScreen(point.dx, point.dy);

  /// Maps an image-space rectangle to a screen-space [Rect].
  Rect rectToScreen(OcrRect rect) {
    final topLeft = imageToScreen(rect.left, rect.top);
    final bottomRight = imageToScreen(rect.right, rect.bottom);
    return Rect.fromLTRB(
      topLeft.dx,
      topLeft.dy,
      bottomRight.dx,
      bottomRight.dy,
    );
  }

  /// Inverse of [imageToScreen] — converts a tap position on screen back into
  /// image coordinates. This is what word-selection hit-testing uses, so the
  /// inverse transform is guaranteed to match the forward one used to render.
  ///
  /// Returns `null` when the point lies in the letterbox area (outside the
  /// actual image), so callers can ignore taps that missed the image.
  Offset? screenToImage(Offset screenPoint) {
    if (scale == 0) return null;
    final imageX = (screenPoint.dx - displayedOffset.dx) / scale;
    final imageY = (screenPoint.dy - displayedOffset.dy) / scale;
    if (imageX < 0 ||
        imageY < 0 ||
        imageX > imageWidth ||
        imageY > imageHeight) {
      return null;
    }
    return Offset(imageX, imageY);
  }

  /// Convenience wrapper returning the domain point type. `null` for letterbox
  /// taps (see [screenToImage]).
  OffsetInImage? screenToImagePoint(Offset screenPoint) {
    final image = screenToImage(screenPoint);
    return image == null ? null : OffsetInImage(image.dx, image.dy);
  }

  @override
  String toString() =>
      'OcrCoordinateMapper(scale: ${scale.toStringAsFixed(3)}, '
      'offset: $displayedOffset, image: ${imageWidth}x$imageHeight, '
      'viewport: $viewportSize)';
}
