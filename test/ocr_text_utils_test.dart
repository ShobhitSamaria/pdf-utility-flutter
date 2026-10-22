import 'package:flutter_test/flutter_test.dart';
import 'package:pdf_utility_flutter/ocr/domain/ocr_block.dart';
import 'package:pdf_utility_flutter/ocr/domain/ocr_element.dart';
import 'package:pdf_utility_flutter/ocr/domain/ocr_line.dart';
import 'package:pdf_utility_flutter/ocr/domain/ocr_rect.dart';
import 'package:pdf_utility_flutter/ocr/domain/ocr_result.dart';
import 'package:pdf_utility_flutter/ocr/domain/ocr_text_utils.dart';

OcrElement _word(String text, double l, double t, double r, double b) =>
    OcrElement(text: text, boundingBox: OcrRect.fromLTRB(l, t, r, b));

void main() {
  group('OcrTextUtils', () {
    test('drops empty/whitespace-only and degenerate elements', () {
      final result = OcrResult(
        sourceImage: const SourceImageInfo(
          path: '/tmp/x.jpg',
          width: 100,
          height: 100,
        ),
        fullText: '',
        blocks: [
          OcrBlock(
            text: '',
            boundingBox: OcrRect.fromLTRB(0, 0, 100, 100),
            lines: [
              OcrLine(
                text: '',
                boundingBox: OcrRect.fromLTRB(0, 0, 100, 100),
                elements: [
                  _word('Real', 0, 0, 20, 10),
                  _word('   ', 20, 0, 40, 10), // whitespace only
                  _word('', 40, 0, 60, 10), // empty
                  _word('Zero', 50, 50, 50, 50), // zero-area box
                ],
              ),
            ],
          ),
        ],
      );

      final selectable = OcrTextUtils.selectableElements(result);
      expect(selectable.map((e) => e.trimmedText), ['Real']);
    });

    test(
      'collapses exact duplicates but keeps repeated words at new positions',
      () {
        final result = OcrResult(
          sourceImage: const SourceImageInfo(
            path: '/tmp/x.jpg',
            width: 100,
            height: 100,
          ),
          fullText: '',
          blocks: [
            OcrBlock(
              text: '',
              boundingBox: OcrRect.fromLTRB(0, 0, 100, 100),
              lines: [
                OcrLine(
                  text: '',
                  boundingBox: OcrRect.fromLTRB(0, 0, 100, 100),
                  elements: [
                    _word('the', 0, 0, 20, 10),
                    _word('the', 0, 0, 20, 10), // exact duplicate -> dropped
                    _word(
                      'the',
                      0,
                      20,
                      20,
                      30,
                    ), // same text, new position -> kept
                  ],
                ),
              ],
            ),
          ],
        );

        final selectable = OcrTextUtils.selectableElements(result);
        expect(selectable.length, 2);
        expect(selectable.every((e) => e.trimmedText == 'the'), isTrue);
      },
    );

    test('preserves reading order', () {
      final result = OcrResult(
        sourceImage: const SourceImageInfo(
          path: '/tmp/x.jpg',
          width: 100,
          height: 100,
        ),
        fullText: '',
        blocks: [
          OcrBlock(
            text: '',
            boundingBox: OcrRect.fromLTRB(0, 0, 100, 100),
            lines: [
              OcrLine(
                text: '',
                boundingBox: OcrRect.fromLTRB(0, 0, 100, 50),
                elements: [_word('a', 0, 0, 10, 10), _word('b', 10, 0, 20, 10)],
              ),
              OcrLine(
                text: '',
                boundingBox: OcrRect.fromLTRB(0, 50, 100, 100),
                elements: [_word('c', 0, 50, 10, 60)],
              ),
            ],
          ),
        ],
      );

      expect(OcrTextUtils.selectableElements(result).map((e) => e.text), [
        'a',
        'b',
        'c',
      ]);
    });
  });
}
