import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdf_utility_flutter/ocr/domain/ocr_rect.dart';
import 'package:pdf_utility_flutter/translation/domain/translated_region.dart';
import 'package:pdf_utility_flutter/translation/domain/translation_language.dart';
import 'package:pdf_utility_flutter/translation/domain/translation_request.dart';
import 'package:pdf_utility_flutter/translation/presentation/translated_overlay_deck.dart';
import 'package:pdf_utility_flutter/translation/presentation/widgets/translation_overlay.dart';

/// A translation that is much longer than the row it replaces — the ordinary
/// case when a dense Hindi column becomes English.
const String _longText =
    'The committee told the Supreme Court that the hills, the forest and the '
    'water bodies around them are one landscape, so protecting only the hills '
    'would leave the rest outside the law.';

TranslatedDeckLayout _place({required double nextTop}) =>
    TranslatedOverlayDeck.layout(
      items: <TranslatedDeckItem>[
        TranslatedDeckItem(
          id: 0,
          text: _longText,
          sourceRect: const Rect.fromLTRB(20, 100, 190, 120),
          isParagraph: true,
        ),
        TranslatedDeckItem(
          id: 1,
          text: 'Published from Jaipur',
          sourceRect: Rect.fromLTRB(20, nextTop, 380, nextTop + 20),
          isParagraph: true,
        ),
      ],
      imageRect: const Rect.fromLTRB(0, 0, 400, 800),
      style: const TextStyle(fontSize: 14),
      // The page overlay allows paragraphs their own line room; without it the
      // fitter's five-line cap would end the text before its height mattered.
      lineCap: TranslationOverlay.paragraphLineCap,
    );

void main() {
  group('adaptive fit', () {
    test('uses free space below the region instead of clipping the text', () {
      final tight = _place(nextTop: 130);
      final roomy = _place(nextTop: 600);

      final tightFirst = tight.blocks.firstWhere((block) => block.id == 0);
      final roomyFirst = roomy.blocks.firstWhere((block) => block.id == 0);

      expect(
        roomy.hiddenRegionIds,
        isEmpty,
        reason: 'both regions must be drawn',
      );
      expect(
        roomyFirst.lines.single.layout.ellipsized,
        isFalse,
        reason:
            'the paragraph owns the space down to the next region, so it must '
            'grow into it rather than ellipsize',
      );
      expect(
        roomyFirst.box.height,
        greaterThan(120 - 100 + 0.5),
        reason: 'the same text earns a taller box when there is room for it',
      );
      // With no room to grow into, the honest fallback is still an ellipsis and
      // the overflow notice — never text painted over the region below.
      expect(tightFirst.lines.single.layout.ellipsized, isTrue);
      // The taller box is still a translation of *this* region: it starts where
      // the source text starts and stays in its column.
      expect(roomyFirst.box.top, closeTo(100, 6));
      expect(roomyFirst.box.left, greaterThanOrEqualTo(0));
      expect(roomyFirst.box.right, lessThanOrEqualTo(400));
    });

    test('never expands over the region below it', () {
      final tight = _place(nextTop: 130);
      final first = tight.blocks.firstWhere((block) => block.id == 0);
      final second = tight.blocks.where((block) => block.id == 1);

      expect(
        first.box.bottom,
        lessThanOrEqualTo(130 + 0.01),
        reason: 'expanding into another region would cover its source text',
      );
      for (final other in second) {
        expect(
          first.box.overlaps(other.box),
          isFalse,
          reason: 'two translated blocks must never intersect',
        );
        expect(
          first.coverage.overlaps(other.lines.first.sourceRect),
          isFalse,
          reason: 'the veil must not hide a line that belongs to another block',
        );
      }
    });
  });

  group('text that does not fit is reported, never swallowed', () {
    test('a clipped block is named in shortenedRegionIds, not hidden', () {
      // The measured failure this covers: on a real Hindi page displayed at
      // 360 x 332 logical pixels, a 540-character English column was fitted at
      // the 7 px floor into a 104 x 138 box and ellipsized. The old layout said
      // nothing, so the page looked complete while five blocks were cut short.
      final tight = _place(nextTop: 130);
      final roomy = _place(nextTop: 600);

      expect(
        tight.shortenedRegionIds,
        <int>[0],
        reason: 'the ellipsized paragraph must be reported',
      );
      expect(
        tight.hiddenRegionIds,
        isNot(contains(0)),
        reason: 'it is drawn — calling it hidden would close the wrong list',
      );
      expect(tight.hasOverflow, isTrue);

      expect(roomy.shortenedRegionIds, isEmpty);
      expect(roomy.hasOverflow, isFalse);
    });

    test('a page with nothing clipped reports no overflow', () {
      final layout = TranslatedOverlayDeck.layout(
        items: <TranslatedDeckItem>[
          TranslatedDeckItem(
            id: 0,
            text: 'Short heading',
            sourceRect: const Rect.fromLTRB(20, 100, 200, 120),
            isParagraph: true,
          ),
        ],
        imageRect: const Rect.fromLTRB(0, 0, 400, 800),
        style: const TextStyle(fontSize: 14),
        lineCap: TranslationOverlay.paragraphLineCap,
      );

      expect(layout.shortenedRegionIds, isEmpty);
      expect(layout.hasOverflow, isFalse);
    });

    testWidgets('the notice appears for a shortened block, with its own word', (
      tester,
    ) async {
      // One paragraph that cannot fit even after expanding into every pixel of
      // free space it owns, and no hidden region at all: the previous build drew
      // it clipped and said nothing, which is indistinguishable from a complete
      // translation. The text is the length of a real newspaper column (English
      // runs 1.4-2.2x the Hindi it replaces) inside a thumbnail-sized photo.
      final overlay = TranslatedOverlay(
        regions: <TranslatedRegion>[
          TranslatedRegion(
            id: 0,
            sourceText: 'स्रोत',
            translatedText: List<String>.filled(8, _longText).join(' '),
            bounds: OcrRect.fromLTRB(20, 20, 200, 44),
            kind: TranslatedRegionKind.paragraph,
          ),
        ],
        sourceLanguage: TranslationLanguages.hindi,
        targetLanguage: TranslationLanguages.english,
      );

      var opened = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: DefaultTextStyle(
            style: const TextStyle(fontSize: 14),
            child: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(
                width: 300,
                height: 240,
                child: TranslationOverlay(
                  overlay: overlay,
                  imageWidth: 400,
                  imageHeight: 400,
                  onOverflowTap: () => opened += 1,
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      final notice = find.byType(TranslatedOverflowNotice);
      expect(
        notice,
        findsOneWidget,
        reason: 'a clipped translation must be announced',
      );
      expect(find.textContaining('shortened'), findsOneWidget);
      expect(
        find.textContaining('more translation'),
        findsNothing,
        reason: 'nothing was hidden, so the hidden count must stay out of it',
      );

      await tester.tap(notice);
      await tester.pump();
      expect(opened, 1);

      // The whole paragraph is still available in text form.
      expect(
        overlay.asResult(TranslationScope.wholePage).translatedText,
        contains('protecting only the hills'),
      );
    });
  });
}
