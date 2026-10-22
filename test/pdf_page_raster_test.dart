import 'package:flutter_test/flutter_test.dart';
import 'package:pdf_utility_flutter/pdf/domain/pdf_page_raster.dart';

void main() {
  group('a normal page is re-rendered for reading', () {
    test('A4 is rasterised at the target width', () {
      // 595 x 842 points is A4 at 72 dpi, which is the resolution a PDF actually
      // stores. This is the number that makes the difference between text the
      // recognizer can see and text it cannot.
      final raster = PdfPageRaster.forPage(pageWidth: 595, pageHeight: 842);

      expect(raster.width, PdfPageRaster.defaultMaxWidth);
      expect(raster.height, 2264);
      expect(raster.height, lessThanOrEqualTo(PdfPageRaster.defaultMaxHeight));
    });

    test('US Letter is rasterised at the target width too', () {
      final raster = PdfPageRaster.forPage(pageWidth: 612, pageHeight: 792);

      expect(raster.width, PdfPageRaster.defaultMaxWidth);
      expect(raster.height, 2071);
    });

    test('a landscape page is capped by width, not height', () {
      final raster = PdfPageRaster.forPage(pageWidth: 842, pageHeight: 595);

      expect(raster.width, PdfPageRaster.defaultMaxWidth);
      expect(raster.height, (595 * 1600 / 842).round());
      expect(raster.height, lessThan(PdfPageRaster.defaultMaxWidth));
    });

    test('a very long page is capped by height instead', () {
      // A receipt: narrow and absurdly tall. Width alone must not be the rule,
      // or the bitmap becomes enormous in memory.
      final raster = PdfPageRaster.forPage(pageWidth: 200, pageHeight: 3000);

      expect(raster.height, PdfPageRaster.defaultMaxHeight);
      expect(raster.width, (200 * 2400 / 3000).round());
      expect(raster.width, lessThan(PdfPageRaster.defaultMaxWidth));
    });

    test('the aspect ratio is never distorted', () {
      for (final page in const [
        [595.0, 842.0],
        [612.0, 792.0],
        [842.0, 595.0],
        [200.0, 3000.0],
        [1000.0, 1000.0],
      ]) {
        final raster = PdfPageRaster.forPage(
          pageWidth: page[0],
          pageHeight: page[1],
        );
        expect(
          raster.aspectRatio,
          closeTo(page[0] / page[1], 0.001),
          reason: 'a ${page[0]}x${page[1]} page was distorted',
        );
      }
    });

    test('the result is a real resolution increase over the stored page', () {
      // ~2.7x the page's own points is the whole point: the recognizer needs an
      // order of magnitude more pixels per line than the PDF carries.
      final raster = PdfPageRaster.forPage(pageWidth: 595, pageHeight: 842);

      expect(raster.width / 595, greaterThan(2));
    });
  });

  group('degenerate input', () {
    test('a zero or negative page falls back instead of a zero bitmap', () {
      for (final raster in [
        PdfPageRaster.forPage(pageWidth: 0, pageHeight: 0),
        PdfPageRaster.forPage(pageWidth: -10, pageHeight: 842),
        PdfPageRaster.forPage(pageWidth: 595, pageHeight: 0),
      ]) {
        expect(raster.width, greaterThan(0));
        expect(raster.height, greaterThan(0));
      }
    });

    test('an unusable target falls back the same way', () {
      expect(
        PdfPageRaster.forPage(pageWidth: 595, pageHeight: 842, maxWidth: 0),
        const PdfPageRaster(
          PdfPageRaster.defaultMaxWidth,
          PdfPageRaster.defaultMaxWidth,
        ),
      );
    });

    test('the tighter of the two caps wins, without distorting the page', () {
      // 800/595 asks for 1.34x but 900/842 only allows 1.07x, so the height cap
      // binds and the width follows the ratio rather than the width cap.
      final raster = PdfPageRaster.forPage(
        pageWidth: 595,
        pageHeight: 842,
        maxWidth: 800,
        maxHeight: 900,
      );

      expect(raster.height, 900);
      expect(raster.width, (595 * 900 / 842).round());
      expect(raster.width, lessThan(800));
      expect(raster.aspectRatio, closeTo(595 / 842, 0.001));
    });
  });

  test('equality and pixel count', () {
    expect(const PdfPageRaster(10, 20), const PdfPageRaster(10, 20));
    expect(const PdfPageRaster(10, 20) == const PdfPageRaster(11, 20), isFalse);
    expect(const PdfPageRaster(10, 20).pixelCount, 200);
    expect(const PdfPageRaster(1600, 2264).pixelCount, 3622400);
  });
}
