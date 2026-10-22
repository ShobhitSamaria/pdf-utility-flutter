import 'package:flutter_test/flutter_test.dart';
import 'package:pdf_utility_flutter/ocr/domain/ocr_block.dart';
import 'package:pdf_utility_flutter/ocr/domain/ocr_element.dart';
import 'package:pdf_utility_flutter/ocr/domain/ocr_line.dart';
import 'package:pdf_utility_flutter/ocr/domain/ocr_rect.dart';
import 'package:pdf_utility_flutter/ocr/domain/ocr_result.dart';
import 'package:pdf_utility_flutter/ocr/domain/ocr_selection.dart';
import 'package:pdf_utility_flutter/translation/domain/translated_region.dart';
import 'package:pdf_utility_flutter/translation/presentation/ocr_translation_regions.dart';

OcrElement _word(String text, double l, double t, double r, double b) =>
    OcrElement(text: text, boundingBox: OcrRect.fromLTRB(l, t, r, b));

OcrLine _line(String text, OcrRect box, List<OcrElement> words) =>
    OcrLine(text: text, boundingBox: box, elements: words);

void main() {
  // --- fixture: two blocks, three content lines + one blank line ------------
  final hello = _word('Hello', 10, 10, 60, 30);
  final world = _word('World', 70, 10, 130, 30);
  final today = _word('Today', 140, 10, 200, 30);

  final again = _word('Again', 10, 40, 70, 60);
  final now = _word('Now', 80, 40, 140, 60);

  final third = _word('Third', 10, 70, 70, 90);
  final line = _word('line', 80, 70, 140, 90);

  final lineOne = _line(
    'Hello World Today',
    OcrRect.fromLTRB(10, 10, 200, 30),
    [hello, world, today],
  );
  final lineTwo = _line('Again Now', OcrRect.fromLTRB(10, 40, 140, 60), [
    again,
    now,
  ]);
  final lineThree = _line('Third line', OcrRect.fromLTRB(10, 70, 140, 90), [
    third,
    line,
  ]);
  final blankLine = _line(
    '   ',
    OcrRect.fromLTRB(10, 100, 140, 120),
    const <OcrElement>[],
  );

  final result = OcrResult(
    sourceImage: const SourceImageInfo(
      path: '/tmp/x.jpg',
      width: 400,
      height: 400,
    ),
    fullText: 'Hello World Today\nAgain Now\nThird line',
    blocks: [
      OcrBlock(
        text: 'Hello World Today\nAgain Now',
        boundingBox: OcrRect.fromLTRB(10, 10, 200, 60),
        lines: [lineOne, lineTwo],
      ),
      OcrBlock(
        text: 'Third line',
        boundingBox: OcrRect.fromLTRB(10, 70, 140, 120),
        lines: [lineThree, blankLine],
      ),
    ],
  );

  group('fromPage', () {
    test('makes one unit per paragraph, in reading order', () {
      final units = OcrTranslationRegions.fromPage(result);

      // Two blocks → two paragraphs. A paragraph is a whole run of lines, not
      // one unit per line: translating line by line is what fragmented the
      // output into unrelated phrases.
      expect(units.length, 2);
      expect(units.map((u) => u.text).toList(), [
        'Hello World Today Again Now',
        'Third line',
      ]);
      expect(units.map((u) => u.id).toList(), [0, 1]);
      expect(
        units.every((u) => u.kind == TranslatedRegionKind.paragraph),
        isTrue,
      );
    });

    test('skips whitespace-only lines', () {
      final units = OcrTranslationRegions.fromPage(result);
      expect(units.any((u) => u.text.trim().isEmpty), isFalse);
      // The blank line inside the second block neither becomes a unit nor
      // duplicates the text around it.
      expect(units[1].text, 'Third line');
    });

    test('keeps each paragraph\'s union box in source-image space', () {
      final units = OcrTranslationRegions.fromPage(result);
      expect(units[0].bounds, OcrRect.fromLTRB(10, 10, 200, 60));
      expect(units[1].bounds, lineThree.boundingBox);
    });

    test('translates one paragraph once even when OCR split it in two', () {
      // ML Kit can cut a paragraph at a block boundary. Each fragment used to
      // become its own translation unit, which read as a sentence broken across
      // two boxes on the photo and as two fragments in the full text.
      OcrLine line(String text, double top) => OcrLine(
        text: text,
        boundingBox: OcrRect.fromLTRB(10, top, 250, top + 20),
        elements: const <OcrElement>[],
      );
      final localResult = OcrResult(
        sourceImage: const SourceImageInfo(
          path: '/tmp/x.jpg',
          width: 300,
          height: 300,
        ),
        fullText: 'The court held that\nworkers are covered\nby Rule 2022.',
        blocks: [
          OcrBlock(
            text: 'The court held that\nworkers are covered',
            boundingBox: OcrRect.fromLTRB(10, 10, 250, 50),
            lines: [
              line('The court held that', 10),
              line('workers are covered', 30),
            ],
          ),
          OcrBlock(
            text: 'by Rule 2022.',
            boundingBox: OcrRect.fromLTRB(10, 56, 250, 76),
            lines: [line('by Rule 2022.', 56)],
          ),
        ],
      );

      final units = OcrTranslationRegions.fromPage(localResult);
      expect(units.length, 1);
      expect(
        units.single.text,
        'The court held that workers are covered by Rule 2022.',
      );
      // The unit's box spans the whole paragraph, not just its first block.
      expect(units.single.bounds, OcrRect.fromLTRB(10, 10, 250, 76));
    });

    test('joins a hyphenated line break instead of inventing a compound', () {
      OcrLine line(String text, double top) => OcrLine(
        text: text,
        boundingBox: OcrRect.fromLTRB(10, top, 250, top + 20),
        elements: const <OcrElement>[],
      );
      final localResult = OcrResult(
        sourceImage: const SourceImageInfo(
          path: '/tmp/x.jpg',
          width: 300,
          height: 300,
        ),
        fullText: 'inter-\nnational',
        blocks: [
          OcrBlock(
            text: 'inter-\nnational',
            boundingBox: OcrRect.fromLTRB(10, 10, 250, 50),
            lines: [line('inter-', 10), line('national', 30)],
          ),
        ],
      );

      final units = OcrTranslationRegions.fromPage(localResult);
      expect(units.single.text, 'international');
    });

    test('keeps text that has no geometry instead of dropping it', () {
      final placeless = OcrLine(
        text: 'Unplaced words',
        boundingBox: OcrRect.fromLTRB(0, 0, 0, 0),
        elements: const <OcrElement>[],
      );
      final localResult = OcrResult(
        sourceImage: const SourceImageInfo(
          path: '/tmp/x.jpg',
          width: 100,
          height: 100,
        ),
        fullText: 'Hello\nUnplaced words',
        blocks: [
          OcrBlock(
            text: 'Hello',
            boundingBox: OcrRect.fromLTRB(10, 10, 60, 30),
            lines: [
              OcrLine(
                text: 'Hello',
                boundingBox: OcrRect.fromLTRB(10, 10, 60, 30),
                elements: const <OcrElement>[],
              ),
              placeless,
            ],
          ),
        ],
      );

      final units = OcrTranslationRegions.fromPage(localResult);
      expect(units.map((u) => u.text).toList(), ['Hello', 'Unplaced words']);
      expect(units.last.hasGeometry, isFalse);
    });

    test('returns nothing for an empty result', () {
      const empty = OcrResult(
        sourceImage: SourceImageInfo(path: '/tmp/x.jpg', width: 10, height: 10),
        fullText: '',
        blocks: [],
      );
      expect(OcrTranslationRegions.fromPage(empty), isEmpty);
    });
  });

  group('fromSelection', () {
    test('returns nothing when nothing is selected', () {
      expect(
        OcrTranslationRegions.fromSelection(OcrSelection.empty(result)),
        isEmpty,
      );
    });

    test('a single word becomes one region at that word', () {
      final units = OcrTranslationRegions.fromSelection(
        OcrSelection.empty(result).only(world),
      );

      expect(units.length, 1);
      expect(units.single.text, 'World');
      expect(units.single.bounds, world.boundingBox);
      expect(units.single.kind, TranslatedRegionKind.selection);
    });

    test('words on one line merge into a single region', () {
      final units = OcrTranslationRegions.fromSelection(
        OcrSelection.empty(result).add(hello).add(world),
      );

      expect(units.length, 1);
      expect(units.single.text, 'Hello World');
      expect(units.single.bounds, OcrRect.fromLTRB(10, 10, 130, 30));
    });

    test('unselected words between two picks are not included in the text', () {
      // Hello + Today, with World unselected in between.
      final units = OcrTranslationRegions.fromSelection(
        OcrSelection.empty(result).add(today).add(hello),
      );

      expect(units.single.text, 'Hello Today');
      // The box is the union of the picked words, so it spans World too — that
      // is what "draw the translation over the selected run" means.
      expect(units.single.bounds, OcrRect.fromLTRB(10, 10, 200, 30));
    });

    test(
      'a multi-line selection becomes one region per line, in reading order',
      () {
        // Tap order deliberately reversed (Now, then Hello) to prove the units
        // follow the OCR reading order, not the tap order.
        final units = OcrTranslationRegions.fromSelection(
          OcrSelection.empty(result).add(now).add(hello),
        );

        expect(units.length, 2);
        expect(units.map((u) => u.text).toList(), ['Hello', 'Now']);
        expect(units[0].bounds, hello.boundingBox);
        expect(units[1].bounds, now.boundingBox);
        expect(units.map((u) => u.id).toList(), [0, 1]);
      },
    );

    test('the whole page selected gives one region per line', () {
      final selection = OcrSelection.empty(result)
          .add(hello)
          .add(world)
          .add(today)
          .add(again)
          .add(now)
          .add(third)
          .add(line);

      final units = OcrTranslationRegions.fromSelection(selection);

      expect(units.length, 3);
      expect(units.map((u) => u.text).toList(), [
        'Hello World Today',
        'Again Now',
        'Third line',
      ]);
    });

    test('words without usable geometry are ignored', () {
      final emptyWord = _word('   ', 10, 10, 60, 30);
      final degenerate = _word('Zero', 10, 10, 10, 10);
      final localResult = OcrResult(
        sourceImage: const SourceImageInfo(
          path: '/tmp/x.jpg',
          width: 100,
          height: 100,
        ),
        fullText: 'Hi',
        blocks: [
          OcrBlock(
            text: 'Hi',
            boundingBox: OcrRect.fromLTRB(10, 10, 60, 30),
            lines: [
              OcrLine(
                text: 'Hi',
                boundingBox: OcrRect.fromLTRB(10, 10, 60, 30),
                elements: [emptyWord, degenerate],
              ),
            ],
          ),
        ],
      );

      final units = OcrTranslationRegions.fromSelection(
        OcrSelection.empty(localResult).add(emptyWord).add(degenerate),
      );

      expect(units, isEmpty);
    });

    test('an element outside any line is still translated on its own', () {
      final orphan = _word('Orphan', 300, 300, 380, 320);
      final selection = OcrSelection.empty(result).add(orphan);

      final units = OcrTranslationRegions.fromSelection(selection);

      expect(units.length, 1);
      expect(units.single.text, 'Orphan');
      expect(units.single.bounds, orphan.boundingBox);
    });
  });
}
