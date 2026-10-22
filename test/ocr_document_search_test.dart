import 'package:flutter_test/flutter_test.dart';
import 'package:pdf_utility_flutter/ocr/domain/ocr_block.dart';
import 'package:pdf_utility_flutter/ocr/domain/ocr_document_search.dart';
import 'package:pdf_utility_flutter/ocr/domain/ocr_element.dart';
import 'package:pdf_utility_flutter/ocr/domain/ocr_line.dart';
import 'package:pdf_utility_flutter/ocr/domain/ocr_rect.dart';
import 'package:pdf_utility_flutter/ocr/domain/ocr_result.dart';

OcrElement _word(String text, int index) => OcrElement(
  text: text,
  boundingBox: OcrRect.fromLTRB(index * 60.0, 0, index * 60.0 + 50, 20),
);

OcrResult _document(List<String> lines) {
  var index = 0;
  final blocks = <OcrBlock>[];

  for (var line = 0; line < lines.length; line++) {
    final words = lines[line].split(' ');
    final elements = <OcrElement>[
      for (final word in words) _word(word, index++),
    ];
    blocks.add(
      OcrBlock(
        text: lines[line],
        boundingBox: OcrRect.fromLTRB(0, line * 30.0, 600, line * 30.0 + 20),
        lines: <OcrLine>[
          OcrLine(
            text: lines[line],
            boundingBox: OcrRect.fromLTRB(
              0,
              line * 30.0,
              600,
              line * 30.0 + 20,
            ),
            elements: elements,
          ),
        ],
      ),
    );
  }

  return OcrResult(
    sourceImage: const SourceImageInfo(
      path: '/tmp/does-not-exist.jpg',
      width: 800,
      height: 600,
    ),
    fullText: lines.join('\n'),
    blocks: blocks,
  );
}

void main() {
  group('document text', () {
    test('is the trimmed words joined by single spaces', () {
      final search = OcrDocumentSearch(_document(['Hello   World', 'नमस्ते']));

      expect(search.documentText, 'Hello World नमस्ते');
      expect(search.words, hasLength(3));
    });

    test('has no matches to find in an empty document', () {
      final search = OcrDocumentSearch(
        OcrResult(
          sourceImage: const SourceImageInfo(
            path: '/tmp/does-not-exist.jpg',
            width: 10,
            height: 10,
          ),
          fullText: '',
          blocks: const <OcrBlock>[],
        ),
      );

      expect(search.documentText, '');
      expect(search.find('anything'), isEmpty);
    });
  });

  group('matching', () {
    final search = OcrDocumentSearch(
      _document(<String>['Hello World', 'नमस्ते दुनिया']),
    );

    test('is case insensitive', () {
      expect(search.find('world'), hasLength(1));
      expect(search.find('WORLD'), hasLength(1));
      expect(search.find('WoRlD'), hasLength(1));
    });

    test('finds a single word and points at that element', () {
      final hit = search.find('world').single;

      expect(hit.matchedText, 'World');
      expect(hit.elements.single.text, 'World');
    });

    test('finds a phrase and covers every word in it', () {
      final hit = search.find('hello world').single;

      expect(hit.matchedText, 'Hello World');
      expect(hit.elements.map((element) => element.text).toList(), <String>[
        'Hello',
        'World',
      ]);
    });

    test('finds Devanagari words', () {
      final hit = search.find('नमस्ते').single;

      expect(hit.elements.single.text, 'नमस्ते');
      expect(hit.start, 'Hello World '.length);
    });

    test('counts every occurrence, in document order', () {
      final hits = search.find('o');

      // One in "Hello", one in "World".
      expect(hits, hasLength(2));
      expect(hits.first.start, lessThan(hits.last.start));
    });

    test('does not report overlapping occurrences of the same run', () {
      // "ll" in "Hello" can only match once, and there is no second "ll".
      expect(search.find('ll'), hasLength(1));
    });

    test('returns nothing for a query that is not present', () {
      expect(search.find('zzzz'), isEmpty);
    });

    test('returns nothing for an empty or whitespace-only query', () {
      expect(search.find(''), isEmpty);
      expect(search.find('    '), isEmpty);
    });

    test('a query longer than the document matches nothing', () {
      expect(search.find('hello world नमस्ते दुनिया and more'), isEmpty);
    });

    test('offsets point into the returned offset space', () {
      final hit = search.find('दुनिया').single;

      expect(search.documentText.substring(hit.start, hit.end), 'दुनिया');
    });
  });

  group('grapheme boundaries', () {
    test('extends a match across a Devanagari vowel sign', () {
      // Searching the base consonant must not report a match that stops before
      // the matra, which would highlight half a syllable.
      final search = OcrDocumentSearch(_document(<String>['कि']));
      final hit = search.find('क').single;

      expect(hit.matchedText, 'कि');
    });

    test('keeps an astral character intact', () {
      final search = OcrDocumentSearch(_document(<String>['😀 ok']));
      final hit = search.find('😀').single;

      expect(hit.matchedText, '😀');
      expect(search.find('ok'), hasLength(1));
    });

    test('never begins a match on a lone low surrogate', () {
      final search = OcrDocumentSearch(_document(<String>['😀']));

      // The low half of a surrogate pair cannot start a match.
      expect(search.find('\uDE00'), isEmpty);
    });
  });
}
