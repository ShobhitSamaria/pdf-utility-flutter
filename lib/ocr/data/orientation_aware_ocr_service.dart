import '../domain/document_orientation.dart';
import '../domain/ocr_result.dart';
import '../domain/ocr_script_mode.dart';
import '../domain/ocr_service.dart';
import '../ocr_log.dart';
import 'image_rotator.dart';

/// Makes every recognition run on an **upright** page.
///
/// The problem this solves is that a document's orientation is not an image
/// property the app could know in advance: EXIF describes how the camera held
/// the sensor, not how the page was held. A landscape page photographed in
/// portrait arrives with upright metadata and turned pixels, and everything
/// downstream — line boxes as tall strips, translations squeezed into them,
/// selection highlights running across the paper — follows from that.
///
/// The orientation is knowable only *after* a read, because ML Kit is what
/// reports each line's baseline angle. So this decorator runs the inner service
/// once, asks [DocumentOrientationDetector] whether the page is turned, and — if
/// it is — rotates the pixels once and reads the upright copy. The result it
/// returns is that second read, whose `sourceImage.path` is the upright file, so
/// the screen displays exactly the image the boxes were measured against.
///
/// Cost, stated plainly: a sideways page is read **twice** (roughly double the
/// time) and re-encoded once. An upright page — the overwhelmingly common case —
/// pays a single pass and nothing else, because the detector only asks for a
/// rotation on explicit evidence.
///
/// Failure policy: if the rotation or the second read fails, the first read is
/// returned (labelled as not rotated) rather than turning a usable, if sideways,
/// result into an error. The failure is logged, never shown as a crash.
class OrientationAwareOcrService implements OcrService {
  OrientationAwareOcrService({
    required this.inner,
    this.detector = const DocumentOrientationDetector(),
    this.rotator = const UiImageRotator(),
  });

  final OcrService inner;

  final DocumentOrientationDetector detector;
  final ImageRotator rotator;

  @override
  String get engineName => inner.engineName;

  @override
  Future<OcrResult> recognizeImage(
    String imagePath, {
    OcrScriptMode mode = OcrScriptMode.defaultMode,
  }) async {
    final first = await inner.recognizeImage(imagePath, mode: mode);
    final orientation = detector.detect(first);

    if (orientation.isUpright) {
      ocrDiag(
        'orientation: page is upright (${first.lines.length} lines, '
        'source ${first.sourceImage.width}x${first.sourceImage.height})',
      );
      return first;
    }

    ocrDiag(
      'orientation: page is ${orientation.label} — rotating and re-reading '
      '(${first.sourceImage.width}x${first.sourceImage.height})',
    );

    try {
      final uprightPath = await rotator.rotate(imagePath, orientation);
      final upright = await inner.recognizeImage(uprightPath, mode: mode);

      ocrDiag(
        'orientation: re-read upright '
        '${upright.sourceImage.width}x${upright.sourceImage.height} '
        'words=${upright.elements.length}',
      );

      return upright.copyWith(orientation: orientation);
    } catch (error, stackTrace) {
      // The first read is real text, just sideways. Losing it because the
      // corrective pass failed would be worse than showing a turned page, so it
      // is returned unchanged and the reason is kept in the log.
      ocrDiagError(
        'orientation: could not straighten the page — keeping the original read',
        error,
        stackTrace,
      );
      return first;
    }
  }

  @override
  Future<void> dispose() => inner.dispose();
}
