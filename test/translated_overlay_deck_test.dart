import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdf_utility_flutter/translation/presentation/translated_overlay_deck.dart';
import 'package:pdf_utility_flutter/translation/presentation/translated_text_layout.dart';

/// A page-sized area, in the screen space the overlay actually works in (the
/// mapper has already been applied by the time the deck sees anything).
const image = Rect.fromLTWH(0, 0, 1000, 1000);
const style = TextStyle(fontSize: 14);

/// A translated line about as long as a real one.
const short = 'नमस्ते दुनिया';
const long =
    'यह एक बहुत लंबा अनुवाद है जिसे अपनी पंक्ति के भीतर ही समायोजित करना है';

void main() {
  // TextPainter needs the binding (and its fixed-width test font, which makes
  // every measurement below deterministic).
  TestWidgetsFlutterBinding.ensureInitialized();

  TranslatedDeckItem item(int id, String text, Rect source) =>
      TranslatedDeckItem(id: id, text: text, sourceRect: source);

  List<TranslatedDeckPlacement> build(
    List<TranslatedDeckItem> items, {
    Rect imageRect = image,
  }) => TranslatedOverlayDeck.build(
    items: items,
    imageRect: imageRect,
    style: style,
  );

  List<TranslatedBlockPlacement> buildBlocks(
    List<TranslatedDeckItem> items, {
    Rect imageRect = image,
  }) => TranslatedOverlayDeck.buildBlocks(
    items: items,
    imageRect: imageRect,
    style: style,
  );

  /// The veil of every block must hide the source lines it translates, without
  /// hiding anything that was not translated.
  void expectCoverage(List<TranslatedBlockPlacement> blocks, Rect imageRect) {
    for (final block in blocks) {
      expect(
        block.coverage.intersect(imageRect).width,
        closeTo(block.coverage.width, 0.01),
        reason: 'block ${block.id} coverage leaves the photo horizontally',
      );
      expect(
        block.coverage.intersect(imageRect).height,
        closeTo(block.coverage.height, 0.01),
        reason: 'block ${block.id} coverage leaves the photo vertically',
      );
      for (final line in block.lines) {
        // The source rectangle is covered, so the Hindi it replaces cannot show
        // beside a shorter English translation...
        expect(
          block.coverage.inflate(0.01).contains(line.sourceRect.topLeft) &&
              block.coverage
                  .inflate(0.01)
                  .contains(line.sourceRect.bottomRight),
          isTrue,
          reason:
              'block ${block.id} veil ${block.coverage} does not cover its '
              'source ${line.sourceRect}',
        );
      }
    }
    // ...and no block's veil may cover another block's text.
    for (final block in blocks) {
      for (final other in blocks) {
        if (identical(block, other)) continue;
        for (final line in other.lines) {
          expect(
            line.box.deflate(0.01).overlaps(block.coverage),
            isFalse,
            reason:
                'block ${block.id} veil ${block.coverage} covers block '
                '${other.id}\'s text ${line.box}',
          );
        }
      }
    }
  }

  /// Blocks must not cover each other either: a backing that swallowed the next
  /// paragraph would be the same defect as the overlapping bubbles, only bigger.
  void expectNoBlockOverlap(List<TranslatedBlockPlacement> blocks) {
    for (var i = 0; i < blocks.length; i++) {
      for (var j = i + 1; j < blocks.length; j++) {
        expect(
          blocks[i].box.intersect(blocks[j].box).isEmpty,
          isTrue,
          reason:
              'block $i (${blocks[i].box}) overlaps '
              'block $j (${blocks[j].box})',
        );
      }
    }
  }

  /// The standalone result for one region — what the deck must reproduce when
  /// nothing is in the region's way.
  Rect standalone(String text, Rect source, {Rect imageRect = image}) =>
      TranslatedTextLayout.fit(
        text: text,
        sourceRect: source,
        imageRect: imageRect,
        style: style,
      ).box;

  /// The whole point of the deck: **no two translated boxes may intersect**.
  void expectNoOverlap(List<TranslatedDeckPlacement> placements) {
    for (var i = 0; i < placements.length; i++) {
      for (var j = i + 1; j < placements.length; j++) {
        expect(
          placements[i].box.intersect(placements[j].box).isEmpty,
          isTrue,
          reason:
              'box $i (${placements[i].box}) overlaps '
              'box $j (${placements[j].box})',
        );
      }
    }
  }

  void expectInside(
    List<TranslatedDeckPlacement> placements, {
    Rect imageRect = image,
  }) {
    for (final placement in placements) {
      expect(placement.box.left, greaterThanOrEqualTo(imageRect.left - 0.01));
      expect(placement.box.top, greaterThanOrEqualTo(imageRect.top - 0.01));
      expect(placement.box.right, lessThanOrEqualTo(imageRect.right + 0.01));
      expect(placement.box.bottom, lessThanOrEqualTo(imageRect.bottom + 0.01));
      expect(placement.box.width, greaterThan(0));
      expect(placement.box.height, greaterThan(0));
    }
  }

  /// A realistic page: [count] OCR lines of uniform [height] on a [pitch] of
  /// vertical rhythm — i.e. lines that nearly touch, which is what produced the
  /// overlapping bubbles.
  List<TranslatedDeckItem> lines(
    int count, {
    String text = short,
    double height = 24,
    double pitch = 30,
    double top = 100,
    double left = 100,
    double width = 300,
  }) => [
    for (var i = 0; i < count; i++)
      item(i, text, Rect.fromLTWH(left, top + i * pitch, width, height)),
  ];

  group('degenerate input', () {
    test('no regions yields no placements', () {
      expect(build(const []), isEmpty);
    });

    test('an empty image rect yields no placements', () {
      expect(build(lines(3), imageRect: Rect.zero), isEmpty);
    });

    test('blank text and empty boxes are dropped, not drawn', () {
      final placements = build([
        item(0, '   ', const Rect.fromLTWH(100, 100, 300, 24)),
        item(1, short, const Rect.fromLTWH(100, 200, 0, 0)),
        item(2, short, const Rect.fromLTWH(100, 300, 300, 24)),
      ]);

      expect(placements.map((p) => p.id), [2]);
    });
  });

  group('no conflict to resolve', () {
    test('a single region lands exactly where the standalone fit puts it', () {
      const source = Rect.fromLTWH(100, 100, 300, 24);
      final placements = build([item(0, short, source)]);

      expect(placements.single.box, standalone(short, source));
      expect(placements.single.constrained, isFalse);
    });

    test('lines far enough apart are all left alone', () {
      final items = lines(4, pitch: 120);
      final placements = build(items);

      expect(placements.length, 4);
      for (final placement in placements) {
        expect(placement.box, standalone(placement.text, placement.sourceRect));
        expect(placement.constrained, isFalse);
      }
      expectNoOverlap(placements);
    });

    test('side-by-side regions in two columns are not pushed apart', () {
      // Same rows, different columns: they cannot collide, so the deck must not
      // treat them as being in each other's way.
      const left = Rect.fromLTWH(40, 100, 200, 24);
      const right = Rect.fromLTWH(560, 100, 200, 24);
      final placements = build([item(0, long, left), item(1, long, right)]);

      // Neither was displaced by the other: both keep their own anchor row, are
      // reported unconstrained, and still cover the line they translate. (The
      // boxes may be *taller* than the standalone fit — a single-line block is
      // allowed to grow so its translation stays whole.)
      expect(placements[0].box.top, closeTo(placements[1].box.top, 0.01));
      for (final (index, source) in [left, right].indexed) {
        expect(placements[index].box.top, lessThanOrEqualTo(source.top + 0.01));
        expect(
          placements[index].box.bottom,
          greaterThanOrEqualTo(source.bottom - 0.01),
        );
        expect(placements[index].constrained, isFalse);
      }
      expectNoOverlap(placements);
    });
  });

  group('a dense page', () {
    test('twenty tightly stacked lines never overlap', () {
      final placements = build(lines(20, text: long));

      expect(placements.length, 20);
      expectNoOverlap(placements);
      expectInside(placements);
    });

    // Replaces the old rule "every line stays inside the gap to the line below
    // it". That rule is what a paragraph-long translation could not survive: it
    // flattened the text into a fraction of a line height and truncated it. The
    // block flow is the deliberate replacement — a long line pushes its own
    // paragraph down instead of being cut to fit one line.
    test(
      'a long line reflows its paragraph rather than covering the next line',
      () {
        const first = Rect.fromLTWH(100, 100, 300, 24);
        const second = Rect.fromLTWH(100, 124, 300, 24);
        final blocks = buildBlocks([
          item(0, long, first),
          item(1, short, second),
        ]);

        // The two lines are one paragraph, so they flow.
        expect(blocks.length, 1);
        final flowed = blocks.single.lines;
        expect(flowed.length, 2);

        // The second line is pushed below the first, never drawn on top of it…
        expect(
          flowed[1].box.top,
          greaterThanOrEqualTo(
            flowed[0].box.bottom + TranslatedOverlayDeck.lineSpacing - 0.01,
          ),
        );
        // …which means the long translation was allowed to take more room than the
        // single line it replaced.
        expect(flowed[0].box.height, greaterThan(first.height));
        expectNoBlockOverlap(blocks);
      },
    );

    test('every line sits one lineSpacing below the line before it', () {
      final blocks = buildBlocks(lines(5, text: short));
      expect(blocks.length, 1);

      final flowed = blocks.single.lines;
      expect(flowed.length, 5);
      for (var i = 1; i < flowed.length; i++) {
        expect(
          flowed[i].box.top,
          closeTo(
            flowed[i - 1].box.bottom + TranslatedOverlayDeck.lineSpacing,
            0.01,
          ),
          reason: 'line $i does not follow the flow formula',
        );
      }

      // The unified backing wraps exactly its own lines.
      expect(blocks.single.box.top, closeTo(flowed.first.box.top, 0.01));
      expect(blocks.single.box.bottom, closeTo(flowed.last.box.bottom, 0.01));
    });

    test('a block never intrudes into the block below it', () {
      final items = <TranslatedDeckItem>[
        ...lines(4, text: long),
        item(9, short, const Rect.fromLTWH(100, 400, 300, 24)),
      ];
      final blocks = buildBlocks(items);

      expect(blocks.length, 2);
      expect(
        blocks.first.box.bottom,
        lessThanOrEqualTo(400 - TranslatedOverlayDeck.gap + 0.01),
      );
      expectNoBlockOverlap(blocks);
      expectInside(blocks.expand((block) => block.lines).toList());
    });

    test('a paragraph that does not fit shrinks instead of losing lines', () {
      final items = <TranslatedDeckItem>[
        ...lines(4, text: long),
        item(9, short, const Rect.fromLTWH(100, 400, 300, 24)),
      ];
      final blocks = buildBlocks(items);

      // Every line of the paragraph is still drawn, and the paragraph had to
      // adapt to its room to manage that.
      expect(blocks.first.lines.length, 4);
      expect(blocks.first.constrained, isTrue);
      for (final line in blocks.first.lines) {
        expect(
          line.layout.style.fontSize!,
          greaterThanOrEqualTo(TranslatedTextLayout.defaultMinSize),
        );
        expect(line.layout.maxLines, greaterThanOrEqualTo(1));
      }
    });

    test(
      'an impossibly dense page squeezes every line rather than losing any',
      () {
        // Sixty overlapping lines with long translations: no size can give each
        // line its natural height, so each gets an equal slice instead. Losing a
        // translation the user asked for is worse than showing it clipped.
        final items = lines(60, text: long, pitch: 14);
        final blocks = buildBlocks(items);
        final placed = [for (final block in blocks) ...block.lines];

        expect(placed.length, 60);
        expectNoOverlap(placed);
        expectInside(placed);
        expectNoBlockOverlap(blocks);
      },
    );

    test(
      'only a page with no room at all drops the tail, and never overlaps',
      () {
        // Four hundred lines two pixels apart: there is not even a minimal slice
        // for each of them, so what fits is drawn and the rest is left undrawn
        // rather than piled on top of the surviving lines.
        final items = lines(400, text: long, pitch: 2);
        final blocks = buildBlocks(items);
        final placed = [for (final block in blocks) ...block.lines];

        expect(placed.length, lessThan(400));
        expect(placed, isNotEmpty);
        expectNoOverlap(placed);
        expectInside(placed);
        expectNoBlockOverlap(blocks);
      },
    );
  });

  group('block grouping', () {
    test('adjacent lines are one block, separate paragraphs are not', () {
      final blocks = buildBlocks([
        // A heading, then a gap wider than its own height…
        item(0, short, const Rect.fromLTWH(100, 100, 300, 30)),
        // …then two body lines that touch.
        item(1, short, const Rect.fromLTWH(100, 160, 300, 24)),
        item(2, short, const Rect.fromLTWH(100, 190, 300, 24)),
      ]);

      expect(blocks.length, 2);
      expect(blocks.first.lines.length, 1);
      expect(blocks.last.lines.length, 2);
      // Reading order is preserved: the heading's block comes first.
      expect(blocks.first.lines.single.id, 0);
      expect(blocks.last.regionIds, [1, 2]);
    });

    test('two columns are two blocks, and neither shortens the other', () {
      // Rows alternate between the columns in reading order, which is exactly
      // the case a naive "group with the previous item" rule gets wrong.
      final items = <TranslatedDeckItem>[
        for (var row = 0; row < 3; row++) ...[
          item(row * 2, long, Rect.fromLTWH(60, 100 + row * 30, 300, 24)),
          item(row * 2 + 1, long, Rect.fromLTWH(560, 100 + row * 30, 300, 24)),
        ],
      ];
      final blocks = buildBlocks(items);

      expect(blocks.length, 2);
      final left = blocks.firstWhere((block) => block.box.left < 300);
      final right = blocks.firstWhere((block) => block.box.left >= 300);
      expect(left.lines.length, 3);
      expect(right.lines.length, 3);

      // Side-by-side blocks share no columns, so neither may have been squeezed
      // into the other's leftover room.
      for (final line in [...left.lines, ...right.lines]) {
        expect(
          line.box.height,
          greaterThan(TranslatedOverlayDeck.minBoxHeight),
        );
      }
      expectNoBlockOverlap(blocks);
    });
  });

  group('geometry that cannot be satisfied', () {
    test('two regions on the same rectangle are stacked, not overlaid', () {
      const source = Rect.fromLTWH(100, 100, 300, 24);
      final placements = build([
        item(0, short, source),
        item(1, short, source),
      ]);

      expect(placements.length, 2);
      expect(placements[0].box, standalone(short, source));
      expect(
        placements[1].box.top,
        greaterThanOrEqualTo(
          placements[0].box.bottom + TranslatedOverlayDeck.gap - 0.01,
        ),
      );
      expect(placements[1].constrained, isTrue);
      expectNoOverlap(placements);
    });

    test('every veil covers its own source lines and nothing else', () {
      final blocks = buildBlocks([
        // Single source lines, with a paragraph-sized gap between them, so the
        // deck sees two paragraphs rather than one tall block.
        item(
          0,
          'First paragraph translated',
          const Rect.fromLTWH(100, 100, 700, 20),
        ),
        item(1, 'Second paragraph', const Rect.fromLTWH(100, 180, 700, 20)),
        item(2, 'Right column', const Rect.fromLTWH(820, 100, 160, 140)),
      ]);

      expect(blocks.length, 3);
      expectCoverage(blocks, image);
    });

    test('a region at the bottom edge stays inside the image', () {
      final placements = build(lines(3, top: 900, pitch: 30));

      expectNoOverlap(placements);
      expectInside(placements);
    });

    test('regions in reverse order come back in reading order', () {
      const first = Rect.fromLTWH(100, 100, 300, 24);
      const second = Rect.fromLTWH(100, 200, 300, 24);
      const third = Rect.fromLTWH(100, 300, 300, 24);

      final placements = build([
        item(7, short, third),
        item(5, short, first),
        item(6, short, second),
      ]);

      expect(placements.map((p) => p.id), [5, 6, 7]);
      expect(placements[0].box.top, lessThan(placements[1].box.top));
      expect(placements[1].box.top, lessThan(placements[2].box.top));
    });
  });

  group('degenerate geometry the deck must survive', () {
    test('overlapping source boxes still produce a clean page', () {
      // Real OCR output occasionally hands back boxes that overlap each other.
      final placements = build([
        item(0, long, const Rect.fromLTWH(100, 100, 300, 40)),
        item(1, long, const Rect.fromLTWH(120, 110, 300, 40)),
        item(2, long, const Rect.fromLTWH(140, 120, 300, 40)),
      ]);

      expectNoOverlap(placements);
      expectInside(placements);
    });

    test('a very tall selection box does not swallow the page', () {
      final placements = build([
        item(0, long, const Rect.fromLTWH(100, 100, 300, 300)),
        item(1, short, const Rect.fromLTWH(100, 200, 300, 24)),
      ]);

      expectNoOverlap(placements);
      expectInside(placements);
    });
  });
}
