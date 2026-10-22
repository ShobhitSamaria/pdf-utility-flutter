import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdf_utility_flutter/ocr/domain/ocr_rect.dart';
import 'package:pdf_utility_flutter/ocr/presentation/ocr_coordinate_mapper.dart';
import 'package:pdf_utility_flutter/translation/domain/translated_region.dart';
import 'package:pdf_utility_flutter/translation/domain/translation_language.dart';
import 'package:pdf_utility_flutter/translation/domain/translation_request.dart';
import 'package:pdf_utility_flutter/translation/presentation/translated_overlay_deck.dart';
import 'package:pdf_utility_flutter/translation/presentation/translated_text_layout.dart';
import 'package:pdf_utility_flutter/translation/presentation/widgets/translation_overlay.dart';

/// The overlay used to force `height: 1.15` on every translation. That constant
/// is fine for Latin but not for Devanagari: Noto Sans Devanagari's natural line
/// is about 1.29 × the font size, so a forced 1.15 line box makes its matras
/// paint outside the box the deck reserved — up to 5 px at 48 px text.
///
/// `flutter_test`'s default font is square and never overflows, so the existing
/// suite could not see this. These tests load a real Devanagari font and assert
/// with the glyph ink extents, not just the layout rectangles.
///
/// The font is Noto Sans Devanagari Regular, licensed under the SIL Open Font
/// License 1.1 (see `test/support/fonts/OFL.txt`).
const _fontFamily = 'NotoSansDevanagari';
const _fontPath = 'test/support/fonts/NotoSansDevanagari-Regular.ttf';

const _hindi =
    'यह एक बहुत लंबा अनुवादित वाक्य है जिसे मूल पंक्ति के भीतर समायोजित करना है';
const _hindiShort = 'नमस्ते दुनिया';
const _mixed = 'यह Hello और world का मिश्रण है';
const _style = TextStyle(fontFamily: _fontFamily, fontSize: 14);

Future<void> _loadFont() async {
  final bytes = await File(_fontPath).readAsBytes();
  await (FontLoader(
    _fontFamily,
  )..addFont(Future<ByteData>.value(ByteData.view(bytes.buffer)))).load();
}

/// Vertical extent of the **painted glyphs** of [text] at [width].
///
/// `TextPainter.height` is the layout height; this is what the user actually
/// sees. The difference between them is exactly the bleed the tests are about.
({double top, double bottom}) _ink(
  String text,
  TextStyle style,
  double width, {
  int? maxLines,
}) {
  final painter = TextPainter(
    text: TextSpan(text: text, style: style),
    textDirection: TextDirection.ltr,
    maxLines: maxLines,
    ellipsis: maxLines == null ? null : '…',
  )..layout(maxWidth: math.max(1.0, width));
  var top = double.infinity;
  var bottom = -double.infinity;
  if (text.isNotEmpty) {
    for (final box in painter.getBoxesForSelection(
      TextSelection(baseOffset: 0, extentOffset: text.length),
    )) {
      top = math.min(top, box.top);
      bottom = math.max(bottom, box.bottom);
    }
  }
  painter.dispose();
  return (top: top.isFinite ? top : 0, bottom: bottom.isFinite ? bottom : 0);
}

void _expectNoOverlap(List<Rect> rects, {String reason = ''}) {
  for (var i = 0; i < rects.length; i++) {
    for (var j = i + 1; j < rects.length; j++) {
      final intersection = rects[i].intersect(rects[j]);
      expect(
        intersection.width <= 0.01 || intersection.height <= 0.01,
        isTrue,
        reason: '$reason ${rects[i]} overlaps ${rects[j]}: $intersection',
      );
    }
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(_loadFont);

  group('Devanagari leading is measured, not assumed', () {
    test('a forced 1.15 line height pushes glyphs out of the line box', () {
      // This is the fixture that reproduces the on-device defect. 48 px is the
      // deck's absolute font ceiling, so this is a heading-sized translation.
      const text = _hindi;
      final forced = const TextStyle(
        fontFamily: _fontFamily,
        fontSize: 48,
        height: TranslatedTextLayout.lineHeightFactor,
      );
      final painter = TextPainter(
        text: TextSpan(text: text, style: forced),
        textDirection: TextDirection.ltr,
      )..layout(maxWidth: 300);
      final layoutHeight = painter.height;
      painter.dispose();

      final ink = _ink(text, forced, 300);
      expect(
        ink.bottom,
        greaterThan(layoutHeight + 1),
        reason:
            'the fixture no longer reproduces the defect: the forced 1.15 line '
            'box already contains Devanagari ink',
      );
    });

    test('the derived line height keeps the same text inside its box', () {
      for (final size in <double>[7, 10, 14, 17, 24, 48]) {
        final style = TextStyle(fontFamily: _fontFamily, fontSize: size);
        final lineHeight = TranslatedTextLayout.lineHeightFor(_hindi, style);
        expect(
          lineHeight,
          greaterThanOrEqualTo(1.25),
          reason: 'Devanagari metrics demand more than 1.15 at $size px',
        );

        final resolved = style.copyWith(height: lineHeight);
        for (final width in <double>[60, 120, 220]) {
          final painter = TextPainter(
            text: TextSpan(text: _hindi, style: resolved),
            textDirection: TextDirection.ltr,
          )..layout(maxWidth: width);
          final layoutHeight = painter.height;
          painter.dispose();

          final ink = _ink(_hindi, resolved, width);
          expect(
            ink.top,
            greaterThan(-0.35),
            reason: 'size $size, width $width paints above its box: ${ink.top}',
          );
          expect(
            ink.bottom,
            lessThanOrEqualTo(layoutHeight + 0.35),
            reason:
                'size $size, width $width paints below its box: ${ink.bottom} '
                '> $layoutHeight',
          );
        }
      }
    });

    test('the factor is deterministic and never below the floor', () {
      final first = TranslatedTextLayout.lineHeightFor(_hindi, _style);
      final second = TranslatedTextLayout.lineHeightFor(_hindi, _style);
      expect(second, first);
      expect(
        first,
        lessThanOrEqualTo(TranslatedTextLayout.maxLineHeightFactor),
      );
      expect(
        TranslatedTextLayout.lineHeightFor(_hindiShort, _style),
        first,
        reason: 'one script, one leading',
      );
      expect(
        TranslatedTextLayout.lineHeightFor(
          'Hello world',
          const TextStyle(fontSize: 14),
        ),
        greaterThanOrEqualTo(TranslatedTextLayout.lineHeightFactor),
      );
    });
  });

  group('the deck keeps Devanagari ink inside its boxes', () {
    late Rect imageRect;
    late List<TranslatedRegion> regions;
    late OcrCoordinateMapper mapper;

    setUp(() {
      mapper = OcrCoordinateMapper(
        imageWidth: 1600,
        imageHeight: 2400,
        viewportSize: const Size(360, 640),
      );
      imageRect = mapper.displayedOffset & mapper.displayedSize;

      // Two columns of closely set lines, long Hindi output: the shape that
      // produced overlapping cards before the block deck, and bleeding glyphs
      // before the leading was derived from metrics.
      final bounds = <OcrRect>[
        OcrRect.fromLTRB(80, 200, 760, 260),
        OcrRect.fromLTRB(80, 268, 760, 328),
        OcrRect.fromLTRB(80, 336, 760, 396),
        OcrRect.fromLTRB(840, 200, 1500, 260),
        OcrRect.fromLTRB(840, 268, 1500, 328),
        OcrRect.fromLTRB(840, 336, 1500, 396),
        OcrRect.fromLTRB(80, 460, 760, 520),
        OcrRect.fromLTRB(840, 460, 1500, 520),
      ];
      const texts = <String>[
        _hindi,
        _hindiShort,
        _mixed,
        _hindi,
        _hindiShort,
        _mixed,
        _hindiShort,
        _mixed,
      ];
      regions = [
        for (var i = 0; i < bounds.length; i++)
          TranslatedRegion(
            id: i,
            sourceText: 'source $i',
            translatedText: texts[i],
            bounds: bounds[i],
            kind: TranslatedRegionKind.line,
          ),
      ];
    });

    test(
      'every drawn line contains its glyphs, with clear space between lines',
      () {
        final layout = TranslatedOverlayDeck.layout(
          items: [
            for (final region in regions)
              TranslatedDeckItem(
                id: region.id,
                text: region.translatedText,
                sourceRect: mapper.rectToScreen(region.bounds),
              ),
          ],
          imageRect: imageRect,
          style: _style,
        );

        expect(layout.lines, isNotEmpty);
        _expectNoOverlap([for (final block in layout.blocks) block.box]);
        _expectNoOverlap([for (final line in layout.lines) line.box]);

        for (final line in layout.lines) {
          final fitted = line.layout;
          expect(
            fitted.style.height,
            closeTo(
              TranslatedTextLayout.lineHeightFor(line.text, _style),
              0.0001,
            ),
            reason: 'line ${line.id} was measured with the wrong leading',
          );

          final ink = _ink(
            line.text,
            fitted.style,
            line.box.width - fitted.insetX * 2,
            maxLines: fitted.maxLines,
          );
          final paintedTop = line.box.top + fitted.insetY + ink.top;
          final paintedBottom = line.box.top + fitted.insetY + ink.bottom;
          expect(
            paintedTop,
            greaterThanOrEqualTo(line.box.top - 0.01),
            reason: 'line ${line.id} glyphs start above their box',
          );
          expect(
            paintedBottom,
            lessThanOrEqualTo(line.box.bottom + 0.01),
            reason:
                'line ${line.id} glyphs end at $paintedBottom, '
                'box ends at ${line.box.bottom}',
          );
          expect(line.box.left, greaterThanOrEqualTo(imageRect.left - 0.01));
          expect(line.box.right, lessThanOrEqualTo(imageRect.right + 0.01));
        }

        // Consecutive lines of a block are separated by `lineSpacing`, so even
        // the ink of one line cannot touch the ink of the next.
        for (final block in layout.blocks) {
          for (var i = 1; i < block.lines.length; i++) {
            final previous = block.lines[i - 1];
            final current = block.lines[i];
            final previousInk = _ink(
              previous.text,
              previous.layout.style,
              previous.box.width - previous.layout.insetX * 2,
              maxLines: previous.layout.maxLines,
            );
            expect(
              previous.box.top + previous.layout.insetY + previousInk.bottom,
              lessThanOrEqualTo(current.box.top + 0.01),
              reason:
                  'ink of line ${previous.id} reaches line ${current.id} '
                  '(${previous.box} / ${current.box})',
            );
          }
        }
      },
    );
  });

  testWidgets('the real font paints inside every rendered box', (tester) async {
    final overlay = TranslatedOverlay(
      regions: [
        for (var i = 0; i < 5; i++)
          TranslatedRegion(
            id: i,
            sourceText: 'source $i',
            translatedText: _hindi,
            bounds: OcrRect.fromLTRB(120, 120 + i * 70, 900, 180 + i * 70),
            kind: TranslatedRegionKind.line,
          ),
      ],
      sourceLanguage: TranslationLanguages.english,
      targetLanguage: TranslationLanguages.hindi,
    );

    await tester.pumpWidget(
      MaterialApp(
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
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    final boxes = <Rect>[];
    for (var i = 0; i < 5; i++) {
      final box = tester.getRect(
        find.byKey(ValueKey<String>('translated-region-$i')),
      );
      boxes.add(box);
      final text = find.descendant(
        of: find.byKey(ValueKey<String>('translated-region-$i')),
        matching: find.byType(Text),
      );
      expect(text, findsOneWidget);
      final textRect = tester.getRect(text);
      expect(textRect.top, greaterThanOrEqualTo(box.top - 0.01));
      expect(textRect.bottom, lessThanOrEqualTo(box.bottom + 0.01));
      expect(textRect.left, greaterThanOrEqualTo(box.left - 0.01));
      expect(textRect.right, lessThanOrEqualTo(box.right + 0.01));
    }
    _expectNoOverlap(boxes);
  });

  testWidgets('translations that do not fit are counted and openable', (
    tester,
  ) async {
    // Dense page: 60 long Hindi lines in a 640 px photo cannot all be legible.
    final overlay = TranslatedOverlay(
      regions: [
        for (var i = 0; i < 60; i++)
          TranslatedRegion(
            id: i,
            sourceText: 'source $i',
            translatedText: _hindi,
            bounds: OcrRect.fromLTRB(40, 30 + i * 8, 960, 36 + i * 8),
            kind: TranslatedRegionKind.line,
          ),
      ],
      sourceLanguage: TranslationLanguages.english,
      targetLanguage: TranslationLanguages.hindi,
    );

    var opened = 0;
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
                overlay: overlay,
                imageWidth: 1000,
                imageHeight: 1000,
                onRegionTap: (_) {},
                onOverflowTap: () => opened += 1,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.byType(TranslatedOverflowNotice), findsOneWidget);
    // Concise and calm — it points at where the rest of the text is, rather
    // than announcing that the page "failed" to hold it.
    final notice = find.textContaining('more translation');
    expect(notice, findsOneWidget);
    expect(find.textContaining('did not fit'), findsNothing);

    // The notice gets its own strip at the bottom: it must not cover a
    // translation that was drawn.
    final noticeRect = tester.getRect(find.byType(TranslatedOverflowNotice));
    var drawn = 0;
    for (var i = 0; i < 60; i++) {
      final finder = find.byKey(ValueKey<String>('translated-region-$i'));
      if (finder.evaluate().isEmpty) continue;
      drawn += 1;
      final box = tester.getRect(finder);
      final intersection = box.intersect(noticeRect);
      expect(
        intersection.width <= 0.01 || intersection.height <= 0.01,
        isTrue,
        reason: 'the notice covers translated line $i: $intersection',
      );
    }
    expect(drawn, greaterThan(0));

    await tester.tap(find.byType(TranslatedOverflowNotice));
    await tester.pump();
    expect(opened, 1, reason: 'the notice must reach the full translation');

    // The text that did not fit is still in the model, in reading order.
    expect(
      overlay.asResult(TranslationScope.wholePage).translatedText.split('\n'),
      hasLength(60),
    );
  });

  testWidgets('the block backing masks the original words', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(home: Center(child: TranslatedBlockPill())),
    );

    final decorations = tester
        .widgetList<DecoratedBox>(
          find.descendant(
            of: find.byType(TranslatedBlockPill),
            matching: find.byType(DecoratedBox),
          ),
        )
        .map((box) => box.decoration)
        .whereType<BoxDecoration>()
        .where((decoration) => decoration.color != null)
        .toList();

    expect(decorations, isNotEmpty);
    final alpha = decorations.last.color!.a;
    expect(alpha, greaterThanOrEqualTo(0.9));
    expect(alpha, TranslatedBlockPill.backingAlpha);
  });
}
