import 'package:flutter_test/flutter_test.dart';
import 'package:pdf_utility_flutter/ocr/domain/ocr_block.dart';
import 'package:pdf_utility_flutter/ocr/domain/ocr_element.dart';
import 'package:pdf_utility_flutter/ocr/domain/ocr_line.dart';
import 'package:pdf_utility_flutter/ocr/domain/ocr_merge_policy.dart';
import 'package:pdf_utility_flutter/ocr/domain/ocr_rect.dart';
import 'package:pdf_utility_flutter/ocr/domain/ocr_result.dart';

/// Builds a result whose blocks are one line each, which is what the policy
/// emits and therefore the easiest shape to reason about.
OcrResult _result(
  List<(String, OcrRect)> lines, {
  String engine = 'stub',
  Duration? elapsed,
}) {
  final blocks = <OcrBlock>[
    for (final (text, box) in lines)
      OcrBlock(
        text: text,
        boundingBox: box,
        lines: <OcrLine>[
          OcrLine(
            text: text,
            boundingBox: box,
            elements: <OcrElement>[OcrElement(text: text, boundingBox: box)],
          ),
        ],
      ),
  ];

  return OcrResult(
    sourceImage: const SourceImageInfo(
      path: '/tmp/does-not-exist.jpg',
      width: 1000,
      height: 1000,
    ),
    fullText: lines.map((line) => line.$1).join('\n'),
    blocks: blocks,
    engineName: engine,
    elapsed: elapsed,
  );
}

OcrRect _box(double top, {double left = 0, double height = 40}) =>
    OcrRect.fromLTRB(left, top, 400, top + height);

void main() {
  const policy = OcrMergePolicy();

  List<String> texts(OcrResult result) =>
      result.blocks.map((block) => block.text).toList();

  test('keeps non-colliding lines from both passes, in reading order', () {
    // The shape of a real mixed page: the English and Hindi blocks sit in
    // different places, so both readings survive untouched.
    final latin = _result(<(String, OcrRect)>[('English heading', _box(0))]);
    final devanagari = _result(<(String, OcrRect)>[
      ('नमस्ते दुनिया', _box(200)),
    ]);

    final merged = policy.merge(primary: latin, secondary: devanagari);

    expect(texts(merged), <String>['English heading', 'नमस्ते दुनिया']);
  });

  test(
    'orders merged lines top to bottom regardless of which pass found them',
    () {
      final latin = _result(<(String, OcrRect)>[('second', _box(300))]);
      final devanagari = _result(<(String, OcrRect)>[('first', _box(100))]);

      final merged = policy.merge(primary: latin, secondary: devanagari);

      expect(texts(merged), <String>['first', 'second']);
    },
  );

  test('prefers the Devanagari reading where both passes claim a region', () {
    // The Latin model cannot emit Devanagari, so a region where only one pass
    // produced Devanagari code points was read by that pass.
    final latin = _result(<(String, OcrRect)>[('sTqT', _box(100))]);
    final devanagari = _result(<(String, OcrRect)>[('नमस्ते', _box(100))]);

    final merged = policy.merge(primary: latin, secondary: devanagari);

    expect(texts(merged), <String>['नमस्ते']);
  });

  test('prefers the Latin reading for a purely Latin region', () {
    final latin = _result(<(String, OcrRect)>[('English line', _box(200))]);
    final devanagari = _result(<(String, OcrRect)>[
      ('Engl1sh l1ne', _box(200)),
    ]);

    final merged = policy.merge(primary: latin, secondary: devanagari);

    expect(texts(merged), <String>['English line']);
  });

  test('treats a barely overlapping box as a different region', () {
    // 5% overlap is far below the threshold, so nothing collides and both
    // readings are kept.
    final latin = _result(<(String, OcrRect)>[
      ('left', OcrRect.fromLTRB(0, 0, 100, 100)),
    ]);
    final devanagari = _result(<(String, OcrRect)>[
      ('right', OcrRect.fromLTRB(95, 95, 195, 195)),
    ]);

    final merged = policy.merge(primary: latin, secondary: devanagari);

    expect(texts(merged), hasLength(2));
  });

  test('a very high threshold keeps overlapping readings apart', () {
    // Intersection over union here is about 0.95, so a threshold of 1 leaves
    // both readings alone: the threshold is a real knob, not decoration.
    //
    // The Latin candidate is a real phrase rather than symbol soup, because
    // this test is about the *threshold*: a fragmented reading is refused
    // elsewhere (see the junk tests), which would hide the knob's effect.
    const strict = OcrMergePolicy(overlapIouThreshold: 1);
    final latin = _result(<(String, OcrRect)>[
      ('English line', OcrRect.fromLTRB(0, 100, 400, 140)),
    ]);
    final devanagari = _result(<(String, OcrRect)>[
      ('नमस्ते', OcrRect.fromLTRB(10, 100, 410, 140)),
    ]);

    final merged = strict.merge(primary: latin, secondary: devanagari);

    expect(texts(merged), hasLength(2));
  });

  test('returns the primary result untouched when the second pass is empty', () {
    // The common case: an English page read in mixed mode. Block structure must
    // survive, because rebuilding it would be a pointless change.
    final latin = _result(<(String, OcrRect)>[('Only English', _box(0))]);
    final devanagari = _result(const <(String, OcrRect)>[]);

    final merged = policy.merge(primary: latin, secondary: devanagari);

    expect(merged.blocks, same(latin.blocks));
    expect(merged.fullText, latin.fullText);
    expect(merged.engineName, isNot(latin.engineName));
  });

  test('ignores candidates with no text', () {
    final latin = _result(<(String, OcrRect)>[('real', _box(0))]);
    final devanagari = _result(<(String, OcrRect)>[('   ', _box(0))]);

    final merged = policy.merge(primary: latin, secondary: devanagari);

    expect(texts(merged), <String>['real']);
  });

  test('survives two empty passes without producing anything', () {
    final merged = policy.merge(
      primary: _result(const <(String, OcrRect)>[]),
      secondary: _result(const <(String, OcrRect)>[]),
    );

    expect(merged.blocks, isEmpty);
    expect(merged.fullText, isEmpty);
  });

  test('reports the time of both passes, not of one', () {
    final merged = policy.merge(
      primary: _result(<(String, OcrRect)>[('a', _box(0))]),
      secondary: _result(const <(String, OcrRect)>[]),
      elapsed: const Duration(milliseconds: 4321),
    );

    expect(merged.elapsed, const Duration(milliseconds: 4321));
  });

  test('appends a real English heading the Devanagari pass never read', () {
    // The common mixed document: an English heading above Hindi body text. The
    // Devanagari model cannot emit those letters, so the Latin reading is the
    // only witness and must survive.
    final latin = _result(<(String, OcrRect)>[
      ('Quarterly Report', OcrRect.fromLTRB(0, 0, 400, 30)),
    ]);
    final devanagari = _result(<(String, OcrRect)>[
      ('नमस्ते दुनिया', _box(300)),
    ]);

    final merged = policy.merge(primary: latin, secondary: devanagari);

    expect(texts(merged), <String>['Quarterly Report', 'नमस्ते दुनिया']);
  });

  test('appends a short abbreviation heading, which is printed in capitals', () {
    // `PDF`, `NOC`, `RTI`: two to six capitals are how abbreviations and short
    // headings appear in real forms. They are shorter than any word-length
    // floor, so they are accepted on their shape alone.
    for (final heading in <String>['PDF', 'NOC', 'RTI 2022']) {
      final latin = _result(<(String, OcrRect)>[
        (heading, OcrRect.fromLTRB(0, 0, 400, 30)),
      ]);
      final devanagari = _result(<(String, OcrRect)>[
        ('नमस्ते दुनिया', _box(300)),
      ]);

      final merged = policy.merge(primary: latin, secondary: devanagari);

      expect(texts(merged), contains(heading));
    }
  });

  test('appends an ordinary short label, such as a form field name', () {
    // Four letters is the floor for a lower-case word: `Name`, `Total`, `Date`
    // are real labels on a Hindi form, and a fragment that short but scrambled
    // is rejected below.
    final latin = _result(<(String, OcrRect)>[
      ('Name', OcrRect.fromLTRB(0, 0, 200, 30)),
    ]);
    final devanagari = _result(<(String, OcrRect)>[
      ('नमस्ते दुनिया', _box(300)),
    ]);

    final merged = policy.merge(primary: latin, secondary: devanagari);

    expect(texts(merged), contains('Name'));
  });

  test('never appends the fragments this engine emits over Devanagari', () {
    // Verbatim output of the Latin recognizer pointed at a Hindi newspaper page
    // (recorded in `test/fixtures/ocr/newspaper_hindi_three_columns.json`).
    // None of these is text on the page, so none may be invented into the
    // result when its box happens not to collide with a Devanagari line.
    const junk = <String>[
      'far',
      'Hhcill',
      'fufat H BH, 2022 fr44 3',
      'vy 28-08-2025',
      'sTqT',
    ];

    for (final fragment in junk) {
      final latin = _result(<(String, OcrRect)>[
        (fragment, OcrRect.fromLTRB(0, 0, 400, 30)),
      ]);
      final devanagari = _result(<(String, OcrRect)>[
        ('नमस्ते दुनिया', _box(300)),
      ]);

      final merged = policy.merge(primary: latin, secondary: devanagari);

      expect(
        texts(merged),
        isNot(contains(fragment)),
        reason: '"$fragment" was invented into the result',
      );
      expect(
        merged.fullText,
        isNot(contains(fragment)),
        reason: '"$fragment" reached the text',
      );
    }
  });

  test('keeps a Hindi line even when the Latin pass read it as symbols', () {
    // The collision rule, on real geometry: the Devanagari reading of a region
    // wins over the Latin reading of the same region.
    final latin = _result(<(String, OcrRect)>[
      ('fufat H BH, 2022 fr44 3', OcrRect.fromLTRB(0, 0, 400, 30)),
    ]);
    final devanagari = _result(<(String, OcrRect)>[
      ('नियम 2022 का लाभ मिलेगा', OcrRect.fromLTRB(2, 0, 398, 30)),
    ]);

    final merged = policy.merge(primary: latin, secondary: devanagari);

    expect(texts(merged), <String>['नियम 2022 का लाभ मिलेगा']);
  });

  test('keeps one block per line when that is what the base read', () {
    final latin = _result(<(String, OcrRect)>[('English', _box(0))]);
    final devanagari = _result(<(String, OcrRect)>[('हिन्दी', _box(200))]);

    final merged = policy.merge(primary: latin, secondary: devanagari);

    expect(merged.blocks, hasLength(2));
    for (final block in merged.blocks) {
      expect(block.lines, hasLength(1));
      expect(block.lines.single.elements, hasLength(1));
      // Word geometry is carried over verbatim.
      expect(block.lines.single.elements.single.boundingBox, block.boundingBox);
    }
  });

  test('keeps a paragraph the base pass read as one multi-line block', () {
    // Rebuilding the result as one block per line — the earlier behaviour —
    // turned the recorded three-column newspaper page into 79 fragments and
    // made its translation jump between columns. A multi-line block must stay
    // a block.
    OcrRect box(double top) => OcrRect.fromLTRB(0, top, 400, top + 30);
    final lines = <OcrLine>[
      for (var index = 0; index < 3; index++)
        OcrLine(
          text: 'हिन्दी पंक्ति $index',
          boundingBox: box(index * 32),
          elements: <OcrElement>[
            OcrElement(
              text: 'हिन्दी पंक्ति $index',
              boundingBox: box(index * 32),
            ),
          ],
        ),
    ];
    final devanagari = OcrResult(
      sourceImage: const SourceImageInfo(
        path: '/tmp/does-not-exist.jpg',
        width: 1000,
        height: 1000,
      ),
      fullText: lines.map((line) => line.text).join('\n'),
      blocks: <OcrBlock>[
        OcrBlock(
          text: lines.map((line) => line.text).join('\n'),
          boundingBox: OcrRect.fromLTRB(0, 0, 400, 94),
          lines: lines,
        ),
      ],
    );

    final merged = policy.merge(
      primary: _result(const <(String, OcrRect)>[]),
      secondary: devanagari,
    );

    expect(merged.blocks, hasLength(1));
    expect(merged.blocks.single.lines, hasLength(3));
  });
}
