import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdf_utility_flutter/ocr/domain/ocr_block.dart';
import 'package:pdf_utility_flutter/ocr/domain/ocr_element.dart';
import 'package:pdf_utility_flutter/ocr/domain/ocr_line.dart';
import 'package:pdf_utility_flutter/ocr/domain/ocr_rect.dart';
import 'package:pdf_utility_flutter/ocr/domain/ocr_result.dart';
import 'package:pdf_utility_flutter/ocr/presentation/ocr_coordinate_mapper.dart';
import 'package:pdf_utility_flutter/ocr/presentation/ocr_hit_tester.dart';

OcrElement _word(String text, double l, double t, double r, double b) =>
    OcrElement(text: text, boundingBox: OcrRect.fromLTRB(l, t, r, b));

void main() {
  // 1000x1000 image with two words in image space.
  final left = _word('Left', 100, 100, 300, 200);
  final right = _word('Right', 600, 100, 900, 200);

  final result = OcrResult(
    sourceImage: const SourceImageInfo(
      path: '/tmp/x.jpg',
      width: 1000,
      height: 1000,
    ),
    fullText: 'Left Right',
    blocks: [
      OcrBlock(
        text: 'Left Right',
        boundingBox: OcrRect.fromLTRB(100, 100, 900, 200),
        lines: [
          OcrLine(
            text: 'Left Right',
            boundingBox: OcrRect.fromLTRB(100, 100, 900, 200),
            elements: [left, right],
          ),
        ],
      ),
    ],
  );

  group('OcrHitTester', () {
    // Square image in a tall 200x400 viewport -> scale 0.2, displayed 200x200,
    // vertical letterbox of 100 top/bottom.
    OcrHitTester buildTester() => OcrHitTester(
      result: result,
      mapper: OcrCoordinateMapper(
        imageWidth: 1000,
        imageHeight: 1000,
        viewportSize: const Size(200, 400),
      ),
    );

    test('selects the word under a screen point', () {
      final tester = buildTester();
      // Image (200,150) -> screen (40, 130). Inside "Left".
      expect(
        tester.elementAtScreen(const Offset(40, 130))?.trimmedText,
        'Left',
      );
      // Image (750,150) -> screen (150, 130). Inside "Right".
      expect(
        tester.elementAtScreen(const Offset(150, 130))?.trimmedText,
        'Right',
      );
    });

    test('returns null for letterbox bands', () {
      final tester = buildTester();
      // y in [0,100) is the top letterbox band -> no word.
      expect(tester.elementAtScreen(const Offset(40, 50)), isNull);
      // y in (300,400] is the bottom letterbox band -> no word.
      expect(tester.elementAtScreen(const Offset(40, 350)), isNull);
    });

    test('returns null for a point over the image but not over any word', () {
      final tester = buildTester();
      // Image (500,500) -> screen (100, 200): between/below both words.
      expect(tester.elementAtScreen(const Offset(100, 200)), isNull);
    });

    test('excludes empty words from hit-testing', () {
      final noisy = OcrResult(
        sourceImage: const SourceImageInfo(
          path: '/tmp/x.jpg',
          width: 1000,
          height: 1000,
        ),
        fullText: '',
        blocks: [
          OcrBlock(
            text: '',
            boundingBox: OcrRect.fromLTRB(100, 100, 300, 200),
            lines: [
              OcrLine(
                text: '',
                boundingBox: OcrRect.fromLTRB(100, 100, 300, 200),
                elements: [_word('   ', 100, 100, 300, 200)],
              ),
            ],
          ),
        ],
      );
      final tester = OcrHitTester(
        result: noisy,
        mapper: OcrCoordinateMapper(
          imageWidth: 1000,
          imageHeight: 1000,
          viewportSize: const Size(200, 400),
        ),
      );
      expect(tester.elementAtScreen(const Offset(40, 130)), isNull);
    });

    test('nearestElementAtScreen snaps through the gap to the closer word', () {
      final tester = buildTester();
      // Image (500,150) -> screen (100, 130): the gap between the two words,
      // closer to "Right" (its box starts at image x=600) than "Left".
      expect(
        tester.nearestElementAtScreen(const Offset(100, 130))?.trimmedText,
        'Right',
      );
      // Image (200,150) -> screen (40, 130): just inside "Left".
      expect(
        tester.nearestElementAtScreen(const Offset(40, 130))?.trimmedText,
        'Left',
      );
    });

    test('nearestElementAtScreen returns null in the letterbox band', () {
      final tester = buildTester();
      expect(tester.nearestElementAtScreen(const Offset(40, 50)), isNull);
      expect(tester.nearestElementAtScreen(const Offset(40, 350)), isNull);
    });

    test('hit-testing uses the same transform as rendering', () {
      // For every word, the center of its *rendered* rect must hit that word.
      final tester = buildTester();
      final mapper = OcrCoordinateMapper(
        imageWidth: 1000,
        imageHeight: 1000,
        viewportSize: const Size(200, 400),
      );
      for (final element in tester.selectableElements) {
        final rect = mapper.rectToScreen(element.boundingBox);
        final hit = tester.elementAtScreen(rect.center);
        expect(hit, element);
      }
    });
  });
}
