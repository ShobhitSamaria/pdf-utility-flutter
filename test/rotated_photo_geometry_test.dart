import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdf_utility_flutter/ocr/data/image_decoder.dart';
import 'package:pdf_utility_flutter/ocr/domain/ocr_block.dart';
import 'package:pdf_utility_flutter/ocr/domain/ocr_element.dart';
import 'package:pdf_utility_flutter/ocr/domain/ocr_line.dart';
import 'package:pdf_utility_flutter/ocr/domain/ocr_rect.dart';
import 'package:pdf_utility_flutter/ocr/domain/ocr_result.dart';
import 'package:pdf_utility_flutter/ocr/domain/ocr_selection.dart';
import 'package:pdf_utility_flutter/ocr/presentation/ocr_coordinate_mapper.dart';
import 'package:pdf_utility_flutter/ocr/presentation/widgets/ocr_overlay.dart';
import 'package:pdf_utility_flutter/translation/domain/translated_region.dart';
import 'package:pdf_utility_flutter/translation/domain/translation_language.dart';
import 'package:pdf_utility_flutter/translation/presentation/widgets/translation_overlay.dart';

/// The four fixtures all **store** 640×480 pixels and differ only in EXIF
/// orientation (1 / 6 / 3 / 8), which is exactly how a phone writes a photo
/// taken while the newspaper lay sideways on the table.
const _fixtures = 'test/assets/exif';

/// Stored pixel size of every fixture, before EXIF is applied.
const _stored = Size(640, 480);

OcrElement _word(String text, double l, double t, double r, double b) =>
    OcrElement(text: text, boundingBox: OcrRect.fromLTRB(l, t, r, b));

/// One line's worth of words, wrapped in the block/line hierarchy ML Kit
/// produces, so the overlay sees the same shape the engine hands it.
OcrLine _line(String text, List<OcrElement> words) => OcrLine(
  text: text,
  boundingBox: OcrRect.fromLTRB(
    words.map((w) => w.boundingBox.left).reduce((a, b) => a < b ? a : b),
    words.map((w) => w.boundingBox.top).reduce((a, b) => a < b ? a : b),
    words.map((w) => w.boundingBox.right).reduce((a, b) => a > b ? a : b),
    words.map((w) => w.boundingBox.bottom).reduce((a, b) => a > b ? a : b),
  ),
  elements: words,
);

/// A page whose coordinates are in the **upright** bitmap — the space ML Kit
/// reports boxes in after the decoder has applied EXIF orientation.
OcrResult _page({
  required String fixture,
  required int width,
  required int height,
  required List<OcrLine> lines,
}) => OcrResult(
  sourceImage: SourceImageInfo(
    path: '$_fixtures/$fixture',
    width: width,
    height: height,
  ),
  fullText: lines.map((line) => line.text).join('\n'),
  blocks: [
    OcrBlock(
      text: lines.map((line) => line.text).join('\n'),
      boundingBox: OcrRect.fromLTRB(0, 0, width.toDouble(), height.toDouble()),
      lines: lines,
    ),
  ],
);

void _expectInside(Rect inner, Rect outer, {required String reason}) {
  expect(inner.left, greaterThanOrEqualTo(outer.left - 0.01), reason: reason);
  expect(inner.top, greaterThanOrEqualTo(outer.top - 0.01), reason: reason);
  expect(inner.right, lessThanOrEqualTo(outer.right + 0.01), reason: reason);
  expect(inner.bottom, lessThanOrEqualTo(outer.bottom + 0.01), reason: reason);
}

/// A translated region per source line, in reading order.
TranslatedOverlay _translationFor(List<OcrLine> lines) => TranslatedOverlay(
  regions: [
    for (final (index, line) in lines.indexed)
      TranslatedRegion(
        id: index,
        sourceText: line.text,
        translatedText: 'Translated line ${index + 1}',
        bounds: line.boundingBox,
        kind: TranslatedRegionKind.line,
      ),
  ],
  sourceLanguage: TranslationLanguages.hindi,
  targetLanguage: TranslationLanguages.english,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('EXIF orientation is applied before any geometry is computed', () {
    test('every fixture stores the same pixels but decodes upright', () async {
      const decoder = ImageDecoder();

      // Baseline: no orientation tag, so decoded == stored.
      final upright = await decoder.decodeDimensions('$_fixtures/upright.jpg');
      expect(
        Size(upright.width.toDouble(), upright.height.toDouble()),
        _stored,
      );

      // 90° and 270° swap the axes. This is the invariant the whole overlay
      // rests on: ML Kit reports boxes in the decoded (upright) bitmap, so the
      // mapper must be built from these dimensions, never the stored ones.
      for (final fixture in ['rotated_90.jpg', 'rotated_270.jpg']) {
        final dims = await decoder.decodeDimensions('$_fixtures/$fixture');
        expect(
          Size(dims.width.toDouble(), dims.height.toDouble()),
          const Size(480, 640),
          reason:
              '$fixture is stored ${_stored.width}x${_stored.height}; decoding '
              'it must report the rotated, upright size',
        );
      }

      // 180° rotates the pixels without changing the axes: same dimensions,
      // and therefore the same coordinate space.
      final flipped = await decoder.decodeDimensions(
        '$_fixtures/rotated_180.jpg',
      );
      expect(
        Size(flipped.width.toDouble(), flipped.height.toDouble()),
        _stored,
      );
    });
  });

  group('a rotated capture keeps photo, words and overlays aligned', () {
    // A portrait page photographed sideways (90° / 270°) or upside down (180°).
    final portraitLines = <OcrLine>[
      _line('नमस्ते दुनिया', [
        _word('नमस्ते', 40, 40, 170, 80),
        _word('दुनिया', 180, 40, 300, 80),
      ]),
      _line('Office of the District', [
        _word('Office', 40, 120, 120, 150),
        _word('of', 128, 120, 150, 150),
        _word('the', 158, 120, 195, 150),
        _word('District', 203, 120, 290, 150),
      ]),
      _line('परीक्षा केंद्र', [
        _word('परीक्षा', 40, 200, 130, 235),
        _word('केंद्र', 140, 200, 230, 235),
      ]),
    ];

    final landscapeLines = <OcrLine>[
      _line('Admit Card 2026', [
        _word('Admit', 40, 40, 140, 80),
        _word('Card', 150, 40, 210, 80),
        _word('2026', 220, 40, 300, 80),
      ]),
      _line('रोल नंबर', [
        _word('रोल', 40, 130, 100, 165),
        _word('नंबर', 110, 130, 190, 165),
      ]),
    ];

    final cases =
        <
          ({
            String label,
            String fixture,
            int width,
            int height,
            List<OcrLine> lines,
          })
        >[
          (
            label: '90°',
            fixture: 'rotated_90.jpg',
            width: 480,
            height: 640,
            lines: portraitLines,
          ),
          (
            label: '180°',
            fixture: 'rotated_180.jpg',
            width: 640,
            height: 480,
            lines: landscapeLines,
          ),
          (
            label: '270°',
            fixture: 'rotated_270.jpg',
            width: 480,
            height: 640,
            lines: portraitLines,
          ),
        ];

    for (final testCase in cases) {
      testWidgets(
        '${testCase.label}: the photo is drawn where the mapper says, and '
        'every word is hit where it is drawn',
        (tester) async {
          final result = _page(
            fixture: testCase.fixture,
            width: testCase.width,
            height: testCase.height,
            lines: testCase.lines,
          );
          final words = [for (final line in testCase.lines) ...line.elements];
          final tapped = <String?>[];

          await tester.pumpWidget(
            MaterialApp(
              home: Scaffold(
                body: Center(
                  child: SizedBox(
                    width: 320,
                    height: 520,
                    child: OcrOverlay(
                      result: result,
                      selection: OcrSelection.empty(result),
                      onElementTap: (element) =>
                          tapped.add(element?.text.trim()),
                    ),
                  ),
                ),
              ),
            ),
          );
          await tester.pump();

          final overlayRect = tester.getRect(find.byType(OcrOverlay));
          final mapper = OcrCoordinateMapper(
            imageWidth: testCase.width,
            imageHeight: testCase.height,
            viewportSize: overlayRect.size,
          );
          final photo = (mapper.displayedOffset & mapper.displayedSize).shift(
            overlayRect.topLeft,
          );

          // The upright photo keeps its own aspect: a sideways capture must not
          // be laid out as if it were still stored landscape.
          expect(
            mapper.displayedSize.width / mapper.displayedSize.height,
            closeTo(testCase.width / testCase.height, 0.001),
          );
          expect(tester.getRect(find.byType(Image)), photo);

          for (final word in words) {
            await tester.tapAt(
              overlayRect.topLeft +
                  mapper.rectToScreen(word.boundingBox).center,
            );
            await tester.pump();
            expect(
              tapped.last,
              word.text.trim(),
              reason:
                  '${testCase.label}: tapping the centre of '
                  '"${word.text}" must select it',
            );
            expect(
              mapper.rectToScreen(word.boundingBox).width,
              greaterThan(0),
              reason: '${testCase.label}: word boxes must not collapse',
            );
          }

          // A tap in the letterbox is not a word: nothing is selected.
          tapped.clear();
          await tester.tapAt(overlayRect.topLeft + const Offset(2, 2));
          await tester.pump();
          expect(tapped, [null]);
        },
      );

      testWidgets(
        '${testCase.label}: translations stay inside the displayed photo and '
        'tap targets match what is drawn',
        (tester) async {
          final result = _page(
            fixture: testCase.fixture,
            width: testCase.width,
            height: testCase.height,
            lines: testCase.lines,
          );
          final overlay = _translationFor(testCase.lines);
          final tappedRegions = <int>[];

          await tester.pumpWidget(
            MaterialApp(
              home: Scaffold(
                body: Center(
                  child: SizedBox(
                    width: 320,
                    height: 520,
                    child: DefaultTextStyle(
                      style: const TextStyle(fontSize: 14),
                      child: Stack(
                        children: [
                          Positioned.fill(
                            child: OcrOverlay(
                              result: result,
                              selection: OcrSelection.empty(result),
                            ),
                          ),
                          Positioned.fill(
                            child: TranslationOverlay(
                              overlay: overlay,
                              imageWidth: testCase.width,
                              imageHeight: testCase.height,
                              onRegionTap: (region) =>
                                  tappedRegions.add(region.id),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          );
          await tester.pump();

          final overlayRect = tester.getRect(find.byType(OcrOverlay));
          final mapper = OcrCoordinateMapper(
            imageWidth: testCase.width,
            imageHeight: testCase.height,
            viewportSize: overlayRect.size,
          );
          final photo = (mapper.displayedOffset & mapper.displayedSize).shift(
            overlayRect.topLeft,
          );

          var drawn = 0;
          for (final region in overlay.regions) {
            final finder = find.byKey(
              ValueKey<String>('translated-region-${region.id}'),
            );
            if (finder.evaluate().isEmpty) continue;
            drawn += 1;
            final box = tester.getRect(finder);
            _expectInside(
              box,
              photo,
              reason:
                  '${testCase.label}: translated region ${region.id} left the '
                  'photo: $box outside $photo',
            );

            // The hit target is the drawn rectangle itself.
            await tester.tapAt(box.center);
            await tester.pump();
            expect(
              tappedRegions.last,
              region.id,
              reason:
                  '${testCase.label}: tapping the box of region '
                  '${region.id} must open that region',
            );
          }

          // At least one line has to reach the photo, otherwise this proves
          // nothing about alignment.
          expect(drawn, greaterThan(0));
        },
      );
    }
  });
}
