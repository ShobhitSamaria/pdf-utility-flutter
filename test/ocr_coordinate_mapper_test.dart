import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdf_utility_flutter/ocr/domain/ocr_rect.dart';
import 'package:pdf_utility_flutter/ocr/presentation/ocr_coordinate_mapper.dart';

void main() {
  group('OcrCoordinateMapper (BoxFit.contain)', () {
    test('computes uniform scale and letterbox offset for a wide image', () {
      // Image 4000x3000 (4:3) inside a 400x400 viewport -> scale = 0.1,
      // displayed 400x300, vertical letterbox of 50 on top and bottom.
      final mapper = OcrCoordinateMapper(
        imageWidth: 4000,
        imageHeight: 3000,
        viewportSize: const Size(400, 400),
      );

      expect(mapper.scale, closeTo(0.1, 1e-9));
      expect(mapper.displayedSize, const Size(400, 300));
      expect(mapper.displayedOffset, const Offset(0, 50));
    });

    test('maps an image point to the expected screen point', () {
      final mapper = OcrCoordinateMapper(
        imageWidth: 4000,
        imageHeight: 3000,
        viewportSize: const Size(400, 400),
      );

      // Image (2000, 1500) is the image center -> viewport center (200, 200).
      expect(mapper.imageToScreen(2000, 1500), const Offset(200, 200));
      // Image origin -> top-left of the letterboxed image.
      expect(mapper.imageToScreen(0, 0), const Offset(0, 50));
    });

    test('maps an image rect to the expected screen rect', () {
      final mapper = OcrCoordinateMapper(
        imageWidth: 1000,
        imageHeight: 1000,
        viewportSize: const Size(200, 400),
      );
      // Square image in a tall viewport -> scale 0.2, displayed 200x200,
      // vertical offset 100.
      final screen = mapper.rectToScreen(
        const OcrRect(left: 100, top: 200, right: 300, bottom: 400),
      );
      expect(screen.left, closeTo(20, 1e-9));
      expect(screen.top, closeTo(140, 1e-9));
      expect(screen.right, closeTo(60, 1e-9));
      expect(screen.bottom, closeTo(180, 1e-9));
    });

    test('screenToImage is the inverse of imageToScreen', () {
      final mapper = OcrCoordinateMapper(
        imageWidth: 1600,
        imageHeight: 900,
        viewportSize: const Size(360, 640),
      );
      final screen = mapper.imageToScreen(1234, 567);
      final back = mapper.screenToImage(screen)!;
      expect(back.dx, closeTo(1234, 1e-6));
      expect(back.dy, closeTo(567, 1e-6));
    });

    test('screenToImage returns null for points in the letterbox area', () {
      final mapper = OcrCoordinateMapper(
        imageWidth: 4000,
        imageHeight: 3000,
        viewportSize: const Size(400, 400),
      );
      // (200, 10) sits in the 50px top letterbox band -> outside the image.
      expect(mapper.screenToImage(const Offset(200, 10)), isNull);
    });

    test('handles zero-sized images without dividing by zero', () {
      final mapper = OcrCoordinateMapper(
        imageWidth: 0,
        imageHeight: 0,
        viewportSize: const Size(100, 100),
      );
      expect(mapper.scale, 1);
      expect(mapper.displayedSize, const Size(0, 0));
    });
  });
}
