import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdf_utility_flutter/app/app_scope.dart';
import 'package:pdf_utility_flutter/app/app_theme.dart';
import 'package:pdf_utility_flutter/ocr/domain/ocr_block.dart';
import 'package:pdf_utility_flutter/ocr/domain/ocr_element.dart';
import 'package:pdf_utility_flutter/ocr/domain/ocr_exception.dart';
import 'package:pdf_utility_flutter/ocr/domain/ocr_line.dart';
import 'package:pdf_utility_flutter/ocr/domain/ocr_rect.dart';
import 'package:pdf_utility_flutter/ocr/domain/ocr_result.dart';
import 'package:pdf_utility_flutter/ocr/domain/ocr_script_mode.dart';
import 'package:pdf_utility_flutter/ocr/domain/ocr_service.dart';
import 'package:pdf_utility_flutter/pdf/domain/pdf_page_draft.dart';
import 'package:pdf_utility_flutter/pdf/presentation/pdf_import_screen.dart';
import 'package:pdf_utility_flutter/pdf/presentation/pdf_review_screen.dart';
import 'package:pdf_utility_flutter/screens/home_screen.dart';
import 'package:pdf_utility_flutter/screens/ocr_result_screen.dart';

import 'support/translation_fakes.dart';

/// A one-line page of text, enough for the result screen to consider itself
/// translatable without touching a real image.
OcrResult _page(String path) => OcrResult(
  sourceImage: SourceImageInfo(path: path, width: 1000, height: 1000),
  fullText: 'Hello world',
  blocks: [
    OcrBlock(
      text: 'Hello world',
      boundingBox: OcrRect.fromLTRB(100, 100, 900, 200),
      lines: [
        OcrLine(
          text: 'Hello world',
          boundingBox: OcrRect.fromLTRB(100, 100, 900, 200),
          elements: [
            OcrElement(
              text: 'Hello',
              boundingBox: OcrRect.fromLTRB(100, 100, 500, 200),
            ),
            OcrElement(
              text: 'world',
              boundingBox: OcrRect.fromLTRB(520, 100, 900, 200),
            ),
          ],
        ),
      ],
    ),
  ],
);

/// An OCR service that always fails, so the screen's error path is exercised
/// through the same seam the real recognizer uses.
class _ThrowingOcrService implements OcrService {
  _ThrowingOcrService(this.error);

  final Object error;
  int calls = 0;

  @override
  String get engineName => 'Throwing';

  @override
  Future<OcrResult> recognizeImage(
    String imagePath, {
    OcrScriptMode mode = OcrScriptMode.defaultMode,
  }) async {
    calls++;
    throw error;
  }

  @override
  Future<void> dispose() async {}
}

/// Records what OCR was actually asked to read, and answers with [_page].
class _RecordingOcrService implements OcrService {
  final List<String> paths = <String>[];
  String? requestedMode;

  @override
  String get engineName => 'Recording';

  @override
  Future<OcrResult> recognizeImage(
    String imagePath, {
    OcrScriptMode mode = OcrScriptMode.defaultMode,
  }) async {
    paths.add(imagePath);
    requestedMode = mode.name;
    return _page(imagePath);
  }

  @override
  Future<void> dispose() async {}
}

void main() {
  late _RecordingOcrService ocr;

  setUp(() => ocr = _RecordingOcrService());

  /// The Home screen with its platform seams stubbed: no camera, no photo
  /// picker, no ML Kit. Everything else — the source screen, the sheet, the
  /// navigation and the recogniser call — is the real code path.
  Widget harness({
    OcrService? ocrService,
    Future<String?> Function()? pickFromGallery,
    Future<String?> Function(BuildContext context)? capturePage,
    Future<List<String>> Function(BuildContext context)? capturePages,
    Future<List<String>> Function()? pickImages,
    Future<void> Function(BuildContext context, List<PdfPageDraft> pages)?
    openPdfReview,
  }) => AppScope(
    ocrService: ocrService ?? ocr,
    translationService: FakeTranslationService(),
    debugGeometry: ValueNotifier<bool>(false),
    ocrScriptMode: ValueNotifier<OcrScriptMode>(OcrScriptMode.defaultMode),
    child: MaterialApp(
      theme: buildAppTheme(),
      home: HomeScreen(
        pickFromGallery: pickFromGallery,
        capturePage: capturePage,
        capturePages: capturePages,
        pickImages: pickImages,
        openPdfReview: openPdfReview,
      ),
    ),
  );

  /// A phone-shaped surface, so nothing under test is clipped off screen.
  Future<void> pumpHome(WidgetTester tester, Widget app) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(app);
    await tester.pump();
  }

  /// Opens the OCR Scanner source screen.
  Future<void> openExtractText(WidgetTester tester) async {
    await tester.tap(find.byKey(const Key('home-extract-text')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
  }

  /// Opens the Create PDF sheet.
  Future<void> openCreatePdf(WidgetTester tester) async {
    await tester.tap(find.byKey(const Key('home-create-pdf')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
  }

  /// Taps a source and lets the work it starts finish.
  ///
  /// Deliberately not `pumpAndSettle`: the result screen renders an image file
  /// that does not exist in a test, so the test must not wait on it (the same
  /// reason `widget_test.dart` pushes that screen with explicit pumps).
  Future<void> chooseSource(WidgetTester tester, String label) async {
    await tester.tap(find.text(label));
    // Source route pops, the OCR flow route pushes, its first frame starts the
    // capture/pick, and the read replaces it with the result. Each of those is
    // a separate frame, so pump through all of them.
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 250));
    }
  }

  testWidgets('Home offers exactly OCR Scanner and Create PDF', (tester) async {
    await pumpHome(tester, harness());

    // The two choices, in priority order.
    expect(find.byKey(const Key('home-extract-text')), findsOneWidget);
    expect(find.byKey(const Key('home-create-pdf')), findsOneWidget);
    expect(find.text('OCR Scanner'), findsOneWidget);
    expect(find.text('Scan photos or PDFs to extract text.'), findsOneWidget);
    expect(
      find.text('Create PDF using camera or gallery images.'),
      findsOneWidget,
    );

    // The old entry points, their sheets and the duplicate script footer are
    // gone from Home. Their screens still exist behind the two choices.
    expect(find.text('Scan document'), findsNothing);
    expect(find.text('Choose image'), findsNothing);
    expect(find.textContaining('Script:'), findsNothing);
    expect(find.text('Import PDF'), findsNothing);
    expect(find.text('Make PDF Searchable'), findsNothing);
  });

  testWidgets('OCR Scanner → Camera reads the captured photo', (tester) async {
    await pumpHome(
      tester,
      harness(capturePage: (_) async => '/tmp/capture.jpg'),
    );

    await openExtractText(tester);
    // The screen's own title, not the Home card behind it.
    expect(
      find.descendant(
        of: find.byType(AppBar),
        matching: find.text('OCR Scanner'),
      ),
      findsOneWidget,
    );
    expect(find.text('Choose a source'), findsOneWidget);

    await chooseSource(tester, 'Camera');

    expect(ocr.paths, ['/tmp/capture.jpg']);
    expect(ocr.requestedMode, OcrScriptMode.defaultMode.name);
    expect(find.byType(OcrResultScreen), findsOneWidget);
  });

  testWidgets('OCR Scanner → Gallery reads the chosen image', (tester) async {
    await pumpHome(
      tester,
      harness(pickFromGallery: () async => '/tmp/gallery.jpg'),
    );

    await openExtractText(tester);
    await chooseSource(tester, 'Gallery');

    // One pick, one read, same recogniser call as the camera path.
    expect(ocr.paths, ['/tmp/gallery.jpg']);
    expect(find.byType(OcrResultScreen), findsOneWidget);
  });

  testWidgets('OCR Scanner → Import PDF opens the PDF importer', (
    tester,
  ) async {
    await pumpHome(tester, harness());

    await openExtractText(tester);
    await chooseSource(tester, 'Import PDF');

    // The existing importer, unchanged: it owns picking and reading a page.
    expect(find.byType(PdfImportScreen), findsOneWidget);
    expect(find.text('Read a PDF'), findsOneWidget);
    expect(ocr.paths, isEmpty);
  });

  testWidgets('a failed read is reported and opens no result screen', (
    tester,
  ) async {
    final failing = _ThrowingOcrService(
      const OcrException(
        OcrErrorKind.imageUnreadable,
        'That image could not be opened. Please capture or choose it again.',
      ),
    );
    await pumpHome(
      tester,
      harness(ocrService: failing, capturePage: (_) async => '/tmp/gone.jpg'),
    );

    await openExtractText(tester);
    await chooseSource(tester, 'Camera');

    // The user gets one actionable sentence, not a stack trace, and no result
    // screen is opened onto a read that did not happen.
    expect(
      find.text(
        'That image could not be opened. Please capture or choose it again.',
      ),
      findsOneWidget,
    );
    expect(find.textContaining('PlatformException'), findsNothing);
    expect(find.byType(OcrResultScreen), findsNothing);
    expect(failing.calls, 1);
  });

  testWidgets('cancelling the camera reads nothing and opens nothing', (
    tester,
  ) async {
    await pumpHome(tester, harness(capturePage: (_) async => null));

    await openExtractText(tester);
    await chooseSource(tester, 'Camera');

    expect(ocr.paths, isEmpty);
    expect(find.byType(OcrResultScreen), findsNothing);
  });

  testWidgets('Create PDF → Camera captures a session of pages', (
    tester,
  ) async {
    final reviewed = <PdfPageDraft>[];
    await pumpHome(
      tester,
      harness(
        capturePages: (_) async => ['/tmp/page-1.jpg', '/tmp/page-2.jpg'],
        openPdfReview: (_, pages) async => reviewed.addAll(pages),
      ),
    );

    await openCreatePdf(tester);
    await chooseSource(tester, 'Camera');

    // Every captured page reached the review step, in capture order, labelled
    // as captured — and OCR was not asked to read anything on the way.
    expect(reviewed.map((page) => page.imagePath).toList(), [
      '/tmp/page-1.jpg',
      '/tmp/page-2.jpg',
    ]);
    expect(
      reviewed.every((page) => page.origin == PdfPageOrigin.camera),
      isTrue,
    );
    expect(ocr.paths, isEmpty);
  });

  testWidgets('Create PDF → Gallery combines the chosen images', (
    tester,
  ) async {
    final reviewed = <PdfPageDraft>[];
    await pumpHome(
      tester,
      harness(
        pickImages: () async => ['/tmp/scan-a.jpg', '/tmp/scan-b.jpg'],
        openPdfReview: (_, pages) async => reviewed.addAll(pages),
      ),
    );

    await openCreatePdf(tester);
    await chooseSource(tester, 'Gallery');

    expect(reviewed.map((page) => page.imagePath).toList(), [
      '/tmp/scan-a.jpg',
      '/tmp/scan-b.jpg',
    ]);
    expect(
      reviewed.every((page) => page.origin == PdfPageOrigin.gallery),
      isTrue,
    );
  });

  testWidgets('cancelling the page capture opens no review step', (
    tester,
  ) async {
    var opened = false;
    await pumpHome(
      tester,
      harness(
        capturePages: (_) async => const <String>[],
        openPdfReview: (_, _) async => opened = true,
      ),
    );

    await openCreatePdf(tester);
    await chooseSource(tester, 'Camera');

    expect(opened, isFalse);
  });

  testWidgets('Create PDF → Gallery opens the real review screen', (
    tester,
  ) async {
    // No review seam: this is the wiring the app actually ships, and the review
    // screen builds itself from the file paths it is handed without touching a
    // plugin.
    await pumpHome(
      tester,
      harness(pickImages: () async => ['/tmp/scan-a.jpg', '/tmp/scan-b.jpg']),
    );

    await openCreatePdf(tester);
    await chooseSource(tester, 'Gallery');
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.byType(PdfReviewScreen), findsOneWidget);
    expect(find.text('Review pages'), findsOneWidget);
    expect(find.text('Page 1'), findsOneWidget);

    // The preview is a full-width lazy list, so the second page is built when it
    // is scrolled into view rather than being squeezed into a half-width grid.
    await tester.scrollUntilVisible(
      find.text('Page 2'),
      240,
      scrollable: find
          .descendant(of: find.byType(ListView), matching: find.byType(Scrollable))
          .first,
    );
    expect(find.text('Page 2'), findsOneWidget);
    expect(find.text('Create PDF (2 pages)'), findsOneWidget);
  });

  testWidgets('the source screen closes before the result opens', (
    tester,
  ) async {
    await pumpHome(
      tester,
      harness(pickFromGallery: () async => '/tmp/gallery.jpg'),
    );

    await openExtractText(tester);
    await tester.pump();
    expect(find.text('Choose a source'), findsOneWidget);

    await chooseSource(tester, 'Gallery');

    // The chooser is gone by the time the result screen is on top, so Back from
    // the result goes Home rather than back into a stale source list.
    expect(find.text('Choose a source'), findsNothing);
    expect(find.byType(OcrResultScreen), findsOneWidget);
  });

  testWidgets('Settings is still reachable from the header icon', (
    tester,
  ) async {
    await pumpHome(tester, harness());

    await tester.tap(find.byTooltip('Settings'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    // The script choice moved here; it was not removed.
    expect(find.text('Text script'), findsOneWidget);
    expect(find.text('Choose a script'), findsOneWidget);
  });
}
