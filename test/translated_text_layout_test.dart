import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdf_utility_flutter/translation/presentation/translated_text_layout.dart';

void main() {
  // TextPainter needs the Flutter test binding (and its fixed-width test font,
  // which makes the measurements below deterministic).
  TestWidgetsFlutterBinding.ensureInitialized();

  const style = TextStyle(fontSize: 14);
  const image = Rect.fromLTWH(0, 0, 400, 400);

  TranslatedTextLayout fit(
    String text,
    Rect source, {
    Rect imageRect = image,
    TextScaler scaler = TextScaler.noScaling,
  }) => TranslatedTextLayout.fit(
    text: text,
    sourceRect: source,
    imageRect: imageRect,
    style: style,
    textScaler: scaler,
  );

  group('degenerate input', () {
    test('empty or blank text yields an empty box', () {
      expect(fit('', const Rect.fromLTWH(20, 20, 200, 20)).box, Rect.zero);
      expect(fit('   ', const Rect.fromLTWH(20, 20, 200, 20)).box, Rect.zero);
    });

    test('an empty source rectangle yields an empty box', () {
      expect(fit('Hello', const Rect.fromLTWH(20, 20, 0, 0)).box, Rect.zero);
    });

    test('an empty image rectangle yields an empty box', () {
      expect(
        fit(
          'Hello',
          const Rect.fromLTWH(20, 20, 200, 20),
          imageRect: Rect.zero,
        ).box,
        Rect.zero,
      );
    });
  });

  group('font sizing', () {
    const region = Rect.fromLTWH(20, 20, 200, 20);

    test('short text keeps the largest size and is not clipped', () {
      final layout = fit('Hello', region);
      expect(layout.style.fontSize, TranslatedTextLayout.defaultMaxSize);
      expect(layout.shrunk, isFalse);
      expect(layout.ellipsized, isFalse);
    });

    test('longer text shrinks to fit the same region', () {
      final short = fit('Hello', region);
      final longer = fit('Hello world again and again', region);

      expect(longer.shrunk, isTrue);
      expect(longer.style.fontSize!, lessThan(short.style.fontSize!));
      expect(longer.ellipsized, isFalse);
      // Still legible: never below the minimum.
      expect(
        longer.style.fontSize!,
        greaterThanOrEqualTo(TranslatedTextLayout.defaultMinSize),
      );
    });

    test('a taller region allows a larger font for the same text', () {
      final flat = fit(
        'Hello world again and again',
        const Rect.fromLTWH(20, 20, 200, 12),
      );
      final tall = fit(
        'Hello world again and again',
        const Rect.fromLTWH(20, 20, 200, 60),
      );

      expect(tall.style.fontSize!, greaterThanOrEqualTo(flat.style.fontSize!));
    });

    test(
      'overwhelming text is clamped and ellipsized instead of overflowing',
      () {
        final huge = fit('word ' * 200, region);

        expect(huge.style.fontSize, TranslatedTextLayout.defaultMinSize);
        expect(huge.ellipsized, isTrue);
        expect(
          huge.maxLines,
          lessThanOrEqualTo(TranslatedTextLayout.defaultLineCap),
        );
        expect(huge.maxLines, greaterThanOrEqualTo(1));
      },
    );

    test('the resolved style carries the line height used for measuring', () {
      expect(
        fit('Hello', region).style.height,
        TranslatedTextLayout.lineHeightFactor,
      );
    });

    test('a heading-sized region gets bigger text than an ordinary line', () {
      // Same short text, very different displayed regions. The ceiling follows
      // the region's height, so a big box is not stuck at body size...
      final line = fit('Hi', const Rect.fromLTWH(20, 20, 200, 20));
      final heading = fit('Hi', const Rect.fromLTWH(20, 20, 200, 80));

      expect(line.style.fontSize, TranslatedTextLayout.defaultMaxSize);
      expect(
        heading.style.fontSize!,
        greaterThan(TranslatedTextLayout.defaultMaxSize),
      );
      // ...but never past the legibility cap.
      expect(
        heading.style.fontSize!,
        lessThanOrEqualTo(TranslatedTextLayout.hardMaxSize),
      );
      // And it is still text inside the box it was measured against.
      expect(heading.ellipsized, isFalse);
    });

    test('the derived ceiling never falls below the caller\'s maximum', () {
      // A short region keeps exactly the ceiling it was given, which is what
      // leaves ordinary pages reading as they did before.
      expect(
        TranslatedTextLayout.effectiveMaxSize(sourceHeight: 4, maxSize: 17),
        17,
      );
      // A caller asking for more than the cap is not silently reduced.
      expect(
        TranslatedTextLayout.effectiveMaxSize(sourceHeight: 10, maxSize: 60),
        60,
      );
      // A tall region is raised, up to the cap.
      expect(
        TranslatedTextLayout.effectiveMaxSize(sourceHeight: 1000, maxSize: 17),
        TranslatedTextLayout.hardMaxSize,
      );
    });

    test('a larger accessibility text scale never increases the font', () {
      final normal = fit('Hello world again and again', region);
      final scaled = fit(
        'Hello world again and again',
        region,
        scaler: const TextScaler.linear(2),
      );

      expect(scaled.style.fontSize!, lessThanOrEqualTo(normal.style.fontSize!));
    });
  });

  group('box geometry', () {
    test('covers the source region so the original words are replaced', () {
      const region = Rect.fromLTWH(20, 20, 200, 20);
      final layout = fit('Hello', region);

      expect(layout.box.height, greaterThanOrEqualTo(region.height));
      expect(layout.box.top, lessThanOrEqualTo(region.top));
      expect(layout.box.bottom, greaterThanOrEqualTo(region.bottom));
      expect(layout.box.center.dx, closeTo(region.center.dx, 0.01));
    });

    test('a tiny region widens to the minimum usable width', () {
      const tiny = Rect.fromLTWH(100, 100, 12, 10);
      final layout = fit('Hello', tiny);

      expect(
        layout.box.width,
        greaterThanOrEqualTo(TranslatedTextLayout.defaultMinWidth),
      );
      expect(layout.box.center.dx, closeTo(tiny.center.dx, 0.01));
    });

    test('never escapes the displayed image', () {
      const regions = <Rect>[
        Rect.fromLTWH(0, 0, 50, 12),
        Rect.fromLTWH(380, 0, 20, 12),
        Rect.fromLTWH(380, 388, 20, 12),
        Rect.fromLTWH(0, 395, 400, 5),
      ];

      for (final region in regions) {
        final box = fit('Hello world again', region).box;
        expect(box.left, greaterThanOrEqualTo(image.left - 0.01));
        expect(box.top, greaterThanOrEqualTo(image.top - 0.01));
        expect(box.right, lessThanOrEqualTo(image.right + 0.01));
        expect(box.bottom, lessThanOrEqualTo(image.bottom + 0.01));
        expect(box.width, greaterThan(0));
        expect(box.height, greaterThan(0));
      }
    });

    test('respects the displayed image rect when the photo is letterboxed', () {
      const imageRect = Rect.fromLTWH(100, 50, 200, 200);
      const region = Rect.fromLTWH(290, 60, 8, 10); // hugging the right edge

      final box = fit('Hello world', region, imageRect: imageRect).box;

      expect(box.right, lessThanOrEqualTo(imageRect.right + 0.01));
      expect(box.left, greaterThanOrEqualTo(imageRect.left - 0.01));
      expect(box.top, greaterThanOrEqualTo(imageRect.top - 0.01));
      expect(box.bottom, lessThanOrEqualTo(imageRect.bottom + 0.01));
    });

    test('does not grow taller than the growth cap', () {
      const region = Rect.fromLTWH(20, 20, 200, 20);
      final layout = fit('Hello', region);

      expect(
        layout.box.height,
        lessThanOrEqualTo(
          region.height * TranslatedTextLayout.defaultHeightGrowth +
              TranslatedTextLayout.insetYFor(region.height) * 2 +
              0.01,
        ),
      );
    });

    test('a longer translation grows the box downwards, not sideways', () {
      const region = Rect.fromLTWH(20, 20, 200, 20);
      final short = fit('Hello', region);
      final long = fit('Hello world again and again', region);

      expect(long.box.height, greaterThan(short.box.height));
      expect(long.box.width, short.box.width);
    });

    test('padding is tight horizontally and proportional vertically', () {
      // Horizontal padding is constant and small: inside a text column, width is
      // the scarce resource, so growing it would either push the box over a
      // neighbouring column or steal width from the text.
      expect(TranslatedTextLayout.horizontalPadding, 3);

      // Vertical padding scales, but stays inside its bounds.
      expect(
        TranslatedTextLayout.insetYFor(10),
        TranslatedTextLayout.verticalPadding,
      );
      expect(
        TranslatedTextLayout.insetYFor(1000),
        TranslatedTextLayout.maxVerticalPadding,
      );

      const line = Rect.fromLTWH(20, 20, 200, 20);
      const tall = Rect.fromLTWH(20, 20, 200, 200);
      final small = fit('Hello', line);
      final big = fit('Hello', tall);

      for (final layout in [small, big]) {
        expect(layout.insetX, TranslatedTextLayout.horizontalPadding);
      }
      expect(small.insetY, TranslatedTextLayout.verticalPadding);
      expect(big.insetY, greaterThan(small.insetY));
      expect(
        big.insetY,
        lessThanOrEqualTo(TranslatedTextLayout.maxVerticalPadding),
      );
      // The reported insets are the ones the geometry used, so the widget
      // painting the text can never pad against a different number than the fit
      // was measured with.
      expect(small.insetY, TranslatedTextLayout.insetYFor(line.height));
      expect(big.insetY, TranslatedTextLayout.insetYFor(tall.height));
    });
  });

  // The headline promise of the whole layout — that translated text stays
  // strictly within its own box — was only checked case by case. This sweeps
  // the geometry space instead, and measures the text the same way the widget
  // will paint it.
  group('containment across many geometries', () {
    const texts = <String>[
      'Hello',
      'Hello world again and again',
      'यह एक बहुत लंबा अनुवाद है जिसे छोटे क्षेत्र में समायोजित करना है',
      'short',
    ];
    const widths = <double>[10, 40, 120, 300, 380];
    const heights = <double>[8, 12, 20, 40, 90, 200];

    test('text always fits inside the box, which always fits the photo', () {
      for (final text in texts) {
        for (final width in widths) {
          for (final height in heights) {
            final region = Rect.fromLTWH(20, 20, width, height);
            final layout = fit(text, region);
            if (layout.box.isEmpty) continue;

            // 1. Never leaves the displayed photo.
            expect(layout.box.left, greaterThanOrEqualTo(image.left - 0.01));
            expect(layout.box.top, greaterThanOrEqualTo(image.top - 0.01));
            expect(layout.box.right, lessThanOrEqualTo(image.right + 0.01));
            expect(layout.box.bottom, lessThanOrEqualTo(image.bottom + 0.01));

            // 2. The font stays inside the supported range.
            expect(
              layout.style.fontSize!,
              greaterThanOrEqualTo(TranslatedTextLayout.defaultMinSize - 0.01),
            );
            expect(
              layout.style.fontSize!,
              lessThanOrEqualTo(TranslatedTextLayout.hardMaxSize + 0.01),
            );

            // 3. The text fits the content area it will be painted into.
            final painter = TextPainter(
              text: TextSpan(text: text, style: layout.style),
              textDirection: TextDirection.ltr,
              maxLines: layout.maxLines,
              ellipsis: '…',
            )..layout(maxWidth: layout.box.width - layout.insetX * 2);
            final contentHeight = layout.box.height - layout.insetY * 2;
            expect(
              painter.height,
              lessThanOrEqualTo(contentHeight + 0.5),
              reason:
                  'text "$text" in $region painted ${painter.height} into '
                  '$contentHeight of content height',
            );
            painter.dispose();
          }
        }
      }
    });
  });
}
