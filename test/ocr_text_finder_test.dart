import 'package:flutter_test/flutter_test.dart';
import 'package:pdf_utility_flutter/ocr/domain/ocr_text_finder.dart';

void main() {
  const finder = OcrTextFinder();

  test('finds every occurrence in order', () {
    expect(finder.findIn('the cat sat on the mat', 'at'), const <OcrTextMatch>[
      OcrTextMatch(5, 7), // cat
      OcrTextMatch(9, 11), // sat
      OcrTextMatch(20, 22), // mat
    ]);
  });

  test('matches case-insensitively but reports original offsets', () {
    expect(
      finder.findIn('Invoice INVOICE invoice', 'invoice'),
      const <OcrTextMatch>[
        OcrTextMatch(0, 7),
        OcrTextMatch(8, 15),
        OcrTextMatch(16, 23),
      ],
    );
  });

  test('finds Devanagari text', () {
    expect(finder.findIn('यह हिन्दी है', 'हिन्दी'), const <OcrTextMatch>[
      OcrTextMatch(3, 9),
    ]);
  });

  test('does not overlap successive matches', () {
    expect(finder.findIn('aaaa', 'aa'), const <OcrTextMatch>[
      OcrTextMatch(0, 2),
      OcrTextMatch(2, 4),
    ]);
  });

  test('empty query or text finds nothing', () {
    expect(finder.findIn('anything', ''), isEmpty);
    expect(finder.findIn('', 'anything'), isEmpty);
  });

  test('a query longer than the text finds nothing', () {
    expect(finder.findIn('short', 'much longer query'), isEmpty);
  });

  test('caps the number of matches so a pathological query stays bounded', () {
    const capped = OcrTextFinder(maxMatches: 3);
    expect(capped.findIn('a' * 500, 'a').length, 3);
  });

  test('dotted capital I folds under simple case mapping', () {
    // Documented behaviour rather than an accident: Dart's toLowerCase is
    // locale-independent simple case mapping, so it maps 'İ' to 'i' without
    // expanding the string, and offsets stay aligned with the rendered text.
    expect(finder.findIn('İstanbul', 'iSTANBUL'), const <OcrTextMatch>[
      OcrTextMatch(0, 8),
    ]);
    expect(finder.findIn('İstanbul', 'stanbul'), const <OcrTextMatch>[
      OcrTextMatch(1, 8),
    ]);
  });

  test('does not normalize composed and decomposed forms together', () {
    // A real limitation, asserted so it stays a known one: there is no
    // normalizer in the Dart core libraries and this phase adds no dependency.
    const composed = 'café';
    const decomposedQuery = 'cafe\u0301';
    expect(finder.findIn(composed, decomposedQuery), isEmpty);
    expect(finder.findIn(decomposedQuery, composed), isEmpty);
  });
}
