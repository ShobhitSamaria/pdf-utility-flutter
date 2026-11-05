import 'package:flutter_test/flutter_test.dart';
import 'package:pdf_utility_flutter/ocr/domain/ocr_block.dart';
import 'package:pdf_utility_flutter/ocr/domain/ocr_document_layout.dart';
import 'package:pdf_utility_flutter/ocr/domain/ocr_line.dart';
import 'package:pdf_utility_flutter/ocr/domain/ocr_rect.dart';
import 'package:pdf_utility_flutter/ocr/domain/ocr_result.dart';

/// Reading order for document types other than a newspaper page.
///
/// The newspaper is one layout. A letter, a government notice and a page whose
/// text wraps around a picture are others, and the same code has to read all of
/// them: this file pins the behaviour on synthetic geometry so a change that
/// helps one cannot silently break another.
OcrLine _line(
  String text, {
  required double left,
  required double top,
  required double right,
  double height = 16,
}) => OcrLine(
  text: text,
  boundingBox: OcrRect.fromLTRB(left, top, right, top + height),
  elements: const [],
);

OcrBlock _block(List<OcrLine> lines, {String? text}) => OcrBlock(
  text: text ?? lines.map((line) => line.text).join('\n'),
  boundingBox: OcrDocumentLayout.boundsOf(lines),
  lines: lines,
);

OcrResult _result(List<OcrBlock> blocks) => OcrResult(
  sourceImage: const SourceImageInfo(
    path: 'page.png',
    width: 1000,
    height: 1400,
  ),
  fullText: blocks.map((block) => block.text).join('\n'),
  blocks: blocks,
);

List<String> _texts(OcrResult result) => [
  for (final block in OcrDocumentLayout.blocks(result)) block.text,
];

void main() {
  group('letters', () {
    test('reads the date block and the reference above the body', () {
      // A letter prints its date and reference at the top right; the body begins
      // lower down on the left. Reading columns left-to-right to the end would
      // put the whole letter before its own date.
      final result = _result([
        _block([_line('14 March 2026', left: 620, top: 80, right: 800)]),
        _block([_line('Ref: DM/2026/118', left: 620, top: 106, right: 810)]),
        _block([
          _line('The District Magistrate', left: 80, top: 200, right: 520),
          _line('Jaipur, Rajasthan', left: 80, top: 222, right: 480),
          _line(
            'Subject: repair of the approach road',
            left: 80,
            top: 244,
            right: 560,
          ),
          _line(
            'Sir, the road has been closed since June.',
            left: 80,
            top: 266,
            right: 560,
          ),
        ]),
        _block([_line('Yours faithfully', left: 80, top: 420, right: 320)]),
        _block([_line('R. Sharma', left: 80, top: 442, right: 260)]),
      ]);

      final texts = _texts(result);

      expect(texts.first, '14 March 2026');
      expect(texts[1], 'Ref: DM/2026/118');
      expect(texts[2], startsWith('The District Magistrate'));
      expect(texts.last, 'R. Sharma');
      // The body is one paragraph, not four lines.
      expect(
        texts.where((text) => text.contains('District Magistrate')),
        hasLength(1),
      );
      expect(
        texts.singleWhere((text) => text.contains('District Magistrate')),
        contains('closed since June'),
      );
    });
  });

  group('notices', () {
    test('reads a centred title before the paragraph under it', () {
      // Government notices are a centred heading over full-width prose. Sorting
      // the page by left edge alone reads the body first, because the body starts
      // further left than the title.
      final result = _result([
        _block([_line('सूचना', left: 430, top: 60, right: 570, height: 26)]),
        _block([
          for (var index = 0; index < 5; index++)
            _line(
              'आवेदन पत्र ${index + 1}',
              left: 80,
              top: 140.0 + index * 22,
              right: 920,
            ),
        ]),
      ]);

      final texts = _texts(result);

      expect(texts, hasLength(2));
      expect(texts.first, 'सूचना');
      expect(texts.last, startsWith('आवेदन पत्र 1'));
      expect(texts.last, contains('आवेदन पत्र 5'));
    });

    test('keeps a heading apart from the body printed under it', () {
      final result = _result([
        _block([_line('NOTICE', left: 80, top: 60, right: 600, height: 40)]),
        _block([
          for (var index = 0; index < 3; index++)
            _line(
              'Body line ${index + 1}',
              left: 80,
              top: 104.0 + index * 20,
              right: 500,
            ),
        ]),
      ]);

      final texts = _texts(result);

      expect(texts, hasLength(2));
      expect(texts.first, 'NOTICE');
      expect(texts[1], startsWith('Body line 1'));
    });
  });

  group('text wrapped around a picture', () {
    test('follows the indentation of a paragraph that steps in', () {
      // A story printed beside a photograph starts each line further right. The
      // lines share a column and are set in one size, so they are one paragraph;
      // the indent must not be read as a change of region.
      final result = _result([
        _block([
          _line(
            'LEH. The social worker Sonam Wangchuk said',
            left: 370,
            top: 100,
            right: 851,
            height: 40,
          ),
          _line(
            'on Monday that the centre has made no',
            left: 416,
            top: 144,
            right: 832,
            height: 40,
          ),
          _line(
            'progress on the demands, and that a',
            left: 442,
            top: 188,
            right: 787,
            height: 40,
          ),
          _line(
            'larger movement will follow in September.',
            left: 463,
            top: 232,
            right: 828,
            height: 40,
          ),
        ]),
        _block([
          _line('सोनम वांगचुक', left: 351, top: 20, right: 597, height: 80),
        ]),
      ]);

      final texts = _texts(result);

      expect(texts, hasLength(2));
      expect(texts.first, 'सोनम वांगचुक');
      expect(
        texts.last,
        'LEH. The social worker Sonam Wangchuk said '
        'on Monday that the centre has made no '
        'progress on the demands, and that a '
        'larger movement will follow in September.',
      );
    });
  });
}
