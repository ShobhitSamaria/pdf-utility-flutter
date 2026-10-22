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
import 'package:pdf_utility_flutter/ocr/presentation/ocr_coordinate_mapper.dart';
import 'package:pdf_utility_flutter/ocr/presentation/widgets/ocr_overlay.dart';
import 'package:pdf_utility_flutter/screens/ocr_result_screen.dart';
import 'package:pdf_utility_flutter/screens/widgets/selection_action_bar.dart';

import 'support/translation_fakes.dart';

class _NoopOcrService implements OcrService {
  @override
  String get engineName => 'Noop';

  @override
  Future<OcrResult> recognizeImage(
    String imagePath, {
    OcrScriptMode mode = OcrScriptMode.defaultMode,
  }) async => throw UnimplementedError();

  @override
  Future<void> dispose() async {}
}

OcrElement _word(String text, double l, double t, double r, double b) =>
    OcrElement(text: text, boundingBox: OcrRect.fromLTRB(l, t, r, b));

final _left = _word('Left', 100, 100, 300, 200);
final _right = _word('Right', 600, 100, 900, 200);
final _bottom = _word('Bottom', 100, 300, 400, 400);

OcrResult _result({int height = 1000}) => OcrResult(
  sourceImage: SourceImageInfo(
    path: '/tmp/does-not-exist.jpg',
    width: 1000,
    height: height,
  ),
  fullText: 'Left Right\nBottom',
  blocks: [
    OcrBlock(
      text: 'Left Right\nBottom',
      boundingBox: OcrRect.fromLTRB(100, 100, 900, 400),
      lines: [
        OcrLine(
          text: 'Left Right',
          boundingBox: OcrRect.fromLTRB(100, 100, 900, 200),
          elements: [_left, _right],
        ),
        OcrLine(
          text: 'Bottom',
          boundingBox: OcrRect.fromLTRB(100, 300, 400, 400),
          elements: [_bottom],
        ),
      ],
    ),
  ],
);

void main() {
  /// The **shipped** configuration: exactly the scope `main.dart` builds, with
  /// no translation flag of any kind. Every assertion below therefore describes
  /// what a user's own build does.
  Widget harness({int height = 1000}) => AppScope(
    ocrService: _NoopOcrService(),
    translationService: FakeTranslationService(),
    debugGeometry: ValueNotifier<bool>(false),
    ocrScriptMode: ValueNotifier<OcrScriptMode>(OcrScriptMode.defaultMode),
    child: MaterialApp(
      home: OcrResultScreen(result: _result(height: height)),
    ),
  );

  /// The mapper the overlay itself builds, derived from the overlay's own box.
  OcrCoordinateMapper mapperFor(WidgetTester tester, {int height = 1000}) {
    final overlayRect = tester.getRect(find.byType(OcrOverlay));
    return OcrCoordinateMapper(
      imageWidth: 1000,
      imageHeight: height,
      viewportSize: overlayRect.size,
    );
  }

  testWidgets('translation is reachable in the shipped build, with no flag', (
    tester,
  ) async {
    await tester.pumpWidget(harness());
    await tester.pump();

    // The whole-page action is present **and enabled**, because this page has
    // text. Nothing was opted into for it to be here: no `dart-define`, no debug
    // mode, no switch passed in by the build.
    final translate = tester.widget<IconButton>(
      find.widgetWithIcon(IconButton, Icons.g_translate),
    );
    expect(translate.onPressed, isNotNull);
    expect(find.byTooltip('Translate'), findsOneWidget);

    // The OCR surfaces remain alongside it.
    expect(find.byTooltip('Find in text'), findsOneWidget);
    expect(find.text('Read text'), findsOneWidget);
  });

  testWidgets('the Extracted Text tab is gone; the photo is the only surface', (
    tester,
  ) async {
    await tester.pumpWidget(harness());
    await tester.pump();

    // No segmented control, no tab labels, no second reading of the result.
    expect(find.byType(TabBar), findsNothing);
    expect(find.byType(SegmentedButton<Object>), findsNothing);
    expect(find.text('Extracted Text'), findsNothing);
    // Nor is it an app-bar option: reading the text lives behind the single
    // `Read text` action in the strip under the photo.
    expect(find.byTooltip('Extracted text'), findsNothing);
    expect(find.text('Image'), findsNothing);
    expect(find.byType(OcrOverlay), findsOneWidget);
    expect(find.textContaining('3 words'), findsOneWidget);
  });

  testWidgets('the selection actions offer Translate in the shipped build', (
    tester,
  ) async {
    await tester.pumpWidget(harness());
    await tester.pump();

    final overlayRect = tester.getRect(find.byType(OcrOverlay));
    await tester.tapAt(
      overlayRect.topLeft +
          mapperFor(tester).rectToScreen(_left.boundingBox).center,
    );
    await tester.pump();

    // Word selection still works, and the fourth action is the translation one.
    expect(find.text('Left'), findsOneWidget);
    expect(find.text('Copy'), findsOneWidget);
    expect(
      find.descendant(
        of: find.byType(SelectionActionBar),
        matching: find.text('Translate'),
      ),
      findsOneWidget,
    );
  });

  // The regression guard for the bug this screen had: translation used to be
  // reachable only in a build made with `--dart-define=ENABLE_TRANSLATION=true`,
  // so the normal build shipped with the feature invisible. That define must now
  // be irrelevant, so this suite passes identically in either configuration.
  testWidgets('the translation UI no longer depends on ENABLE_TRANSLATION', (
    tester,
  ) async {
    const translationEnabled = bool.fromEnvironment('ENABLE_TRANSLATION');

    await tester.pumpWidget(harness());
    await tester.pump();

    expect(
      find.byTooltip('Translate'),
      findsOneWidget,
      reason:
          'translation must be present whether or not '
          'ENABLE_TRANSLATION=$translationEnabled is passed to the build',
    );
    // OCR is never gated by a flag either.
    expect(find.text('Read text'), findsOneWidget);
  });

  test('AppScope always carries a translation service', () {
    final translation = FakeTranslationService();
    final scope = AppScope(
      ocrService: _NoopOcrService(),
      translationService: translation,
      debugGeometry: ValueNotifier<bool>(false),
      ocrScriptMode: ValueNotifier<OcrScriptMode>(OcrScriptMode.defaultMode),
      child: const SizedBox.shrink(),
    );
    // There is no flag that can turn the feature off, so the service the UI
    // translates with is simply always the one the composition root provided.
    expect(scope.translationService, same(translation));
  });

  testWidgets('the photo is drawn exactly where the mapper places it', (
    tester,
  ) async {
    await tester.pumpWidget(harness());
    await tester.pump();

    final overlayRect = tester.getRect(find.byType(OcrOverlay));
    final mapper = mapperFor(tester);
    final expected = (mapper.displayedOffset & mapper.displayedSize).shift(
      overlayRect.topLeft,
    );

    expect(tester.getRect(find.byType(Image)), expected);
  });

  testWidgets('a portrait photo is letterboxed, and the photo matches', (
    tester,
  ) async {
    await tester.pumpWidget(harness(height: 2000));
    await tester.pump();

    final overlayRect = tester.getRect(find.byType(OcrOverlay));
    final mapper = mapperFor(tester, height: 2000);
    // Portrait in a landscape-ish viewport: the image must not fill the width.
    expect(mapper.displayedSize.width, lessThan(overlayRect.width));
    expect(
      tester.getRect(find.byType(Image)),
      (mapper.displayedOffset & mapper.displayedSize).shift(
        overlayRect.topLeft,
      ),
    );
  });

  testWidgets('a tapped word is selected through the shared mapper', (
    tester,
  ) async {
    await tester.pumpWidget(harness());
    await tester.pump();

    final overlayRect = tester.getRect(find.byType(OcrOverlay));
    final mapper = mapperFor(tester);
    await tester.tapAt(
      overlayRect.topLeft + mapper.rectToScreen(_left.boundingBox).center,
    );
    await tester.pump();

    // The selection panel shows the word that was actually under the finger.
    expect(find.text('Left'), findsOneWidget);
    expect(find.text('Copy'), findsOneWidget);
    expect(find.text('Search'), findsOneWidget);
    expect(find.text('Share'), findsOneWidget);
    expect(
      find.descendant(
        of: find.byType(SelectionActionBar),
        matching: find.text('Translate'),
      ),
      findsOneWidget,
    );
  });

  testWidgets('the highlight lands on the word box it came from', (
    tester,
  ) async {
    await tester.pumpWidget(harness());
    await tester.pump();

    final before = tester.getRect(find.byType(OcrOverlay));
    final beforeMapper = mapperFor(tester);
    await tester.tapAt(
      before.topLeft + beforeMapper.rectToScreen(_bottom.boundingBox).center,
    );
    await tester.pump();

    // Selecting a word adds the selection panel, which changes the overlay's
    // box and therefore its mapper. The assertion is that rendering stays in
    // step with hit-testing *after* that relayout, using the mapper the overlay
    // has now.
    final overlayRect = tester.getRect(find.byType(OcrOverlay));
    final mapper = mapperFor(tester);

    final highlights = find.descendant(
      of: find.byType(OcrOverlay),
      matching: find.byType(DecoratedBox),
    );
    expect(highlights, findsOneWidget);
    expect(
      tester.getRect(highlights),
      mapper.rectToScreen(_bottom.boundingBox).shift(overlayRect.topLeft),
    );
  });

  testWidgets('a tap on the letterbox clears the selection', (tester) async {
    await tester.pumpWidget(harness());
    await tester.pump();

    final overlayRect = tester.getRect(find.byType(OcrOverlay));
    final mapper = mapperFor(tester);
    await tester.tapAt(
      overlayRect.topLeft + mapper.rectToScreen(_left.boundingBox).center,
    );
    await tester.pump();
    expect(find.text('Left'), findsOneWidget);

    // Two logical pixels into the top-left corner of the letterbox.
    await tester.tapAt(overlayRect.topLeft + const Offset(2, 2));
    await tester.pump();

    expect(find.text('Left'), findsNothing);
    expect(find.text('Copy'), findsNothing);
  });

  testWidgets('Read text opens a sheet with search and copy intact', (
    tester,
  ) async {
    await tester.pumpWidget(harness());
    await tester.pump();

    await tester.tap(find.text('Read text'));
    await tester.pumpAndSettle();

    // The tab is gone, the capability is not: same body, same find field, same
    // copy action, now in a sheet over the photo.
    expect(find.text('Extracted text'), findsWidgets);
    expect(find.text('Left Right'), findsOneWidget);
    expect(find.text('Bottom'), findsOneWidget);
    expect(find.text('Copy all'), findsOneWidget);
    expect(find.byType(TextField), findsOneWidget);
    expect(find.byType(OcrOverlay), findsOneWidget);
  });

  testWidgets('Show on photo drives the find bar on the photo', (tester) async {
    await tester.pumpWidget(harness());
    await tester.pump();

    await tester.tap(find.text('Read text'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), 'Right');
    await tester.pump();
    await tester.tap(find.text('Show on photo'));
    await tester.pumpAndSettle();

    // The sheet is gone and the search bar is open with the same query, showing
    // its match count from the existing in-document search.
    expect(find.text('Show on photo'), findsNothing);
    // The app bar action has flipped from "Find in text" to the close state.
    expect(find.byTooltip('Find in text'), findsNothing);
    expect(find.widgetWithText(TextField, 'Right'), findsOneWidget);
    expect(find.text('1 / 1'), findsOneWidget);
  });
}
