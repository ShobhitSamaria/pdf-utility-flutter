import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdf_utility_flutter/ocr/domain/ocr_block.dart';
import 'package:pdf_utility_flutter/ocr/domain/ocr_element.dart';
import 'package:pdf_utility_flutter/ocr/domain/ocr_line.dart';
import 'package:pdf_utility_flutter/ocr/domain/ocr_rect.dart';
import 'package:pdf_utility_flutter/ocr/domain/ocr_result.dart';
import 'package:pdf_utility_flutter/screens/widgets/extracted_text_view.dart';

OcrElement _word(String text, double l, double t, double r, double b) =>
    OcrElement(text: text, boundingBox: OcrRect.fromLTRB(l, t, r, b));

OcrResult _result(String text) {
  final rawLines = [
    for (final line in text.split('\n'))
      if (line.trim().isNotEmpty) line,
  ];
  final lines = <OcrLine>[];
  final words = <OcrElement>[];
  for (var i = 0; i < rawLines.length; i++) {
    final lineWords = <OcrElement>[];
    var x = 50.0;
    for (final token in rawLines[i].split(' ')) {
      if (token.isEmpty) continue;
      final word = _word(token, x, i * 100.0 + 50, x + 80, i * 100.0 + 90);
      lineWords.add(word);
      words.add(word);
      x += 90;
    }
    lines.add(
      OcrLine(
        text: rawLines[i],
        boundingBox: OcrRect.fromLTRB(50, i * 100.0 + 50, x, i * 100.0 + 90),
        elements: lineWords,
      ),
    );
  }
  return OcrResult(
    sourceImage: const SourceImageInfo(
      path: '/tmp/does-not-exist.jpg',
      width: 1000,
      height: 1000,
    ),
    fullText: text,
    blocks: [
      OcrBlock(
        text: text,
        boundingBox: OcrRect.fromLTRB(0, 0, 1000, 1000),
        lines: lines,
      ),
    ],
    engineName: 'Fake',
    elapsed: const Duration(milliseconds: 120),
  );
}

void main() {
  late String? copied;

  setUp(() {
    copied = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
          if (call.method == 'Clipboard.setData') {
            copied = (call.arguments as Map)['text'] as String?;
          }
          return null;
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
  });

  Widget harness({
    String text = 'The quick brown fox\njumps over the lazy dog',
    ValueChanged<String>? onSearchOnPhoto,
  }) => MaterialApp(
    home: Scaffold(
      body: ExtractedTextView(
        result: _result(text),
        onSearchOnPhoto: onSearchOnPhoto,
      ),
    ),
  );

  testWidgets('shows the page as readable text, one line at a time', (
    tester,
  ) async {
    await tester.pumpWidget(harness());

    expect(find.text('Extracted text'), findsOneWidget);
    expect(find.text('The quick brown fox'), findsOneWidget);
    expect(find.text('jumps over the lazy dog'), findsOneWidget);
    // A summary of what was recognized, so the text has provenance.
    expect(find.textContaining('1 blocks'), findsOneWidget);
    expect(find.textContaining('9 words'), findsOneWidget);
  });

  testWidgets('Copy all puts the whole text on the clipboard', (tester) async {
    await tester.pumpWidget(harness());

    await tester.tap(find.text('Copy all'));
    await tester.pump();

    // The two lines are a printed paragraph apart, so the copied page keeps the
    // paragraph break — and keeps every word.
    expect(copied, 'The quick brown fox\n\njumps over the lazy dog');
    expect(find.text('Copied to clipboard'), findsOneWidget);
  });

  testWidgets('searching reports how many matches the text contains', (
    tester,
  ) async {
    await tester.pumpWidget(harness(text: 'the cat sat on the mat'));

    await tester.enterText(find.byType(TextField), 'at');
    await tester.pump();

    // "cat", "sat" and "mat".
    expect(find.text('1 / 3'), findsOneWidget);
  });

  testWidgets('next and previous step through matches and wrap around', (
    tester,
  ) async {
    await tester.pumpWidget(harness(text: 'the cat sat on the mat'));

    await tester.enterText(find.byType(TextField), 'at');
    await tester.pump();
    expect(find.text('1 / 3'), findsOneWidget);

    await tester.tap(find.byTooltip('Next match'));
    await tester.pump();
    expect(find.text('2 / 3'), findsOneWidget);

    await tester.tap(find.byTooltip('Previous match'));
    await tester.pump();
    expect(find.text('1 / 3'), findsOneWidget);

    // Wrapping backwards from the first match lands on the last.
    await tester.tap(find.byTooltip('Previous match'));
    await tester.pump();
    expect(find.text('3 / 3'), findsOneWidget);
  });

  testWidgets('a query with no matches says so rather than showing 0 / 0', (
    tester,
  ) async {
    await tester.pumpWidget(harness());

    await tester.enterText(find.byType(TextField), 'zebra');
    await tester.pump();

    expect(find.text('No matches'), findsOneWidget);
  });

  testWidgets('a query highlights the matched text', (tester) async {
    await tester.pumpWidget(harness(text: 'the cat sat on the mat'));

    expect(find.byType(SelectableText), findsWidgets);
    await tester.enterText(find.byType(TextField), 'cat');
    await tester.pump();

    // Highlighting switches the line to a rich text span.
    expect(find.byType(SelectableText), findsWidgets);
    expect(find.text('1 / 1'), findsOneWidget);
  });

  testWidgets('Show on photo hands the query back and closes the sheet', (
    tester,
  ) async {
    final queries = <String>[];
    await tester.pumpWidget(harness(onSearchOnPhoto: queries.add));

    await tester.enterText(find.byType(TextField), 'fox');
    await tester.pump();

    await tester.tap(find.text('Show on photo'));
    await tester.pump();

    expect(queries, <String>['fox']);
  });

  testWidgets('no photo handoff means no Show on photo action', (tester) async {
    await tester.pumpWidget(harness());
    expect(find.text('Show on photo'), findsNothing);
  });

  testWidgets('an empty result says so instead of showing a blank sheet', (
    tester,
  ) async {
    await tester.pumpWidget(harness(text: ''));

    expect(find.text('No text was extracted from this image.'), findsOneWidget);
    // Nothing to copy and nothing to search.
    final copyAll = tester.widget<TextButton>(
      find.ancestor(
        of: find.text('Copy all'),
        matching: find.byType(TextButton),
      ),
    );
    expect(copyAll.onPressed, isNull);
    expect(find.byType(TextField), findsNothing);
  });
}
