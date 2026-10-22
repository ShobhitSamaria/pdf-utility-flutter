import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdf_utility_flutter/pdf/domain/pdf_creation.dart';
import 'package:pdf_utility_flutter/pdf/domain/pdf_document_info.dart';
import 'package:pdf_utility_flutter/pdf/domain/pdf_exception.dart';
import 'package:pdf_utility_flutter/pdf/domain/pdf_page_draft.dart';
import 'package:pdf_utility_flutter/pdf/domain/pdf_page_raster.dart';
import 'package:pdf_utility_flutter/pdf/domain/pdf_page_renderer.dart';
import 'package:pdf_utility_flutter/pdf/domain/rendered_pdf_page.dart';
import 'package:pdf_utility_flutter/pdf/presentation/pdf_page_selection_screen.dart';

import 'support/pdf_test_images.dart';

/// A renderer that answers with prepared image files instead of rasterising.
///
/// It decides which file to answer with from the raster policy it was built
/// with, so a test can prove that the grid asked for **thumbnails** and the
/// document asked for **reading-quality** pages — the one distinction that
/// keeps a grid of a 300-page file affordable.
class _FakeRenderer implements PdfPageRenderer {
  _FakeRenderer({
    required this.pageCount,
    required this.directory,
    required this.rasterFor,
    this.failPages = const <int>{},
    this.failOpen = false,
    this.rasterError,
  });

  final int pageCount;
  final String directory;
  final PdfPageRaster Function(double pageWidth, double pageHeight) rasterFor;

  /// Pages this renderer refuses to render, as a real PDF can.
  final Set<int> failPages;

  /// Whether opening the document fails at all.
  final bool failOpen;

  /// When set, rendering throws this — used to prove the assembly step reports
  /// a failure rather than creating a short document.
  final PdfException? rasterError;

  /// Whether the page images this renderer produces are the small ones.
  bool get isThumbnailQuality => rasterFor(600, 800).width < 1000;

  final List<int> rendered = <int>[];

  @override
  String get engineName => 'Fake';

  @override
  Future<PdfDocumentInfo> open(String path) async {
    if (failOpen) {
      throw const PdfException(
        PdfErrorKind.unreadable,
        'That file could not be opened. It may be damaged or not a PDF.',
      );
    }
    return PdfDocumentInfo(
      path: path,
      title: 'imported.pdf',
      pageCount: pageCount,
    );
  }

  @override
  Future<RenderedPdfPage> renderPage(int pageNumber) async {
    final error = rasterError;
    if (error != null) throw error;
    if (failPages.contains(pageNumber)) {
      throw const PdfException(
        PdfErrorKind.renderFailure,
        'That page could not be prepared for reading.',
      );
    }
    rendered.add(pageNumber);

    final raster = rasterFor(600, 800);
    final prefix = isThumbnailQuality ? 'thumb' : 'full';
    return RenderedPdfPage(
      pageNumber: pageNumber,
      imagePath: '$directory/${prefix}_$pageNumber.png',
      width: raster.width,
      height: raster.height,
    );
  }

  @override
  Future<void> close() async {}
}

void main() {
  late Directory root;
  late List<_FakeRenderer> created;

  /// Writes one thumbnail and one reading-quality image per page, so the two
  /// requests are distinguishable by path.
  Future<void> writeFixtures({int pages = 3}) async {
    for (var page = 1; page <= pages; page++) {
      await writeTestPng(
        directory: root,
        name: 'thumb_$page.png',
        width: 120,
        height: 160,
      );
      await writeTestPng(
        directory: root,
        name: 'full_$page.png',
        width: 240,
        height: 320,
      );
    }
  }

  setUp(() async {
    root = await Directory.systemTemp.createTemp('pdf_selection_test');
    await writeFixtures();
    created = <_FakeRenderer>[];
  });

  tearDown(() async {
    if (root.existsSync()) await root.delete(recursive: true);
  });

  PdfRendererFactory factory({
    int pages = 3,
    Set<int> failPages = const <int>{},
    bool failOpen = false,
  }) => (rasterFor) {
    final renderer = _FakeRenderer(
      pageCount: pages,
      directory: root.path,
      rasterFor: rasterFor,
      failPages: failPages,
      failOpen: failOpen,
    );
    created.add(renderer);
    return renderer;
  };

  /// Opens the selection screen as a pushed route, so its pop after creating a
  /// document has somewhere to go.
  Future<void> openScreen(
    WidgetTester tester, {
    PdfRendererFactory? rendererFactory,
    PdfOpenReview? openReview,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => PdfPageSelectionScreen(
                      path: '${root.path}/imported.pdf',
                      title: 'imported.pdf',
                      rendererFactory: rendererFactory ?? factory(),
                      openReview: openReview,
                    ),
                  ),
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pump();
    // The push transition has to finish before anything on the new route is
    // where it looks like it is — a half-slid-in route puts its app bar actions
    // off the right edge of the screen.
    await tester.pump(const Duration(milliseconds: 400));
    // Thumbnails are rendered one at a time, so let the queue drain.
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pump();
  }

  /// Whether the tile labelled [pageLabel] shows [text] — used for the selection
  /// badges, which number the pages in the order they were chosen.
  bool tileShows(WidgetTester tester, String pageLabel, String text) => find
      .descendant(
        of: find
            .ancestor(
              of: find.text(pageLabel),
              matching: find.byType(GestureDetector),
            )
            .first,
        matching: find.text(text),
      )
      .evaluate()
      .isNotEmpty;

  testWidgets('shows a page per page of the document, unselected', (
    tester,
  ) async {
    await openScreen(tester);

    expect(find.text('Page 1'), findsOneWidget);
    expect(find.text('Page 2'), findsOneWidget);
    expect(find.text('Page 3'), findsOneWidget);
    expect(find.text('Tap pages to select them'), findsOneWidget);
    expect(find.text('Select pages first'), findsOneWidget);
    expect(find.text('of 3'), findsOneWidget);
  });

  testWidgets('pages are added in the order they are selected', (tester) async {
    await openScreen(tester);

    // Choose page 3, then page 1: that is the order the new document will have.
    await tester.tap(find.text('Page 3'));
    await tester.pump();
    await tester.tap(find.text('Page 1'));
    await tester.pump();

    expect(find.text('2 pages selected'), findsOneWidget);
    expect(find.text('Create PDF from 2 pages'), findsOneWidget);
    // The badges number the selection, so the order is visible rather than
    // implied: page 3 is the first page of the new document, page 1 the second.
    expect(tileShows(tester, 'Page 3', '1'), isTrue);
    expect(tileShows(tester, 'Page 1', '2'), isTrue);

    // Tapping a selected page removes it again.
    await tester.tap(find.text('Page 3'));
    await tester.pump();
    expect(find.text('1 page selected'), findsOneWidget);
  });

  testWidgets('select all and clear cover the whole document', (tester) async {
    await openScreen(tester);

    await tester.tap(find.text('All'));
    await tester.pump();

    expect(find.text('3 pages selected'), findsOneWidget);

    await tester.tap(find.text('Clear'));
    await tester.pump();

    expect(find.text('Tap pages to select them'), findsOneWidget);
  });

  testWidgets('the grid asks for thumbnails, and the document for pages', (
    tester,
  ) async {
    final reviewed = <List<String>>[];
    await openScreen(
      tester,
      openReview: (_, pages) async {
        reviewed.add(<String>[for (final page in pages) page.imagePath]);
        return null; // The user backed out of the review step.
      },
    );

    await tester.tap(find.text('Page 2'));
    await tester.pump();
    await tester.tap(find.text('Create PDF from 1 page'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump();

    // Two renderers were built: the grid's small one and the document's
    // reading-quality one.
    expect(created.length, 2);
    expect(created.first.isThumbnailQuality, isTrue);
    expect(created.last.isThumbnailQuality, isFalse);

    // The page handed to the review step is the big one, and it is the page
    // that was chosen.
    expect(reviewed.single, <String>['${root.path}/full_2.png']);
  });

  testWidgets('the chosen pages reach the review step in selection order', (
    tester,
  ) async {
    final reviewed = <PdfPageDraft>[];
    await openScreen(
      tester,
      openReview: (_, pages) async {
        reviewed.addAll(pages);
        return null;
      },
    );

    await tester.tap(find.text('Page 3'));
    await tester.pump();
    await tester.tap(find.text('Page 1'));
    await tester.pump();
    await tester.tap(find.text('Create PDF from 2 pages'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump();

    expect(reviewed.map((page) => page.imagePath).toList(), <String>[
      '${root.path}/full_3.png',
      '${root.path}/full_1.png',
    ]);
    // They are pages of a PDF, and they are numbered as they appear.
    expect(
      reviewed.every((page) => page.origin == PdfPageOrigin.importedPage),
      isTrue,
    );
    expect(reviewed.map((page) => page.id).toList(), <int>[1, 2]);
  });

  testWidgets('a page that cannot be rendered is shown, and cannot be chosen', (
    tester,
  ) async {
    await openScreen(
      tester,
      rendererFactory: factory(failPages: const <int>{2}),
    );

    // Every page is still listed, so the grid does not silently skip one.
    expect(find.text('Page 2'), findsOneWidget);
    expect(find.byIcon(Icons.broken_image_outlined), findsOneWidget);

    await tester.tap(find.text('Page 2'));
    await tester.pump();
    expect(find.text('Tap pages to select them'), findsOneWidget);

    // Select all covers the pages that exist, not the one that failed.
    await tester.tap(find.text('All'));
    await tester.pump();
    expect(find.text('2 pages selected'), findsOneWidget);
  });

  testWidgets('a document that cannot be opened says so', (tester) async {
    await openScreen(tester, rendererFactory: factory(failOpen: true));

    expect(find.text('This PDF could not be opened'), findsOneWidget);
    expect(find.textContaining('damaged'), findsOneWidget);
    expect(find.text('Go back'), findsOneWidget);
  });

  testWidgets('a document with one page is still selectable', (tester) async {
    await openScreen(tester, rendererFactory: factory(pages: 1));

    expect(find.text('of 1'), findsOneWidget);
    await tester.tap(find.text('Page 1'));
    await tester.pump();
    expect(find.text('Create PDF from 1 page'), findsOneWidget);
  });

  testWidgets('a failure while preparing the pages is reported', (
    tester,
  ) async {
    var reviewOpened = false;
    await openScreen(
      tester,
      rendererFactory: (rasterFor) {
        // The grid renders small images; only the document's own renderer
        // fails, which is the case a user would hit on a damaged page.
        final renderer = _FakeRenderer(
          pageCount: 3,
          directory: root.path,
          rasterFor: rasterFor,
          rasterError: rasterFor(600, 800).width > 1000
              ? const PdfException(
                  PdfErrorKind.renderFailure,
                  'That page could not be prepared for reading.',
                )
              : null,
        );
        created.add(renderer);
        return renderer;
      },
      openReview: (_, _) async {
        reviewOpened = true;
        return null;
      },
    );

    await tester.tap(find.text('Page 1'));
    await tester.pump();
    await tester.tap(find.text('Create PDF from 1 page'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump();

    expect(reviewOpened, isFalse);
    expect(
      find.text('That page could not be prepared for reading.'),
      findsOneWidget,
    );
    // The selection survives, so the user can try another page.
    expect(find.text('1 page selected'), findsOneWidget);
  });

  testWidgets('a created document is handed back to the caller', (
    tester,
  ) async {
    await openScreen(
      tester,
      openReview: (_, pages) async => CreatedPdf(
        path: '${root.path}/new.pdf',
        fileName: 'new.pdf',
        pageCount: pages.length,
        byteSize: 1024,
      ),
    );

    await tester.tap(find.text('Page 1'));
    await tester.pump();
    await tester.tap(find.text('Create PDF from 1 page'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    // Let the pop transition finish, so the assertion is about the route rather
    // than about an animation frame.
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump();

    // The selection screen is gone: its caller owns what happens next.
    expect(find.text('open'), findsOneWidget);
    expect(find.byType(PdfPageSelectionScreen), findsNothing);
  });
}
