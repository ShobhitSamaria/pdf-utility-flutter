import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdf_utility_flutter/pdf/domain/pdf_text_layer.dart';
import 'package:pdf_utility_flutter/pdf/presentation/widgets/searchable_pdf_page.dart';

/// The smallest valid PNG, so the widget test never needs a real page render.
final Uint8List _onePixelPng = Uint8List.fromList(const <int>[
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, //
  0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52, //
  0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01, //
  0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4, //
  0x89, 0x00, 0x00, 0x00, 0x0A, 0x49, 0x44, 0x41, //
  0x54, 0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00, //
  0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00, //
  0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE, //
  0x42, 0x60, 0x82,
]);

const _matchKey = ValueKey('searchable-pdf-highlight');

Widget _harness({
  required Size pageSize,
  required Size viewport,
  PdfTextBounds? highlight,
}) => MaterialApp(
  home: Scaffold(
    body: Center(
      child: SizedBox(
        width: viewport.width,
        height: viewport.height,
        child: SearchablePdfPage(
          image: MemoryImage(_onePixelPng),
          pageSize: pageSize,
          highlight: highlight,
        ),
      ),
    ),
  ),
);

void main() {
  testWidgets('draws the highlight at the word, in page coordinates', (
    tester,
  ) async {
    await tester.pumpWidget(
      _harness(
        pageSize: const Size(400, 300),
        viewport: const Size(400, 300),
        highlight: const PdfTextBounds(
          left: 0.25,
          top: 0.5,
          right: 0.75,
          bottom: 0.75,
        ),
      ),
    );
    await tester.pump();

    final highlight = tester.widget<Positioned>(find.byKey(_matchKey));

    // The page is 400 × 300, so the fractions are absolute page pixels. The
    // 2 pt inflate is applied in the same space.
    expect(highlight.left, 98);
    expect(highlight.top, 148);
    expect(highlight.width, 204);
    expect(highlight.height, 79);
  });

  testWidgets('a landscape page keeps its own aspect and its own box', (
    tester,
  ) async {
    await tester.pumpWidget(
      _harness(
        pageSize: const Size(300, 200),
        viewport: const Size(300, 200),
        highlight: const PdfTextBounds(
          left: 0.1,
          top: 0.2,
          right: 0.5,
          bottom: 0.6,
        ),
      ),
    );
    await tester.pump();

    final image = tester.getSize(find.byType(Image));
    expect(image, const Size(300, 200));

    final highlight = tester.widget<Positioned>(find.byKey(_matchKey));
    expect(highlight.left, 28); // 0.1 * 300 - 2
    expect(highlight.top, 38); // 0.2 * 200 - 2
    expect(highlight.width, 124); // 0.4 * 300 + 4
    expect(highlight.height, 84); // 0.4 * 200 + 4
  });

  testWidgets('no match means no box, but the page is still drawn', (
    tester,
  ) async {
    await tester.pumpWidget(
      _harness(
        pageSize: const Size(400, 300),
        viewport: const Size(400, 300),
      ),
    );
    await tester.pump();

    expect(find.byType(Image), findsOneWidget);
    expect(find.byKey(_matchKey), findsNothing);
  });

  testWidgets('a page with no size draws nothing rather than dividing by zero', (
    tester,
  ) async {
    await tester.pumpWidget(
      _harness(
        pageSize: Size.zero,
        viewport: const Size(200, 200),
        highlight: const PdfTextBounds(left: 0, top: 0, right: 1, bottom: 1),
      ),
    );
    await tester.pump();

    expect(find.byType(Image), findsNothing);
    expect(find.byKey(_matchKey), findsNothing);
  });

  testWidgets('the highlight is painted above the page image', (tester) async {
    await tester.pumpWidget(
      _harness(
        pageSize: const Size(200, 200),
        viewport: const Size(200, 200),
        highlight: const PdfTextBounds(
          left: 0.2,
          top: 0.2,
          right: 0.6,
          bottom: 0.4,
        ),
      ),
    );
    await tester.pump();

    final stack = tester.widget<Stack>(
      find.ancestor(of: find.byKey(_matchKey), matching: find.byType(Stack)).first,
    );
    expect(stack.children, hasLength(2));
    expect(stack.children.first, isA<Image>());
    expect(stack.children.last, isA<Positioned>());
    expect((stack.children.last as Positioned).key, _matchKey);
  });
}
