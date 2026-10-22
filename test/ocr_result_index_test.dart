import 'package:flutter_test/flutter_test.dart';
import 'package:pdf_utility_flutter/ocr/domain/ocr_block.dart';
import 'package:pdf_utility_flutter/ocr/domain/ocr_element.dart';
import 'package:pdf_utility_flutter/ocr/domain/ocr_line.dart';
import 'package:pdf_utility_flutter/ocr/domain/ocr_rect.dart';
import 'package:pdf_utility_flutter/ocr/domain/ocr_result.dart';
import 'package:pdf_utility_flutter/ocr/domain/ocr_result_index.dart';
import 'package:pdf_utility_flutter/ocr/domain/ocr_text_utils.dart';

OcrElement _word(String text, double left) => OcrElement(
  text: text,
  boundingBox: OcrRect.fromLTRB(left, 0, left + 50, 20),
);

OcrResult _result({
  required List<OcrLine> lines,
  List<String> extraWords = const [],
}) {
  final blank = OcrElement(
    text: '   ',
    boundingBox: OcrRect.fromLTRB(0, 0, 10, 10),
  );
  final degenerate = OcrElement(
    text: 'no-geometry',
    boundingBox: OcrRect.fromLTRB(5, 5, 5, 5),
  );

  return OcrResult(
    sourceImage: const SourceImageInfo(
      path: '/tmp/does-not-exist.jpg',
      width: 800,
      height: 600,
    ),
    fullText: 'text',
    blocks: [
      OcrBlock(
        text: 'text',
        boundingBox: OcrRect.fromLTRB(0, 0, 700, 100),
        lines: <OcrLine>[
          ...lines,
          OcrLine(
            text: '   ${extraWords.join(' ')}',
            boundingBox: OcrRect.fromLTRB(0, 300, 700, 320),
            elements: <OcrElement>[
              blank,
              degenerate,
              for (var i = 0; i < extraWords.length; i++)
                _word(extraWords[i], 100.0 + i * 60),
            ],
          ),
        ],
      ),
    ],
  );
}

void main() {
  final first = _word('Alpha', 0);
  final second = _word('Beta', 60);
  final duplicateOfFirst = _word('Alpha', 0);

  OcrResult build() => _result(
    lines: <OcrLine>[
      OcrLine(
        text: 'Alpha Beta',
        boundingBox: OcrRect.fromLTRB(0, 0, 400, 20),
        elements: <OcrElement>[first, second],
      ),
    ],
    extraWords: const ['Gamma'],
  );

  test('returns the same index for the same result', () {
    final result = build();

    expect(
      identical(OcrResultIndex.of(result), OcrResultIndex.of(result)),
      isTrue,
    );
  });

  test('returns a different index for a different result', () {
    expect(
      identical(OcrResultIndex.of(build()), OcrResultIndex.of(build())),
      isFalse,
    );
  });

  test('flattens lines and words once, in reading order', () {
    final result = build();
    final index = OcrResultIndex.of(result);

    expect(index.lines, hasLength(2));
    // Every word is kept, including the ones selection filters out later.
    expect(index.elements.map((element) => element.text).toList(), <String>[
      'Alpha',
      'Beta',
      '   ',
      'no-geometry',
      'Gamma',
    ]);
    // Same collection instance on every read, which is the whole point.
    expect(identical(index.elements, index.elements), isTrue);
  });

  test('selectable words match the un-cached helper exactly', () {
    final result = build();

    expect(
      OcrResultIndex.of(result).selectableElements,
      equals(OcrTextUtils.selectableElements(result)),
    );
  });

  test('drops whitespace-only and zero-size elements from selection', () {
    final selectable = OcrResultIndex.of(build()).selectableElements;
    final texts = selectable.map((element) => element.text).toList();

    expect(texts, contains('Alpha'));
    expect(texts, contains('Beta'));
    expect(texts, contains('Gamma'));
    expect(texts.any((text) => text.trim().isEmpty), isFalse);
    expect(texts, isNot(contains('no-geometry')));
  });

  test('indexOf agrees with List.indexOf, including for duplicates', () {
    final result = build();
    final index = OcrResultIndex.of(result);
    final words = result.elements;

    for (final element in words) {
      expect(index.indexOf(element), words.indexOf(element));
    }

    // A value-equal word that is not in the list reports -1, exactly as
    // `indexOf` does.
    expect(index.indexOf(duplicateOfFirst), words.indexOf(duplicateOfFirst));
  });

  test('indexOf answers in constant time for a word deep in the list', () {
    final tail = _word('Omega', 900);
    final result = _result(
      lines: <OcrLine>[
        OcrLine(
          text: 'Alpha Beta',
          boundingBox: OcrRect.fromLTRB(0, 0, 400, 20),
          elements: <OcrElement>[first, second],
        ),
      ],
      extraWords: const ['Gamma', 'Delta'],
    );
    final index = OcrResultIndex.of(result);

    expect(index.indexOf(tail), -1);
    expect(index.indexOf(second), 1);
  });
}
