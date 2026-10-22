import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdf_utility_flutter/screens/widgets/selection_action_bar.dart';

const _longText =
    'Pages (Without Cover) Worldwide information M.R. Vasudevan Nair, '
    'published by the Sahitya Akademi, is widely regarded as one of the most '
    'important novels in modern Malayalam literature.';

Widget harness({
  String text = _longText,
  int wordCount = 3,
  VoidCallback? onCopy,
  VoidCallback? onSearch,
  VoidCallback? onTranslate,
  VoidCallback? onClear,
}) {
  return MaterialApp(
    home: Scaffold(
      body: Align(
        alignment: Alignment.bottomCenter,
        child: SelectionActionBar(
          selectedText: text,
          wordCount: wordCount,
          onCopy: onCopy ?? () {},
          onSearch: onSearch ?? () {},
          onTranslate: onTranslate ?? () {},
          onClear: onClear ?? () {},
        ),
      ),
    ),
  );
}

void main() {
  testWidgets('collapsed shows a truncated preview, the actions, and the count', (
    tester,
  ) async {
    await tester.pumpWidget(harness());

    expect(find.text('3 words selected'), findsOneWidget);
    expect(find.text('Copy'), findsOneWidget);
    expect(find.text('Search'), findsOneWidget);
    expect(find.text('Translate'), findsOneWidget);

    // Collapsed: no full-text surface yet, and the preview is clipped to 2 lines.
    expect(find.byType(SelectableText), findsNothing);
    final preview = tester.widget<Text>(find.text(_longText));
    expect(preview.maxLines, 2);
    expect(preview.overflow, TextOverflow.ellipsis);
  });

  testWidgets('tapping the header expands to the full, wrapped text', (
    tester,
  ) async {
    await tester.pumpWidget(harness());

    await tester.tap(find.text('3 words selected'));
    await tester.pumpAndSettle();

    expect(find.text('Selected text'), findsOneWidget);
    final full = tester.widget<SelectableText>(find.byType(SelectableText));
    expect(full.data, _longText);
  });

  testWidgets('swiping up expands and swiping down collapses', (tester) async {
    await tester.pumpWidget(harness());

    await tester.drag(find.text('3 words selected'), const Offset(0, -140));
    await tester.pumpAndSettle();
    expect(find.byType(SelectableText), findsOneWidget);

    await tester.drag(find.text('Selected text'), const Offset(0, 140));
    await tester.pumpAndSettle();
    expect(find.byType(SelectableText), findsNothing);
  });

  testWidgets('the actions stay reachable while expanded and fire callbacks', (
    tester,
  ) async {
    var copied = 0;
    var searched = 0;
    var translated = 0;
    await tester.pumpWidget(
      harness(
        onCopy: () => copied++,
        onSearch: () => searched++,
        onTranslate: () => translated++,
      ),
    );

    await tester.tap(find.text('3 words selected'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Copy'));
    await tester.tap(find.text('Search'));
    await tester.tap(find.text('Translate'));
    await tester.pump();

    expect(copied, 1);
    expect(searched, 1);
    expect(translated, 1);
  });

  testWidgets('a single word is described in the singular', (tester) async {
    await tester.pumpWidget(harness(text: 'Hello', wordCount: 1));
    expect(find.text('1 word selected'), findsOneWidget);
  });
}
