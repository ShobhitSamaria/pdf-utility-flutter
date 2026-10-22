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
import 'package:pdf_utility_flutter/translation/domain/translated_region.dart';
import 'package:pdf_utility_flutter/translation/domain/translation_exception.dart';
import 'package:pdf_utility_flutter/translation/domain/translation_language.dart';
import 'package:pdf_utility_flutter/translation/domain/translation_request.dart';
import 'package:pdf_utility_flutter/translation/presentation/translation_controller.dart';
import 'package:pdf_utility_flutter/translation/presentation/widgets/inline_translation_panel.dart';
import 'package:pdf_utility_flutter/translation/presentation/widgets/language_selector.dart';
import 'package:pdf_utility_flutter/translation/presentation/widgets/translation_overlay.dart';

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

class _RecordingObserver extends NavigatorObserver {
  final List<Route<dynamic>> pushes = <Route<dynamic>>[];

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    pushes.add(route);
    super.didPush(route, previousRoute);
  }
}

OcrElement _word(String text, double l, double t, double r, double b) =>
    OcrElement(text: text, boundingBox: OcrRect.fromLTRB(l, t, r, b));

OcrResult _page({bool empty = false}) {
  final left = _word('Left', 100, 100, 300, 200);
  final right = _word('Right', 600, 100, 900, 200);
  final bottom = _word('Bottom', 100, 300, 400, 400);

  return OcrResult(
    sourceImage: const SourceImageInfo(
      path: '/tmp/does-not-exist.jpg',
      width: 1000,
      height: 1000,
    ),
    fullText: empty ? '' : 'Left Right\nBottom',
    blocks: empty
        ? const <OcrBlock>[]
        : [
            OcrBlock(
              text: 'Left Right\nBottom',
              boundingBox: OcrRect.fromLTRB(100, 100, 900, 400),
              lines: [
                OcrLine(
                  text: 'Left Right',
                  boundingBox: OcrRect.fromLTRB(100, 100, 900, 200),
                  elements: [left, right],
                ),
                OcrLine(
                  text: 'Bottom',
                  boundingBox: OcrRect.fromLTRB(100, 300, 400, 400),
                  elements: [bottom],
                ),
              ],
            ),
          ],
  );
}

void main() {
  final page = _page();

  late FakeTranslationService service;

  Widget harness({
    FakeTranslationService? withService,
    NavigatorObserver? observer,
    OcrResult? result,
  }) {
    service = withService ?? FakeTranslationService();
    return AppScope(
      ocrService: _NoopOcrService(),
      translationService: service,
      debugGeometry: ValueNotifier<bool>(false),
      ocrScriptMode: ValueNotifier<OcrScriptMode>(OcrScriptMode.defaultMode),
      child: MaterialApp(
        navigatorObservers: [?observer],
        home: OcrResultScreen(
          result: result ?? page,
          translationService: service,
        ),
      ),
    );
  }

  /// Taps the centre of [word] using the same mapper the overlay renders with.
  Future<void> tapWord(WidgetTester tester, OcrElement word) async {
    final overlayRect = tester.getRect(find.byType(OcrOverlay));
    final mapper = OcrCoordinateMapper(
      imageWidth: 1000,
      imageHeight: 1000,
      viewportSize: overlayRect.size,
    );
    await tester.tapAt(
      overlayRect.topLeft + mapper.rectToScreen(word.boundingBox).center,
    );
    await tester.pump();
  }

  /// Lets a translation started by a tap (or a retry) finish.
  Future<void> settleTranslation(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 10));
    await tester.pump();
  }

  /// Opens the inline section from the app bar and lets detection settle.
  Future<void> openPanel(WidgetTester tester) async {
    await tester.tap(find.byTooltip('Translate'));
    await tester.pump();
    await tester.pump();
  }

  Finder selectionTranslate() => find.descendant(
    of: find.byType(SelectionActionBar),
    matching: find.text('Translate'),
  );

  LanguageSelector fromSelector(WidgetTester tester) =>
      tester.widgetList<LanguageSelector>(find.byType(LanguageSelector)).first;

  LanguageSelector toSelector(WidgetTester tester) =>
      tester.widgetList<LanguageSelector>(find.byType(LanguageSelector)).last;

  Future<void> pickSource(WidgetTester tester, String label) async {
    await tester.tap(find.text(fromSelector(tester).value.label));
    await tester.pumpAndSettle();
    await tester.tap(find.text(label).last);
    await tester.pumpAndSettle();
  }

  testWidgets('tapping Translate shows the inline controls, not a new screen', (
    tester,
  ) async {
    final observer = _RecordingObserver();
    await tester.pumpWidget(harness(observer: observer));
    await tester.pump();
    observer.pushes.clear();

    await openPanel(tester);

    // The section is open underneath the photo, and the photo was never left.
    expect(find.byType(InlineTranslationPanel), findsOneWidget);
    expect(find.text('From'), findsOneWidget);
    expect(find.text('To'), findsOneWidget);
    expect(find.text('Translate'), findsWidgets);
    expect(find.byType(OcrOverlay), findsOneWidget);

    // Opening the controls is not a translation and not a navigation.
    expect(service.regionRequests, isEmpty);
    expect(observer.pushes, isEmpty);
  });

  testWidgets('the default target is English and a detected source is chosen', (
    tester,
  ) async {
    await tester.pumpWidget(
      harness(
        withService: FakeTranslationService(
          detectedSource: TranslationLanguages.hindi,
        ),
      ),
    );
    await tester.pump();

    await openPanel(tester);

    expect(fromSelector(tester).value.code, 'hi');
    expect(toSelector(tester).value.code, 'en');
    // Detection ran once, on the OCR text, without translating anything.
    expect(service.detectionRequests, hasLength(1));
    expect(service.detectionRequests.single, contains('Left Right'));
    expect(service.regionRequests, isEmpty);
  });

  testWidgets('choosing a source language bypasses auto-detection', (
    tester,
  ) async {
    // Detection would answer English; the user overrides it with Bengali.
    await tester.pumpWidget(
      harness(
        withService: FakeTranslationService(
          detectedSource: TranslationLanguages.english,
        ),
      ),
    );
    await tester.pump();
    await openPanel(tester);
    final detectionsAfterOpen = service.detectionRequests.length;

    await pickSource(tester, 'বাংলা (Bengali)');
    expect(fromSelector(tester).value.code, 'bn');

    await tester.tap(find.widgetWithText(FilledButton, 'Translate'));
    await settleTranslation(tester);

    expect(service.detectionRequests, hasLength(detectionsAfterOpen));
    expect(service.regionLanguages.single.source, 'bn');
    // Detection had answered English, so the target had already moved off it;
    // the explicit Bengali source is the only thing that changed here.
    expect(service.regionLanguages.single.target, 'hi');
    expect(find.byType(TranslationOverlay), findsOneWidget);
  });

  testWidgets('a detection failure offers a manual source and translates', (
    tester,
  ) async {
    final failing = FakeTranslationService(
      detectionFails: true,
      failure: const TranslationException(
        TranslationErrorKind.detectionFailed,
        "We couldn't tell which language this is. "
        'Pick the source language and try again.',
      ),
    );
    await tester.pumpWidget(harness(withService: failing));
    await tester.pump();
    await openPanel(tester);

    // Detection failed quietly: the source stays Auto-detect.
    expect(fromSelector(tester).value.isAuto, isTrue);
    await tester.tap(find.widgetWithText(FilledButton, 'Translate'));
    await settleTranslation(tester);

    // A concise inline failure that names the recovery, without a pointless
    // retry of the same automatic request.
    expect(find.textContaining("couldn't tell which language"), findsOneWidget);
    expect(
      find.textContaining('Choose the source language above'),
      findsOneWidget,
    );
    expect(find.text('Try again'), findsNothing);
    expect(find.byType(TranslationOverlay), findsNothing);
    // The OCR content is still there.
    expect(find.byType(OcrOverlay), findsOneWidget);

    // Picking a source retries immediately, with that explicit language.
    failing
      ..failure = null
      ..detectionFails = false;
    await pickSource(tester, 'हिन्दी (Hindi)');
    await settleTranslation(tester);

    expect(service.regionLanguages.last.source, 'hi');
    expect(service.regionLanguages.last.target, 'en');
    expect(find.textContaining('अनुवाद: Left Right'), findsWidgets);
    expect(find.byType(TranslationOverlay), findsOneWidget);
  });

  testWidgets('a successful translation is shown inline and on the photo', (
    tester,
  ) async {
    await tester.pumpWidget(
      harness(
        withService: FakeTranslationService(
          detectedSource: TranslationLanguages.hindi,
        ),
      ),
    );
    await tester.pump();
    await openPanel(tester);

    await tester.tap(find.widgetWithText(FilledButton, 'Translate'));
    await settleTranslation(tester);

    // The result is readable in the section itself...
    expect(find.text('Hindi → English'), findsOneWidget);
    expect(find.textContaining('अनुवाद: Left Right'), findsWidgets);
    // ...and the overlay is on, because the photo is the surface it belongs to.
    expect(find.byType(TranslationOverlay), findsOneWidget);
    expect(tester.widget<Switch>(find.byType(Switch)).value, isTrue);

    // The overlay is optional: switching it off keeps the text available.
    await tester.tap(find.text('On photo'));
    await tester.pump();
    expect(find.byType(TranslationOverlay), findsNothing);
    expect(find.textContaining('अनुवाद: Left Right'), findsWidgets);

    await tester.tap(find.text('On photo'));
    await tester.pump();
    expect(find.byType(TranslationOverlay), findsOneWidget);
  });

  testWidgets('a model failure is inline, keeps OCR, and can be retried', (
    tester,
  ) async {
    final failing = FakeTranslationService(
      failure: TranslationException(
        TranslationErrorKind.modelUnavailable,
        "The Hindi offline language model couldn't be downloaded. "
        'Check your connection and try again.',
      ),
    );
    await tester.pumpWidget(harness(withService: failing));
    await tester.pump();
    await openPanel(tester);

    await tester.tap(find.widgetWithText(FilledButton, 'Translate'));
    await settleTranslation(tester);

    expect(
      find.textContaining("offline language model couldn't be downloaded"),
      findsOneWidget,
    );
    expect(find.text('Try again'), findsOneWidget);
    expect(find.byType(TranslationOverlay), findsNothing);
    expect(find.byType(OcrOverlay), findsOneWidget);
    // Nothing pretends to have been translated.
    expect(find.textContaining('अनुवाद'), findsNothing);

    failing.failure = null;
    await tester.tap(find.text('Try again'));
    await settleTranslation(tester);

    expect(find.textContaining('अनुवाद: Left Right'), findsWidgets);
    expect(find.byType(TranslationOverlay), findsOneWidget);
  });

  testWidgets('empty OCR text disables translation and says why', (
    tester,
  ) async {
    await tester.pumpWidget(harness(result: _page(empty: true)));
    await tester.pump();

    final translate = tester.widget<IconButton>(
      find.widgetWithIcon(IconButton, Icons.g_translate),
    );
    expect(translate.onPressed, isNull);

    // The panel itself is explicit rather than silently doing nothing.
    final controller = TranslationController(service: FakeTranslationService());
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: InlineTranslationPanel(
            controller: controller,
            hasSourceText: false,
            showOnPhoto: false,
            onTranslate: () {},
            onShowOnPhotoChanged: (_) {},
            onLanguagesChanged: () {},
            onClose: () {},
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.textContaining('nothing to translate'), findsOneWidget);
    expect(
      tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
      isNull,
    );
  });

  testWidgets('selecting a word then Translate shows the result inline', (
    tester,
  ) async {
    await tester.pumpWidget(
      harness(
        withService: FakeTranslationService(
          detectedSource: TranslationLanguages.hindi,
        ),
      ),
    );
    await tester.pump();

    await tapWord(tester, _word('Left', 100, 100, 300, 200));
    expect(selectionTranslate(), findsOneWidget);

    await tester.tap(selectionTranslate());
    await settleTranslation(tester);

    // Only the selected word was sent for translation.
    expect(service.regionRequests.single.map((unit) => unit.text).toList(), [
      'Left',
    ]);
    expect(find.byType(TranslationOverlay), findsOneWidget);
    expect(find.textContaining('अनुवाद: Left'), findsWidgets);
    // The result is also in the section under the photo, so it is never only
    // pixels on the image.
    expect(find.byType(InlineTranslationPanel), findsOneWidget);
    // The selection is cleared so the highlight does not sit under the result.
    expect(selectionTranslate(), findsNothing);
  });

  testWidgets(
    'tapping a translated box opens its full text, not a bigger box',
    (tester) async {
      await tester.pumpWidget(
        harness(
          withService: FakeTranslationService(
            detectedSource: TranslationLanguages.hindi,
          ),
        ),
      );
      await tester.pump();
      await openPanel(tester);
      await tester.tap(find.widgetWithText(FilledButton, 'Translate'));
      await settleTranslation(tester);

      await tapWord(tester, _word('Left', 100, 100, 300, 200));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      final sheet = find.byType(BottomSheet);
      expect(
        find.descendant(of: sheet, matching: find.text('Translated')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: sheet, matching: find.text('Original')),
        findsOneWidget,
      );
      expect(find.text('Left Right'), findsOneWidget);
      expect(find.text('Copy translation'), findsOneWidget);
    },
  );

  testWidgets('switching the photo back to original restores word selection', (
    tester,
  ) async {
    await tester.pumpWidget(
      harness(
        withService: FakeTranslationService(
          detectedSource: TranslationLanguages.hindi,
        ),
      ),
    );
    await tester.pump();
    await openPanel(tester);
    await tester.tap(find.widgetWithText(FilledButton, 'Translate'));
    await settleTranslation(tester);

    await tester.tap(find.text('On photo'));
    await tester.pump();

    // With no translated boxes on screen the whole surface is the gesture path
    // again, so a tap on any word selects it.
    await tapWord(tester, _word('Right', 600, 100, 900, 200));
    expect(selectionTranslate(), findsOneWidget);
    expect(find.text('Right'), findsWidgets);
  });

  testWidgets('the working state shows a percentage on a determinate bar', (
    tester,
  ) async {
    final slow = FakeTranslationService(
      detectedSource: TranslationLanguages.hindi,
      delay: const Duration(milliseconds: 300),
      tickDelay: const Duration(milliseconds: 20),
    );
    await tester.pumpWidget(harness(withService: slow));
    await tester.pump();
    await openPanel(tester);

    await tester.tap(find.widgetWithText(FilledButton, 'Translate'));
    await tester.pump();

    expect(find.text('Translating… 50%'), findsOneWidget);
    expect(
      tester
          .widget<LinearProgressIndicator>(find.byType(LinearProgressIndicator))
          .value,
      0.5,
    );

    await tester.pump(const Duration(milliseconds: 600));
    await tester.pump();
    expect(find.byType(LinearProgressIndicator), findsNothing);
  });

  testWidgets('closing the section leaves the photo and result state intact', (
    tester,
  ) async {
    await tester.pumpWidget(harness());
    await tester.pump();
    await openPanel(tester);
    expect(find.byType(InlineTranslationPanel), findsOneWidget);

    await tester.tap(find.byTooltip('Close translation'));
    await tester.pump();

    expect(find.byType(InlineTranslationPanel), findsNothing);
    expect(find.byType(OcrOverlay), findsOneWidget);
    expect(find.textContaining('3 words'), findsOneWidget);
  });

  // Regression guard for the screen's single reading of the page: with the
  // Extracted Text tab gone, `Read text` is the only way to see a read that
  // produced text but no usable word geometry — it must not be lost, and it must
  // not be replaced by the "no text found" notice either.
  testWidgets('a read with text but no word geometry still offers Read text', (
    tester,
  ) async {
    final geometryless = OcrResult(
      sourceImage: const SourceImageInfo(
        path: '/tmp/does-not-exist.jpg',
        width: 1000,
        height: 1000,
      ),
      fullText: 'Left Right\nBottom',
      blocks: const <OcrBlock>[],
    );

    await tester.pumpWidget(harness(result: geometryless));
    await tester.pump();

    expect(find.textContaining('No text found'), findsNothing);
    expect(find.text('Read text'), findsOneWidget);

    await tester.tap(find.text('Read text'));
    await tester.pumpAndSettle();

    expect(find.text('Left Right'), findsOneWidget);
    expect(find.text('Bottom'), findsOneWidget);
    expect(find.text('Copy all'), findsOneWidget);
  });

  // The regression this whole layout pass exists for: a multi-column page used
  // to be translated one OCR line at a time in engine order, so the result read
  // as unrelated fragments that jumped between columns. The page must now go to
  // the translator as whole paragraphs, in column reading order.
  testWidgets('a newspaper page is translated as paragraphs in reading order', (
    tester,
  ) async {
    OcrLine line(String text, double left, double right, double top) => OcrLine(
      text: text,
      boundingBox: OcrRect.fromLTRB(left, top, right, top + 22),
      elements: const <OcrElement>[],
    );

    List<OcrLine> column(double left, String name) => [
      for (var index = 0; index < 4; index++)
        line(
          '$name sentence ${index + 1}',
          left,
          left + 300,
          300.0 + index * 26,
        ),
    ];

    final headlineLines = [
      line('Relief to contract workers', 100, 1100, 100),
      line('benefits under Rules 2022', 100, 1100, 130),
    ];
    OcrBlock block(List<OcrLine> lines) => OcrBlock(
      text: lines.map((l) => l.text).join('\n'),
      boundingBox: OcrRect.fromLTRB(
        lines.first.boundingBox.left,
        lines.first.boundingBox.top,
        lines.last.boundingBox.right,
        lines.last.boundingBox.bottom,
      ),
      lines: lines,
    );

    // Engine block order is scrambled on purpose.
    final newspaper = OcrResult(
      sourceImage: const SourceImageInfo(
        path: '/tmp/does-not-exist.jpg',
        width: 1200,
        height: 1600,
      ),
      fullText: 'Right\nRelief\nLeft\nMiddle',
      blocks: [
        block(column(820, 'Right')),
        block(headlineLines),
        block(column(100, 'Left')),
        block(column(460, 'Middle')),
      ],
    );

    await tester.pumpWidget(
      harness(
        result: newspaper,
        withService: FakeTranslationService(
          detectedSource: TranslationLanguages.hindi,
        ),
      ),
    );
    await tester.pump();
    await openPanel(tester);
    await tester.tap(find.widgetWithText(FilledButton, 'Translate'));
    await settleTranslation(tester);

    // One request, four paragraph units — not one unit per line.
    expect(service.regionRequests, hasLength(1));
    final units = service.regionRequests.single;
    expect(units, hasLength(4));
    expect(
      units.every((unit) => unit.kind == TranslatedRegionKind.paragraph),
      isTrue,
    );
    expect(units.map((unit) => unit.text).toList(), [
      'Relief to contract workers benefits under Rules 2022',
      'Left sentence 1 Left sentence 2 Left sentence 3 Left sentence 4',
      'Middle sentence 1 Middle sentence 2 Middle sentence 3 Middle sentence 4',
      'Right sentence 1 Right sentence 2 Right sentence 3 Right sentence 4',
    ]);

    // Nothing is drawn outside the page, and the overlay is on the photo.
    expect(tester.takeException(), isNull);
    final overlay = tester
        .widget<TranslationOverlay>(find.byType(TranslationOverlay))
        .overlay;
    expect(overlay.regions.map((region) => region.kind).toSet(), {
      TranslatedRegionKind.paragraph,
    });
    expect(overlay.regions.first.translatedText, startsWith('अनुवाद: Relief'));

    // The full text keeps paragraph boundaries and every sentence, once.
    final full = overlay.asResult(TranslationScope.wholePage).translatedText;
    expect(full.split('\n\n'), hasLength(4));
    expect('Left sentence 1'.allMatches(full), hasLength(1));
    expect(
      full.indexOf('Left sentence'),
      lessThan(full.indexOf('Middle sentence')),
    );
    expect(
      full.indexOf('Middle sentence'),
      lessThan(full.indexOf('Right sentence')),
    );
  });
}
