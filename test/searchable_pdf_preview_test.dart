import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdf_utility_flutter/pdf/data/pdf_file_exporter.dart';
import 'package:pdf_utility_flutter/pdf/domain/pdf_creation.dart';
import 'package:pdf_utility_flutter/pdf/domain/pdf_exception.dart';
import 'package:pdf_utility_flutter/pdf/presentation/searchable_pdf_preview_screen.dart';
import 'package:pdf_utility_flutter/pdf/presentation/searchable_pdf_screen.dart';
import 'package:pdf_utility_flutter/pdf/domain/pdf_source_service.dart';

/// Counts what the screen asked the exporter to do, without a platform.
class _RecordingExporter extends PdfFileExporter {
  _RecordingExporter();

  int saves = 0;
  int shares = 0;

  @override
  Future<String?> saveToDownloads(CreatedPdf pdf) async {
    saves++;
    return 'Downloads/${pdf.fileName}';
  }

  @override
  Future<bool> share(CreatedPdf pdf, {String? subject}) async {
    shares++;
    return true;
  }
}

class _FakeSurface extends StatefulWidget {
  const _FakeSurface({
    required this.pages,
    required this.onLoaded,
    required this.onPageChanged,
  });

  final int pages;
  final ValueChanged<int> onLoaded;
  final ValueChanged<int> onPageChanged;

  @override
  State<_FakeSurface> createState() => _FakeSurfaceState();
}

class _FakeSurfaceState extends State<_FakeSurface> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => widget.onLoaded(widget.pages),
    );
  }

  @override
  Widget build(BuildContext context) => Center(
    child: TextButton(
      onPressed: () => widget.onPageChanged(3),
      child: const Text('fake page'),
    ),
  );
}

class _FixedSource implements PdfSourceService {
  const _FixedSource(this.path);

  final String? path;

  @override
  Future<String?> pickPdf() async => path;
}

void main() {
  late Directory work;
  late File pdf;

  setUp(() {
    work = Directory.systemTemp.createTempSync('searchable_preview_test');
    pdf = File('${work.path}/Newspaper Scan.pdf')
      ..writeAsBytesSync(List<int>.filled(2048, 7));
  });

  tearDown(() {
    if (work.existsSync()) work.deleteSync(recursive: true);
  });

  // A surface that reports a page count once, and lets a test drive page
  // changes. Reporting on every build would loop forever (the screen's setState
  // rebuilds it), so the report lives in initState.
  Widget fakeSurface(
    BuildContext context, {
    required ValueChanged<int> onLoaded,
    required ValueChanged<int> onPageChanged,
    int pages = 9,
  }) => _FakeSurface(
    pages: pages,
    onLoaded: onLoaded,
    onPageChanged: onPageChanged,
  );

  testWidgets('the document, its size and its pages are shown up front', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: SearchablePdfPreviewScreen(
          path: pdf.path,
          // The viewer is opened by the real flow; these tests inspect the
          // screen's own states, so the hand-off is stubbed out.
          onConverted: (_, _) {},
          convert: ({required inputPath, onProgress}) async =>
              throw StateError('not used'),
          surface: (context, {required onLoaded, required onPageChanged}) =>
              fakeSurface(
                context,
                onLoaded: onLoaded,
                onPageChanged: onPageChanged,
              ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    // The size comes from the file system, which needs the real event loop.
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 60)),
    );
    await tester.pumpAndSettle();

    // File name, page count and size: one compact header, no filename card.
    expect(find.text('Newspaper Scan.pdf'), findsOneWidget);
    expect(find.textContaining('9 pages'), findsOneWidget);
    expect(find.textContaining('2 KB'), findsOneWidget);

    // The page indicator reports the page the reader is on.
    expect(find.text('Page 1 of 9'), findsOneWidget);
    await tester.tap(find.text('fake page'));
    await tester.pump();
    expect(find.text('Page 3 of 9'), findsOneWidget);

    // One primary action, and it says exactly what it does.
    expect(
      find.widgetWithText(FilledButton, 'Make Searchable PDF'),
      findsOneWidget,
    );
  });

  testWidgets(
    'progress replaces the action, page by page, and cannot restart',
    (tester) async {
      final completer = Completer<CreatedPdf>();
      var runs = 0;
      void Function(int, int)? report;

      await tester.pumpWidget(
        MaterialApp(
          home: SearchablePdfPreviewScreen(
            path: pdf.path,
            // The viewer is opened by the real flow; these tests inspect the
            // screen's own states, so the hand-off is stubbed out.
            onConverted: (_, _) {},
            convert: ({required inputPath, onProgress}) {
              runs++;
              report = onProgress;
              return completer.future;
            },
            surface: (context, {required onLoaded, required onPageChanged}) =>
                fakeSurface(
                  context,
                  onLoaded: onLoaded,
                  onPageChanged: onPageChanged,
                ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(
        find.widgetWithText(FilledButton, 'Make Searchable PDF'),
      );
      await tester.pump();

      // The strip is now the progress readout, not a button to press again.
      expect(
        find.widgetWithText(FilledButton, 'Make Searchable PDF'),
        findsNothing,
      );
      expect(find.text('Processing page 1 of 9'), findsOneWidget);
      expect(find.text('0%'), findsOneWidget);

      report!(4, 9);
      await tester.pump();
      expect(find.text('Processing page 4 of 9'), findsOneWidget);
      expect(find.text('44%'), findsOneWidget);

      report!(9, 9);
      await tester.pump();
      expect(find.text('100%'), findsOneWidget);

      // A tap while it runs must not start a second conversion.
      await tester.tap(find.text('100%'), warnIfMissed: false);
      await tester.pump();
      expect(runs, 1);

      completer.complete(
        CreatedPdf(
          path: pdf.path,
          fileName: 'Newspaper Scan (searchable).pdf',
          pageCount: 9,
          byteSize: 4096,
        ),
      );
      await tester.pumpAndSettle();
    },
  );

  testWidgets('finishing hands over the new file with Save and Share', (
    tester,
  ) async {
    final exporter = _RecordingExporter();

    await tester.pumpWidget(
      MaterialApp(
        home: SearchablePdfPreviewScreen(
          path: pdf.path,
          // The viewer is opened by the real flow; these tests inspect the
          // screen's own states, so the hand-off is stubbed out.
          onConverted: (_, _) {},
          exporter: exporter,
          convert: ({required inputPath, onProgress}) async {
            onProgress?.call(9, 9);
            return CreatedPdf(
              path: pdf.path,
              fileName: 'Newspaper Scan (searchable).pdf',
              pageCount: 9,
              byteSize: 4096,
            );
          },
          surface: (context, {required onLoaded, required onPageChanged}) =>
              fakeSurface(
                context,
                onLoaded: onLoaded,
                onPageChanged: onPageChanged,
              ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(FilledButton, 'Make Searchable PDF'));
    await tester.pumpAndSettle();

    // Completion state: what was made, how big it is, and the two ways out.
    expect(find.text('Searchable PDF ready'), findsOneWidget);
    expect(find.text('Newspaper Scan (searchable).pdf'), findsOneWidget);
    expect(find.textContaining('9 pages'), findsWidgets);
    expect(find.textContaining('4 KB'), findsOneWidget);

    await tester.tap(find.text('Save PDF'));
    await tester.pumpAndSettle();
    expect(exporter.saves, 1);
    expect(find.textContaining('Saved to Downloads/'), findsOneWidget);

    await tester.tap(find.text('Share PDF'));
    await tester.pumpAndSettle();
    expect(exporter.shares, 1);
  });

  testWidgets('a failure explains itself and keeps the document usable', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: SearchablePdfPreviewScreen(
          path: pdf.path,
          // The viewer is opened by the real flow; these tests inspect the
          // screen's own states, so the hand-off is stubbed out.
          onConverted: (_, _) {},
          convert: ({required inputPath, onProgress}) async =>
              throw const PdfException(
                PdfErrorKind.unreadable,
                'That file is no longer available.',
              ),
          surface: (context, {required onLoaded, required onPageChanged}) =>
              fakeSurface(
                context,
                onLoaded: onLoaded,
                onPageChanged: onPageChanged,
              ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(FilledButton, 'Make Searchable PDF'));
    await tester.pumpAndSettle();

    expect(find.text('That file is no longer available.'), findsOneWidget);
    // The button is back, so a transient failure can simply be retried.
    expect(
      find.widgetWithText(FilledButton, 'Make Searchable PDF'),
      findsOneWidget,
    );
  });

  testWidgets('choosing a document opens its preview, not a filename row', (
    tester,
  ) async {
    String? previewed;
    await tester.pumpWidget(
      MaterialApp(
        home: SearchablePdfScreen(
          source: _FixedSource(pdf.path),
          previewBuilder: (context, path) {
            previewed = path;
            return const Scaffold(body: Text('preview'));
          },
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(FilledButton, 'Choose PDF'));
    await tester.pumpAndSettle();

    expect(previewed, pdf.path);
    expect(find.text('preview'), findsOneWidget);
  });

  testWidgets('cancelling the picker stays on the pick screen', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: SearchablePdfScreen(
          source: const _FixedSource(null),
          previewBuilder: (context, path) =>
              const Scaffold(body: Text('should not open')),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(FilledButton, 'Choose PDF'));
    await tester.pumpAndSettle();

    expect(find.text('should not open'), findsNothing);
    expect(find.text('Choose a PDF to make searchable'), findsOneWidget);
  });
}
