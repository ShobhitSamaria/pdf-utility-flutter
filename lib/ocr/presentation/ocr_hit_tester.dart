import 'package:flutter/widgets.dart';

import '../domain/ocr_element.dart';
import '../domain/ocr_rect.dart';
import '../domain/ocr_result.dart';
import '../domain/ocr_result_index.dart';
import 'ocr_coordinate_mapper.dart';

/// Translates a **screen-space** tap into the [OcrElement] under the finger.
///
/// Single source of truth for the screen→word decision. It deliberately reuses
/// [OcrCoordinateMapper] (the same object the overlay renders with) so hit
/// testing and rendering can never drift apart: both go through the identical
/// `BoxFit.contain` scale + letterbox offset.
///
/// Pipeline: screen point → [OcrCoordinateMapper.screenToImage] → image point →
/// point-in-rect search over [selectableElements] → nearest word box (smallest
/// area wins on overlap).
///
/// Letterbox behaviour: taps in the letterbox bands map to `null` and therefore
/// select nothing, which the UI treats as "clear selection".
class OcrHitTester {
  OcrHitTester({required this.result, required this.mapper})
    // Reuses the per-result index rather than re-deriving the list: this
    // constructor runs on every layout pass of the overlay.
    : selectableElements = OcrResultIndex.of(result).selectableElements;

  final OcrResult result;
  final OcrCoordinateMapper mapper;

  /// Words eligible for selection: non-empty text, non-degenerate geometry,
  /// exact duplicates collapsed, in reading order. The overlay renders exactly
  /// this collection, so what you see is what you can hit.
  final List<OcrElement> selectableElements;

  /// The word under [screenPoint], or `null` if the point is over the
  /// letterbox/background or over no word.
  OcrElement? elementAtScreen(Offset screenPoint) {
    final imagePoint = mapper.screenToImagePoint(screenPoint);
    if (imagePoint == null) return null;
    return _elementAt(imagePoint, selectableElements);
  }

  /// The selectable word closest to [screenPoint], even when the point itself
  /// misses every box.
  ///
  /// Used only while dragging a selection: a finger sweeping across a page
  /// often passes through the gaps between words or lines, and snapping to the
  /// nearest word there keeps the range growing smoothly instead of freezing
  /// the moment the finger leaves a box. Taps use [elementAtScreen] instead, so
  /// a tap on empty space still clears the selection.
  ///
  /// Returns `null` only when the point is in the letterbox/background band or
  /// there are no selectable words at all.
  OcrElement? nearestElementAtScreen(Offset screenPoint) {
    final imagePoint = mapper.screenToImagePoint(screenPoint);
    if (imagePoint == null) return null;
    OcrElement? best;
    double? bestDistance;
    for (final element in selectableElements) {
      final distance = _squaredDistanceToBox(imagePoint, element.boundingBox);
      if (bestDistance == null || distance < bestDistance) {
        best = element;
        bestDistance = distance;
      }
    }
    return best;
  }

  /// Squared Euclidean distance from [point] to the nearest edge of [box]
  /// (`0` when the point is inside). Squared so no `sqrt` is needed to compare.
  double _squaredDistanceToBox(OffsetInImage point, OcrRect box) {
    final dx = point.dx < box.left
        ? box.left - point.dx
        : (point.dx > box.right ? point.dx - box.right : 0.0);
    final dy = point.dy < box.top
        ? box.top - point.dy
        : (point.dy > box.bottom ? point.dy - box.bottom : 0.0);
    return dx * dx + dy * dy;
  }

  /// Core point-in-rect search over [candidates]; smallest box wins so words
  /// that overlap a larger region remain individually selectable.
  OcrElement? _elementAt(OffsetInImage point, List<OcrElement> candidates) {
    OcrElement? best;
    double? bestArea;
    for (final element in candidates) {
      final box = element.boundingBox;
      if (point.dx < box.left ||
          point.dx > box.right ||
          point.dy < box.top ||
          point.dy > box.bottom) {
        continue;
      }
      final area = box.width * box.height;
      if (bestArea == null || area < bestArea) {
        best = element;
        bestArea = area;
      }
    }
    return best;
  }
}
