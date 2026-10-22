import 'package:flutter_test/flutter_test.dart';
import 'package:pdf_utility_flutter/ocr/domain/ocr_block.dart';
import 'package:pdf_utility_flutter/ocr/domain/ocr_element.dart';
import 'package:pdf_utility_flutter/ocr/domain/ocr_line.dart';
import 'package:pdf_utility_flutter/ocr/domain/ocr_rect.dart';
import 'package:pdf_utility_flutter/ocr/domain/ocr_result.dart';
import 'package:pdf_utility_flutter/ocr/domain/ocr_selection.dart';

OcrElement _word(String text, double l, double t, double r, double b) =>
    OcrElement(text: text, boundingBox: OcrRect.fromLTRB(l, t, r, b));

void main() {
  final hello = _word('Hello', 10, 10, 60, 30);
  final world = _word('World', 70, 10, 130, 30);
  final again = _word('Again', 10, 40, 60, 60);

  final result = OcrResult(
    sourceImage: const SourceImageInfo(
      path: '/tmp/x.jpg',
      width: 200,
      height: 100,
    ),
    fullText: 'Hello World\nAgain',
    blocks: [
      OcrBlock(
        text: 'Hello World',
        boundingBox: OcrRect.fromLTRB(10, 10, 130, 30),
        lines: [
          OcrLine(
            text: 'Hello World',
            boundingBox: OcrRect.fromLTRB(10, 10, 130, 30),
            elements: [hello, world],
          ),
          OcrLine(
            text: 'Again',
            boundingBox: OcrRect.fromLTRB(10, 40, 60, 60),
            elements: [again],
          ),
        ],
      ),
    ],
  );

  group('OcrSelection', () {
    test('starts empty', () {
      final selection = OcrSelection.empty(result);
      expect(selection.isEmpty, isTrue);
      expect(selection.text, '');
    });

    test('only() replaces the selection with a single word', () {
      final selection = OcrSelection.empty(result).only(hello);
      expect(selection.length, 1);
      expect(selection.text, 'Hello');
      expect(selection.contains(hello), isTrue);
    });

    test('add() accumulates words and is idempotent', () {
      var selection = OcrSelection.empty(result).add(hello).add(world);
      expect(selection.length, 2);
      selection = selection.add(hello); // duplicate ignored
      expect(selection.length, 2);
    });

    test('remove() drops a word', () {
      final selection = OcrSelection.empty(
        result,
      ).add(hello).add(world).remove(hello);
      expect(selection.length, 1);
      expect(selection.contains(world), isTrue);
      expect(selection.contains(hello), isFalse);
    });

    test('toggle() adds then removes', () {
      final selection = OcrSelection.empty(result).toggle(world);
      expect(selection.contains(world), isTrue);
      expect(selection.toggle(world).contains(world), isFalse);
    });

    test(
      'concatenates selected text in reading order regardless of tap order',
      () {
        // Tap order: Again, then Hello, then World.
        final selection = OcrSelection.empty(
          result,
        ).add(again).add(hello).add(world);
        expect(selection.text, 'Hello World Again');
      },
    );

    test('isContiguous detects adjacent runs in reading order', () {
      expect(
        OcrSelection.empty(result).add(hello).add(world).isContiguous,
        isTrue,
      );
      expect(
        OcrSelection.empty(result).add(hello).add(again).isContiguous,
        isFalse,
      );
    });

    test('clear() empties the selection', () {
      expect(OcrSelection.empty(result).add(hello).clear().isEmpty, isTrue);
    });

    test('addAll() adds several words, preserving reading order', () {
      final selection = OcrSelection.empty(result).addAll([world, hello]);
      expect(selection.length, 2);
      expect(selection.text, 'Hello World');
    });
  });

  group('range selection (drag)', () {
    test('covers every word between the anchor and extent, forward', () {
      final selection = OcrSelection.empty(result).range(hello, world);
      expect(selection.elements, [hello, world]);
      expect(selection.text, 'Hello World');
      expect(selection.isContiguous, isTrue);
    });

    test('is symmetric: dragging backwards selects the same words', () {
      final forward = OcrSelection.empty(result).range(hello, again);
      final backward = OcrSelection.empty(result).range(again, hello);
      expect(backward.elements, forward.elements);
      expect(backward.text, 'Hello World Again');
    });

    test('spans lines, keeping reading order', () {
      final selection = OcrSelection.empty(result).range(world, again);
      expect(selection.text, 'World Again');
      expect(selection.isContiguous, isTrue);
    });

    test('a range that starts and ends on the same word is a single word', () {
      final selection = OcrSelection.empty(result).range(world, world);
      expect(selection.elements, [world]);
      expect(selection.text, 'World');
    });

    test('the extent from a previous drag can shrink the range', () {
      final selection = OcrSelection.empty(
        result,
      ).range(hello, again).range(hello, world);
      expect(selection.text, 'Hello World');
    });

    test('an unknown anchor or extent degrades to the word that is known', () {
      final stranger = _word('Stranger', 200, 200, 260, 220);
      expect(OcrSelection.empty(result).range(stranger, world).elements, [
        world,
      ]);
      expect(OcrSelection.empty(result).range(hello, stranger).elements, [
        hello,
      ]);
    });
  });
}
