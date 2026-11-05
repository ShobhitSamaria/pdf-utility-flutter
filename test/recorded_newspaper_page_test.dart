import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pdf_utility_flutter/ocr/domain/ocr_document_layout.dart';
import 'package:pdf_utility_flutter/ocr/domain/ocr_line.dart';
import 'package:pdf_utility_flutter/ocr/domain/ocr_merge_policy.dart';
import 'package:pdf_utility_flutter/ocr/domain/ocr_rect.dart';

import 'support/recorded_page_fixture.dart';

/// Regression cover for the real newspaper page the user supplied, using the
/// recognition output Google ML Kit actually produced for it.
///
/// The fixture is not synthetic geometry: it is the verbatim block/line output
/// of the two single-script passes over
/// `test/assets/real/newspaper_hindi_three_columns.png`, recorded once on a
/// device that has ML Kit (see the fixture's `provenance` field). Replaying it
/// here is what lets the reading-order and merge rules be checked in a plain
/// `flutter test` run, with no phone and no emulator attached.
///
/// What the recording measured on the old code, and why these tests exist:
///
/// * the **Devanagari pass alone** produced 15 blocks whose order jumped
///   between columns (column 2, then column 3, then column 1, …), so a reader
///   — and the translator — saw the middle column arrive after the right-hand
///   one;
/// * **Auto mode** (which merges the Latin and Devanagari passes) produced
///   **79 one-line blocks in row order** — left line, middle line, right line,
///   next row. Every paragraph was destroyed and the page read like a stack of
///   unrelated fragments. That is the "middle column is missing" report.
///
/// A page's *block boxes* are not its content: in this recording the masthead,
/// the deck and the headline are single blocks 754, 1001 and 1003 px wide —
/// wider than two of the three body columns together. Those boxes bridge every
/// gutter on the page, so a column cut computed over block boxes sees one
/// column and falls back to top-then-left, which is the interleaving the user
/// reported. These tests therefore pin the ordering to line geometry, and the
/// "block boxes" test below keeps the evidence for that reasoning.
void main() {
  final page = RecordedPage.load(recordedNewspaperFixture);
  final devanagari = page['devanagari'];
  final latin = page['latin'];

  /// Body text starts below the headline on this page. Above it are the
  /// masthead, the deck and the headline itself — the only lines allowed to
  /// span more than one column.
  const bodyTop = 575.0;

  /// Column of [box] on this page, from its left edge: the body columns start
  /// at x ≈ 46, 396 and 737 with ~20 px gutters between them.
  int columnOf(OcrRect box) {
    if (box.left < 390) return 0;
    if (box.left < 730) return 1;
    return 2;
  }

  String describe(OcrLine line) =>
      '${line.text} @ '
      '${line.boundingBox.left.round()},${line.boundingBox.top.round()}';

  /// Index of the first line in [ordered] whose text is [text].
  int indexOf(List<OcrLine> ordered, String text) {
    final index = ordered.indexWhere((line) => line.text.trim() == text.trim());
    expect(index, isNonNegative, reason: '"$text" is missing from the output');
    return index;
  }

  group('the recording itself', () {
    test('is the real photograph, at the size the fixture claims', () {
      final bytes = File(page.imagePath).readAsBytesSync();
      expect(bytes.sublist(1, 4), <int>[0x50, 0x4e, 0x47], reason: 'not a PNG');
      final header = ByteData.sublistView(bytes, 16, 24);
      expect(
        (width: header.getUint32(0), height: header.getUint32(4)),
        (width: page.width, height: page.height),
        reason:
            'the recording must describe the image in the repository, or the '
            'geometry below means nothing',
      );
    });

    test('holds the two passes the app actually runs', () {
      // Counts are the engine's, not a target: they are asserted so a fixture
      // that was truncated on the way in cannot silently weaken the tests.
      expect(devanagari.blocks, hasLength(15));
      expect(devanagari.lines, hasLength(79));
      expect(latin.blocks, hasLength(4));
      expect(latin.lines, hasLength(4));
      // The Devanagari pass is the one that reads the page; the Latin pass
      // returned four fragments, three of them symbol soup.
      expect(
        devanagari.lines.where(
          (line) => line.text.runes.any((rune) => rune >= 0x0900),
        ),
        hasLength(79),
      );
    });

    test('carries spanning block boxes that hide every gutter', () {
      // The masthead, deck and headline blocks are each wider than the page's
      // three body columns are together, so a layout computed over block boxes
      // would see a single column. This is the shape the fix has to survive;
      // if this assertion ever fails the fixture no longer represents it.
      final pageWidth = page.width.toDouble();
      final spanning = <int>[];
      for (var index = 0; index < devanagari.blocks.length; index++) {
        final box = devanagari.blocks[index].boundingBox;
        if (box.width > pageWidth * 0.9) spanning.add(index);
      }
      expect(
        spanning,
        isNotEmpty,
        reason: 'the recording must contain a full-width block',
      );
      expect(
        spanning,
        contains(3),
        reason: 'the headline block is the one that bridges the gutters',
      );

      // The body blocks, by contrast, are one column wide — so a block-level
      // layout cannot tell the headline from the columns under it.
      final bodyBlocks = [
        for (final block in devanagari.blocks)
          if (block.boundingBox.top >= bodyTop) block,
      ];
      expect(bodyBlocks, isNotEmpty);
      for (final block in bodyBlocks) {
        expect(block.boundingBox.width, lessThan(pageWidth * 0.4));
      }
    });
  });

  group('reading order', () {
    final layout = OcrDocumentLayout.blocks(devanagari);
    final ordered = OcrDocumentLayout.lines(devanagari);

    test('keeps every recognized line, exactly once', () {
      expect(ordered, hasLength(devanagari.lines.length));
      final before = <String, int>{};
      for (final line in devanagari.lines) {
        before.update(describe(line), (count) => count + 1, ifAbsent: () => 1);
      }
      final after = <String, int>{};
      for (final line in ordered) {
        after.update(describe(line), (count) => count + 1, ifAbsent: () => 1);
      }
      expect(after, before, reason: 'layout must not drop or duplicate text');
    });

    test('reads the three body columns one after another', () {
      final orderedBody = [
        for (final block in layout)
          for (final line in block.lines)
            if (line.boundingBox.top >= bodyTop) line,
      ];
      // All 73 body lines are in the body, and they are grouped by column:
      // column 1's 23 lines, then column 2's 25, then column 3's 25.
      expect(orderedBody, hasLength(73));
      final counts = <int, int>{};
      for (final line in orderedBody) {
        counts.update(
          columnOf(line.boundingBox),
          (n) => n + 1,
          ifAbsent: () => 1,
        );
      }
      expect(counts, <int, int>{0: 23, 1: 25, 2: 25});

      // Column-major, never row-major: the column number never goes backwards.
      // This is the assertion that fails loudly if the page is ever read
      // left-middle-right per row again.
      var previous = 0;
      for (final line in orderedBody) {
        final column = columnOf(line.boundingBox);
        expect(
          column,
          greaterThanOrEqualTo(previous),
          reason:
              'reading order went back to column ${column + 1} after column '
              '${previous + 1}: ${describe(line)}',
        );
        previous = column;
      }

      // And inside a column the lines still run top to bottom.
      for (var column = 0; column < 3; column++) {
        final inColumn = [
          for (final line in orderedBody)
            if (columnOf(line.boundingBox) == column) line,
        ];
        for (var index = 1; index < inColumn.length; index++) {
          expect(
            inColumn[index].boundingBox.top,
            greaterThanOrEqualTo(inColumn[index - 1].boundingBox.top),
            reason: 'column ${column + 1} is not top-to-bottom',
          );
        }
      }
    });

    test('reads the headline before the body, and its split line in order', () {
      final masthead = indexOf(ordered, 'दैनिक जयपुर 28-08-2025');
      final deck = indexOf(
        ordered,
        'यदि नियुव्ति विज्ञापन से हुई तो यह नहीं देखा जाए कि एजेंसी ने की या '
        'सरकार नेः कोर्ट',
      );
      final headline = indexOf(
        ordered,
        'एजेंसी से व ठेके पर लगे संविदाकर्मियों को',
      );
      // One printed headline line came back as two boxes; the left half has to
      // be read first or the words of that line are reversed.
      final headlineLeft = indexOf(ordered, 'राहत, नियम');
      final headlineRight = indexOf(ordered, '2022 के तहत लाभ मिलेगा');
      final firstBody = indexOf(ordered, 'राजस्थान हाईकोर्ट ने एक महत्वपूर्ण');

      expect(masthead, lessThan(deck));
      expect(deck, lessThan(headline));
      expect(headline, lessThan(headlineLeft));
      expect(headlineLeft, lessThan(headlineRight));
      expect(headlineRight, lessThan(firstBody));
    });

    test('forms paragraphs instead of one block per line', () {
      // The old merged output was 79 blocks — one per line. A page of 79 lines
      // has no business producing anything near that: the body alone is five
      // paragraphs over 73 lines.
      expect(layout.length, inInclusiveRange(6, 20));
      expect(layout.fold<int>(0, (n, b) => n + b.lines.length), 79);
      for (final block in layout) {
        expect(block.lines, isNotEmpty);
        expect(block.text.trim(), isNotEmpty);
        expect(block.bounds.isEmpty, isFalse);
      }
    });

    test('keeps a Devanagari final line inside its paragraph', () {
      // ML Kit's box for `सकता।` is 16 px tall under a 24 px line above it,
      // because those glyphs have no ascender or matra. Judged on height alone
      // it looked like a change of type size, so the page read
      // "…नहीं लाया जा" and "सकता।" as two paragraphs — a visible fragment at the
      // foot of the middle column. It is the paragraph's last line and the only
      // line on this page whose height falls outside the similarity band, so the
      // width rule that now joins it cannot affect anything else here.
      final owner = layout.where(
        (block) => block.lines.any((line) => line.text.trim() == 'सकता।'),
      );
      expect(owner, hasLength(1), reason: 'the line is in two places at once');
      expect(owner.single.text, contains('नहीं लाया जा सकता।'));
      expect(
        owner.single.lines.length,
        greaterThan(1),
        reason:
            'a one-line paragraph of just the final word is still a fragment',
      );
      expect(
        layout.where((block) => block.text.trim() == 'सकता।'),
        isEmpty,
        reason: 'the final word became its own paragraph again',
      );
      // Two paragraphs fewer than before these fixes (12), with the line count
      // unchanged, because the line was joined rather than dropped. The other
      // one is the split headline, below.
      expect(layout, hasLength(10));
      expect(layout.fold<int>(0, (n, b) => n + b.lines.length), 79);
    });

    test('joins the two halves of a split headline into one sentence', () {
      // ML Kit returned the headline's second line as two boxes:
      // `…संविदाकर्मियों को राहत, नियम` (55–1053) and `2022 के तहत लाभ मिलेगा`
      // (381–1058). Translating them separately produced "Relief, Rule, Rule"
      // and "2022 will get benefit" — two fragments of one sentence, neither of
      // which reads as English. They are display type (87 px against a 24 px
      // body line), so the layout now reads them as one line.
      final headline = layout.where(
        (block) => block.text.contains('संविदाकर्मियों को'),
      );
      expect(headline, hasLength(1));
      expect(
        headline.single.text,
        contains('राहत, नियम 2022 के तहत लाभ मिलेगा'),
        reason: 'the headline is still two fragments of one sentence',
      );
      // And the three body columns are still three paragraphs: the same rule
      // must never join body text across a gutter.
      expect(
        layout.where((block) => block.text.contains('राजस्थान हाईकोर्ट')),
        hasLength(1),
      );
    });

    test('never puts two columns in one paragraph', () {
      for (final block in layout) {
        final columns = <int>{
          for (final line in block.lines)
            if (line.boundingBox.top >= bodyTop) columnOf(line.boundingBox),
        };
        expect(
          columns.length,
          lessThanOrEqualTo(1),
          reason:
              'block ${block.id} mixes columns $columns: '
              '"${block.text.substring(0, block.text.length.clamp(0, 40))}…"',
        );
      }
    });
  });

  group('mixed-script merge', () {
    final merged = const OcrMergePolicy().merge(
      primary: latin,
      secondary: devanagari,
    );

    test('keeps the Devanagari paragraphs instead of one block per line', () {
      final layout = OcrDocumentLayout.blocks(devanagari);
      expect(merged.blocks, hasLength(layout.length));
      expect(merged.lines, hasLength(79));
    });

    test('loses none of the page and adds none of the junk', () {
      final mergedText = merged.fullText;
      for (final line in devanagari.lines) {
        expect(
          mergedText.replaceAll(RegExp(r'\s+'), ''),
          contains(line.text.replaceAll(RegExp(r'\s+'), '')),
          reason: 'the merge dropped "${line.text}"',
        );
      }
      // The four fragments the Latin pass produced over this Devanagari page,
      // verbatim. None of them is on the page.
      for (final junk in <String>[
        'far',
        'Hhcill',
        'fufat H BH, 2022 fr44 3',
        'vy 28-08-2025',
      ]) {
        expect(
          mergedText,
          isNot(contains(junk)),
          reason: 'the merge injected "$junk", which is not in the photograph',
        );
      }
    });

    test('is in reading order across the columns', () {
      final text = merged.fullText.replaceAll(RegExp(r'\s+'), '');
      int at(String phrase) {
        final index = text.indexOf(phrase.replaceAll(RegExp(r'\s+'), ''));
        expect(index, isNonNegative, reason: 'missing "$phrase"');
        return index;
      }

      // Column 1's opening, then column 2's, then column 3's — in that order.
      expect(
        at('राजस्थान हाईकोर्ट ने एक महत्वपूर्ण'),
        lessThan(at('की ओर से विभिन्न विभारगों के अतिरिक्त')),
      );
      expect(
        at('की ओर से विभिन्न विभारगों के अतिरिक्त'),
        lessThan(at('का पक्ष था कि चूंकि उनकी नियुक्ति')),
      );
      // The headline arrives before any body text.
      expect(
        at('एजेंसी से व ठेके पर लगे संविदाकर्मियों को'),
        lessThan(at('राजस्थान हाईकोर्ट ने एक महत्वपूर्ण')),
      );
    });

    test('the Latin pass never wins a region the Devanagari pass read', () {
      // Every Latin line in the recording sits on top of a Devanagari line, so
      // nothing from that pass may survive: 79 lines in, 79 lines out.
      final mergedText = merged.fullText;
      expect(mergedText, isNot(contains('Hhcill')));
      expect(merged.lines.every((line) => line.text.trim().isNotEmpty), isTrue);
      expect(merged.engineName, contains('Devanagari'));
    });
  });
}
