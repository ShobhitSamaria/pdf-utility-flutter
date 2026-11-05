import 'dart:ui' show Rect, Size;

import 'package:flutter_test/flutter_test.dart';
import 'package:pdf_utility_flutter/pdf/domain/pdf_text_layer.dart';

void main() {
  group('PdfTextBounds.rectOn', () {
    test('maps normalised bounds onto a portrait page', () {
      const bounds = PdfTextBounds(
        left: 0.1,
        top: 0.2,
        right: 0.5,
        bottom: 0.4,
      );

      final rect = bounds.rectOn(const Size(600, 800));

      expect(rect, const Rect.fromLTRB(60, 160, 300, 320));
    });

    test('keeps a landscape page landscape', () {
      const bounds = PdfTextBounds(
        left: 0.25,
        top: 0.5,
        right: 0.75,
        bottom: 0.75,
      );

      final rect = bounds.rectOn(const Size(800, 600));

      expect(rect.left, 200);
      expect(rect.top, 300);
      expect(rect.width, 400);
      expect(rect.height, 150);
    });

    test('clamps bounds that hang off the page', () {
      const bounds = PdfTextBounds(
        left: -0.2,
        top: -0.1,
        right: 1.3,
        bottom: 1.4,
      );

      final rect = bounds.rectOn(const Size(400, 300));

      expect(rect, const Rect.fromLTRB(0, 0, 400, 300));
    });

    test('normalises reversed edges instead of producing a negative box', () {
      const bounds = PdfTextBounds(
        left: 0.8,
        top: 0.6,
        right: 0.2,
        bottom: 0.1,
      );

      final rect = bounds.rectOn(const Size(100, 200));

      expect(rect, const Rect.fromLTRB(20, 20, 80, 120));
    });

    test('inflates without leaving the page', () {
      const bounds = PdfTextBounds(
        left: 0.005,
        top: 0.005,
        right: 0.995,
        bottom: 0.995,
      );

      final rect = bounds.rectOn(const Size(100, 100), inflate: 5);

      expect(rect, const Rect.fromLTRB(0, 0, 100, 100));
    });

    test('a degenerate page has no rectangle to draw on', () {
      const bounds = PdfTextBounds(left: 0, top: 0, right: 1, bottom: 1);

      expect(bounds.rectOn(Size.zero), Rect.zero);
      expect(bounds.rectOn(const Size(0, 100)), Rect.zero);
      expect(bounds.rectOn(const Size(100, 0)), Rect.zero);
    });

    test('a zero-height box is still positioned, not dropped', () {
      const bounds = PdfTextBounds(
        left: 0.1,
        top: 0.5,
        right: 0.9,
        bottom: 0.5,
      );

      final rect = bounds.rectOn(const Size(200, 100));

      expect(rect.left, 20);
      expect(rect.top, 50);
      expect(rect.width, 160);
      expect(rect.height, 0);
    });
  });
}
