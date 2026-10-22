import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdf_utility_flutter/app/app_theme.dart';
import 'package:pdf_utility_flutter/pdf/data/pdf_file_exporter.dart';
import 'package:pdf_utility_flutter/pdf/domain/pdf_creation.dart';
import 'package:pdf_utility_flutter/pdf/domain/pdf_exception.dart';
import 'package:pdf_utility_flutter/pdf/domain/pdf_page_draft.dart';
import 'package:pdf_utility_flutter/pdf/presentation/pdf_review_screen.dart';

import 'support/pdf_test_images.dart';

/// Records what the review screen asked the writer to produce.
class _RecordingWriter implements PdfCreationService {
  _RecordingWriter({this.failure});

  /// When set, every create call fails with this, so the screen's failure
  /// handling is exercised without a filesystem.
  final PdfException? failure;

  List<String>? paths;
  String? fileName;
  int calls = 0;

  @override
  String get engineName => 'Recording';

  @override
  Future<CreatedPdf> create({
    required List<String> pageImagePaths,
    String fileName = PdfCreationService.defaultFileName,
    void Function(int completed, int total)? onProgress,
  }) async {
    calls++;
    paths = List<String>.from(pageImagePaths);
    this.fileName = fileName;

    final error = failure;
    if (error != null) throw error;

    for (var index = 0; index < pageImagePaths.length; index++) {
      onProgress?.call(index + 1, pageImagePaths.length);
    }

    return CreatedPdf(
      path: '/tmp/created/${sanitizePdfFileName(fileName)}',
      fileName: sanitizePdfFileName(fileName),
      pageCount: pageImagePaths.length,
      byteSize: 4096,
      elapsed: const Duration(milliseconds: 250),
    );
  }
}

void main() {
  late Directory root;
  late String pageA;
  late String pageB;
  late String pageC;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('pdf_review_test');
    pageA = await writeTestPng(
      directory: root,
      name: 'a.png',
      width: 400,
      height: 560,
    );
    pageB = await writeTestPng(
      directory: root,
      name: 'b.png',
      width: 400,
      height: 560,
      color: const Color(0xFFFF8A3D),
    );
    pageC = await writeTestPng(
      directory: root,
      name: 'c.png',
      width: 400,
      height: 560,
      color: const Color(0xFF3D9BFF),
    );
  });

  tearDown(() async {
    if (root.existsSync()) await root.delete(recursive: true);
  });

  List<PdfPageDraft> drafts(List<String> paths) => <PdfPageDraft>[
    for (var index = 0; index < paths.length; index++)
      PdfPageDraft(
        id: index + 1,
        imagePath: paths[index],
        origin: PdfPageOrigin.gallery,
      ),
  ];

  Widget harness({
    List<PdfPageDraft> pages = const <PdfPageDraft>[],
    PdfCreationService? writer,
    PdfFileExporter? exporter,
    Future<List<String>> Function()? pickImages,
    Future<List<String>> Function(BuildContext context)? capturePages,
  }) => MaterialApp(
    home: PdfReviewScreen(
      pages: pages,
      creationService: writer ?? _RecordingWriter(),
      exporter: exporter,
      capturePages: capturePages,
      pickImages: pickImages,
    ),
  );

  /// Long-presses the tile holding [from] and drops it on [to], which is how
  /// the grid reorders pages.
  Future<void> dragTile(WidgetTester tester, String from, String to) async {
    final start = tester.getCenter(find.text(from));
    final end = tester.getCenter(find.text(to));

    final gesture = await tester.startGesture(start);
    // Past the long-press threshold: the drag only starts after it.
    await tester.pump(const Duration(milliseconds: 700));
    await gesture.moveTo(end);
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();
  }

  Finder deleteButtons() => find.descendant(
    of: find.byType(PdfReviewScreen),
    matching: find.byIcon(Icons.close),
  );

  testWidgets('shows every page, numbered, with the create action', (
    tester,
  ) async {
    await tester.pumpWidget(harness(pages: drafts([pageA, pageB, pageC])));
    await tester.pump();

    expect(find.text('Page 1'), findsOneWidget);
    expect(find.text('Page 2'), findsOneWidget);
    expect(find.text('Page 3'), findsOneWidget);
    expect(find.text('3 pages'), findsOneWidget);
    expect(find.text('Create PDF (3 pages)'), findsOneWidget);

    // The field starts **empty**, with a hint, and nothing is claimed about a
    // name that has not been typed. Create PDF is disabled until one is.
    final field = tester.widget<TextField>(find.byType(TextField));
    expect(field.controller?.text, isEmpty);
    expect(find.text('File name'), findsOneWidget);
    expect(find.text('Enter file name'), findsOneWidget);
    // Readability is explicit, not inherited: dark ink on a light fill, so the
    // name is legible on Android in this theme.
    expect(field.style?.color, AppColors.ink);
    expect(field.decoration?.fillColor, AppColors.rowTint);
    expect(find.textContaining('Will be saved as'), findsNothing);
    expect(find.text('Enter a file name to create the PDF.'), findsOneWidget);

    final create = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, 'Create PDF (3 pages)'),
    );
    expect(create.onPressed, isNull);
  });

  testWidgets('an empty file name cannot be created, and writes nothing', (
    tester,
  ) async {
    final writer = _RecordingWriter();
    await tester.pumpWidget(harness(pages: drafts([pageA]), writer: writer));
    await tester.pump();

    await tester.tap(find.widgetWithText(FilledButton, 'Create PDF (1 page)'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    // The button is disabled, so the tap is not a create: no writer call, no
    // sheet, no document named `document.pdf` behind the user's back.
    expect(writer.calls, 0);
    expect(find.text('PDF created'), findsNothing);

    // Whitespace is not a name either.
    await tester.enterText(find.byType(TextField), '   ');
    await tester.pump();
    final create = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, 'Create PDF (1 page)'),
    );
    expect(create.onPressed, isNull);

    // A real name enables it, and the exact name that will be written is shown.
    await tester.enterText(find.byType(TextField), '  Scan 1  ');
    await tester.pump();
    expect(find.text('Will be saved as Scan 1.pdf'), findsOneWidget);
    final enabled = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, 'Create PDF (1 page)'),
    );
    expect(enabled.onPressed, isNotNull);
  });

  testWidgets('deleting a page removes it from the document', (tester) async {
    await tester.pumpWidget(harness(pages: drafts([pageA, pageB, pageC])));
    await tester.pump();

    expect(deleteButtons(), findsNWidgets(3));

    await tester.tap(deleteButtons().first);
    await tester.pump();

    expect(deleteButtons(), findsNWidgets(2));
    // Pages are renumbered by position, so the last one is now page 2.
    expect(find.text('Page 3'), findsNothing);
    expect(find.text('2 pages'), findsOneWidget);
    expect(find.text('Create PDF (2 pages)'), findsOneWidget);
  });

  testWidgets('the last page can be deleted, leaving the empty state', (
    tester,
  ) async {
    await tester.pumpWidget(harness(pages: drafts([pageA])));
    await tester.pump();

    await tester.tap(deleteButtons());
    await tester.pump();

    expect(find.text('No pages yet'), findsOneWidget);
    // Nothing can be created from nothing, and the button says why.
    final create = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, 'Add a page first'),
    );
    expect(create.onPressed, isNull);
  });

  testWidgets('adding images appends them, and says how many arrived', (
    tester,
  ) async {
    await tester.pumpWidget(
      harness(pages: drafts([pageA]), pickImages: () async => [pageB, pageC]),
    );
    await tester.pump();

    await tester.tap(find.text('Add images'));
    await tester.pump();
    await tester.pump();

    expect(find.text('Page 3'), findsOneWidget);
    expect(find.text('Create PDF (3 pages)'), findsOneWidget);
    expect(find.text('2 pages added'), findsOneWidget);
  });

  testWidgets('cancelling the gallery leaves the document alone', (
    tester,
  ) async {
    await tester.pumpWidget(
      harness(pages: drafts([pageA]), pickImages: () async => const <String>[]),
    );
    await tester.pump();

    await tester.tap(find.text('Add images'));
    await tester.pump();
    await tester.pump();

    expect(deleteButtons(), findsOneWidget);
    expect(find.byType(SnackBar), findsNothing);
  });

  testWidgets('a capture session adds every page it returns', (tester) async {
    await tester.pumpWidget(
      harness(
        pages: drafts([pageA]),
        capturePages: (_) async => [pageB, pageC],
      ),
    );
    await tester.pump();

    await tester.tap(find.text('Add pages'));
    await tester.pump();
    await tester.pump();

    expect(deleteButtons(), findsNWidgets(3));
  });

  testWidgets('the file name is editable and the resolved name follows it', (
    tester,
  ) async {
    await tester.pumpWidget(harness(pages: drafts([pageA])));
    await tester.pump();

    await tester.enterText(find.byType(TextField), 'Holiday: 2026');
    await tester.pump();

    // What was typed stays in the field; what will be written is shown next to
    // it, so a name that had to be adjusted is never a silent surprise.
    expect(find.text('Will be saved as Holiday 2026.pdf'), findsOneWidget);

    // A pasted path keeps only its last segment: this is a name, not a
    // destination, so nothing can be written outside the export directory.
    await tester.enterText(find.byType(TextField), 'Holiday/photos');
    await tester.pump();
    expect(find.text('Will be saved as photos.pdf'), findsOneWidget);

    // The extension is added when the user does not type one, and not doubled
    // when they do — including a pasted `report.pdf.pdf`.
    await tester.enterText(find.byType(TextField), 'Final.PDF');
    await tester.pump();
    expect(find.text('Will be saved as Final.pdf'), findsOneWidget);

    await tester.enterText(find.byType(TextField), 'report.pdf.pdf');
    await tester.pump();
    expect(find.text('Will be saved as report.pdf'), findsOneWidget);
  });

  testWidgets('reordering a page changes the document order', (tester) async {
    final writer = _RecordingWriter();
    await tester.pumpWidget(
      harness(pages: drafts([pageA, pageB, pageC]), writer: writer),
    );
    await tester.pump();

    // Drop page 3 onto page 1: it becomes the first page.
    await dragTile(tester, 'Page 3', 'Page 1');

    // A name is required now, so create with one.
    await tester.enterText(find.byType(TextField), 'Order');
    await tester.pump();
    await tester.tap(find.textContaining('Create PDF'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    // The order the user arranged is the order in the file — exactly.
    expect(writer.paths, <String>[pageC, pageA, pageB]);
  });

  testWidgets('creating writes the pages with the chosen file name', (
    tester,
  ) async {
    final writer = _RecordingWriter();
    await tester.pumpWidget(
      harness(pages: drafts([pageA, pageB]), writer: writer),
    );
    await tester.pump();

    await tester.enterText(find.byType(TextField), 'Trip');
    await tester.pump();

    await tester.tap(find.textContaining('Create PDF'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(writer.calls, 1);
    expect(writer.fileName, 'Trip.pdf');
    expect(writer.paths, <String>[pageA, pageB]);

    // The success sheet is built from what the writer returned, not from what
    // the screen intended.
    expect(find.text('PDF created'), findsOneWidget);
    expect(find.text('Trip.pdf'), findsOneWidget);
    expect(find.text('2 pages · 4 KB'), findsOneWidget);
    expect(find.text('Written in 0.3 s'), findsOneWidget);
  });

  testWidgets('a failure is reported and no success is claimed', (
    tester,
  ) async {
    final writer = _RecordingWriter(
      failure: const PdfException(
        PdfErrorKind.writeFailure,
        'There was not enough space (or permission) to save the PDF.',
      ),
    );
    await tester.pumpWidget(harness(pages: drafts([pageA]), writer: writer));
    await tester.pump();

    // The button is only enabled once there is a name, so type one: this test
    // is about a *writer* failure, not about the disabled state.
    await tester.enterText(find.byType(TextField), 'Attempt');
    await tester.pump();
    await tester.tap(find.textContaining('Create PDF'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('PDF created'), findsNothing);
    expect(
      find.text('There was not enough space (or permission) to save the PDF.'),
      findsOneWidget,
    );
    // Still usable: the page is exactly where it was.
    expect(writer.calls, 1);
    expect(deleteButtons(), findsOneWidget);
  });

  /// Pushes the review screen over a Home stub, so "Save a copy goes Home" is
  /// observed as real navigation rather than a single-route no-op.
  Future<void> pumpOverHome(
    WidgetTester tester, {
    required List<PdfPageDraft> pages,
    PdfCreationService? writer,
    PdfFileExporter? exporter,
  }) async {
    final navigator = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navigator,
        home: const Scaffold(body: Center(child: Text('Home stub'))),
      ),
    );

    unawaited(
      navigator.currentState!.push<CreatedPdf>(
        MaterialPageRoute<CreatedPdf>(
          builder: (_) => PdfReviewScreen(
            pages: pages,
            creationService: writer ?? _RecordingWriter(),
            exporter: exporter,
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
  }

  /// Types a name and taps **Create PDF**, then lets the sheet open.
  Future<void> createPdf(
    WidgetTester tester, {
    String name = 'Document',
  }) async {
    await tester.enterText(find.byType(TextField), name);
    await tester.pump();
    await tester.tap(find.textContaining('Create PDF'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
  }

  /// Stubs the native share/export channel and removes the stub afterwards.
  Future<void> mockShareChannel(
    WidgetTester tester,
    Future<Object?> Function(MethodCall call) handler,
  ) async {
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('pdf_utility/share'),
      handler,
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('pdf_utility/share'),
        null,
      ),
    );
  }

  testWidgets('Share keeps the sheet open, with no Done button to tap', (
    tester,
  ) async {
    final calls = <String>[];
    await pumpOverHome(
      tester,
      pages: drafts([pageA]),
      // The real exporter, driven over the mocked platform channel: the ways out
      // of the sheet go through the same code a device would run.
      exporter: const PdfFileExporter(),
    );
    await mockShareChannel(tester, (call) async {
      calls.add(call.method);
      return call.method == 'shareFile' ? true : null;
    });

    await createPdf(tester);
    expect(find.text('PDF created'), findsOneWidget);
    // Done is gone: saving is the end of the flow now, not a third button.
    expect(find.text('Done'), findsNothing);

    await tester.tap(find.text('Share'));
    await tester.pump();
    await tester.pump();

    expect(calls, contains('shareFile'));
    // Sharing does not navigate: the user is still on the sheet, with Save a
    // copy available.
    expect(find.text('PDF created'), findsOneWidget);
    expect(find.text('Save a copy'), findsOneWidget);
    expect(find.text('Home stub'), findsNothing);
  });

  testWidgets('Save a copy saves the file, then goes Home by itself', (
    tester,
  ) async {
    final exportedNames = <String>[];
    final exportPaths = <String>[];
    await pumpOverHome(
      tester,
      pages: drafts([pageA]),
      exporter: const PdfFileExporter(),
    );
    await mockShareChannel(tester, (call) async {
      if (call.method != 'exportFile') return null;
      final arguments = Map<String, dynamic>.from(call.arguments as Map);
      exportedNames.add(arguments['fileName'] as String);
      exportPaths.add(arguments['path'] as String);
      return 'Downloads/Document.pdf';
    });

    await createPdf(tester, name: 'Holiday 2026');
    expect(find.text('Holiday 2026.pdf'), findsOneWidget);

    await tester.tap(find.text('Save a copy'));
    // Settle the sheet's exit and the route pop, so only Home's Scaffold is on
    // screen when the snackbar is asserted.
    await tester.pumpAndSettle();

    // The export used the name the user typed, and the file the writer created.
    expect(exportedNames, <String>['Holiday 2026.pdf']);
    expect(exportPaths, <String>['/tmp/created/Holiday 2026.pdf']);

    // Saving finished the flow: no Done tap, and Home is on top.
    expect(find.text('Home stub'), findsOneWidget);
    expect(find.text('PDF created'), findsNothing);
    expect(find.text('Saved to Downloads/Document.pdf'), findsOneWidget);
  });

  testWidgets('a failed save reports it, stays put and can be retried', (
    tester,
  ) async {
    var attempts = 0;
    await pumpOverHome(
      tester,
      pages: drafts([pageA]),
      exporter: const PdfFileExporter(),
    );
    await mockShareChannel(tester, (call) async {
      if (call.method != 'exportFile') return null;
      attempts++;
      // First attempt fails, second succeeds — the retry must be possible
      // without leaving the screen.
      return attempts == 1 ? null : 'Downloads/Document.pdf';
    });

    await createPdf(tester);
    await tester.tap(find.text('Save a copy'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.textContaining('Could not save a copy'), findsOneWidget);
    // Still on the sheet, and Home was not reached — nothing is claimed that
    // did not happen.
    expect(find.text('PDF created'), findsOneWidget);
    expect(find.text('Home stub'), findsNothing);

    await tester.tap(find.text('Save a copy'));
    await tester.pumpAndSettle();

    expect(attempts, 2);
    expect(find.text('Home stub'), findsOneWidget);
    expect(find.text('Saved to Downloads/Document.pdf'), findsOneWidget);
  });

  testWidgets('a double tap on Save a copy exports once', (tester) async {
    final gate = Completer<void>();
    var exports = 0;
    await pumpOverHome(
      tester,
      pages: drafts([pageA]),
      exporter: const PdfFileExporter(),
    );
    await mockShareChannel(tester, (call) async {
      if (call.method != 'exportFile') return null;
      exports++;
      await gate.future;
      return 'Downloads/Document.pdf';
    });

    await createPdf(tester);
    await tester.tap(find.text('Save a copy'));
    await tester.pump();
    expect(find.text('Saving…'), findsOneWidget);

    // Disabled while writing, so a second tap cannot start a second export or a
    // second navigation.
    await tester.tap(find.text('Saving…'));
    await tester.pump();
    expect(exports, 1);

    gate.complete();
    await tester.pumpAndSettle();

    expect(exports, 1);
    expect(find.text('Home stub'), findsOneWidget);
  });

  testWidgets(
    'a device that cannot share says so instead of claiming success',
    (tester) async {
      await pumpOverHome(
        tester,
        pages: drafts([pageA]),
        exporter: const PdfFileExporter(),
      );
      await mockShareChannel(
        tester,
        (call) async => call.method == 'shareFile' ? false : null,
      );

      await createPdf(tester);

      await tester.tap(find.text('Share'));
      await tester.pump();
      await tester.pump();

      expect(
        find.text('No app on this device could open the share sheet.'),
        findsOneWidget,
      );
      // The file is still there to try the other way out.
      expect(find.text('Save a copy'), findsOneWidget);
    },
  );
}
