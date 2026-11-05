import 'dart:ui' show Size;

import 'package:flutter_test/flutter_test.dart';
import 'package:pdf_utility_flutter/ocr/domain/document_orientation.dart';
import 'package:pdf_utility_flutter/ocr/domain/ocr_element.dart';
import 'package:pdf_utility_flutter/ocr/domain/ocr_line.dart';
import 'package:pdf_utility_flutter/ocr/domain/ocr_orientation_transform.dart';
import 'package:pdf_utility_flutter/ocr/domain/ocr_rect.dart';

const _box = OcrRect(left: 10, top: 20, right: 30, bottom: 80);

void main() {
  group('OcrOrientationTransform', () {
    test('an upright read is passed through unchanged', () {
      const transform = OcrOrientationTransform(DocumentOrientation.upright);

      final result = transform.toSourceRect(
        _box,
        uprightSize: const Size(300, 200),
        sourceSize: const Size(300, 200),
      );

      expect(result, _box);
    });

    test('90° clockwise is undone with an anticlockwise quarter turn', () {
      const transform = OcrOrientationTransform(DocumentOrientation(1));

      final result = transform.toSourceRect(
        _box,
        // A 200 × 100 page read after a quarter turn is 100 × 200.
        uprightSize: const Size(100, 200),
        sourceSize: const Size(200, 100),
      );

      // (x, y) -> (y, H - x), with H the stored height.
      expect(result.left, closeTo(20, 0.001));
      expect(result.top, closeTo(70, 0.001));
      expect(result.right, closeTo(80, 0.001));
      expect(result.bottom, closeTo(90, 0.001));
    });

    test('180° is its own inverse and keeps the box size', () {
      const transform = OcrOrientationTransform(DocumentOrientation(2));

      final result = transform.toSourceRect(
        _box,
        uprightSize: const Size(200, 100),
        sourceSize: const Size(200, 100),
      );

      expect(result.left, closeTo(170, 0.001));
      expect(result.top, closeTo(20, 0.001));
      expect(result.right, closeTo(190, 0.001));
      expect(result.bottom, closeTo(80, 0.001));
    });

    test('270° clockwise is undone with a clockwise quarter turn', () {
      const transform = OcrOrientationTransform(DocumentOrientation(3));

      final result = transform.toSourceRect(
        _box,
        uprightSize: const Size(100, 200),
        sourceSize: const Size(200, 100),
      );

      // (x, y) -> (W - y, x), with W the stored width.
      expect(result.left, closeTo(120, 0.001));
      expect(result.top, closeTo(10, 0.001));
      expect(result.right, closeTo(180, 0.001));
      expect(result.bottom, closeTo(30, 0.001));
    });

    test('an asymmetric box is mapped corner by corner', () {
      const transform = OcrOrientationTransform(DocumentOrientation(3));
      const asymmetric = OcrRect(
        left: 5,
        top: 10,
        right: 25,
        bottom: 90,
      );

      final result = transform.toSourceRect(
        asymmetric,
        uprightSize: const Size(100, 200),
        sourceSize: const Size(200, 100),
      );

      // The upright box is 20 wide and 80 tall; after undoing the turn it must
      // be 80 wide and 20 tall. Swapping width and height without moving the
      // corners would put it in the wrong place.
      expect(result.left, closeTo(110, 0.001));
      expect(result.top, closeTo(5, 0.001));
      expect(result.right, closeTo(190, 0.001));
      expect(result.bottom, closeTo(25, 0.001));
    });

    test('a portrait source rotated to landscape is handled', () {
      const transform = OcrOrientationTransform(DocumentOrientation(1));
      const uprightBox = OcrRect(
        left: 10,
        top: 20,
        right: 40,
        bottom: 80,
      );

      final result = transform.toSourceRect(
        uprightBox,
        // Source is 100 × 200; a quarter turn makes it 200 × 100.
        uprightSize: const Size(200, 100),
        sourceSize: const Size(100, 200),
      );

      expect(result.left, closeTo(20, 0.001));
      expect(result.top, closeTo(160, 0.001));
      expect(result.right, closeTo(80, 0.001));
      expect(result.bottom, closeTo(190, 0.001));
    });

    test('a downscaled OCR copy is scaled back to the stored raster', () {
      const transform = OcrOrientationTransform(DocumentOrientation(1));

      final result = transform.toSourceRect(
        // The recogniser read a 50 × 100 copy; the stored raster is 200 × 100.
        const OcrRect(left: 5, top: 10, right: 15, bottom: 40),
        uprightSize: const Size(50, 100),
        sourceSize: const Size(200, 100),
      );

      // Doubling into the 100 × 200 upright frame first gives the same box as
      // the full-resolution 90° case above.
      expect(result.left, closeTo(20, 0.001));
      expect(result.top, closeTo(70, 0.001));
      expect(result.right, closeTo(80, 0.001));
      expect(result.bottom, closeTo(90, 0.001));
    });

    test('line and word boxes are transformed together', () {
      const transform = OcrOrientationTransform(DocumentOrientation(2));
      final line = OcrLine(
        text: 'Total 120',
        boundingBox: const OcrRect(left: 10, top: 20, right: 90, bottom: 50),
        elements: const [
          OcrElement(
            text: 'Total',
            boundingBox: OcrRect(left: 10, top: 20, right: 50, bottom: 50),
          ),
          OcrElement(
            text: '120',
            boundingBox: OcrRect(left: 60, top: 20, right: 90, bottom: 50),
          ),
        ],
      );

      final result = transform.toSourceLine(
        line,
        uprightSize: const Size(200, 100),
        sourceSize: const Size(200, 100),
      );

      expect(result.text, 'Total 120');
      expect(result.boundingBox.left, closeTo(110, 0.001));
      expect(result.boundingBox.right, closeTo(190, 0.001));
      expect(result.elements, hasLength(2));
      expect(result.elements.first.text, 'Total');
      expect(result.elements.first.boundingBox.left, closeTo(150, 0.001));
      expect(result.elements.last.boundingBox.right, closeTo(140, 0.001));
    });

    test('sourceSizeFor returns the stored size from an upright one', () {
      const transform = OcrOrientationTransform(DocumentOrientation(1));

      expect(transform.sourceSizeFor(const Size(100, 200)), const Size(200, 100));
      expect(
        const OcrOrientationTransform(
          DocumentOrientation.upright,
        ).sourceSizeFor(const Size(300, 200)),
        const Size(300, 200),
      );
    });
  });
}
