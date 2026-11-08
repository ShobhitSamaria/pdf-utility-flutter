import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdf_utility_flutter/app/app_brand.dart';
import 'package:pdf_utility_flutter/app/app_theme.dart';
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

  testWidgets('Home offers OCR Scanner and Create PDF, and nothing else', (
    tester,
  ) async {
    await pumpApp(tester);

    expect(find.text(AppBrand.name), findsOneWidget);
    expect(find.text('Your documents,\nready to use.'), findsOneWidget);
    expect(
      find.text('Scan, extract text and translate.\nAll in one place.'),
      findsOneWidget,
    );

    // The product's two choices, in priority order.
    expect(find.byKey(const Key('home-extract-text')), findsOneWidget);
    expect(find.byKey(const Key('home-create-pdf')), findsOneWidget);
    expect(find.text('OCR Scanner'), findsOneWidget);
    expect(find.text('Scan photos or PDFs to extract text.'), findsOneWidget);
    expect(
      find.text('Create PDF using camera or gallery images.'),
      findsOneWidget,
    );

    // The old three entry points and the duplicate script footer are gone.
    expect(find.text('Scan document'), findsNothing);
    expect(find.text('Choose image'), findsNothing);
    expect(find.text('Import PDF'), findsNothing);
    expect(find.text('Script: '), findsNothing);
  });

  testWidgets('OCR Scanner offers Camera, Gallery and Import PDF', (
    tester,
  ) async {
    await pumpApp(tester);
    await tapVisible(tester, find.byKey(const Key('home-extract-text')));
    await tester.pumpAndSettle();

    expect(find.text('Camera'), findsOneWidget);
    expect(find.text('Gallery'), findsOneWidget);
    expect(find.text('Import PDF'), findsOneWidget);
    expect(find.text('Take a photo of a document'), findsOneWidget);
    expect(find.text('Choose photos from your library'), findsOneWidget);
    expect(find.text('Pick a PDF and select a page'), findsOneWidget);
    expect(find.text('Your files stay on this device.'), findsOneWidget);

    // Import PDF is the recommended source: first, and on the filled brand
    // surface rather than the quiet row used by Camera and Gallery.
    final importTop = tester.getTopLeft(find.text('Import PDF')).dy;
    final cameraTop = tester.getTopLeft(find.text('Camera')).dy;
    final galleryTop = tester.getTopLeft(find.text('Gallery')).dy;
    expect(importTop, lessThan(cameraTop));
    expect(cameraTop, lessThan(galleryTop));

    final importSurface = tester.widget<Material>(
      find
          .ancestor(
            of: find.text('Import PDF'),
            matching: find.byType(Material),
          )
          .first,
    );
    expect(importSurface.color, AppColors.primary);
  });

  testWidgets('Create PDF offers Camera and Gallery', (tester) async {
    await pumpApp(tester);
    await tapVisible(tester, find.byKey(const Key('home-create-pdf')));
    await tester.pumpAndSettle();

    expect(find.text('Capture one or more pages'), findsOneWidget);
    expect(find.text('Combine images into a PDF'), findsOneWidget);
    expect(find.text('Coming soon'), findsNothing);
  });

  testWidgets('OCR Scanner -> Import PDF opens the existing import screen', (
    tester,
  ) async {
    await pumpApp(tester);
    await tapVisible(tester, find.byKey(const Key('home-extract-text')));
    await tester.pumpAndSettle();
    await tapVisible(tester, find.text('Import PDF'));
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
