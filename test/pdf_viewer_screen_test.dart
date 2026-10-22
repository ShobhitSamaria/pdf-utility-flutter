import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdf_utility_flutter/pdf/presentation/pdf_viewer_screen.dart';

/// Stands in for `pdfx`'s page view.
///
/// The real surface needs native PDFium, which no widget test has — so the
/// screen is written against a builder (see [PdfDocumentSurface]) and this is
/// the other implementation of it. Everything the screen decides — page state,
/// navigation, the error state, the Select-pages action — is therefore under
/// test, and only the rasterisation itself is left to the device.
class _StubSurface extends StatefulWidget {
  const _StubSurface({
    required this.pageCount,
    required this.failure,
    required this.requestedPage,
    required this.onPageChanged,
    required this.onLoaded,
    required this.onError,
  });

  final int pageCount;
  final Object? failure;
  final int? requestedPage;
  final ValueChanged<int> onPageChanged;
  final ValueChanged<int> onLoaded;
  final ValueChanged<Object> onError;

  @override
  State<_StubSurface> createState() => _StubSurfaceState();
}

class _StubSurfaceState extends State<_StubSurface> {
  int _page = 1;

  @override
  void initState() {
    super.initState();
    // After the first frame, the way the real surface reports a loaded document.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (widget.failure != null) {
        widget.onError(widget.failure!);
      } else {
        widget.onLoaded(widget.pageCount);
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

void main() {
  PdfDocumentSurface stub({int pageCount = 3, Object? failure}) =>
      (
        BuildContext context, {
        required int? requestedPage,
        required ValueChanged<int> onPageChanged,
        required ValueChanged<int> onLoaded,
        required ValueChanged<Object> onError,
      }) => _StubSurface(
        pageCount: pageCount,
        failure: failure,
        requestedPage: requestedPage,
        onPageChanged: onPageChanged,
        onLoaded: onLoaded,
        onError: onError,
      );

  Widget harness({
    String path = '/tmp/imported/My Document.pdf',
    String? title,
    PdfDocumentSurface? surface,
    int pageCount = 3,
    Object? failure,
    Future<void> Function(BuildContext context)? onSelectPages,
  }) => MaterialApp(
    home: PdfViewerScreen(
      path: path,
      title: title,
      surface: surface ?? stub(pageCount: pageCount, failure: failure),
      onSelectPages: onSelectPages,
    ),
  );

  /// The action behind a tooltip. `find.byTooltip` finds the `Tooltip` widget,
  /// which is not the button — the button is its ancestor.
  IconButton buttonWithTooltip(WidgetTester tester, String tooltip) =>
      tester.widget<IconButton>(
        find.ancestor(
          of: find.byTooltip(tooltip),
          matching: find.byType(IconButton),
        ),
      );

  testWidgets('names the document and reports its page count', (tester) async {
    await tester.pumpWidget(harness());
    await tester.pump();
    await tester.pump();

    // The title is the file name, not the whole path.
    expect(find.text('My Document.pdf'), findsOneWidget);
    expect(find.text('Page 1 of 3'), findsOneWidget);
  });

  testWidgets('an explicit title wins over the file name', (tester) async {
    await tester.pumpWidget(harness(title: 'Holiday reading'));
    await tester.pump();
    await tester.pump();

    expect(find.text('Holiday reading'), findsOneWidget);
  });

  testWidgets('next and previous move one page, and stop at the ends', (
    tester,
  ) async {
    await tester.pumpWidget(harness());
    await tester.pump();
    await tester.pump();

    // On the first page, going back is not offered.
    expect(buttonWithTooltip(tester, 'Previous page').onPressed, isNull);

    await tester.tap(find.byTooltip('Next page'));
    await tester.pump();
    await tester.pump();
    expect(find.text('Page 2 of 3'), findsOneWidget);

    // Now both directions are available.
    expect(buttonWithTooltip(tester, 'Previous page').onPressed, isNotNull);

    await tester.tap(find.byTooltip('Next page'));
    await tester.pump();
    await tester.pump();
    expect(find.text('Page 3 of 3'), findsOneWidget);
    // The last page: there is nowhere further to go.
    expect(buttonWithTooltip(tester, 'Next page').onPressed, isNull);

    await tester.tap(find.byTooltip('Previous page'));
    await tester.pump();
    await tester.pump();
    expect(find.text('Page 2 of 3'), findsOneWidget);
  });

  testWidgets('Select pages opens the page-selection step', (tester) async {
    var opened = 0;
    await tester.pumpWidget(harness(onSelectPages: (_) async => opened++));
    await tester.pump();
    await tester.pump();

    await tester.tap(find.byTooltip('Select pages'));
    await tester.pump();

    expect(opened, 1);
  });

  testWidgets('Select pages is not offered before the document is known', (
    tester,
  ) async {
    // No page count yet: the action cannot do anything, so it is disabled
    // rather than opening a grid of nothing.
    await tester.pumpWidget(
      harness(
        surface:
            (
              context, {
              required requestedPage,
              required onPageChanged,
              required onLoaded,
              required onError,
            }) => const SizedBox.shrink(),
      ),
    );
    await tester.pump();

    expect(find.text('Opening…'), findsOneWidget);
    expect(buttonWithTooltip(tester, 'Select pages').onPressed, isNull);
  });

  testWidgets(
    'a document that cannot be opened says so, and offers a way out',
    (tester) async {
      await tester.pumpWidget(harness(failure: Exception('damaged')));
      await tester.pump();
      await tester.pump();

      expect(find.text('This PDF could not be opened'), findsOneWidget);
      expect(find.textContaining('password'), findsOneWidget);
      expect(find.text('Go back'), findsOneWidget);
      expect(buttonWithTooltip(tester, 'Select pages').onPressed, isNull);
    },
  );

  testWidgets('a single page document has no navigation', (tester) async {
    await tester.pumpWidget(harness(pageCount: 1));
    await tester.pump();
    await tester.pump();

    expect(find.text('Page 1 of 1'), findsOneWidget);
    expect(buttonWithTooltip(tester, 'Previous page').onPressed, isNull);
    expect(buttonWithTooltip(tester, 'Next page').onPressed, isNull);
    // It can still be read and its pages selected for a new document.
    expect(buttonWithTooltip(tester, 'Select pages').onPressed, isNotNull);
  });

  group('pdfFileLooksReadable', () {
    test('is true for a file that exists and has content', () async {
      final directory = await Directory.systemTemp.createTemp(
        'pdf_viewer_test',
      );
      addTearDown(() async {
        if (directory.existsSync()) await directory.delete(recursive: true);
      });

      final file = File('${directory.path}/doc.pdf');
      await file.writeAsString('%PDF-1.4\n%%EOF\n');
      expect(pdfFileLooksReadable(file.path), isTrue);

      // A zero-byte file is not a document, whatever its name.
      final empty = File('${directory.path}/empty.pdf');
      await empty.writeAsString('');
      expect(pdfFileLooksReadable(empty.path), isFalse);

      expect(pdfFileLooksReadable('${directory.path}/missing.pdf'), isFalse);
    });
  });
}
