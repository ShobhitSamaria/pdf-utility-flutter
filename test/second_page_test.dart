import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdf_utility_flutter/ocr/domain/ocr_document_layout.dart';
import 'package:pdf_utility_flutter/ocr/domain/ocr_merge_policy.dart';
import 'package:pdf_utility_flutter/ocr/domain/ocr_rect.dart';
import 'package:pdf_utility_flutter/translation/presentation/ocr_translation_regions.dart';
import 'package:pdf_utility_flutter/translation/presentation/translated_overlay_deck.dart';

import 'support/recorded_page_fixture.dart';

/// Regression cover for the **second** real newspaper page the user supplied,
/// using the recognition output Google ML Kit actually produced for it.
///
/// This page is a different layout from the three-column one, and it is the one
/// that used to come out badly:
///
/// * a photograph and a story at the top, with the story's lines indented
///   *around* the picture;
/// * a three-line display headline across the page, only 3 px above the body;
/// * one wide body column on the left and a boxed sidebar on the right;
/// * a cropped sliver of the neighbouring column along the left edge, and a
///   strip of city names along the bottom.
///
/// On the old layout code every column gutter was "blocked" by the story above
/// it, so the page collapsed into a single column, fell back to top-then-left,
/// and turned **50 recognized lines into 46 one-line blocks** — the same
/// fragmentation the first page showed, from a different cause. Ordering is now
/// computed from paragraph chains, so the page yields 12 units and each column is
/// one paragraph.
void main() {
  final page = RecordedPage.load(recordedSecondPageFixture);
  final devanagari = page['devanagari'];
  final latin = page['latin'];

  /// Everything printed in the left body column or the cropped sliver to its
  /// left starts before this x; the sidebar starts after it.
  const columnSplit = 460.0;

  group('the recording itself', () {
    test('is the real photograph, at the size the fixture claims', () {
      final bytes = File(page.imagePath).readAsBytesSync();
      expect(bytes.sublist(1, 4), <int>[0x50, 0x4e, 0x47], reason: 'not a PNG');
      final header = ByteData.sublistView(bytes, 16, 24);
      expect(
        (width: header.getUint32(0), height: header.getUint32(4)),
        (width: page.width, height: page.height),
      );
    });

    test('holds the two passes the app runs, with the engine counts', () {
      expect(devanagari.blocks, hasLength(14));
      expect(devanagari.lines, hasLength(50));
      expect(latin.blocks, hasLength(3));
      expect(latin.lines, hasLength(3));
      // Every Devanagari line is real Devanagari: this page has no Latin text in
      // its body, so the Latin pass read symbol soup and nothing else.
      expect(
        devanagari.lines.where(
          (line) => line.text.runes.any((rune) => rune >= 0x0900),
        ),
        hasLength(50),
      );
    });
  });

  group('reading order', () {
    final layout = OcrDocumentLayout.blocks(devanagari);
    final ordered = OcrDocumentLayout.lines(devanagari);

    test('forms paragraphs instead of one block per line', () {
      // The number that matters: 46 one-line blocks was the old output.
      expect(layout, hasLength(12));
      expect(layout.fold<int>(0, (n, b) => n + b.lines.length), 49);
      expect(ordered, hasLength(49));
    });

    test('drops nothing but the line the engine reported twice', () {
      final before = <String>[
        for (final line in devanagari.lines) line.text.trim(),
      ];
      final after = <String>[for (final line in ordered) line.text.trim()];
      // One line is missing, and it is the duplicate: `राज्यों में कैली` is a
      // second box over the words of `दिल्ली तक चार राज्यों में फैली`, on the
      // same row of the same block. Everything else survives exactly once.
      expect(before.where((text) => !after.contains(text)).toList(), <String>[
        'राज्यों में कैली',
      ]);
      expect(
        after.where((text) => text == 'राज्यों में कैली'),
        isEmpty,
        reason: 'the repeated ink must not be translated twice',
      );
    });

    test('reads the top of the page downwards', () {
      int at(String text) {
        final index = ordered.indexWhere((line) => line.text.trim() == text);
        expect(index, isNonNegative, reason: '"$text" is missing');
        return index;
      }

      final name = at('सोनम वांगचुक');
      final subHeadline = at('मांगें नहीं मा्नीं तो करेंगे बड्ध आंदोलन');
      final story = at('लेह. सामाजिक कार्यकर्ता सोनम वांगचुक ने कहा');
      final headline = at('समयसीमा खत्म, कमेटी ने मांगे और 6 माह');
      final body = at('उदयपुर G पत्रिका. गुजरात से');
      final sidebar = at('भारतीय वानिकी अनुसंधान एवं');
      final footer = at('लाई भीलवाड़ा भोपाल रतलाम रायपर सतना सारर ीक');

      expect(name, lessThan(subHeadline));
      expect(subHeadline, lessThan(story));
      expect(story, lessThan(headline));
      expect(headline, lessThan(body));
      expect(body, lessThan(sidebar));
      expect(sidebar, lessThan(footer));
    });

    test('groups each column into one paragraph', () {
      final body = layout.singleWhere(
        (block) => block.text.startsWith('उदयपुर G पत्रिका.'),
      );
      // 17 body lines came back; one of them is the duplicate, so 16 remain in
      // one paragraph instead of sixteen fragments.
      expect(body.lines, hasLength(16));
      expect(body.text, contains('पढ़ं अरावली @ पेज 16'));

      final sidebarBody = layout.singleWhere(
        (block) => block.text.startsWith('भारतीय वानिकी'),
      );
      expect(sidebarBody.lines, hasLength(13));
      // The line the engine placed on the right half of its row still belongs to
      // the paragraph it was printed in.
      expect(sidebarBody.text, contains('पहाड़ियों का समूह मानने के बजाय'));

      final story = layout.singleWhere(
        (block) => block.text.startsWith('लेह. सामाजिक'),
      );
      expect(story.lines, hasLength(5));

      final headline = layout.singleWhere(
        (block) => block.text.startsWith('समयसीमा खत्म'),
      );
      expect(headline.lines, hasLength(3));

      final sidebarTitle = layout.singleWhere(
        (block) => block.text.startsWith('7 को सुप्रीम कोर्ट'),
      );
      expect(sidebarTitle.lines, hasLength(2));
    });

    test('never mixes the body column with the sidebar', () {
      for (final block in layout) {
        final left = block.lines.where(
          (line) => line.boundingBox.right <= columnSplit,
        );
        final right = block.lines.where(
          (line) => line.boundingBox.left >= columnSplit,
        );
        expect(
          left.isEmpty || right.isEmpty,
          isTrue,
          reason:
              'block ${block.id} mixes the column and the sidebar: '
              '"${block.lines.first.text}"',
        );
      }
    });
  });

  group('mixed-script merge', () {
    final merged = const OcrMergePolicy().merge(
      primary: latin,
      secondary: devanagari,
    );

    test('keeps every Devanagari line and none of the Latin soup', () {
      final text = merged.fullText.replaceAll(RegExp(r'\s+'), '');
      for (final line in OcrDocumentLayout.lines(devanagari)) {
        expect(
          text,
          contains(line.text.replaceAll(RegExp(r'\s+'), '')),
          reason: 'the merge dropped "${line.text}"',
        );
      }
      for (final junk in <String>['48I5', 'GIaT', 'RITeT']) {
        expect(merged.fullText, isNot(contains(junk)));
      }
    });

    test('is in the same order as the single-script read', () {
      final text = merged.fullText;
      final name = text.indexOf('सोनम वांगचुक');
      final headline = text.indexOf('समयसीमा खत्म');
      final body = text.indexOf('उदयपुर G पत्रिका');
      final sidebar = text.indexOf('भारतीय वानिकी');
      expect(name, isNonNegative);
      expect(name, lessThan(headline));
      expect(headline, lessThan(body));
      expect(body, lessThan(sidebar));
    });
  });

  group('what reaches the photo', () {
    // The units this recording really produces, laid out the way the overlay
    // does it on a phone: the 960 px photograph shown 360 px wide.
    final units = OcrTranslationRegions.fromPage(devanagari);
    const shownWidth = 360.0;
    final scale = shownWidth / page.width;
    Rect shown(OcrRect box) => Rect.fromLTRB(
      box.left * scale,
      box.top * scale,
      box.right * scale,
      box.bottom * scale,
    );
    final layout = TranslatedOverlayDeck.layout(
      items: [
        for (final unit in units)
          TranslatedDeckItem(
            id: unit.id,
            text: unit.text,
            sourceRect: shown(unit.bounds),
            isParagraph: true,
          ),
      ],
      imageRect: const Rect.fromLTWH(0, 0, shownWidth, shownWidth * 4 / 3),
      style: const TextStyle(fontSize: 14),
    );
    final drawn = <int>{for (final block in layout.blocks) ...block.regionIds};

    /// Whether [text] has a letter or a digit in it, in any script.
    bool carriesWords(String text) =>
        RegExp(r'[\p{L}\p{N}]', unicode: true).hasMatch(text);

    test('the recording really does yield punctuation-only units', () {
      // Without these the "do not paint a lone danda" rule below would be
      // vacuous, and a real newspaper photograph is exactly where they occur:
      // the engine isolates a danda and a double danda beside its own column.
      final punctuationOnly = [
        for (final unit in units)
          if (!carriesWords(unit.text)) unit.id,
      ];
      expect(punctuationOnly, isNotEmpty);
      expect(
        units.where((unit) => unit.id == punctuationOnly.first).single.text,
        matches(RegExp(r'^[।॥\.\-]+$')),
      );
    });

    test('no block is painted for a region that holds no words', () {
      for (final block in layout.blocks) {
        for (final line in block.lines) {
          expect(
            carriesWords(line.text),
            isTrue,
            reason:
                'block ${block.id} paints "${line.text}", which has nothing '
                'to translate — it can only be a blank pill over clean paper',
          );
        }
      }
    });

    test('skipping them is not reported as a translation that did not fit', () {
      final punctuationOnly = {
        for (final unit in units)
          if (!carriesWords(unit.text)) unit.id,
      };
      expect(
        layout.hiddenRegionIds.where(punctuationOnly.contains),
        isEmpty,
        reason:
            'a lone danda is not a translation the page ran out of room for',
      );
      expect(
        layout.shortenedRegionIds.where(punctuationOnly.contains),
        isEmpty,
      );
    });

    test(
      'every region with words is drawn or reported, never silently lost',
      () {
        final withWords = {
          for (final unit in units)
            if (carriesWords(unit.text)) unit.id,
        };
        expect(withWords, isNotEmpty);
        expect(
          drawn.union(layout.hiddenRegionIds.toSet()),
          containsAll(withWords),
          reason:
              'a recognized paragraph disappeared from both the photo and the '
              'did-not-fit notice',
        );
      },
    );

    test('the body column and the sidebar stay on their own sides', () {
      // Column integrity must survive the punctuation rule: the wide left body
      // column and the boxed sidebar are never merged into one block.
      final body = layout.blocks.where(
        (block) => block.lines.any((line) => line.text.contains('उदयपुर')),
      );
      final sidebar = layout.blocks.where(
        (block) =>
            block.lines.any((line) => line.text.contains('भारतीय वानिकी')),
      );
      expect(body, hasLength(1));
      expect(sidebar, hasLength(1));
      expect(body.single.coverage.right, lessThanOrEqualTo(shownWidth * 0.5));
      expect(sidebar.single.coverage.left, greaterThan(shownWidth * 0.4));
    });
  });
}
