import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdf_utility_flutter/ocr/domain/ocr_rect.dart';
import 'package:pdf_utility_flutter/translation/domain/translated_region.dart';
import 'package:pdf_utility_flutter/translation/domain/translation_language.dart';
import 'package:pdf_utility_flutter/translation/domain/translation_request.dart';
import 'package:pdf_utility_flutter/translation/presentation/widgets/translation_overlay.dart';

/// A paragraph's worth of English — several printed lines once wrapped into a
/// newspaper column, so the fitter has to do real work.
const String _longParagraph =
    'The High Court ruled that contract workers appointed through placement '
    'agencies must receive the benefits of Rule 2022, and that denying them '
    'those benefits is unconstitutional. The order was given while hearing '
    'hundreds of petitions from across the state. Advocates representing the '
    'petitioners argued that the recruitment process and the nature of the work '
    'are the same, so excluding these employees is discriminatory.';

TranslatedRegion _paragraph({
  required int id,
  required OcrRect bounds,
  String text = _longParagraph,
  String source = 'स्रोत',
}) => TranslatedRegion(
  id: id,
  sourceText: source,
  translatedText: text,
  bounds: bounds,
  kind: TranslatedRegionKind.paragraph,
);

TranslatedOverlay _overlay(List<TranslatedRegion> regions) => TranslatedOverlay(
  regions: regions,
  sourceLanguage: TranslationLanguages.hindi,
  targetLanguage: TranslationLanguages.english,
);

Widget _harness(TranslatedOverlay overlay, {required Size size}) => MaterialApp(
  home: DefaultTextStyle(
    style: const TextStyle(fontSize: 14),
    child: Align(
      alignment: Alignment.topLeft,
      child: SizedBox(
        width: size.width,
        height: size.height,
        child: TranslationOverlay(
          overlay: overlay,
          imageWidth: 1000,
          imageHeight: 1000,
        ),
      ),
    ),
  ),
);

void main() {
  group('full text', () {
    test('keeps paragraph boundaries and every segment, once, in order', () {
      final overlay = _overlay([
        _paragraph(
          id: 0,
          bounds: OcrRect.fromLTRB(50, 50, 400, 200),
          text: 'One',
        ),
        _paragraph(
          id: 1,
          bounds: OcrRect.fromLTRB(50, 220, 400, 400),
          text: 'Two',
        ),
        TranslatedRegion(
          id: 2,
          sourceText: 'तीन',
          translatedText: 'Three',
          bounds: OcrRect.fromLTRB(50, 420, 400, 440),
          kind: TranslatedRegionKind.line,
        ),
      ]);

      final result = overlay.asResult(TranslationScope.wholePage);

      expect(result.translatedText, 'One\n\nTwo\nThree');
      expect(result.originalText, 'स्रोत\n\nस्रोत\nतीन');
    });

    test(
      'an untranslated region is skipped instead of leaving a blank block',
      () {
        final overlay = _overlay([
          _paragraph(
            id: 0,
            bounds: OcrRect.fromLTRB(50, 50, 400, 200),
            text: 'One',
          ),
          _paragraph(
            id: 1,
            bounds: OcrRect.fromLTRB(50, 220, 400, 400),
            text: '  ',
          ),
          _paragraph(
            id: 2,
            bounds: OcrRect.fromLTRB(50, 420, 400, 600),
            text: 'Two',
          ),
        ]);

        expect(
          overlay.asResult(TranslationScope.wholePage).translatedText,
          'One\n\nTwo',
        );
      },
    );
  });

  group('overlay', () {
    testWidgets('a paragraph is drawn as a block, not clipped to five lines', (
      tester,
    ) async {
      const size = Size(500, 1000);
      // Two newspaper columns.
      final overlay = _overlay([
        _paragraph(id: 0, bounds: OcrRect.fromLTRB(100, 100, 480, 800)),
        _paragraph(
          id: 1,
          bounds: OcrRect.fromLTRB(520, 100, 900, 800),
          text:
              'A second column of translated text that also needs several '
              'lines to be readable inside its own region.',
        ),
      ]);

      await tester.pumpWidget(_harness(overlay, size: size));
      await tester.pump();

      final left = tester.getRect(
        find.byKey(const ValueKey<String>('translated-region-0')),
      );
      final right = tester.getRect(
        find.byKey(const ValueKey<String>('translated-region-1')),
      );

      // Both stay inside the photo, and neither runs into the other column.
      expect(left.left, greaterThanOrEqualTo(0));
      expect(left.right, lessThanOrEqualTo(size.width));
      expect(left.bottom, lessThanOrEqualTo(size.height));
      expect(left.overlaps(right), isFalse);

      // The paragraph gets the line room its length needs; the old five-line cap
      // would have ellipsized it even with the space available.
      final text = tester.widget<Text>(
        find.descendant(
          of: find.byKey(const ValueKey<String>('translated-region-0')),
          matching: find.byType(Text),
        ),
      );
      expect(text.maxLines, greaterThan(5));
      expect(text.overflow, TextOverflow.ellipsis);
      expect(text.data, contains('High Court'));
      expect(tester.takeException(), isNull);
    });

    testWidgets('a sliver of a region is never painted outside the photo', (
      tester,
    ) async {
      final overlay = _overlay([
        // A sliver far too small for a line, at the very edge of the source.
        _paragraph(id: 0, bounds: OcrRect.fromLTRB(0, 0, 30, 14)),
      ]);

      await tester.pumpWidget(_harness(overlay, size: const Size(500, 1000)));
      await tester.pump();

      final slots = find.byKey(const ValueKey<String>('translated-region-0'));
      if (slots.evaluate().isNotEmpty) {
        final rect = tester.getRect(slots);
        expect(rect.left, greaterThanOrEqualTo(0));
        expect(rect.top, greaterThanOrEqualTo(0));
        expect(rect.right, lessThanOrEqualTo(500));
        expect(rect.bottom, lessThanOrEqualTo(1000));
      }
      expect(tester.takeException(), isNull);
      // Whatever the placement decision, the text itself is never lost.
      expect(
        overlay.asResult(TranslationScope.wholePage).translatedText,
        _longParagraph,
      );
    });

    testWidgets('a dense page keeps every paragraph in the full text', (
      tester,
    ) async {
      const count = 40;
      final overlay = _overlay([
        for (var index = 0; index < count; index++)
          _paragraph(
            id: index,
            // Printed-line sized regions with far too much text for each.
            bounds: OcrRect.fromLTRB(
              60,
              20.0 + index * 24,
              940,
              42.0 + index * 24,
            ),
            text:
                'Paragraph $index of a dense page, whose translation is much '
                'longer than the printed line it replaces and therefore has to '
                'shrink, ellipsize or be reported rather than cover its '
                'neighbour.',
          ),
      ]);

      await tester.pumpWidget(_harness(overlay, size: const Size(500, 1000)));
      await tester.pump();

      expect(tester.takeException(), isNull);
      // Every drawn slot is inside the photo.
      for (var index = 0; index < count; index++) {
        final finder = find.byKey(ValueKey<String>('translated-region-$index'));
        if (finder.evaluate().isEmpty) continue;
        final rect = tester.getRect(finder);
        expect(rect.left, greaterThanOrEqualTo(0));
        expect(rect.right, lessThanOrEqualTo(500));
        expect(rect.bottom, lessThanOrEqualTo(1000));
      }

      // All forty translations are present, once each, in reading order.
      final full = overlay.asResult(TranslationScope.wholePage).translatedText;
      final paragraphs = full.split('\n\n');
      expect(paragraphs, hasLength(count));
      for (var index = 0; index < count; index++) {
        expect(full, contains('Paragraph $index '));
      }
    });
  });
}
