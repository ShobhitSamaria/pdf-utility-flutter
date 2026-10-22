import 'dart:ui' as ui;

/// Axis-aligned bounding rectangle expressed in **source-image pixel
/// coordinates**.
///
/// Coordinate space contract
/// -------------------------
/// * The origin `(0, 0)` is the **top-left** corner of the *upright* source
///   image (after any EXIF rotation has been applied). This matches ML Kit's
///   "default coordinate space", so engine values can be stored verbatim.
/// * Units are **pixels** of the decoded source image, not logical screen
///   pixels. `sourceWidth` / `sourceHeight` (see [OcrResult]) describe the
///   image these rectangles belong to.
/// * `left`/`top` are the top-left corner; `right`/`bottom` are exclusive
///   (i.e. `width == right - left`). This mirrors Flutter's [ui.Rect].
///
/// Keeping the rect engine-agnostic (plain doubles) means the UI layer never
/// needs to know which OCR engine produced a result.
class OcrRect {
  const OcrRect({
    required this.left,
    required this.top,
    required this.right,
    required this.bottom,
  });

  final double left;
  final double top;
  final double right;
  final double bottom;

  double get width => right - left;
  double get height => bottom - top;

  /// Center point, useful for placing a selection handle or a label.
  double get centerX => left + width / 2;
  double get centerY => top + height / 2;

  bool get isEmpty => width <= 0 || height <= 0;

  /// Converts to a Flutter [ui.Rect] for use with `Canvas`/`CustomPaint`.
  ui.Rect toRect() => ui.Rect.fromLTRB(left, top, right, bottom);

  factory OcrRect.fromLTRB(
    double left,
    double top,
    double right,
    double bottom,
  ) => OcrRect(left: left, top: top, right: right, bottom: bottom);

  /// Builds from a Flutter [ui.Rect] (e.g. straight out of ML Kit).
  factory OcrRect.fromRect(ui.Rect rect) => OcrRect(
    left: rect.left,
    top: rect.top,
    right: rect.right,
    bottom: rect.bottom,
  );

  /// Returns a copy scaled by [scaleX]/[scaleY]. Used by the coordinate mapper
  /// to translate image space into screen space.
  OcrRect scaled(
    double scaleX,
    double scaleY, {
    double dx = 0,
    double dy = 0,
  }) => OcrRect(
    left: left * scaleX + dx,
    top: top * scaleY + dy,
    right: right * scaleX + dx,
    bottom: bottom * scaleY + dy,
  );

  /// Whether [other] lies entirely within this rectangle (with an optional
  /// tolerance). Used by multi-word selection to test geometric adjacency.
  bool contains(OcrRect other, {double tolerance = 0}) {
    final t = tolerance;
    return other.left >= left - t &&
        other.top >= top - t &&
        other.right <= right + t &&
        other.bottom <= bottom + t;
  }

  @override
  bool operator ==(Object other) =>
      other is OcrRect &&
      other.left == left &&
      other.top == top &&
      other.right == right &&
      other.bottom == bottom;

  @override
  int get hashCode => Object.hash(left, top, right, bottom);

  @override
  String toString() =>
      'OcrRect(${left.toStringAsFixed(1)}, ${top.toStringAsFixed(1)}, '
      '${right.toStringAsFixed(1)}, ${bottom.toStringAsFixed(1)})';
}
