import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
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
import 'package:pdf_utility_flutter/translation/domain/translation_request.dart';
import 'package:pdf_utility_flutter/translation/presentation/translated_overlay_deck.dart';
import 'package:pdf_utility_flutter/translation/presentation/translated_text_layout.dart';
import 'package:pdf_utility_flutter/translation/presentation/widgets/translation_overlay.dart';

const _style = TextStyle(fontSize: 14);
const _hindi =
    'यह एक बहुत लंबा अनुवाद है जिसे मूल पंक्ति के भीतर समायोजित करना है';
const _hindiShort = 'नमस्ते दुनिया';
const _latin = 'A translated sentence that is much longer than its source';
const _mixed = 'यह Hello और world का मिश्रण है';

TranslatedDeckItem _item(int id, String text, Rect source) =>
    TranslatedDeckItem(id: id, text: text, sourceRect: source);

/// Height the text actually paints, measured exactly like the widget does.
double _paintedHeight(TranslatedDeckPlacement line) {
  final layout = line.layout;
  final painter = TextPainter(
    text: TextSpan(text: line.text, style: layout.style),
    textDirection: TextDirection.ltr,
    textScaler: TextScaler.noScaling,
    maxLines: layout.maxLines,
    ellipsis: '…',
  )..layout(maxWidth: math.max(1.0, line.box.width - layout.insetX * 2));
  final height = painter.height;
  painter.dispose();
  return height + layout.insetY * 2;
}

void _expectNoOverlap(List<Rect> rects, {String reason = ''}) {
  for (var i = 0; i < rects.length; i++) {
    for (var j = i + 1; j < rects.length; j++) {
      final intersection = rects[i].intersect(rects[j]);
      expect(
        intersection.width <= 0.01 || intersection.height <= 0.01,
        isTrue,
        reason:
            '$reason rect $i (${rects[i]}) overlaps rect $j (${rects[j]}): '
            '$intersection',
      );
    }
  }
}

void _expectContained(
  List<TranslatedDeckPlacement> lines, {
  String reason = '',
}) {
  for (final line in lines) {
    expect(line.layout.paintText, isTrue, reason: '$reason line ${line.id}');
    expect(
      line.layout.isContained,
      isTrue,
      reason: '$reason line ${line.id} layout is not contained: ${line.box}',
    );
    expect(
      _paintedHeight(line),
      lessThanOrEqualTo(line.box.height + 0.01),
      reason:
          '$reason line ${line.id} paints '
          '${_paintedHeight(line)} into a box of ${line.box.height}',
    );
  }
}

void _expectInside(List<TranslatedDeckPlacement> lines, Rect imageRect) {
  for (final line in lines) {
    expect(line.box.left, greaterThanOrEqualTo(imageRect.left - 0.01));
    expect(line.box.top, greaterThanOrEqualTo(imageRect.top - 0.01));
    expect(line.box.right, lessThanOrEqualTo(imageRect.right + 0.01));
    expect(line.box.bottom, lessThanOrEqualTo(imageRect.bottom + 0.01));
  }
}

List<TranslatedDeckPlacement> _flat(List<TranslatedBlockPlacement> blocks) => [
  for (final block in blocks) ...block.lines,
];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const page = Rect.fromLTWH(0, 0, 360, 640);

  group('the two defects that survived the previous fix', () {
    test(
      'narrow lines in neighbouring columns do not collide once widened',
      () {
        // Reproduces the previous implementation exactly: two six-pixel OCR
        // boxes ten pixels apart. Collision maths ran on those source boxes and
        // concluded "different columns", while the painter widened each one to
        // `minWidth` (56) and centred it — boxes 85..131 and 141..197 wide
        // enough to overlap by 46 px on screen.
        final blocks = TranslatedOverlayDeck.buildBlocks(
          items: [
            _item(0, _hindiShort, const Rect.fromLTWH(100, 100, 6, 14)),
            _item(1, _hindiShort, const Rect.fromLTWH(110, 100, 6, 14)),
          ],
          imageRect: page,
          style: _style,
        );
        final lines = _flat(blocks);

        expect(lines.length, 2);
        _expectNoOverlap([for (final line in lines) line.box]);
        for (final line in lines) {
          // Each box stays anchored on its own source, so the association
          // between translation and source region is preserved.
          expect(
            line.box.left,
            lessThanOrEqualTo(line.sourceRect.center.dx + 0.01),
          );
          expect(
            line.box.right,
            greaterThanOrEqualTo(line.sourceRect.center.dx - 0.01),
          );
        }
      },
    );

    test('a narrow-page sweep draws or reports every region', () {
      // A very narrow photo displays only a few dozen pixels wide, so many
      // lines cannot be given even one measured line of room. Those regions may
      // be left off the image, but they must be *reported*: before `layout()`
      // existed, a group skipped before it reached a block vanished with no
      // record at all, and a dense page could hide a third of its translation
      // while still claiming every region had been placed.
      const texts = [_hindi, _hindiShort, _mixed, _latin, 'क'];
      for (var seed = 0; seed < 60; seed++) {
        final random = math.Random(seed + 900);
        final mapper = OcrCoordinateMapper(
          imageWidth: 60 + random.nextInt(200),
          imageHeight: 900 + random.nextInt(1200),
          viewportSize: const Size(360, 640),
        );
        final imageRect = mapper.displayedOffset & mapper.displayedSize;
        final items = <TranslatedDeckItem>[];
        for (var row = 0; row < 20; row++) {
          final imageTop = 40 + row * 50.0;
          final imageLeft = 4 + random.nextDouble() * 10;
          final imageWidth = 20 + random.nextDouble() * 26;
          final topLeft = mapper.imageToScreen(imageLeft, imageTop);
          final bottomRight = mapper.imageToScreen(
            imageLeft + imageWidth,
            imageTop + 34,
          );
          items.add(
            _item(
              row,
              texts[random.nextInt(texts.length)],
              Rect.fromLTRB(
                topLeft.dx,
                topLeft.dy,
                bottomRight.dx,
                bottomRight.dy,
              ),
            ),
          );
        }

        final layout = TranslatedOverlayDeck.layout(
          items: items,
          imageRect: imageRect,
          style: _style,
        );
        final drawn = layout.drawnRegionIds.toSet();
        final hidden = layout.hiddenRegionIds.toSet();

        expect(drawn.intersection(hidden), isEmpty, reason: 'seed $seed');
        expect(drawn.union(hidden), {
          for (final item in items) item.id,
        }, reason: 'seed $seed lost a region');
        expect(layout.drawnRegionIds, isNotEmpty, reason: 'seed $seed');
        _expectNoOverlap([
          for (final block in layout.blocks) block.box,
        ], reason: 'seed $seed');
        _expectNoOverlap([
          for (final line in layout.lines) line.box,
        ], reason: 'seed $seed');
        for (final line in layout.lines) {
          expect(line.box.left, greaterThanOrEqualTo(imageRect.left - 0.01));
          expect(line.box.right, lessThanOrEqualTo(imageRect.right + 0.01));
          expect(line.box.top, greaterThanOrEqualTo(imageRect.top - 0.01));
          expect(line.box.bottom, lessThanOrEqualTo(imageRect.bottom + 0.01));
        }
      }
    });

    test('a line squeezed below one painted line is never drawn', () {
      // Seventy lines of long Hindi in a 640 px page: the previous fallback gave
      // each line a ~5 px slice. The rectangles did not overlap, but one line of
      // 7 px text needs ~12 px with padding, so the glyphs painted straight over
      // the next translation. Now the floor is a measured line, and the tail is
      // reported instead of squeezed.
      final items = [
        for (var i = 0; i < 70; i++)
          _item(i, _hindi, Rect.fromLTWH(40, 40.0 + i * 8, 280, 7)),
      ];
      final blocks = TranslatedOverlayDeck.buildBlocks(
        items: items,
        imageRect: page,
        style: _style,
      );
      final lines = _flat(blocks);
      final hidden = [for (final block in blocks) ...block.hiddenRegionIds];

      expect(lines, isNotEmpty);
      expect(hidden, isNotEmpty, reason: 'a 640 px page cannot hold 70 lines');
      _expectNoOverlap([for (final line in lines) line.box]);
      _expectContained(lines);
      _expectInside(lines, page);
      // Every region is either on the page or reported as hidden — none is
      // silently forgotten.
      expect(
        {...lines.map((line) => line.id), ...hidden},
        {for (var i = 0; i < 70; i++) i},
      );
    });

    test('a 40-page geometry sweep produces no overlap and no bleed', () {
      // The shapes that broke the old deck: 1–3 columns, 10–300 px source
      // widths, mixed scripts, random page sizes. Before the fix this sweep had
      // overlaps on 173 of 300 pages and 983 lines whose text left its box.
      const texts = [_hindi, _hindiShort, _mixed, _latin, 'क'];
      for (var seed = 0; seed < 40; seed++) {
        final random = math.Random(seed);
        final viewport = Size(
          260 + random.nextDouble() * 140,
          360 + random.nextDouble() * 380,
        );
        final mapper = OcrCoordinateMapper(
          imageWidth: 600 + random.nextInt(900),
          imageHeight: 800 + random.nextInt(1200),
          viewportSize: viewport,
        );
        final imageRect = mapper.displayedOffset & mapper.displayedSize;
        final columns = 1 + random.nextInt(3);
        final rows = 8 + random.nextInt(16);
        final items = <TranslatedDeckItem>[];
        var id = 0;
        for (var row = 0; row < rows; row++) {
          for (var column = 0; column < columns; column++) {
            if (random.nextDouble() < 0.25) continue;
            final columnWidth = (random.nextInt(600) + 600) / columns;
            final left = column * columnWidth + 20 + random.nextDouble() * 40;
            final width = 10 + random.nextDouble() * (columnWidth * 0.7);
            final top = 80.0 + row * (400.0 / rows);
            final height = 24 + random.nextDouble() * 24;
            final topLeft = mapper.imageToScreen(left, top);
            final bottomRight = mapper.imageToScreen(
              left + width,
              top + height,
            );
            items.add(
              _item(
                id++,
                texts[random.nextInt(texts.length)],
                Rect.fromLTRB(
                  topLeft.dx,
                  topLeft.dy,
                  bottomRight.dx,
                  bottomRight.dy,
                ),
              ),
            );
          }
        }

        final blocks = TranslatedOverlayDeck.buildBlocks(
          items: items,
          imageRect: imageRect,
          style: _style,
        );
        final lines = _flat(blocks);

        expect(lines, isNotEmpty, reason: 'seed $seed placed nothing');
        _expectNoOverlap([
          for (final block in blocks) block.box,
        ], reason: 'seed $seed');
        _expectNoOverlap([
          for (final line in lines) line.box,
        ], reason: 'seed $seed');
        _expectContained(lines, reason: 'seed $seed');
        _expectInside(lines, imageRect);
      }
    });
  });

  group('layout strategy', () {
    test('taller Devanagari fits by pushing its own paragraph down', () {
      final blocks = TranslatedOverlayDeck.buildBlocks(
        items: [
          _item(0, _hindi, const Rect.fromLTWH(40, 100, 280, 18)),
          _item(1, _hindiShort, const Rect.fromLTWH(40, 120, 280, 18)),
        ],
        imageRect: page,
        style: _style,
      );
      final lines = _flat(blocks);

      expect(blocks, hasLength(1));
      expect(lines, hasLength(2));
      expect(
        lines[1].box.top,
        greaterThanOrEqualTo(lines[0].box.bottom - 0.01),
      );
      expect(lines[0].box.height, greaterThan(18));
      _expectContained(lines);
      _expectNoOverlap([for (final line in lines) line.box]);

      // Long Hindi may legitimately ellipsize; it must not lose its lines.
      for (final line in lines) {
        expect(
          line.layout.style.fontSize,
          greaterThanOrEqualTo(TranslatedTextLayout.defaultMinSize),
        );
      }
    });

    test('a long translation wider than its source stays legible', () {
      final line = TranslatedOverlayDeck.build(
        items: [_item(0, _hindi, const Rect.fromLTWH(40, 100, 40, 14))],
        imageRect: page,
        style: _style,
      ).single;

      expect(line.box.width, greaterThanOrEqualTo(40));
      expect(
        line.layout.style.fontSize,
        greaterThanOrEqualTo(TranslatedTextLayout.defaultMinSize),
      );
      expect(line.layout.maxLines, greaterThanOrEqualTo(1));
      _expectContained([line]);
    });

    test('two paragraphs and two separate columns are not merged', () {
      final items = <TranslatedDeckItem>[];
      var id = 0;
      for (var row = 0; row < 3; row++) {
        items
          ..add(_item(id++, _hindi, Rect.fromLTWH(10, 100 + row * 30, 150, 24)))
          ..add(
            _item(id++, _hindi, Rect.fromLTWH(200, 100 + row * 30, 150, 24)),
          );
      }
      // A separate paragraph well below, in the left column.
      items.add(_item(id, _hindiShort, const Rect.fromLTWH(10, 400, 150, 20)));

      final blocks = TranslatedOverlayDeck.buildBlocks(
        items: items,
        imageRect: page,
        style: _style,
      );

      expect(blocks, hasLength(3));
      final left = blocks.where((block) => block.box.left < 180).toList();
      final right = blocks.where((block) => block.box.left >= 180).toList();
      expect(left, hasLength(2));
      expect(right, hasLength(1));
      expect(left.first.regionIds, [0, 2, 4]);
      expect(right.single.regionIds, [1, 3, 5]);
      expect(left.last.regionIds, [6]);

      _expectNoOverlap([for (final block in blocks) block.box]);
      _expectContained(_flat(blocks));
    });

    test('dense neighbouring lines stay separate and readable', () {
      final items = [
        for (var i = 0; i < 30; i++)
          _item(i, _mixed, Rect.fromLTWH(20, 60.0 + i * 17, 320, 14)),
      ];
      final blocks = TranslatedOverlayDeck.buildBlocks(
        items: items,
        imageRect: page,
        style: _style,
      );
      final lines = _flat(blocks);

      expect(
        lines.length +
            blocks.fold<int>(0, (sum, b) => sum + b.hiddenRegionIds.length),
        30,
      );
      _expectNoOverlap([for (final block in blocks) block.box]);
      _expectNoOverlap([for (final line in lines) line.box]);
      _expectContained(lines);
      _expectInside(lines, page);
    });

    test('mixed Latin and Devanagari share one page without collisions', () {
      final lines = TranslatedOverlayDeck.build(
        items: [
          _item(0, _latin, const Rect.fromLTWH(20, 80, 320, 24)),
          _item(1, _hindi, const Rect.fromLTWH(20, 110, 320, 24)),
          _item(2, _mixed, const Rect.fromLTWH(20, 140, 320, 24)),
        ],
        imageRect: page,
        style: _style,
      );

      _expectNoOverlap([for (final line in lines) line.box]);
      _expectContained(lines);
      expect(
        lines.where((line) => line.layout.ellipsized).length,
        lessThan(lines.length),
        reason:
            'not every mixed-script line needs ellipsis on a full-width page',
      );
    });
  });

  group('image shapes and display transforms', () {
    test('very narrow and very wide displayed images stay contained', () {
      for (final imageRect in const [
        Rect.fromLTWH(0, 0, 90, 620),
        Rect.fromLTWH(0, 0, 1600, 200),
      ]) {
        final sourceWidth = math.min(60.0, imageRect.width * 0.6);
        final lines = TranslatedOverlayDeck.build(
          items: [
            for (var i = 0; i < 4; i++)
              _item(
                i,
                _hindi,
                Rect.fromLTWH(
                  imageRect.left + 4,
                  imageRect.top + 10 + i * 30,
                  sourceWidth,
                  14,
                ),
              ),
          ],
          imageRect: imageRect,
          style: _style,
        );

        expect(lines, isNotEmpty);
        _expectNoOverlap([for (final line in lines) line.box]);
        _expectContained(lines);
        _expectInside(lines, imageRect);
      }
    });

    test('portrait and landscape photos map to the displayed photo only', () {
      for (final (width, height) in const [(1000, 2000), (2000, 1000)]) {
        final mapper = OcrCoordinateMapper(
          imageWidth: width,
          imageHeight: height,
          viewportSize: const Size(360, 640),
        );
        final imageRect = mapper.displayedOffset & mapper.displayedSize;
        final items = [
          for (var i = 0; i < 6; i++)
            _item(
              i,
              _hindi,
              mapper.rectToScreen(
                OcrRect.fromLTRB(
                  100,
                  200 + i * 120,
                  width - 100,
                  260 + i * 120,
                ),
              ),
            ),
        ];

        final lines = TranslatedOverlayDeck.build(
          items: items,
          imageRect: imageRect,
          style: _style,
        );

        _expectNoOverlap([for (final line in lines) line.box]);
        _expectContained(lines);
        _expectInside(lines, imageRect);
      }
    });

    test('letterbox offsets and display sizes are respected', () {
      // The displayed photo is inset and much smaller than the viewport, which
      // is what a portrait photo in a landscape box looks like.
      const imageRect = Rect.fromLTWH(40, 30, 280, 560);
      for (final scale in [0.5, 1.0, 1.75]) {
        final lines = TranslatedOverlayDeck.build(
          items: [
            for (var i = 0; i < 5; i++)
              _item(
                i,
                _hindi,
                Rect.fromLTWH(
                  imageRect.left + 20,
                  imageRect.top + 20 + i * 40,
                  120 * scale,
                  16 * scale,
                ),
              ),
          ],
          imageRect: imageRect,
          style: _style,
        );

        _expectNoOverlap([for (final line in lines) line.box]);
        _expectContained(lines);
        _expectInside(lines, imageRect);
      }
    });
  });

  group('determinism and availability', () {
    List<TranslatedDeckItem> denseItems() => [
      for (var i = 0; i < 26; i++)
        _item(
          i,
          i.isEven ? _hindi : _mixed,
          Rect.fromLTWH(30 + (i % 2) * 0, 60.0 + i * 21, 300, 16),
        ),
    ];

    test('repeated layout calculations are identical', () {
      final first = TranslatedOverlayDeck.buildBlocks(
        items: denseItems(),
        imageRect: page,
        style: _style,
      );
      final second = TranslatedOverlayDeck.buildBlocks(
        items: denseItems(),
        imageRect: page,
        style: _style,
      );

      expect(second.toString(), first.toString());
      for (var i = 0; i < first.length; i++) {
        for (var j = 0; j < first[i].lines.length; j++) {
          expect(second[i].lines[j].box, first[i].lines[j].box);
          expect(
            second[i].lines[j].layout.maxLines,
            first[i].lines[j].layout.maxLines,
          );
          expect(
            second[i].lines[j].layout.style.fontSize,
            first[i].lines[j].layout.style.fontSize,
          );
        }
      }
    });

    test('unplaceable lines stay in the overlay and in the full text', () {
      final regions = [
        for (var i = 0; i < 90; i++)
          TranslatedRegion(
            id: i,
            sourceText: 'source $i',
            translatedText: _hindi,
            bounds: OcrRect.fromLTRB(20, 40 + i * 6, 340, 46 + i * 6),
            kind: TranslatedRegionKind.line,
          ),
      ];
      final overlay = TranslatedOverlay(
        regions: regions,
        sourceLanguage: TranslationLanguages.english,
        targetLanguage: TranslationLanguages.hindi,
      );
      final mapper = OcrCoordinateMapper(
        imageWidth: 360,
        imageHeight: 640,
        viewportSize: const Size(360, 640),
      );
      final blocks = TranslatedOverlayDeck.buildBlocks(
        items: [
          for (final region in regions)
            _item(
              region.id,
              region.translatedText,
              mapper.rectToScreen(region.bounds),
            ),
        ],
        imageRect: mapper.displayedOffset & mapper.displayedSize,
        style: _style,
      );

      final drawn = {for (final block in blocks) ...block.regionIds};
      final hidden = {for (final block in blocks) ...block.hiddenRegionIds};
      expect(hidden, isNotEmpty);
      expect(drawn.intersection(hidden), isEmpty);
      expect({...drawn, ...hidden}, {for (final region in regions) region.id});

      // Nothing is dropped from the model the translation sheet reads.
      expect(overlay.regions, hasLength(90));
      expect(
        overlay.asResult(TranslationScope.wholePage).translatedText.split('\n'),
        hasLength(90),
      );
    });
  });

  group('widget geometry and interaction', () {
    TranslatedOverlay overlayOf(List<TranslatedRegion> regions) =>
        TranslatedOverlay(
          regions: regions,
          sourceLanguage: TranslationLanguages.english,
          targetLanguage: TranslationLanguages.hindi,
        );

    TranslatedRegion region(int id, String text, OcrRect bounds) =>
        TranslatedRegion(
          id: id,
          sourceText: 'source $id',
          translatedText: text,
          bounds: bounds,
          kind: TranslatedRegionKind.line,
        );

    Widget harness(
      TranslatedOverlay overlay, {
      required void Function(int id) onTap,
    }) => MaterialApp(
      home: DefaultTextStyle(
        style: _style,
        child: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
            width: 360,
            height: 640,
            child: Stack(
              fit: StackFit.expand,
              children: [
                TranslationOverlay(
                  overlay: overlay,
                  imageWidth: 1000,
                  imageHeight: 1000,
                  onRegionTap: (region) => onTap(region.id),
                ),
              ],
            ),
          ),
        ),
      ),
    );

    testWidgets('tapping a repositioned box reports its own region', (
      tester,
    ) async {
      final tapped = <int>[];
      // Three regions on the same rectangle: the deck stacks them, so every box
      // after the first is drawn somewhere other than its source. Tapping each
      // rendered box must still report the region drawn there.
      await tester.pumpWidget(
        harness(
          overlayOf([
            for (var i = 0; i < 3; i++)
              region(i, 'अनुवाद $i', OcrRect.fromLTRB(100, 100, 400, 160)),
          ]),
          onTap: tapped.add,
        ),
      );
      await tester.pump();

      final rects = [
        for (var i = 0; i < 3; i++)
          tester.getRect(find.byKey(ValueKey<String>('translated-region-$i'))),
      ];
      _expectNoOverlap(rects);

      for (var i = 2; i >= 0; i--) {
        await tester.tapAt(rects[i].center);
        await tester.pump();
      }

      expect(tapped, [2, 1, 0]);
    });

    testWidgets('every painted line stays inside its rendered box', (
      tester,
    ) async {
      await tester.pumpWidget(
        harness(
          overlayOf([
            for (var i = 0; i < 6; i++)
              region(
                i,
                _hindi,
                OcrRect.fromLTRB(100, 100 + i * 40, 900, 140 + i * 40),
              ),
          ]),
          onTap: (_) {},
        ),
      );
      await tester.pump();

      final boxes = [
        for (var i = 0; i < 6; i++)
          tester.getRect(find.byKey(ValueKey<String>('translated-region-$i'))),
      ];
      _expectNoOverlap(boxes);

      for (var i = 0; i < 6; i++) {
        final text = find.descendant(
          of: find.byKey(ValueKey<String>('translated-region-$i')),
          matching: find.byType(Text),
        );
        expect(text, findsOneWidget);
        final textRect = tester.getRect(text);
        expect(textRect.top, greaterThanOrEqualTo(boxes[i].top - 0.01));
        expect(textRect.bottom, lessThanOrEqualTo(boxes[i].bottom + 0.01));
        expect(textRect.left, greaterThanOrEqualTo(boxes[i].left - 0.01));
        expect(textRect.right, lessThanOrEqualTo(boxes[i].right + 0.01));
      }
    });

    testWidgets('an RTL target is measured and painted right to left', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          home: DefaultTextStyle(
            style: _style,
            child: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(
                width: 360,
                height: 640,
                child: TranslationOverlay(
                  overlay: TranslatedOverlay(
                    regions: [
                      region(
                        0,
                        'مرحبا بالعالم',
                        OcrRect.fromLTRB(100, 100, 900, 160),
                      ),
                    ],
                    sourceLanguage: TranslationLanguages.english,
                    targetLanguage: TranslationLanguages.arabic,
                  ),
                  imageWidth: 1000,
                  imageHeight: 1000,
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      final text = tester.widget<Text>(find.text('مرحبا بالعالم'));
      expect(text.textDirection, TextDirection.rtl);
    });

    testWidgets('turning the overlay off restores OCR word selection', (
      tester,
    ) async {
      final word = OcrElement(
        text: 'Hello',
        boundingBox: OcrRect.fromLTRB(100, 100, 900, 200),
      );
      final result = OcrResult(
        sourceImage: const SourceImageInfo(
          path: '/tmp/does-not-exist.jpg',
          width: 1000,
          height: 1000,
        ),
        fullText: 'Hello',
        blocks: [
          OcrBlock(
            text: 'Hello',
            boundingBox: OcrRect.fromLTRB(100, 100, 900, 200),
            lines: [
              OcrLine(
                text: 'Hello',
                boundingBox: OcrRect.fromLTRB(100, 100, 900, 200),
                elements: [word],
              ),
            ],
          ),
        ],
      );
      final overlay = TranslatedOverlay(
        regions: [region(0, _hindi, OcrRect.fromLTRB(100, 100, 900, 200))],
        sourceLanguage: TranslationLanguages.english,
        targetLanguage: TranslationLanguages.hindi,
      );

      final taps = <String>[];
      var toggles = 0;
      var translationVisible = true;

      await tester.pumpWidget(
        MaterialApp(
          home: StatefulBuilder(
            builder: (context, setState) => Align(
              alignment: Alignment.topLeft,
              child: SizedBox(
                width: 360,
                height: 640,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    OcrOverlay(
                      result: result,
                      selection: OcrSelection.empty(result),
                      onElementTap: (element) =>
                          taps.add('ocr:${element?.text ?? 'none'}'),
                    ),
                    if (translationVisible)
                      TranslationOverlay(
                        overlay: overlay,
                        imageWidth: 1000,
                        imageHeight: 1000,
                        onRegionTap: (region) =>
                            taps.add('translation:${region.id}'),
                      ),
                    Positioned(
                      top: 8,
                      right: 8,
                      child: TextButton(
                        onPressed: () {
                          toggles += 1;
                          setState(() => translationVisible = false);
                        },
                        child: const Text('toggle'),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      // The translated box covers the word, so it owns the tap. The tap point is
      // derived from the overlay's actual laid-out size — the test window is
      // shorter than the requested 640 px, so hard-coded coordinates would miss.
      final overlayRect = tester.getRect(find.byType(OcrOverlay));
      final mapper = OcrCoordinateMapper(
        imageWidth: 1000,
        imageHeight: 1000,
        viewportSize: overlayRect.size,
      );
      final wordCentre = overlayRect.topLeft + mapper.imageToScreen(500, 150);

      await tester.tapAt(wordCentre);
      await tester.pump();
      expect(taps, ['translation:0']);

      // …and with the overlay off, the same point is a word again.
      await tester.tap(find.text('toggle'), warnIfMissed: true);
      await tester.pump();
      expect(toggles, 1, reason: 'the toggle button was never pressed');
      expect(
        find.byKey(const ValueKey<String>('translated-region-0')),
        findsNothing,
      );
      await tester.tapAt(wordCentre);
      await tester.pump();
      expect(taps, ['translation:0', 'ocr:Hello']);
    });
  });
}
