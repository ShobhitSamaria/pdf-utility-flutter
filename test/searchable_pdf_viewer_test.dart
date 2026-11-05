import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdf_utility_flutter/pdf/data/pdf_file_exporter.dart';
import 'package:pdf_utility_flutter/pdf/domain/pdf_creation.dart';
import 'package:pdf_utility_flutter/pdf/domain/pdf_text_layer.dart';
import 'package:pdf_utility_flutter/pdf/presentation/searchable_pdf_viewer_screen.dart';

/// Records export calls without a platform channel.
class _RecordingExporter extends PdfFileExporter {
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

/// Stands in for `pdfx`: reports the document and honours requested jumps.
class _StubSurface extends StatefulWidget {
  const _StubSurface({
    required this.pageCount,
    required this.requestedPage,
    required this.onLoaded,
    required this.onPageChanged,
  });

  final int pageCount;
  final int? requestedPage;
  final ValueChanged<int> onLoaded;
  final ValueChanged<int> onPageChanged;

  @override
  State<_StubSurface> createState() => _StubSurfaceState();
}

class _StubSurfaceState extends State<_StubSurface> {
  int _page = 1;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      widget.onLoaded(widget.pageCount);
      // A page requested before the document is ready is applied on load, just
      // as the real surface does.
      final target = widget.requestedPage;
      if (target != null) {
        _page = target;
        widget.onPageChanged(target);
      }
    });
  }

  @override
  void didUpdateWidget(covariant _StubSurface oldWidget) {
    super.didUpdateWidget(oldWidget);
    final target = widget.requestedPage;
    if (target != null && target != oldWidget.requestedPage) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _page = target;
        widget.onPageChanged(target);
      });
    }
  }

  @override
  Widget build(BuildContext context) =>
      Center(child: Text('page $_page of ${widget.pageCount}'));
}

PdfTextLayer _layer({bool withText = true}) => PdfTextLayer(
  pages: [
    PdfTextPage(
      pageNumber: 1,
      width: 400,
      height: 300,
      runs: [
        PdfTextRun(
          text: withText ? 'Recovery 80' : '',
          left: 0.05,
          top: 0.1,
          right: 0.6,
          bottom: 0.2,
        ),
      ],
    ),
    PdfTextPage(
      pageNumber: 2,
      width: 300,
      height: 400,
      runs: [
        PdfTextRun(
          text: withText ? 'Total 120' : '',
          left: 0.1,
          top: 0.4,
          right: 0.5,
          bottom: 0.48,
        ),
        PdfTextRun(
          text: withText ? 'Revenue' : '',
          left: 0.55,
          top: 0.4,
          right: 0.8,
          bottom: 0.48,
        ),
      ],
    ),
    PdfTextPage(
      pageNumber: 3,
      width: 400,
      height: 300,
      runs: [
        PdfTextRun(
          text: withText ? 'पवन सामरिया' : '',
          left: 0.2,
          top: 0.6,
          right: 0.5,
          bottom: 0.68,
        ),
        PdfTextRun(
          text: withText ? 'ज़रूरत Invoice' : '',
          left: 0.55,
          top: 0.6,
          right: 0.8,
          bottom: 0.68,
        ),
      ],
    ),
  ],
);

void main() {
  Widget harness({
    PdfTextLayer? layer,
    PdfFileExporter? exporter,
    bool withText = true,
    String? initialQuery,
  }) => MaterialApp(
    home: SearchablePdfViewerScreen(
      path: '/tmp/created/Scan (searchable).pdf',
      title: 'Scan (searchable).pdf',
      textLayer: layer ?? _layer(withText: withText),
      exporter: exporter ?? _RecordingExporter(),
      initialQuery: initialQuery,
      surface:
          (
            context, {
            required path,
            required requestedPage,
            required onLoaded,
            required onPageChanged,
            required onError,
          }) => _StubSurface(
            pageCount: 3,
            requestedPage: requestedPage,
            onLoaded: onLoaded,
            onPageChanged: onPageChanged,
          ),
    ),
  );

  testWidgets('opening with a query shows its hits and jumps to the first', (
    tester,
  ) async {
    await tester.pumpWidget(harness(initialQuery: 'Total 120'));
    await tester.pump();
    await tester.pump();

    expect(find.text('Total 120'), findsWidgets);
    expect(find.text('1 match'), findsOneWidget);
    expect(find.text('page 2 of 3'), findsOneWidget);
  });

  testWidgets('opens the generated file and offers search', (tester) async {
    await tester.pumpWidget(harness());
    await tester.pump();
    await tester.pump();

    expect(find.text('Scan (searchable).pdf'), findsOneWidget);
    expect(find.text('Page 1 of 3'), findsOneWidget);
    expect(find.byTooltip('Search'), findsOneWidget);
  });

  testWidgets('search finds text and jumps to the page it is on', (
    tester,
  ) async {
    await tester.pumpWidget(harness());
    await tester.pump();
    await tester.pump();

    await tester.tap(find.byTooltip('Search'));
    await tester.pump();
    expect(find.text('Search Hindi or English text'), findsOneWidget);

    await tester.enterText(find.byType(TextField), 'Total 120');
    await tester.pump();

    // A result, with the page it is on.
    expect(find.text('1 match'), findsOneWidget);
    expect(find.textContaining('Total 120 Revenue'), findsWidgets);
    expect(find.text('Page 2'), findsOneWidget);

    await tester.tap(find.text('Page 2'));
    await tester.pump();
    await tester.pump();

    // The viewer actually moved to page 2, where the match is.
    expect(find.text('page 2 of 3'), findsOneWidget);
  });

  testWidgets('Hindi is searchable like English', (tester) async {
    await tester.pumpWidget(harness());
    await tester.pump();
    await tester.pump();

    await tester.tap(find.byTooltip('Search'));
    await tester.pump();
    await tester.enterText(find.byType(TextField), 'सामरिया');
    await tester.pump();

    expect(find.text('1 match'), findsOneWidget);
    expect(find.text('Page 3'), findsOneWidget);
  });

  testWidgets('a query with no hits says so, and does not jump', (
    tester,
  ) async {
    await tester.pumpWidget(harness());
    await tester.pump();
    await tester.pump();

    await tester.tap(find.byTooltip('Search'));
    await tester.pump();
    await tester.enterText(find.byType(TextField), 'nothing here');
    await tester.pump();

    expect(find.text('No matches for “nothing here”'), findsOneWidget);
    expect(find.text('page 1 of 3'), findsOneWidget);
  });

  testWidgets('search is not offered on a document without a text layer', (
    tester,
  ) async {
    await tester.pumpWidget(harness(layer: _layer(withText: false)));
    await tester.pump();
    await tester.pump();

    expect(find.byTooltip('No searchable text found'), findsOneWidget);
  });

  testWidgets('English search ignores case', (tester) async {
    await tester.pumpWidget(harness());
    await tester.pump();
    await tester.pump();

    await tester.tap(find.byTooltip('Search'));
    await tester.pump();
    await tester.enterText(find.byType(TextField), 'total 120');
    await tester.pump();

    expect(find.text('1 match'), findsOneWidget);
    expect(find.text('Page 2'), findsOneWidget);
  });

  testWidgets('Devanagari with a nukta is searchable', (tester) async {
    await tester.pumpWidget(harness());
    await tester.pump();
    await tester.pump();

    await tester.tap(find.byTooltip('Search'));
    await tester.pump();
    await tester.enterText(find.byType(TextField), 'ज़रूरत');
    await tester.pump();

    expect(find.text('1 match'), findsOneWidget);
    expect(find.text('Page 3'), findsOneWidget);
  });

  testWidgets('a mixed Hindi + English query spans adjacent runs', (
    tester,
  ) async {
    await tester.pumpWidget(harness());
    await tester.pump();
    await tester.pump();

    await tester.tap(find.byTooltip('Search'));
    await tester.pump();
    await tester.enterText(find.byType(TextField), 'ज़रूरत invoice');
    await tester.pump();

    expect(find.text('1 match'), findsOneWidget);
    expect(find.text('Page 3'), findsOneWidget);
  });

  testWidgets('a query spanning two runs is still one result', (tester) async {
    await tester.pumpWidget(harness());
    await tester.pump();
    await tester.pump();

    await tester.tap(find.byTooltip('Search'));
    await tester.pump();
    await tester.enterText(find.byType(TextField), 'Total 120 Revenue');
    await tester.pump();

    expect(find.text('1 match'), findsOneWidget);
    expect(find.text('Page 2'), findsOneWidget);
  });

  testWidgets('Save and Share are optional, and both work', (tester) async {
    final exporter = _RecordingExporter();
    await tester.pumpWidget(harness(exporter: exporter));
    await tester.pump();
    await tester.pump();

    await tester.tap(find.byTooltip('Save or share'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Save PDF'));
    await tester.pumpAndSettle();
    expect(exporter.saves, 1);
    expect(find.textContaining('Saved to Downloads/'), findsOneWidget);

    await tester.tap(find.byTooltip('Save or share'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Share PDF'));
    await tester.pumpAndSettle();
    expect(exporter.shares, 1);
  });
}
