import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdf_utility_flutter/ocr/domain/ocr_rect.dart';
import 'package:pdf_utility_flutter/ocr/presentation/ocr_coordinate_mapper.dart';
import 'package:pdf_utility_flutter/translation/domain/translated_region.dart';
import 'package:pdf_utility_flutter/translation/domain/translation_language.dart';
import 'package:pdf_utility_flutter/translation/presentation/translated_overlay_deck.dart';
import 'package:pdf_utility_flutter/translation/presentation/widgets/translation_overlay.dart';

/// WCAG relative luminance of an sRGB colour.
double _luminance(Color color) {
  double channel(double value) => value <= 0.03928
      ? value / 12.92
      : math.pow((value + 0.055) / 1.055, 2.4).toDouble();
  return 0.2126 * channel(color.r) +
      0.7152 * channel(color.g) +
      0.0722 * channel(color.b);
}

/// WCAG contrast ratio between two colours (1:1 … 21:1).
double _contrast(Color a, Color b) {
  final high = math.max(_luminance(a), _luminance(b));
  final low = math.min(_luminance(a), _luminance(b));
  return (high + 0.05) / (low + 0.05);
}

void main() {
  // A square 1000x1000 source image, so the mapping maths stays readable.
  const imageWidth = 1000;
  const imageHeight = 1000;
  const squareViewport = Size(400, 400);
  const style = TextStyle(fontSize: 14);

  TranslatedRegion region({
    required int id,
    required String translated,
    required OcrRect bounds,
    String source = 'source',
  }) => TranslatedRegion(
    id: id,
    sourceText: source,
    translatedText: translated,
    bounds: bounds,
    kind: TranslatedRegionKind.line,
  );

  TranslatedOverlay overlayOf(List<TranslatedRegion> regions) =>
      TranslatedOverlay(
        regions: regions,
        sourceLanguage: TranslationLanguages.english,
        targetLanguage: TranslationLanguages.hindi,
      );

  Widget harness(
    TranslatedOverlay overlay, {
    Size size = squareViewport,
    ValueChanged<TranslatedRegion>? onRegionTap,
  }) => MaterialApp(
    home: DefaultTextStyle(
      style: style,
      child: Align(
        alignment: Alignment.topLeft,
        child: SizedBox(
          width: size.width,
          height: size.height,
          child: TranslationOverlay(
            overlay: overlay,
            imageWidth: imageWidth,
            imageHeight: imageHeight,
            onRegionTap: onRegionTap,
          ),
        ),
      ),
    ),
  );

  /// The box the overlay *should* draw, computed with the very same mapper and
  /// the very same deck the widget uses. Every test that calls this has one
  /// region per block, so the deck's single-item answer is its block answer;
  /// what this asserts is that the widget draws the deck's geometry faithfully
  /// rather than re-deriving it (or padding around it).
  Rect expectedBox(OcrRect bounds, String text, {Size size = squareViewport}) {
    final mapper = OcrCoordinateMapper(
      imageWidth: imageWidth,
      imageHeight: imageHeight,
      viewportSize: size,
    );
    return TranslatedOverlayDeck.build(
      items: [
        TranslatedDeckItem(
          id: 0,
          text: text,
          sourceRect: mapper.rectToScreen(bounds),
        ),
      ],
      imageRect: mapper.displayedOffset & mapper.displayedSize,
      style: style,
    ).single.box;
  }

  Finder boxFinder(int id) =>
      find.byKey(ValueKey<String>('translated-region-$id'));

  Finder blockFinder(int id) =>
      find.byKey(ValueKey<String>('translated-block-$id'));

  testWidgets('draws each region at the position its OCR box maps to', (
    tester,
  ) async {
    final top = region(
      id: 0,
      translated: 'नमस्ते',
      bounds: OcrRect.fromLTRB(100, 100, 400, 160),
    );
    final bottom = region(
      id: 1,
      translated: 'दुनिया',
      bounds: OcrRect.fromLTRB(100, 300, 500, 360),
    );

    await tester.pumpWidget(harness(overlayOf([top, bottom])));
    await tester.pump();

    expect(boxFinder(0), findsOneWidget);
    expect(boxFinder(1), findsOneWidget);
    expect(
      tester.getRect(boxFinder(0)),
      expectedBox(top.bounds, top.translatedText),
    );
    expect(
      tester.getRect(boxFinder(1)),
      expectedBox(bottom.bounds, bottom.translatedText),
    );
    // The lower region really is drawn lower down.
    expect(
      tester.getRect(boxFinder(1)).top,
      greaterThan(tester.getRect(boxFinder(0)).top),
    );
  });

  testWidgets('renders the translation, never the source text', (tester) async {
    await tester.pumpWidget(
      harness(
        overlayOf([
          region(
            id: 0,
            translated: 'नमस्ते दुनिया',
            bounds: OcrRect.fromLTRB(100, 100, 400, 160),
            source: 'Hello world',
          ),
        ]),
      ),
    );
    await tester.pump();

    expect(find.text('नमस्ते दुनिया'), findsOneWidget);
    expect(find.text('Hello world'), findsNothing);
  });

  testWidgets('skips regions without geometry', (tester) async {
    await tester.pumpWidget(
      harness(
        overlayOf([
          region(
            id: 0,
            translated: 'ठीक है',
            bounds: OcrRect.fromLTRB(100, 100, 400, 160),
          ),
          region(
            id: 1,
            translated: 'nowhere',
            bounds: const OcrRect(left: 10, top: 10, right: 10, bottom: 10),
          ),
        ]),
      ),
    );
    await tester.pump();

    expect(boxFinder(0), findsOneWidget);
    expect(boxFinder(1), findsNothing);
    expect(find.text('nowhere'), findsNothing);
  });

  testWidgets('skips regions whose translation came back empty', (
    tester,
  ) async {
    await tester.pumpWidget(
      harness(
        overlayOf([
          region(
            id: 0,
            translated: '   ',
            bounds: OcrRect.fromLTRB(100, 100, 400, 160),
          ),
        ]),
      ),
    );
    await tester.pump();

    expect(boxFinder(0), findsNothing);
    expect(find.byType(Text), findsNothing);
  });

  testWidgets('draws nothing at all for an empty overlay', (tester) async {
    await tester.pumpWidget(harness(overlayOf(const [])));
    await tester.pump();

    expect(find.byType(Text), findsNothing);
  });

  testWidgets('maps correctly through a letterboxed (non-square) viewport', (
    tester,
  ) async {
    // Square image in a 400x300 box: scale 0.3, displayed 300x300, dx 50.
    const viewport = Size(400, 300);
    final mapped = region(
      id: 0,
      translated: 'नमस्ते',
      bounds: OcrRect.fromLTRB(200, 200, 600, 260),
    );

    await tester.pumpWidget(harness(overlayOf([mapped]), size: viewport));
    await tester.pump();

    final rect = tester.getRect(boxFinder(0));
    expect(
      rect,
      expectedBox(mapped.bounds, mapped.translatedText, size: viewport),
    );

    // The letterbox band on the left (0..50) is never covered.
    final mapper = OcrCoordinateMapper(
      imageWidth: imageWidth,
      imageHeight: imageHeight,
      viewportSize: viewport,
    );
    final imageRect = mapper.displayedOffset & mapper.displayedSize;
    expect(rect.left, greaterThanOrEqualTo(imageRect.left - 0.01));
    expect(rect.right, lessThanOrEqualTo(imageRect.right + 0.01));
    expect(rect.bottom, lessThanOrEqualTo(imageRect.bottom + 0.01));
  });

  testWidgets('backings stay small — the photo is never covered by a panel', (
    tester,
  ) async {
    await tester.pumpWidget(
      harness(
        overlayOf([
          region(
            id: 0,
            translated: 'नमस्ते',
            bounds: OcrRect.fromLTRB(100, 100, 400, 160),
          ),
        ]),
      ),
    );
    await tester.pump();

    final rect = tester.getRect(boxFinder(0));
    expect(rect.height, lessThan(squareViewport.height / 2));
    expect(rect.width, lessThanOrEqualTo(squareViewport.width));
  });

  testWidgets('a dense page of translations never draws overlapping boxes', (
    tester,
  ) async {
    // Nine OCR lines 30px apart in a 1000px-tall image, each translated to text
    // far longer than its own line — the exact shape that used to produce a
    // pile of overlapping bubbles.
    final overlay = overlayOf([
      for (var i = 0; i < 9; i++)
        region(
          id: i,
          translated:
              'यह एक बहुत लंबा अनुवाद है जिसे छोटे क्षेत्र में समायोजित करना है',
          bounds: OcrRect.fromLTRB(100, 100 + i * 30, 420, 124 + i * 30),
        ),
    ]);

    await tester.pumpWidget(harness(overlay));
    await tester.pump();

    final rects = [for (var i = 0; i < 9; i++) tester.getRect(boxFinder(i))];

    for (var i = 0; i < rects.length; i++) {
      for (var j = i + 1; j < rects.length; j++) {
        expect(
          rects[i].intersect(rects[j]).isEmpty,
          isTrue,
          reason: 'drawn box $i (${rects[i]}) overlaps box $j (${rects[j]})',
        );
      }
      expect(rects[i].top, greaterThanOrEqualTo(0));
      expect(rects[i].bottom, lessThanOrEqualTo(squareViewport.height + 0.01));
    }
  });

  testWidgets('tapping a box reports the region drawn there', (tester) async {
    final tapped = <int>[];
    final top = region(
      id: 3,
      translated: 'नमस्ते',
      bounds: OcrRect.fromLTRB(100, 100, 400, 160),
    );
    final bottom = region(
      id: 8,
      translated: 'दुनिया',
      bounds: OcrRect.fromLTRB(100, 700, 400, 760),
    );

    await tester.pumpWidget(
      harness(
        overlayOf([top, bottom]),
        onRegionTap: (region) => tapped.add(region.id),
      ),
    );
    await tester.pump();

    await tester.tap(boxFinder(8));
    await tester.pump();
    await tester.tap(boxFinder(3));
    await tester.pump();

    expect(tapped, [8, 3]);

    // A tap that misses every box is not a region tap: the OCR gesture path
    // underneath still owns it.
    await tester.tapAt(
      tester.getRect(boxFinder(3)).center + const Offset(180, 0),
    );
    await tester.pump();
    expect(tapped, [8, 3]);
  });

  testWidgets('the backing is a tinted, rounded veil rather than a white block', (
    tester,
  ) async {
    await tester.pumpWidget(
      harness(
        overlayOf([
          region(
            id: 0,
            translated: 'नमस्ते',
            bounds: OcrRect.fromLTRB(100, 100, 400, 160),
          ),
        ]),
      ),
    );
    await tester.pump();

    // The backing belongs to the block.
    expect(blockFinder(0), findsOneWidget);

    // Subtle rounded corners, as specified.
    expect(TranslatedBlockPill.radius, 3);
    expect(
      tester
          .widget<ClipRRect>(
            find.descendant(
              of: blockFinder(0),
              matching: find.byType(ClipRRect),
            ),
          )
          .borderRadius,
      BorderRadius.circular(TranslatedBlockPill.radius),
    );

    final decorations = tester
        .widgetList<DecoratedBox>(
          find.descendant(
            of: blockFinder(0),
            matching: find.byType(DecoratedBox),
          ),
        )
        .toList();
    expect(decorations.length, 2);

    // Outer: the shadow lifts the box off the photo. It has to live outside the
    // clip, or ClipRRect would clip the blur away and leave it looking pasted.
    expect(
      (decorations.first.decoration as BoxDecoration).boxShadow,
      isNotEmpty,
    );

    // Inner: the veil that masks the words it replaces — translucent, and tinted
    // rather than paper-white, which is what made the old boxes glare.
    final veil = decorations.last.decoration as BoxDecoration;
    final color = veil.color!;
    // Still dense enough to mask the source words beneath it; the exact value is
    // asserted against the shared constant, so a future change has one home.
    expect(color.a, greaterThanOrEqualTo(0.9));
    expect(color.a, TranslatedBlockPill.backingAlpha);
    expect(color.a, lessThan(1.0));
    expect(color, isNot(const Color(0xFFFFFFFF)));

    // "Poor contrast" was the other half of the complaint, so it is measured
    // rather than eyeballed: the resolved text colour against the veil as it
    // actually appears, composited over a white page — the case where a light
    // backing has the least separation from dark text.
    final scheme = Theme.of(tester.element(boxFinder(0))).colorScheme;
    final asPainted = Color.alphaBlend(color, const Color(0xFFFFFFFF));
    expect(_contrast(scheme.onSurface, asPainted), greaterThanOrEqualTo(4.5));
  });

  testWidgets('a paragraph shares one backing instead of one per line', (
    tester,
  ) async {
    // Three lines of one paragraph: their boxes touch, in image space too.
    await tester.pumpWidget(
      harness(
        overlayOf([
          for (var i = 0; i < 3; i++)
            region(
              id: i,
              translated: 'नमस्ते',
              bounds: OcrRect.fromLTRB(100, 100 + i * 60, 400, 160 + i * 60),
            ),
        ]),
      ),
    );
    await tester.pump();

    // One pill behind all three lines — a paragraph, not three cards.
    expect(find.byType(TranslatedBlockPill), findsOneWidget);
    expect(blockFinder(0), findsOneWidget);

    // Each line is still its own slot, so it stays individually tappable.
    for (var i = 0; i < 3; i++) {
      expect(boxFinder(i), findsOneWidget);
    }

    // And the lines flow: each is exactly one lineSpacing below the last.
    final rects = [for (var i = 0; i < 3; i++) tester.getRect(boxFinder(i))];
    for (var i = 1; i < rects.length; i++) {
      expect(
        rects[i].top,
        closeTo(rects[i - 1].bottom + TranslatedOverlayDeck.lineSpacing, 0.01),
      );
    }
    for (var i = 1; i < rects.length; i++) {
      expect(rects[i].top, greaterThanOrEqualTo(rects[i - 1].bottom));
    }

    // The pill wraps exactly the flowed lines.
    final pill = tester.getRect(blockFinder(0));
    expect(pill.top, closeTo(rects.first.top, 0.01));
    expect(pill.bottom, closeTo(rects.last.bottom, 0.01));
  });

  testWidgets('the backing never absorbs a tap meant for the photo', (
    tester,
  ) async {
    // A tap on the pill *between* two lines must reach the OCR layer, or word
    // selection underneath would break whenever translation is on.
    await tester.pumpWidget(
      harness(
        overlayOf([
          for (var i = 0; i < 2; i++)
            region(
              id: i,
              translated: 'नमस्ते',
              bounds: OcrRect.fromLTRB(100, 100 + i * 60, 400, 160 + i * 60),
            ),
        ]),
      ),
    );
    await tester.pump();

    expect(
      find.descendant(of: blockFinder(0), matching: find.byType(IgnorePointer)),
      findsOneWidget,
    );
  });

  testWidgets('a long translation stays inside the image', (tester) async {
    await tester.pumpWidget(
      harness(
        overlayOf([
          region(
            id: 0,
            translated:
                'यह एक बहुत लंबा अनुवाद है जिसे छोटे क्षेत्र में समायोजित करना है',
            bounds: OcrRect.fromLTRB(200, 200, 300, 240),
          ),
        ]),
      ),
    );
    await tester.pump();

    final rect = tester.getRect(boxFinder(0));
    expect(rect.left, greaterThanOrEqualTo(0));
    expect(rect.top, greaterThanOrEqualTo(0));
    expect(rect.right, lessThanOrEqualTo(squareViewport.width + 0.01));
    expect(rect.bottom, lessThanOrEqualTo(squareViewport.height + 0.01));
  });
}
