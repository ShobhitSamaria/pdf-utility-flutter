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

  /// The Home screen with its two platform seams stubbed: no camera, no photo
  /// picker, no ML Kit. Everything else — the sheets, the navigation, the
  /// recogniser call — is the real code path.
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

  /// Taps an entry point on Home and lets the sheet appear.
  Future<void> openSheet(WidgetTester tester, String entryLabel) async {
    await tester.tap(find.text(entryLabel));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
  }

  /// Taps a row inside the open sheet and lets the work it starts finish.
  ///
  /// Deliberately not `pumpAndSettle`: the result screen renders an image file
  /// that does not exist in a test, so the test must not wait on it (the same
  /// reason `widget_test.dart` pushes that screen with explicit pumps).
  Future<void> chooseRow(WidgetTester tester, String rowLabel) async {
    await tester.tap(find.text(rowLabel));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
  }

  testWidgets('Scan document → Extract Text reads the captured photo', (
    tester,
  ) async {
    await pumpHome(
      tester,
      harness(capturePage: (_) async => '/tmp/capture.jpg'),
    );

    await openSheet(tester, 'Scan document');
    await chooseRow(tester, 'Extract Text (OCR)');

    // The sheet's first row is the pre-existing camera → OCR flow, unchanged.
    expect(ocr.paths, ['/tmp/capture.jpg']);
    expect(ocr.requestedMode, OcrScriptMode.defaultMode.name);
    expect(find.byType(OcrResultScreen), findsOneWidget);
  });

  testWidgets('Choose image → Extract Text reads the chosen image', (
    tester,
  ) async {
    await pumpHome(
      tester,
      harness(pickFromGallery: () async => '/tmp/gallery.jpg'),
    );

    await openSheet(tester, 'Choose image');
    await chooseRow(tester, 'Extract Text');

    // The gallery flow is still the gallery flow: one pick, one read.
    expect(ocr.paths, ['/tmp/gallery.jpg']);
    expect(find.byType(OcrResultScreen), findsOneWidget);
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

    await openSheet(tester, 'Scan document');
    await chooseRow(tester, 'Extract Text (OCR)');

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

    await openSheet(tester, 'Scan document');
    await chooseRow(tester, 'Extract Text (OCR)');

    expect(ocr.paths, isEmpty);
    expect(find.byType(OcrResultScreen), findsNothing);
  });

  testWidgets('Scan document → Create PDF captures a session of pages', (
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

    await openSheet(tester, 'Scan document');
    await chooseRow(tester, 'Create PDF');

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
    expect(find.byType(OcrResultScreen), findsNothing);
  });

  testWidgets('Choose image → Create PDF combines the chosen images', (
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

    await openSheet(tester, 'Choose image');
    await chooseRow(tester, 'Create PDF');

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

    await openSheet(tester, 'Scan document');
    await chooseRow(tester, 'Create PDF');

    expect(opened, isFalse);
  });

  testWidgets('Choose image → Create PDF opens the real review screen', (
    tester,
  ) async {
    // No review seam: this is the wiring the app actually ships, and the review
    // screen builds itself from the file paths it is handed without touching a
    // plugin.
    await pumpHome(
      tester,
      harness(pickImages: () async => ['/tmp/scan-a.jpg', '/tmp/scan-b.jpg']),
    );

    await openSheet(tester, 'Choose image');
    await chooseRow(tester, 'Create PDF');
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.byType(PdfReviewScreen), findsOneWidget);
    expect(find.text('Review pages'), findsOneWidget);
    expect(find.text('Page 1'), findsOneWidget);
    expect(find.text('Page 2'), findsOneWidget);
    expect(find.text('Create PDF (2 pages)'), findsOneWidget);
  });

  testWidgets('Import PDF offers Extract Text and nothing else', (
    tester,
  ) async {
    await pumpHome(tester, harness());

    await openSheet(tester, 'Import PDF');

    // The one action that reads a PDF. "View PDF / Create PDF" used to sit here
    // as a second, differently-shaped way into the same document; it is gone.
    expect(find.text('Extract Text'), findsOneWidget);
    expect(find.text('Choose a page to recognize'), findsOneWidget);
    expect(find.text('View PDF / Create PDF'), findsNothing);
    expect(find.textContaining('View PDF'), findsNothing);
  });

  testWidgets('the sheet closes before anything navigates', (tester) async {
    await pumpHome(
      tester,
      harness(pickFromGallery: () async => '/tmp/gallery.jpg'),
    );

    await openSheet(tester, 'Choose image');
    expect(find.text('Read text from an image'), findsOneWidget);

    await chooseRow(tester, 'Extract Text');

    // The sheet is gone by the time the result screen is on top, so the user
    // never sees a modal stranded over the result.
    expect(find.text('Read text from an image'), findsNothing);
    expect(find.byType(OcrResultScreen), findsOneWidget);
  });
}
