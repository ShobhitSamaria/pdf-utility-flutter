import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdf_utility_flutter/main.dart';
import 'package:pdf_utility_flutter/ocr/domain/ocr_block.dart';
import 'package:pdf_utility_flutter/ocr/domain/ocr_element.dart';
import 'package:pdf_utility_flutter/ocr/domain/ocr_line.dart';
import 'package:pdf_utility_flutter/ocr/domain/ocr_rect.dart';
import 'package:pdf_utility_flutter/ocr/domain/ocr_result.dart';
import 'package:pdf_utility_flutter/ocr/domain/ocr_script_mode.dart';
import 'package:pdf_utility_flutter/ocr/domain/ocr_service.dart';
import 'package:pdf_utility_flutter/screens/ocr_result_screen.dart';

import 'support/translation_fakes.dart';

/// A one-line page of text: enough for the result screen to consider itself
/// translatable, without touching a real image or a platform channel.
OcrResult _page() => OcrResult(
  sourceImage: SourceImageInfo(
    path: '/tmp/does-not-exist.jpg',
    width: 1000,
    height: 1000,
  ),
  fullText: 'Hello world',
  blocks: [
    OcrBlock(
      text: 'Hello world',
      boundingBox: OcrRect.fromLTRB(100, 100, 900, 200),
      lines: [
        OcrLine(
          text: 'Hello world',
          boundingBox: OcrRect.fromLTRB(100, 100, 900, 200),
          elements: [
            OcrElement(
              text: 'Hello',
              boundingBox: OcrRect.fromLTRB(100, 100, 500, 200),
            ),
            OcrElement(
              text: 'world',
              boundingBox: OcrRect.fromLTRB(520, 100, 900, 200),
            ),
          ],
        ),
      ],
    ),
  ],
);

/// A no-op [OcrService] so the widget test never touches the ML Kit platform
/// channel. This also demonstrates that the UI is fully decoupled from the
/// concrete engine.
class _FakeOcrService implements OcrService {
  @override
  String get engineName => 'Fake';

  @override
  Future<OcrResult> recognizeImage(
    String imagePath, {
    OcrScriptMode mode = OcrScriptMode.defaultMode,
  }) async => throw UnimplementedError();

  @override
  Future<void> dispose() async {}
}

void main() {
  /// A phone-shaped surface, so the script controls are reachable by tap rather
  /// than clipped off the default 800x600 test window.
  Future<void> pumpApp(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1200, 2700);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      PdfUtilityApp(
        ocrService: _FakeOcrService(),
        translationService: FakeTranslationService(),
      ),
    );
  }

  /// Scrolls [finder] into view and taps it.
  Future<void> tapVisible(WidgetTester tester, Finder finder) async {
    await tester.ensureVisible(finder);
    await tester.pump();
    await tester.tap(finder);
    await tester.pump();
  }

  /// Opens the settings sheet. The script choice lives there now: it is not
  /// inline on Home any more, but it is still one tap away and still optional.
  Future<void> openSettings(WidgetTester tester) async {
    await tapVisible(tester, find.byTooltip('Settings'));
    await tester.pumpAndSettle();
  }

  /// Opens the manual script overrides inside the settings sheet.
  Future<void> openOverrides(WidgetTester tester) async {
    await openSettings(tester);
    await tapVisible(tester, find.text('Choose a script'));
  }

  testWidgets('Home presents the design: hero, primary and two ghost actions', (
    tester,
  ) async {
    await pumpApp(tester);

    expect(find.text('PDF Utility'), findsOneWidget);
    expect(find.text('Your documents,\nready to use.'), findsOneWidget);
    expect(
      find.text('Scan, extract text and translate.\nAll in one place.'),
      findsOneWidget,
    );
    expect(find.text('Scan document'), findsOneWidget);
    expect(find.text('Choose image'), findsOneWidget);
    expect(find.text('Import PDF'), findsOneWidget);

    // The script is not a question the user has to answer, so it is a quiet row
    // rather than a control block.
    expect(find.text('Script: '), findsOneWidget);
    expect(find.text('Auto'), findsOneWidget);
  });

  testWidgets('Scan document offers Extract Text and Create PDF', (
    tester,
  ) async {
    await pumpApp(tester);
    await tapVisible(tester, find.text('Scan document'));
    await tester.pumpAndSettle();

    expect(find.text('Extract Text (OCR)'), findsOneWidget);
    expect(find.text('Scan, copy and translate'), findsOneWidget);
    expect(find.text('Create PDF'), findsOneWidget);
    expect(find.text('Capture one or more pages'), findsOneWidget);
    // Both rows work now (capture → review → the PDF is written), so neither
    // carries a badge: there is no placeholder left in this sheet.
    expect(find.text('Coming soon'), findsNothing);
  });

  testWidgets('Choose image offers Extract Text and Create PDF', (
    tester,
  ) async {
    await pumpApp(tester);
    await tapVisible(tester, find.text('Choose image'));
    await tester.pumpAndSettle();

    expect(find.text('Extract Text'), findsOneWidget);
    expect(find.text('Read text from an image'), findsOneWidget);
    expect(find.text('Create PDF'), findsOneWidget);
    expect(find.text('Combine images into a PDF'), findsOneWidget);
    expect(find.text('Coming soon'), findsNothing);
  });

  testWidgets('Import PDF offers Extract Text only', (tester) async {
    await pumpApp(tester);
    await tapVisible(tester, find.text('Import PDF'));
    await tester.pumpAndSettle();

    expect(find.text('Extract Text'), findsOneWidget);
    expect(find.text('Choose a page to recognize'), findsOneWidget);
    // "View PDF / Create PDF" was removed: importing a PDF is for reading it,
    // and the viewer is no longer offered from Home.
    expect(find.text('View PDF / Create PDF'), findsNothing);
    expect(find.text('Read or select pages for a new PDF'), findsNothing);
    expect(find.text('Coming soon'), findsNothing);
  });

  testWidgets('Import PDF → Extract Text opens the existing import screen', (
    tester,
  ) async {
    await pumpApp(tester);
    await tapVisible(tester, find.text('Import PDF'));
    await tester.pumpAndSettle();
    await tapVisible(tester, find.text('Extract Text'));
    await tester.pumpAndSettle();

    // The import screen is reached without touching a picker or the native
    // rasteriser: those are only constructed when the user actually chooses a
    // document, which is what keeps this test off the platform channels.
    expect(find.text('Read a PDF'), findsOneWidget);
    expect(find.text('Choose PDF'), findsOneWidget);
  });

  testWidgets('Auto is the default, and the manual scripts are an override', (
    tester,
  ) async {
    await pumpApp(tester);
    await openSettings(tester);

    // Auto is offered, selected, and explained...
    //
    // Asserted on the chip rather than on the bare string: the quiet `Script:`
    // row on Home shows the same word, so the control is what matters here.
    final autoChip = tester.widget<ChoiceChip>(
      find.widgetWithText(ChoiceChip, OcrScriptMode.auto.label),
    );
    expect(autoChip.selected, isTrue);
    expect(find.text(OcrScriptMode.auto.description), findsOneWidget);
    // ...and the user is no longer asked which script their page is in.
    for (final mode in OcrScriptMode.manualModes) {
      expect(find.widgetWithText(ChoiceChip, mode.label), findsNothing);
    }
  });

  testWidgets('the manual overrides are still reachable', (tester) async {
    await pumpApp(tester);
    await openOverrides(tester);

    for (final mode in OcrScriptMode.manualModes) {
      expect(find.widgetWithText(ChoiceChip, mode.label), findsOneWidget);
    }
  });

  testWidgets('choosing an override updates the explanation in place', (
    tester,
  ) async {
    await pumpApp(tester);
    await openOverrides(tester);

    await tapVisible(
      tester,
      find.widgetWithText(ChoiceChip, OcrScriptMode.devanagari.label),
    );

    expect(find.text(OcrScriptMode.devanagari.description), findsOneWidget);
    expect(find.text(OcrScriptMode.auto.description), findsNothing);
    // The override list stays open, so the active choice is never hidden.
    expect(find.text('Hide script overrides'), findsOneWidget);

    // Mixed still advertises itself as an unmeasured experiment.
    await tapVisible(
      tester,
      find.widgetWithText(ChoiceChip, OcrScriptMode.mixed.label),
    );

    expect(find.textContaining('not been measured'), findsOneWidget);
    expect(find.textContaining('twice'), findsWidgets);
  });

  testWidgets('Auto explains what it costs before the user runs it', (
    tester,
  ) async {
    await pumpApp(tester);
    await openSettings(tester);

    // The two-pass fallback is stated up front rather than discovered as a
    // slower read.
    expect(
      find.textContaining('English page costs nothing extra'),
      findsOneWidget,
    );
  });

  testWidgets('developer tools are debug-gated and out of the normal flow', (
    tester,
  ) async {
    await pumpApp(tester);

    // Home itself offers no developer controls any more.
    expect(find.textContaining('Show OCR geometry'), findsNothing);
    expect(find.text('OCR benchmark (debug)'), findsNothing);

    await openSettings(tester);

    // The diagnostics screen was a test-only entry point. Translation is a
    // normal feature now, so it is not offered here — and this is no longer a
    // build-flag question: it is absent in every configuration, not just the
    // one this test happens to run in.
    const translationEnabled = bool.fromEnvironment('ENABLE_TRANSLATION');
    expect(
      find.text('Translation diagnostics (debug)'),
      findsNothing,
      reason:
          'the diagnostics door must be gone even though '
          'ENABLE_TRANSLATION=$translationEnabled (and regardless of its value)',
    );

    // The OCR benchmark stays: it is the measuring instrument behind this
    // project's accuracy numbers, and it is debug-gated so a release build never
    // renders it.
    expect(find.text('OCR benchmark (debug)'), findsOneWidget);
    expect(find.textContaining('Show OCR geometry'), findsOneWidget);
  });

  // The end-to-end form of the acceptance criterion: the *real* composition root
  // (`PdfUtilityApp` → `AppScope`, i.e. exactly what `main()` builds), with no
  // `--dart-define` of any kind, must reach working translation UI. Nothing is
  // stubbed except the two services, so this fails if a gate is ever
  // reintroduced anywhere between `main.dart` and the result screen.
  testWidgets('the real app composition exposes translation with no build flag', (
    tester,
  ) async {
    await pumpApp(tester);

    final navigator = tester.state<NavigatorState>(find.byType(Navigator));
    unawaited(
      navigator.push(
        MaterialPageRoute<void>(
          builder: (_) => OcrResultScreen(result: _page()),
        ),
      ),
    );
    // Push the route and let the transition finish, without `pumpAndSettle`:
    // the deliberately missing image file must not be allowed to pace the test.
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));

    expect(find.byType(OcrResultScreen), findsOneWidget);
    expect(find.byTooltip('Translate'), findsOneWidget);
    expect(
      tester
          .widget<IconButton>(
            find.widgetWithIcon(IconButton, Icons.g_translate),
          )
          .onPressed,
      isNotNull,
      reason: 'the action must be usable, not merely rendered',
    );

    // Tapping it opens the inline section on this same screen: the photo and
    // the OCR result never give way to a separate translation screen.
    await tester.tap(find.widgetWithIcon(IconButton, Icons.g_translate));
    await tester.pump();

    expect(find.byType(OcrResultScreen), findsOneWidget);
    expect(find.text('From'), findsOneWidget);
    expect(find.text('To'), findsOneWidget);
  });
}
