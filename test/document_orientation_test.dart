import 'package:flutter_test/flutter_test.dart';
import 'package:pdf_utility_flutter/ocr/domain/document_orientation.dart';
import 'package:pdf_utility_flutter/ocr/domain/ocr_block.dart';
import 'package:pdf_utility_flutter/ocr/domain/ocr_element.dart';
import 'package:pdf_utility_flutter/ocr/domain/ocr_line.dart';
import 'package:pdf_utility_flutter/ocr/domain/ocr_rect.dart';
import 'package:pdf_utility_flutter/ocr/domain/ocr_result.dart';

/// Builds a word, in image pixels.
OcrElement _word(
  String text,
  double left,
  double top,
  double right,
  double bottom,
) => OcrElement(
  text: text,
  boundingBox: OcrRect.fromLTRB(left, top, right, bottom),
);

/// A line whose box is derived from its words, exactly as the engine reports
/// it — so every fixture states real geometry rather than a hand-picked box.
OcrLine _line(List<OcrElement> words, {double? angle}) {
  final boxes = words.map((word) => word.boundingBox);
  return OcrLine(
    text: words.map((word) => word.text).join(' '),
    boundingBox: OcrRect.fromLTRB(
      boxes.map((box) => box.left).reduce((a, b) => a < b ? a : b),
      boxes.map((box) => box.top).reduce((a, b) => a < b ? a : b),
      boxes.map((box) => box.right).reduce((a, b) => a > b ? a : b),
      boxes.map((box) => box.bottom).reduce((a, b) => a > b ? a : b),
    ),
    elements: words,
    angle: angle,
  );
}

/// A page of [width]×[height] pixels holding [lines].
OcrResult _page(
  List<OcrLine> lines, {
  int width = 900,
  int height = 1600,
}) => OcrResult(
  sourceImage: SourceImageInfo(path: 'page.png', width: width, height: height),
  fullText: lines.map((line) => line.text).join('\n'),
  blocks: [
    OcrBlock(
      text: lines.map((line) => line.text).join('\n'),
      boundingBox: OcrRect.fromLTRB(0, 0, width.toDouble(), height.toDouble()),
      lines: lines,
    ),
  ],
);

/// Ten upright prose lines: wide boxes, words ordered left to right.
List<OcrLine> _uprightLines() => [
  for (var i = 0; i < 10; i++)
    _line([
      _word('word', 40, 100.0 + i * 40, 120, 130.0 + i * 40),
      _word('order', 130, 100.0 + i * 40, 220, 130.0 + i * 40),
      _word('upright', 230, 100.0 + i * 40, 330, 130.0 + i * 40),
    ], angle: 0),
];

/// Ten of the same words with the page lying on its side, reading **downwards**
/// (which is what a page turned 90° clockwise from upright produces).
List<OcrLine> _readingDownwards() => [
  for (var i = 0; i < 10; i++)
    _line(
      [
        _word('word', 100.0 + i * 40, 40, 130.0 + i * 40, 120),
        _word('order', 100.0 + i * 40, 130, 130.0 + i * 40, 220),
        _word('sideways', 100.0 + i * 40, 230, 130.0 + i * 40, 330),
      ],
      // The angle's *sign* is deliberately not relied upon anywhere; 90 is
      // what Android reports here and 270 is what a plugin reporting the other
      // convention would, so the fixtures pin both.
      angle: i.isEven ? 90 : 270,
    ),
];

/// The same lines reading **upwards** (page turned 90° anticlockwise).
List<OcrLine> _readingUpwards() => [
  for (var i = 0; i < 10; i++)
    _line([
      _word('word', 100.0 + i * 40, 250, 130.0 + i * 40, 330),
      _word('order', 100.0 + i * 40, 150, 130.0 + i * 40, 240),
      _word('sideways', 100.0 + i * 40, 40, 130.0 + i * 40, 140),
    ], angle: 270),
];

void main() {
  const detector = DocumentOrientationDetector();

  group('the turn itself', () {
    test('is named by what has to be done to the image', () {
      expect(DocumentOrientation.upright.isUpright, isTrue);
      expect(DocumentOrientation.upright.swapsAxes, isFalse);
      expect(const DocumentOrientation(1).label, contains('90° clockwise'));
      expect(const DocumentOrientation(2).label, 'upside down');
      expect(const DocumentOrientation(3).label, contains('anticlockwise'));
      // A quarter turn either way swaps the axes; half a turn does not.
      expect(const DocumentOrientation(1).swapsAxes, isTrue);
      expect(const DocumentOrientation(3).swapsAxes, isTrue);
      expect(const DocumentOrientation(2).swapsAxes, isFalse);
      // 899×1599 portrait turned 90° is 1599×899 landscape.
      expect(const DocumentOrientation(3).widthOf(899, 1599), 1599);
      expect(const DocumentOrientation(3).heightOf(899, 1599), 899);
      expect(DocumentOrientation.upright.widthOf(899, 1599), 899);
    });

    test('equality is by quarter turn', () {
      expect(const DocumentOrientation(1), const DocumentOrientation(1));
      expect(const DocumentOrientation(1), isNot(const DocumentOrientation(3)));
    });
  });

  group('detection', () {
    test('upright prose is left alone', () {
      expect(
        detector.detect(_page(_uprightLines())),
        DocumentOrientation.upright,
      );
    });

    test('a page reading downwards is turned 90° anticlockwise', () {
      // Reading downwards means the pixels were turned clockwise: the fix is
      // the opposite quarter turn, 3 clockwise.
      expect(
        detector.detect(_page(_readingDownwards())),
        const DocumentOrientation(3),
      );
    });

    test('a page reading upwards is turned 90° clockwise', () {
      // The direction comes from the order of the words, not from the sign of
      // the angle: the fixture's first word is the lowest, so the page reads
      // upwards and has to be turned clockwise to stand up.
      expect(
        detector.detect(_page(_readingUpwards())),
        const DocumentOrientation(1),
      );
    });

    test('the angle sign cannot flip the direction', () {
      // Both conventions are in the wild; the geometry must decide, so the
      // same page reports the same turn whether lines say +90 or -90.
      final negative = [
        for (final line in _readingUpwards())
          OcrLine(
            text: line.text,
            boundingBox: line.boundingBox,
            elements: line.elements,
            angle: -90,
          ),
      ];
      expect(detector.detect(_page(negative)), const DocumentOrientation(1));
    });

    test(
      'an upside-down page is turned 180°, whichever way the angle signs',
      () {
        final upsideDown = [
          for (var i = 0; i < 10; i++)
            _line(
              [
                _word('word', 40, 100.0 + i * 40, 120, 130.0 + i * 40),
                _word('upside', 130, 100.0 + i * 40, 220, 130.0 + i * 40),
                _word('down', 230, 100.0 + i * 40, 330, 130.0 + i * 40),
              ],
              // +180 and -180 are the same page; the detector must not care.
              angle: i.isEven ? 180 : -180,
            ),
        ];
        expect(
          detector.detect(_page(upsideDown)),
          const DocumentOrientation(2),
        );
      },
    );

    test('a nearly-level baseline is still upright', () {
      // Photographed paper is rarely perfectly level; 6° of skew is a reader
      // holding the phone, not a turned page.
      final skewed = [
        for (var i = 0; i < 10; i++)
          _line([
            _word('word', 40, 100.0 + i * 40, 120, 130.0 + i * 40),
            _word('skewed', 130, 100.0 + i * 40, 220, 130.0 + i * 40),
          ], angle: i.isEven ? 6 : -6),
      ];
      expect(detector.detect(_page(skewed)), DocumentOrientation.upright);
    });

    test('a missing angle is not evidence of a turned page', () {
      final ios = [
        for (var i = 0; i < 10; i++)
          _line([
            _word('word', 40, 100.0 + i * 40, 120, 130.0 + i * 40),
            _word('without', 130, 100.0 + i * 40, 220, 130.0 + i * 40),
            _word('angle', 230, 100.0 + i * 40, 330, 130.0 + i * 40),
          ]),
      ];
      expect(detector.detect(_page(ios)), DocumentOrientation.upright);
    });

    test('a page with too little text is never turned', () {
      // One short line is not a page: turning the pixels costs a re-encode and
      // a second read, and cannot be justified by a single word.
      expect(
        detector.detect(
          _page([
            _line([_word('Hi', 100, 40, 130, 120)]),
          ]),
        ),
        DocumentOrientation.upright,
      );
    });

    test('a minority of sideways labels cannot turn the page', () {
      final page = [
        ..._uprightLines(),
        for (var i = 0; i < 2; i++)
          _line([
            _word('a', 700.0 + i * 30, 40, 720.0 + i * 30, 60),
            _word('b', 700.0 + i * 30, 70, 720.0 + i * 30, 90),
          ]),
      ];
      expect(detector.detect(_page(page)), DocumentOrientation.upright);
    });

    test(
      'a single-word vertical line abstains but does not block the page',
      () {
        // Words are the witness of direction, so a one-word line cannot vote —
        // but the rest of the page still can, and its vote decides.
        final page = [
          ..._readingDownwards(),
          _line([_word('क्र.', 850, 40, 880, 120)], angle: 90),
        ];
        expect(detector.detect(_page(page)), const DocumentOrientation(3));
      },
    );

    test('an empty read is upright, not a guess', () {
      expect(detector.detect(_page(const [])), DocumentOrientation.upright);
    });

    test('the threshold is configurable and honoured', () {
      const strict = DocumentOrientationDetector(minimumCharacters: 10000);
      expect(
        strict.detect(_page(_readingDownwards())),
        DocumentOrientation.upright,
      );
    });
  });
}
