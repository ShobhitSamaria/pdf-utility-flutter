import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdf_utility_flutter/ocr/domain/ocr_block.dart';
import 'package:pdf_utility_flutter/ocr/domain/ocr_element.dart';
import 'package:pdf_utility_flutter/ocr/domain/ocr_line.dart';
import 'package:pdf_utility_flutter/ocr/domain/ocr_rect.dart';
import 'package:pdf_utility_flutter/ocr/domain/ocr_result.dart';
import 'package:pdf_utility_flutter/ocr/domain/ocr_selection.dart';
import 'package:pdf_utility_flutter/ocr/presentation/widgets/ocr_overlay.dart';

OcrElement _word(String text, double l, double t, double r, double b) =>
    OcrElement(text: text, boundingBox: OcrRect.fromLTRB(l, t, r, b));

void main() {
  final left = _word('Left', 100, 100, 300, 200);
  final right = _word('Right', 600, 100, 900, 200);

  final result = OcrResult(
    sourceImage: const SourceImageInfo(
      path: '/tmp/does-not-exist.jpg',
      width: 1000,
      height: 1000,
    ),
    fullText: 'Left Right',
    blocks: [
      OcrBlock(
        text: 'Left Right',
        boundingBox: OcrRect.fromLTRB(100, 100, 900, 200),
        lines: [
          OcrLine(
            text: 'Left Right',
            boundingBox: OcrRect.fromLTRB(100, 100, 900, 200),
            elements: [left, right],
          ),
        ],
      ),
    ],
  );

  // Overlay placed at the top-left of a 200x400 box: square image -> scale 0.2,
  // displayed 200x200 with a 100px vertical letterbox.
  Widget harness({
    required OcrSelection selection,
    ValueChanged<OcrElement?>? onTap,
    ValueChanged<OcrElement>? onLongPress,
  }) {
    return MaterialApp(
      home: Align(
        alignment: Alignment.topLeft,
        child: SizedBox(
          width: 200,
          height: 400,
          child: OcrOverlay(
            result: result,
            selection: selection,
            onElementTap: onTap,
            onElementLongPress: onLongPress,
          ),
        ),
      ),
    );
  }

  testWidgets('tap on a word reports that word', (tester) async {
    OcrElement? tapped;
    await tester.pumpWidget(
      harness(selection: OcrSelection.empty(result), onTap: (e) => tapped = e),
    );

    await tester.tapAt(const Offset(40, 130)); // inside "Left"
    expect(tapped, left);
  });

  testWidgets('tap on empty image area reports null', (tester) async {
    OcrElement? tapped = left;
    var called = false;
    await tester.pumpWidget(
      harness(
        selection: OcrSelection.empty(result),
        onTap: (e) {
          called = true;
          tapped = e;
        },
      ),
    );

    await tester.tapAt(const Offset(100, 200)); // over image, no word
    expect(called, isTrue);
    expect(tapped, isNull);
  });

  testWidgets('tap in the letterbox band reports null', (tester) async {
    OcrElement? tapped = left;
    await tester.pumpWidget(
      harness(selection: OcrSelection.empty(result), onTap: (e) => tapped = e),
    );

    await tester.tapAt(const Offset(40, 50)); // top letterbox band
    expect(tapped, isNull);
  });

  testWidgets('long-press on a word reports that word', (tester) async {
    OcrElement? longPressed;
    await tester.pumpWidget(
      harness(
        selection: OcrSelection.empty(result),
        onLongPress: (e) => longPressed = e,
      ),
    );

    await tester.longPressAt(const Offset(150, 130)); // inside "Right"
    expect(longPressed, right);
  });

  testWidgets('selected word renders a highlight', (tester) async {
    await tester.pumpWidget(
      harness(selection: OcrSelection.empty(result).only(left)),
    );
    await tester.pump();

    // Exactly one selection highlight DecoratedBox with a border should exist.
    final highlighted = find.byWidgetPredicate((w) {
      if (w is! DecoratedBox) return false;
      final deco = w.decoration;
      return deco is BoxDecoration && deco.border != null;
    });
    expect(highlighted, findsOneWidget);
  });

  testWidgets('no highlight is drawn when nothing is selected', (tester) async {
    await tester.pumpWidget(harness(selection: OcrSelection.empty(result)));
    await tester.pump();

    final highlighted = find.byWidgetPredicate((w) {
      if (w is! DecoratedBox) return false;
      final deco = w.decoration;
      return deco is BoxDecoration && deco.border != null;
    });
    expect(highlighted, findsNothing);
  });

  testWidgets('long-press then drag selects a range of words', (tester) async {
    var ended = false;
    await tester.pumpWidget(
      _DragHarness(result: result, onEnd: () => ended = true),
    );

    // Press on "Left" and hold long enough for the long-press to be recognized.
    final gesture = await tester.startGesture(const Offset(40, 130));
    await tester.pump(const Duration(milliseconds: 600));
    expect(_highlightCount(tester), 1, reason: 'anchor selects its own word');

    // Sweep onto "Right": the range grows to cover both words.
    await gesture.moveTo(const Offset(150, 130));
    await tester.pump();
    expect(_highlightCount(tester), 2);

    // Sweep back onto "Left": the range shrinks again (drag both ways).
    await gesture.moveTo(const Offset(40, 130));
    await tester.pump();
    expect(_highlightCount(tester), 1);

    await gesture.up();
    await tester.pump();
    expect(ended, isTrue);
  });
}

int _highlightCount(WidgetTester tester) => tester
    .widgetList(
      find.byWidgetPredicate((w) {
        if (w is! DecoratedBox) return false;
        final deco = w.decoration;
        return deco is BoxDecoration && deco.border != null;
      }),
    )
    .length;

/// Drives the overlay's drag callbacks the way the result screen does, so the
/// range logic and the rendering are exercised together.
class _DragHarness extends StatefulWidget {
  const _DragHarness({required this.result, this.onEnd});

  final OcrResult result;
  final VoidCallback? onEnd;

  @override
  State<_DragHarness> createState() => _DragHarnessState();
}

class _DragHarnessState extends State<_DragHarness> {
  late OcrSelection _selection = OcrSelection.empty(widget.result);
  OcrElement? _anchor;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Align(
        alignment: Alignment.topLeft,
        child: SizedBox(
          width: 200,
          height: 400,
          child: OcrOverlay(
            result: widget.result,
            selection: _selection,
            onSelectionStart: (element) => setState(() {
              _anchor = element;
              _selection = _selection.only(element);
            }),
            onSelectionUpdate: (element) {
              final anchor = _anchor;
              if (anchor == null || element == null) return;
              setState(() => _selection = _selection.range(anchor, element));
            },
            onSelectionEnd: () {
              _anchor = null;
              widget.onEnd?.call();
            },
          ),
        ),
      ),
    );
  }
}
