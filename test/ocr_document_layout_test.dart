import 'package:flutter_test/flutter_test.dart';
import 'package:pdf_utility_flutter/ocr/domain/ocr_block.dart';
import 'package:pdf_utility_flutter/ocr/domain/ocr_document_layout.dart';
import 'package:pdf_utility_flutter/ocr/domain/ocr_line.dart';
import 'package:pdf_utility_flutter/ocr/domain/ocr_rect.dart';
import 'package:pdf_utility_flutter/ocr/domain/ocr_result.dart';

OcrLine _line(
  String text, {
  required double left,
  required double top,
  required double right,
  double height = 20,
}) => OcrLine(
  text: text,
  boundingBox: OcrRect.fromLTRB(left, top, right, top + height),
  elements: const [],
);

OcrBlock _block(List<OcrLine> lines, {double padding = 0}) {
  final bounds = OcrDocumentLayout.boundsOf(lines);
  return OcrBlock(
    text: OcrDocumentLayout.joinLines(lines.map((line) => line.text)),
    boundingBox: padding == 0
        ? bounds
        : OcrRect.fromLTRB(
            bounds.left - padding,
            bounds.top - padding,
            bounds.right + padding,
            bounds.bottom + padding,
          ),
    lines: lines,
  );
}

OcrResult _result(
  List<OcrBlock> blocks, {
  int width = 1200,
  int height = 1600,
}) => OcrResult(
  sourceImage: SourceImageInfo(
    path: '/tmp/page.jpg',
    width: width,
    height: height,
  ),
  fullText: blocks.map((block) => block.text).join('\n'),
  blocks: blocks,
  engineName: 'Synthetic',
);

/// Six body lines for one newspaper column.
List<OcrLine> _column({
  required double left,
  required double right,
  required double top,
  String prefix = 'Body',
}) => [
  for (var index = 0; index < 6; index++)
    _line(
      '$prefix line ${index + 1}',
      left: left,
      right: right,
      top: top + index * 26,
      height: 22,
    ),
];

void main() {
  group('reading order', () {
    test('reads a three-column newspaper column by column', () {
      final headline = [
        _line(
          'Relief to contract workers employed through agencies',
          left: 100,
          right: 1100,
          top: 100,
          height: 40,
        ),
        _line(
          'on contract, benefits will be provided under Rules 2022',
          left: 100,
          right: 1100,
          top: 140,
          height: 40,
        ),
      ];
      final left = _column(left: 100, right: 420, top: 260, prefix: 'Left');
      final middle = _column(left: 460, right: 780, top: 260, prefix: 'Middle');
      final right = _column(left: 820, right: 1140, top: 260, prefix: 'Right');

      // Block order from the engine is deliberately scrambled: this is what
      // makes a newspaper's translation jump between unrelated sentences.
      final layout = OcrDocumentLayout.blocks(
        _result([
          _block(right),
          _block(headline),
          _block(middle),
          _block(left),
        ]),
      );

      expect(layout.length, 4);
      expect(layout[0].text, startsWith('Relief to contract workers'));
      expect(layout[0].lines.length, 2);
      expect(layout[1].text, startsWith('Left line 1'));
      expect(layout[2].text, startsWith('Middle line 1'));
      expect(layout[3].text, startsWith('Right line 1'));

      // Every column is one coherent paragraph, not six separate lines.
      for (final block in layout.skip(1)) {
        expect(block.lines.length, 6);
        expect(block.text.split(' ').length, greaterThan(6));
      }
      expect(layout.map((block) => block.id).toList(), [0, 1, 2, 3]);
    });

    test('never merges text from two columns into one block', () {
      final left = _column(left: 100, right: 400, top: 100, prefix: 'L');
      final right = _column(left: 440, right: 740, top: 100, prefix: 'R');

      final layout = OcrDocumentLayout.blocks(
        _result([_block(left), _block(right)]),
      );

      expect(layout.length, 2);
      expect(layout[0].text, isNot(contains('R line')));
      expect(layout[1].text, isNot(contains('L line')));
    });

    test('lays out a single block that covers the whole page', () {
      // ML Kit sometimes returns one block for a dense page. Geometry still has
      // to recover the columns, otherwise the page translates row by row.
      final lines = <OcrLine>[
        for (var index = 0; index < 3; index++)
          _line('A${index + 1}', left: 100, right: 300, top: 100 + index * 26),
        for (var index = 0; index < 3; index++)
          _line('B${index + 1}', left: 340, right: 540, top: 100 + index * 26),
      ];

      final layout = OcrDocumentLayout.blocks(_result([_block(lines)]));

      expect(layout.map((block) => block.lines.map((l) => l.text).join(',')), [
        'A1,A2,A3',
        'B1,B2,B3',
      ]);
    });

    test('is deterministic', () {
      final lines = [
        ..._column(left: 100, right: 400, top: 100),
        ..._column(left: 440, right: 740, top: 100, prefix: 'Second'),
      ];
      final first = OcrDocumentLayout.blocks(_result([_block(lines)]));
      final second = OcrDocumentLayout.blocks(_result([_block(lines)]));

      expect(
        first.map((block) => '${block.id}:${block.text}').toList(),
        second.map((block) => '${block.id}:${block.text}').toList(),
      );
    });

    test('keeps portrait and landscape pages in the same order', () {
      final lines = [
        ..._column(left: 100, right: 400, top: 100, prefix: 'Portrait'),
        ..._column(left: 440, right: 740, top: 100, prefix: 'Right'),
      ];
      final portrait = OcrDocumentLayout.blocks(_result([_block(lines)]));
      final landscape = OcrDocumentLayout.blocks(
        _result([_block(lines)], width: 1600, height: 1200),
      );

      expect(
        portrait.map((block) => block.text).toList(),
        landscape.map((block) => block.text).toList(),
      );
    });
  });

  group('paragraphs', () {
    test('splits a block at a paragraph gap', () {
      final lines = <OcrLine>[
        _line('First paragraph line one.', left: 100, right: 600, top: 100),
        _line('First paragraph line two.', left: 100, right: 600, top: 120),
        // 26 px gap > 0.8 × 20: a printed paragraph break.
        _line('Second paragraph line one.', left: 100, right: 600, top: 166),
        _line('Second paragraph line two.', left: 100, right: 600, top: 186),
      ];

      final layout = OcrDocumentLayout.blocks(_result([_block(lines)]));

      expect(layout.length, 2);
      expect(
        layout[0].text,
        'First paragraph line one. First paragraph line two.',
      );
      expect(
        layout[1].text,
        'Second paragraph line one. Second paragraph line two.',
      );
    });

    test('keeps a heading out of the paragraph beneath it', () {
      final lines = <OcrLine>[
        _line('GOVERNMENT NOTICE', left: 100, right: 600, top: 100, height: 34),
        _line('1. Applications must be filed', left: 100, right: 600, top: 140),
        _line(
          '2. The last date is 31-10-2026',
          left: 100,
          right: 600,
          top: 160,
        ),
        _line('3. Fees are non-refundable', left: 100, right: 600, top: 180),
      ];

      final layout = OcrDocumentLayout.blocks(_result([_block(lines)]));

      expect(layout.length, 2);
      expect(layout[0].text, 'GOVERNMENT NOTICE');
      expect(layout[1].text, contains('1. Applications'));
      expect(layout[1].text, isNot(contains('GOVERNMENT')));
    });

    test('rejoins a short final line that ends its own block region', () {
      // What ML Kit actually returned for the last line of a Hindi newspaper
      // column: `सकता।` has no ascender, matra or descender, so its box is 16 px
      // tall under a 24 px line (0.67) while it is the same type size. The
      // height test alone split it off, and the column read as a paragraph
      // followed by a stray fragment. Its width is what identifies it: a final
      // line does not fill the measure.
      final lines = <OcrLine>[
        _line(
          'नियम 2022 के अंतर्गत',
          left: 397,
          top: 643,
          right: 715,
          height: 28,
        ),
        _line('नहीं लाया जा', left: 397, top: 672, right: 715, height: 24),
        _line('सकता।', left: 397, top: 707, right: 457, height: 16),
      ];

      final layout = OcrDocumentLayout.blocks(_result([_block(lines)]));

      expect(layout, hasLength(1));
      expect(layout.single.lines, hasLength(3));
      expect(layout.single.text, endsWith('नहीं लाया जा सकता।'));
    });

    test('keeps a smaller-type line in the same column out of the paragraph', () {
      // A byline or a figure caption sits below the text in a smaller face and,
      // unlike a final line, can be narrow too. What tells them apart is that no
      // single block holds both: the box below is its own region.
      final body = <OcrLine>[
        _line('Applications must be filed', left: 100, top: 100, right: 500),
        _line('with the department by', left: 100, top: 120, right: 500),
      ];
      final byline = [
        _line('Bhaskar News', left: 100, top: 144, right: 250, height: 12),
      ];

      final layout = OcrDocumentLayout.blocks(
        _result([_block(body), _block(byline)]),
      );

      expect(layout, hasLength(2));
      expect(layout[0].text, isNot(contains('Bhaskar')));
      expect(layout[1].text, 'Bhaskar News');
    });

    test('rejoins a paragraph ML Kit split across two blocks', () {
      // Same column, ordinary leading (6 px at a 20 px line): the engine cut
      // this paragraph in two, not the typesetter. Paragraphing each block in
      // isolation is what turned it into two translated fragments.
      final first = <OcrLine>[
        _line('The High Court held that', left: 100, right: 600, top: 100),
        _line('contract workers appointed', left: 100, right: 600, top: 120),
      ];
      final second = <OcrLine>[
        _line('through agencies are covered', left: 100, right: 600, top: 146),
        _line('by Rule 2022.', left: 100, right: 600, top: 166),
      ];

      final layout = OcrDocumentLayout.blocks(
        _result([_block(first), _block(second)]),
      );

      expect(layout.length, 1);
      expect(layout.single.lines.length, 4);
      expect(layout.single.text, contains('contract workers appointed'));
      expect(layout.single.text, contains('by Rule 2022.'));
    });

    test('does not merge a printed paragraph break across blocks', () {
      final first = <OcrLine>[
        _line('First paragraph line one.', left: 100, right: 600, top: 100),
        _line('First paragraph line two.', left: 100, right: 600, top: 120),
      ];
      final second = <OcrLine>[
        _line('Second paragraph starts here.', left: 100, right: 600, top: 154),
        _line('And continues here.', left: 100, right: 600, top: 174),
      ];

      // 14 px gap at a 20 px line: wider than leading, so the block boundary is
      // a real paragraph break even though it is below the within-block gap
      // threshold. Treating it as a continuation is what merged separate
      // paragraphs into one translated run.
      final layout = OcrDocumentLayout.blocks(
        _result([_block(first), _block(second)]),
      );

      expect(layout.length, 2);
      expect(layout[0].lines.length, 2);
      expect(layout[0].text, isNot(contains('Second paragraph')));
      expect(layout[1].text, startsWith('Second paragraph'));
    });

    test('never glues two tightly stacked table cells together', () {
      // Single-line blocks sitting almost flush: this is a table, not a
      // paragraph, and a merged unit would translate and draw across two rows.
      final layout = OcrDocumentLayout.blocks(
        _result([
          _block([_line('Polling team 1', left: 100, right: 320, top: 100)]),
          _block([_line('Polling team 2', left: 100, right: 320, top: 121)]),
        ]),
      );

      expect(layout.length, 2);
      expect(layout[0].text, 'Polling team 1');
      expect(layout[1].text, 'Polling team 2');
    });

    test('joins a wrapped address split across single-line blocks', () {
      // ML Kit returns each line of a shipping label's return address as its own
      // block. The text itself shows the wrap (`… First Floor, S` continues as
      // `ector-76 …`), so the whole address must become one paragraph: six
      // separate units were translated as six unconnected fragments and drawn as
      // six boxes, which is what the overlay showed as cut-off text.
      final layout = OcrDocumentLayout.blocks(
        _result([
          _block([
            _line(
              'Shipped By (If undelivered, return to)',
              left: 100,
              top: 100,
              right: 600,
            ),
            _line(
              'Near East International LLP',
              left: 100,
              top: 122,
              right: 560,
            ),
          ]),
          _block([
            _line(
              'Plot No. 31/13, First Floor, S',
              left: 100,
              top: 144,
              right: 500,
            ),
          ]),
          _block([
            _line(
              'ector-76 Main Branch Darbaripur',
              left: 100,
              top: 166,
              right: 520,
            ),
          ]),
          _block([
            _line('r Road, Joining NH-8', left: 100, top: 188, right: 420),
          ]),
          _block([_line('Gurgaon', left: 100, top: 210, right: 240)]),
        ]),
      );

      expect(layout.length, 1);
      expect(
        layout.single.text,
        'Shipped By (If undelivered, return to) Near East International LLP '
        'Plot No. 31/13, First Floor, Sector-76 Main Branch Darbaripur '
        'r Road, Joining NH-8 Gurgaon',
      );
    });

    test('never joins stacked rows that have partners on their row', () {
      // A form prints its label and its value side by side. Two such rows look
      // exactly like a wrapped paragraph geometrically, but every line has a
      // same-row neighbour, which is what marks the region as a grid.
      final layout = OcrDocumentLayout.blocks(
        _result([
          _block([_line('Invoice No. :', left: 100, top: 100, right: 260)]),
          _block([_line('Retail219038', left: 300, top: 100, right: 520)]),
          _block([_line('Invoice Date :', left: 100, top: 122, right: 280)]),
          _block([_line('2026-10-23', left: 300, top: 122, right: 470)]),
        ]),
      );

      expect(layout.length, 4);
      expect(layout.map((block) => block.text), [
        'Invoice No. :',
        'Retail219038',
        'Invoice Date :',
        '2026-10-23',
      ]);
    });

    test('joins the two display-type halves of one printed line', () {
      // A headline that ML Kit split into a short left box and a long right box.
      // Both are display type — three times the body line — which is what marks
      // them as one line even though the left half is narrower than a column.
      // Translating the halves separately is what produced "Relief, Rule, Rule".
      // A headline is a small share of a page, and "display type" is measured
      // against the page's median line height — so the fixture has to look like
      // a page, not like half a headline and half a column.
      final body = <OcrLine>[
        for (var index = 0; index < 9; index++)
          _line(
            'Body line ${index + 1}.',
            left: 100,
            top: 200.0 + index * 20,
            right: 500,
          ),
      ];
      final headline = <OcrLine>[
        _line(
          'Headline long first line',
          left: 60,
          top: 60,
          right: 900,
          height: 44,
        ),
        _line('and its second', left: 60, top: 110, right: 400, height: 44),
        _line('half here', left: 430, top: 110, right: 900, height: 44),
      ];

      final layout = OcrDocumentLayout.blocks(
        _result([_block(headline), _block(body)]),
      );

      expect(layout, hasLength(2));
      expect(
        layout.first.text,
        'Headline long first line and its second half here',
      );
    });

    test('never joins the body columns of one row into a sentence', () {
      // The same row, three boxes side by side — a newspaper's three columns.
      // They are body-sized, so the display-type rule cannot fire, and they do
      // not share a column. Reading them as one paragraph would translate three
      // different articles as one sentence.
      final row = <OcrLine>[
        for (var column = 0; column < 3; column++)
          _line(
            'Column ${column + 1} line 1',
            left: 60 + column * 330.0,
            top: 100,
            right: 60 + column * 330.0 + 300,
          ),
        for (var column = 0; column < 3; column++)
          _line(
            'Column ${column + 1} line 2',
            left: 60 + column * 330.0,
            top: 122,
            right: 60 + column * 330.0 + 300,
          ),
      ];

      final layout = OcrDocumentLayout.blocks(_result([_block(row)]));

      expect(layout, hasLength(3));
      for (var column = 0; column < 3; column++) {
        expect(layout[column].text, contains('Column ${column + 1}'));
        for (var other = 0; other < 3; other++) {
          if (other == column) continue;
          expect(
            layout[column].text,
            isNot(contains('Column ${other + 1}')),
            reason: 'columns $column and $other were joined into one sentence',
          );
        }
      }
    });

    test('reads the columns inside one block left to right, not row by row', () {
      // ML Kit sometimes returns a block that spans two columns. Sorting its
      // lines by top-then-left interleaves the columns: every line becomes its
      // own fragment and the translation jumps left/right/left.
      final twoColumns = <OcrLine>[
        for (var row = 0; row < 3; row++) ...[
          _line(
            'Left ${row + 1}',
            left: 100,
            right: 300,
            top: 100.0 + row * 22,
          ),
          _line(
            'Right ${row + 1}',
            left: 400,
            right: 600,
            top: 100.0 + row * 22,
          ),
        ],
      ];
      final footer = [_line('Footer', left: 100, right: 600, top: 400)];

      final layout = OcrDocumentLayout.blocks(
        _result([_block(footer), _block(twoColumns)]),
      );

      expect(layout.map((block) => block.text).toList(), [
        'Left 1 Left 2 Left 3',
        'Right 1 Right 2 Right 3',
        'Footer',
      ]);
    });

    test('keeps a caption in another column out of the body paragraph', () {
      final body = _column(left: 100, right: 420, top: 100);
      final caption = [
        _line(
          'Photo: Bhaskar News',
          left: 460,
          right: 780,
          top: 130,
          height: 16,
        ),
      ];

      final layout = OcrDocumentLayout.blocks(
        _result([_block(body), _block(caption)]),
      );

      expect(layout.length, 2);
      expect(layout[1].text, 'Photo: Bhaskar News');
      expect(layout[0].text, isNot(contains('Photo')));
    });

    test('preserves mixed script, numbers, dates and punctuation', () {
      final lines = <OcrLine>[
        _line(
          'जयपुर 28-08-2025: राजस्थान हाईकोर्ट ने 4,000 कर्मचारियों को राहत दी।',
          left: 100,
          right: 700,
          top: 100,
        ),
        _line(
          'Rule 2022 (Section 3) applies — 100% benefit.',
          left: 100,
          right: 700,
          top: 120,
        ),
      ];

      final layout = OcrDocumentLayout.blocks(_result([_block(lines)]));

      expect(layout.single.text, contains('28-08-2025'));
      expect(layout.single.text, contains('4,000'));
      expect(layout.single.text, contains('राहत'));
      expect(layout.single.text, contains('Rule 2022 (Section 3)'));
      expect(layout.single.text, contains('100%'));
    });

    test('bounds are the union of the paragraph lines', () {
      final lines = <OcrLine>[
        _line('One', left: 100, right: 500, top: 100),
        _line('Two', left: 120, right: 600, top: 122),
      ];

      final layout = OcrDocumentLayout.blocks(_result([_block(lines)]));

      expect(layout.single.bounds, OcrRect.fromLTRB(100, 100, 600, 142));
    });
  });

  group('small print and spanning headlines', () {
    test('reads small print in three columns', () {
      // A notice photographed from far enough away that a line is 9 px tall and
      // the gutters are 10 px. Every threshold in the layout is a fraction of
      // the page's own line height, so the same geometry must produce the same
      // order as a large page — nothing here is tuned to pixel counts.
      const height = 9.0;
      const pitch = 11.0;
      final columns = <List<OcrLine>>[
        for (var column = 0; column < 3; column++)
          [
            for (var index = 0; index < 30; index++)
              _line(
                'C${column + 1}L${index + 1}',
                left: 20.0 + column * 110,
                right: 120.0 + column * 110,
                top: 100.0 + index * pitch,
                height: height,
              ),
          ],
      ];

      final layout = OcrDocumentLayout.blocks(
        // One block for the whole page, as the engine often returns for dense
        // small print.
        _result(
          [
            _block([for (final column in columns) ...column]),
          ],
          width: 400,
          height: 600,
        ),
      );

      expect(layout, hasLength(3));
      for (var column = 0; column < 3; column++) {
        final block = layout[column];
        expect(block.lines, hasLength(30));
        expect(
          block.text,
          startsWith('C${column + 1}L1 '),
          reason: 'small print must still be read column by column',
        );
        expect(block.text, isNot(contains('C${column + 2}L')));
      }
    });

    test(
      'reads a headline split into two boxes left to right, above the body',
      () {
        // ML Kit regularly returns one printed headline as two boxes. Both are
        // wide enough to be spanning anchors, so they must come out in order and
        // before the three columns under them — not one of them first and the
        // other after the body.
        final lines = <OcrLine>[
          _line(
            'Relief for contract workers',
            left: 100,
            right: 600,
            top: 40,
            height: 30,
          ),
          _line(
            'under the 2022 rules',
            left: 610,
            right: 1100,
            top: 40,
            height: 30,
          ),
          for (final column in <int>[0, 1, 2])
            for (var index = 0; index < 4; index++)
              _line(
                'C${column + 1}L${index + 1}',
                left: 100.0 + column * 340,
                right: 400.0 + column * 340,
                top: 120.0 + index * 26,
              ),
        ];

        final layout = OcrDocumentLayout.blocks(
          _result(
            [
              _block([lines[2]]),
              _block([lines[1]]),
              _block([lines[0]]),
              _block(lines.sublist(3)),
            ],
            width: 1200,
            height: 1600,
          ),
        );

        expect(layout.first.text, 'Relief for contract workers');
        expect(layout[1].text, 'under the 2022 rules');
        expect(layout[2].text, startsWith('C1L1'));
        expect(layout[3].text, startsWith('C2L1'));
        expect(layout[4].text, startsWith('C3L1'));
      },
    );
  });

  group('tables', () {
    test('reads a table row by row, one cell per block', () {
      final cells = <List<OcrLine>>[];
      for (var row = 0; row < 3; row++) {
        for (var column = 0; column < 3; column++) {
          final left = 100.0 + column * 240;
          cells.add([
            _line(
              'R${row + 1}C${column + 1}',
              left: left,
              right: left + 200,
              top: 100.0 + row * 60,
            ),
          ]);
        }
      }

      final layout = OcrDocumentLayout.blocks(
        _result([for (final cell in cells) _block(cell)]),
      );

      expect(layout.map((block) => block.text).toList(), [
        'R1C1',
        'R1C2',
        'R1C3',
        'R2C1',
        'R2C2',
        'R2C3',
        'R3C1',
        'R3C2',
        'R3C3',
      ]);
      // Cells are not merged into one long paragraph per column.
      expect(layout.every((block) => block.lines.length == 1), isTrue);
    });

    test('a receipt with two aligned columns is still read row by row', () {
      final rows = <List<OcrLine>>[
        for (var index = 0; index < 5; index++)
          [
            _line(
              'Item ${index + 1}',
              left: 100,
              right: 400,
              top: 100.0 + index * 50,
            ),
            _line(
              '₹${(index + 1) * 25}',
              left: 600,
              right: 700,
              top: 100.0 + index * 50,
            ),
          ],
      ];

      final layout = OcrDocumentLayout.blocks(
        _result([
          for (final row in rows)
            for (final cell in row) _block([cell]),
        ]),
      );

      expect(layout.length, 10);
      expect(layout[0].text, 'Item 1');
      expect(layout[1].text, '₹25');
      expect(layout[2].text, 'Item 2');
    });
  });

  group('degenerate input', () {
    test('an empty result has no blocks', () {
      const empty = OcrResult(
        sourceImage: SourceImageInfo(path: '/tmp/x.jpg', width: 10, height: 10),
        fullText: '',
        blocks: [],
      );
      expect(OcrDocumentLayout.blocks(empty), isEmpty);
      expect(OcrDocumentLayout.lines(empty), isEmpty);
    });

    test('blank lines are not content', () {
      final lines = <OcrLine>[
        _line('Real text', left: 100, right: 400, top: 100),
        _line('   ', left: 100, right: 400, top: 122),
      ];

      final layout = OcrDocumentLayout.blocks(_result([_block(lines)]));
      expect(layout.single.text, 'Real text');
    });

    test('a block with an unusable box still gets its lines laid out', () {
      final lines = <OcrLine>[
        _line('Unboxed block text', left: 100, right: 400, top: 100),
      ];
      final block = OcrBlock(
        text: 'Unboxed block text',
        boundingBox: const OcrRect(left: 0, top: 0, right: 0, bottom: 0),
        lines: lines,
      );

      final layout = OcrDocumentLayout.blocks(_result([block]));
      expect(layout.single.text, 'Unboxed block text');
      expect(layout.single.bounds, lines.single.boundingBox);
    });
  });
}
