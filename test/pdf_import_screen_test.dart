import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdf_utility_flutter/app/app_scope.dart';
import 'package:pdf_utility_flutter/ocr/domain/ocr_block.dart';
import 'package:pdf_utility_flutter/ocr/domain/ocr_element.dart';
import 'package:pdf_utility_flutter/ocr/domain/ocr_line.dart';
import 'package:pdf_utility_flutter/ocr/domain/ocr_rect.dart';
import 'package:pdf_utility_flutter/ocr/domain/ocr_result.dart';
import 'package:pdf_utility_flutter/ocr/domain/ocr_script_mode.dart';
import 'package:pdf_utility_flutter/ocr/domain/ocr_service.dart';
import 'package:pdf_utility_flutter/pdf/domain/pdf_document_info.dart';
import 'package:pdf_utility_flutter/pdf/domain/pdf_exception.dart';
import 'package:pdf_utility_flutter/pdf/domain/pdf_page_renderer.dart';
import 'package:pdf_utility_flutter/pdf/domain/pdf_source_service.dart';
import 'package:pdf_utility_flutter/pdf/domain/rendered_pdf_page.dart';
import 'package:pdf_utility_flutter/pdf/presentation/pdf_import_screen.dart';
import 'package:pdf_utility_flutter/screens/ocr_result_screen.dart';

import 'support/translation_fakes.dart';

/// A real, valid 1x1 PNG, so the preview path is exercised against an actual
/// file the image layer can decode — never a path that only exists in a stub.
const String _onePixelPngBase64 =
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8AAAW'
    'AB/AF+7lPWAAAAAElFTkSuQmCC';

/// Stands in for the platform document picker.
class _FakePdfSource implements PdfSourceService {
  _FakePdfSource({this.path});

  /// What the picker returns. `null` is the user cancelling.
  String? path;

  Object? failure;
  int calls = 0;

  @override
  Future<String?> pickPdf() async {
    calls++;
    if (failure != null) throw failure!;
    return path;
  }
}

/// Stands in for native PDFium. Writes real files, adds no delays.
class _FakePdfRenderer implements PdfPageRenderer {
  _FakePdfRenderer({required this.directory});

  final Directory directory;

  /// Pages in the fake document.
  int pageCount = 3;

  final List<int> renderedPages = <int>[];
  int openCalls = 0;
  int closeCalls = 0;
  Object? openFailure;
  Object? renderFailure;

  /// The image file the last render produced — the same path the screen must
  /// both preview and hand to OCR.
  String? lastRenderedPath;

  @override
  String get engineName => 'Fake PDFium';

  @override
  Future<PdfDocumentInfo> open(String path) async {
    openCalls++;
    if (openFailure != null) throw openFailure!;
    return PdfDocumentInfo(
      path: path,
      title: 'report.pdf',
      pageCount: pageCount,
    );
  }

  @override
  Future<RenderedPdfPage> renderPage(int pageNumber) async {
    renderedPages.add(pageNumber);
    if (renderFailure != null) throw renderFailure!;

    final file = File('${directory.path}/page_$pageNumber.png')
      ..writeAsBytesSync(base64Decode(_onePixelPngBase64));
    lastRenderedPath = file.path;

    return RenderedPdfPage(
      pageNumber: pageNumber,
      imagePath: file.path,
      width: 1600,
      height: 2263,
      elapsed: const Duration(milliseconds: 300),
    );
  }

  @override
  Future<void> close() async {
    closeCalls++;
  }
}

/// Records what OCR was actually asked to read.
class _RecordingOcrService implements OcrService {
  final List<String> paths = <String>[];
  Object? failure;
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
    if (failure != null) throw failure!;

    final box = OcrRect.fromLTRB(100, 100, 900, 200);
    return OcrResult(
      sourceImage: SourceImageInfo(path: imagePath, width: 1600, height: 2263),
      fullText: 'Invoice',
      blocks: [
        OcrBlock(
          text: 'Invoice',
          boundingBox: box,
          lines: [
            OcrLine(
              text: 'Invoice',
              boundingBox: box,
              elements: [OcrElement(text: 'Invoice', boundingBox: box)],
            ),
          ],
        ),
      ],
    );
  }

  @override
  Future<void> dispose() async {}
}

void main() {
  late Directory tempDir;
  late _FakePdfSource source;
  late _FakePdfRenderer renderer;
  late _RecordingOcrService ocr;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('pdf_import_screen_test');
    source = _FakePdfSource(path: '${tempDir.path}/report.pdf');
    renderer = _FakePdfRenderer(directory: tempDir);
    ocr = _RecordingOcrService();
  });

  tearDown(() {
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  Widget harness() => AppScope(
    ocrService: ocr,
    translationService: FakeTranslationService(),
    debugGeometry: ValueNotifier<bool>(false),
    ocrScriptMode: ValueNotifier<OcrScriptMode>(OcrScriptMode.defaultMode),
    child: MaterialApp(
      home: PdfImportScreen(source: source, renderer: renderer),
    ),
  );

  /// A phone-shaped surface, so nothing under test is clipped off screen.
  Future<void> pumpScreen(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(harness());
    await tester.pump();
  }

  /// Chooses the PDF and lets the open + first-page render finish.
  Future<void> choosePdf(WidgetTester tester) async {
    await tester.tap(find.text('Choose PDF'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
  }

  /// The page stepper button that carries [icon] — read off the button itself,
  /// so a disabled state is asserted rather than a tooltip's presence.
  IconButton stepper(WidgetTester tester, IconData icon) =>
      tester.widget<IconButton>(find.widgetWithIcon(IconButton, icon));

  Future<void> tapStepper(WidgetTester tester, IconData icon) async {
    await tester.tap(find.byIcon(icon));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
  }

  testWidgets('invites a PDF before anything is chosen', (tester) async {
    await pumpScreen(tester);

    expect(find.text('Read a PDF'), findsOneWidget);
    expect(find.text('Choose PDF'), findsOneWidget);
    // The promise is stated where the decision is made.
    expect(find.textContaining('Nothing is uploaded'), findsOneWidget);
    // Nothing is open, so there is no document chrome and no preview.
    expect(find.text('Read this page'), findsNothing);
    expect(find.byType(Image), findsNothing);
    expect(renderer.openCalls, 0);
  });

  testWidgets('cancelling the picker leaves the screen exactly as it was', (
    tester,
  ) async {
    source.path = null;
    await pumpScreen(tester);
    await choosePdf(tester);

    expect(source.calls, 1);
    expect(renderer.openCalls, 0);
    expect(find.text('Choose PDF'), findsOneWidget);
    expect(find.text('Try again'), findsNothing);
  });

  testWidgets('choosing a PDF opens it and prepares the first page', (
    tester,
  ) async {
    await pumpScreen(tester);
    await choosePdf(tester);

    expect(renderer.openCalls, 1);
    expect(renderer.renderedPages, [1]);
    // The document is named, positioned, and ready to read.
    expect(find.text('report.pdf'), findsOneWidget);
    expect(find.text('Page 1 of 3'), findsOneWidget);
    expect(find.text('Read this page'), findsOneWidget);
    // The preview is the rendered image, and the size is stated so a coarse
    // render is visible before the read rather than after it.
    expect(find.byType(Image), findsOneWidget);
    expect(find.textContaining('1600 × 2263'), findsOneWidget);
    expect(
      find.textContaining('this is the image that will be read'),
      findsOneWidget,
    );
  });

  testWidgets('reading a page sends the previewed file to OCR', (tester) async {
    await pumpScreen(tester);
    await choosePdf(tester);
    await tester.tap(find.text('Read this page'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    // One path, and it is the very file on screen: what is read is what was
    // previewed.
    expect(ocr.paths, [renderer.lastRenderedPath]);
    expect(find.byType(OcrResultScreen), findsOneWidget);
  });

  testWidgets(
    'the page stepper moves through the document and stops at the ends',
    (tester) async {
      await pumpScreen(tester);
      await choosePdf(tester);

      expect(
        stepper(tester, Icons.chevron_left).onPressed,
        isNull,
        reason: 'page 1 has nowhere to go back to',
      );

      await tapStepper(tester, Icons.chevron_right);

      expect(renderer.renderedPages, [1, 2]);
      expect(find.text('Page 2 of 3'), findsOneWidget);

      await tapStepper(tester, Icons.chevron_right);

      expect(renderer.renderedPages, [1, 2, 3]);
      expect(find.text('Page 3 of 3'), findsOneWidget);
      expect(
        stepper(tester, Icons.chevron_right).onPressed,
        isNull,
        reason: 'the last page has nowhere to go forward to',
      );
      expect(stepper(tester, Icons.chevron_left).onPressed, isNotNull);
      // Reading follows the page that is on screen.
      await tester.tap(find.text('Read this page'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(ocr.paths, ['${tempDir.path}/page_3.png']);
    },
  );

  testWidgets('a page that will not render is recoverable', (tester) async {
    renderer.renderFailure = const PdfException(
      PdfErrorKind.renderFailure,
      'That page came back empty. Please try another page.',
    );

    await pumpScreen(tester);
    await choosePdf(tester);

    expect(
      find.text('That page came back empty. Please try another page.'),
      findsOneWidget,
    );
    expect(find.text('Try again'), findsWidgets);
    // The failure is a state, not a dead end: nothing was read.
    expect(ocr.paths, isEmpty);

    renderer.renderFailure = null;
    await tester.tap(find.text('Try again').first);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.text('Page 1 of 3'), findsOneWidget);
    expect(find.text('Read this page'), findsOneWidget);
  });

  testWidgets('a PDF that cannot be opened says why', (tester) async {
    renderer.openFailure = const PdfException(
      PdfErrorKind.unreadable,
      'This PDF is password protected. Unlock it first, then import it.',
    );

    await pumpScreen(tester);
    await choosePdf(tester);

    expect(
      find.text(
        'This PDF is password protected. Unlock it first, then import it.',
      ),
      findsOneWidget,
    );
    // No half-open document is left behind.
    expect(find.text('report.pdf'), findsNothing);
    expect(find.text('Read this page'), findsNothing);
    expect(renderer.renderedPages, isEmpty);
  });

  testWidgets('a picker that throws is reported, not swallowed', (
    tester,
  ) async {
    source.failure = const PdfException(
      PdfErrorKind.unreadable,
      'That file is no longer available. Please choose it again.',
    );

    await pumpScreen(tester);
    await choosePdf(tester);

    expect(
      find.text('That file is no longer available. Please choose it again.'),
      findsOneWidget,
    );
    expect(find.text('Choose PDF'), findsOneWidget);
  });
}
