import 'package:flutter_test/flutter_test.dart';
import 'package:pdf_utility_flutter/ocr/domain/ocr_block.dart';
import 'package:pdf_utility_flutter/ocr/domain/ocr_element.dart';
import 'package:pdf_utility_flutter/ocr/domain/ocr_line.dart';
import 'package:pdf_utility_flutter/ocr/domain/ocr_rect.dart';
import 'package:pdf_utility_flutter/ocr/domain/ocr_result.dart';

OcrElement _word(String text, double l, double t, double r, double b) =>
    OcrElement(text: text, boundingBox: OcrRect.fromLTRB(l, t, r, b));

void main() {
  final hello = _word('Hello', 10, 10, 60, 30);
  final world = _word('World', 70, 10, 130, 30);
  final line = OcrLine(
    text: 'Hello World',
    boundingBox: OcrRect.fromLTRB(10, 10, 130, 30),
    elements: [hello, world],
  );
  final block = OcrBlock(
    text: 'Hello World',
    boundingBox: OcrRect.fromLTRB(10, 10, 130, 30),
    lines: [line],
  );
  final result = OcrResult(
    sourceImage: const SourceImageInfo(
      path: '/tmp/x.jpg',
      width: 200,
      height: 100,
    ),
    fullText: 'Hello World',
    blocks: [block],
  );

  group('OcrResult', () {
    test('flattens lines and elements in reading order', () {
      expect(result.lines, [line]);
      expect(result.elements, [hello, world]);
    });

    test('elementAt finds the word under an image-space point', () {
      expect(result.elementAt(const OffsetInImage(20, 20)), hello);
      expect(result.elementAt(const OffsetInImage(100, 20)), world);
    });

    test('elementAt returns null outside any word', () {
      expect(result.elementAt(const OffsetInImage(0, 0)), isNull);
      expect(result.elementAt(const OffsetInImage(199, 99)), isNull);
    });

    test('isEmpty reflects the block list', () {
      const empty = OcrResult(
        sourceImage: SourceImageInfo(path: '/tmp/x.jpg', width: 1, height: 1),
        fullText: '',
        blocks: [],
      );
      expect(empty.isEmpty, isTrue);
      expect(result.isEmpty, isFalse);
    });
  });
}
