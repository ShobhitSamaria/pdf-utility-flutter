import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:pdf_utility_flutter/main.dart'
    show createOcrService, createTranslationService;
import 'package:pdf_utility_flutter/ocr/domain/ocr_result.dart';
import 'package:pdf_utility_flutter/ocr/domain/ocr_script_mode.dart';
import 'package:pdf_utility_flutter/ocr/presentation/ocr_coordinate_mapper.dart';
import 'package:pdf_utility_flutter/translation/domain/translated_region.dart';
import 'package:pdf_utility_flutter/translation/domain/translation_language.dart';
import 'package:pdf_utility_flutter/translation/presentation/ocr_translation_regions.dart';
import 'package:pdf_utility_flutter/translation/presentation/translated_overlay_deck.dart';
import 'package:pdf_utility_flutter/translation/presentation/translated_text_layout.dart';

/// Diagnostic only: runs the **whole** chain — OCR, region building, on-device
/// translation and the overlay deck — and prints what happened to every region,
/// so a region that never reaches the photo can be traced to its cause.
///
/// ```
/// adb push page.png /data/local/tmp/ocr_page.png
/// flutter test integration_test/ocr_translation_probe_test.dart \
///   -d 163ea46d --dart-define=PROBE_IMAGE=/data/local/tmp/ocr_page.png
/// ```
///
/// Never part of the shipped suite.
const String _probeImageOverride = String.fromEnvironment('PROBE_IMAGE');

/// Source and target language codes, so the same probe can drive an English
/// document into Hindi as well as a Hindi page into English.
const String _probeSourceCode = String.fromEnvironment(
  'PROBE_SOURCE',
  defaultValue: 'hi',
);
const String _probeTargetCode = String.fromEnvironment(
  'PROBE_TARGET',
  defaultValue: 'en',
);

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('probe the translation overlay end to end', (tester) async {
    await tester.runAsync(() async {
      final path = _probeImageOverride.isEmpty
          ? 'test/assets/real/newspaper_hindi_three_columns.png'
          : _probeImageOverride;
      // ignore: avoid_print
      print('TPROBE image=$path exists=${File(path).existsSync()}');

      // --- 1. OCR -----------------------------------------------------------
      final ocr = createOcrService();
      late final OcrResult result;
      try {
        result = await ocr.recognizeImage(path, mode: OcrScriptMode.auto);
      } finally {
        await ocr.dispose();
      }
      // ignore: avoid_print
      print(
        'TPROBE ocr engine=${result.engineName} '
        'image=${result.sourceImage.width}x${result.sourceImage.height} '
        'lines=${result.lines.length} words=${result.elements.length}',
      );

      // --- 2. translation units --------------------------------------------
      final units = OcrTranslationRegions.fromPage(result);
      // ignore: avoid_print
      print('TPROBE units=${units.length}');
      for (final unit in units) {
        // ignore: avoid_print
        print(
          'TPROBE UNIT ${unit.id} ${unit.kind.name} '
          'bounds=[${unit.bounds.left.round()},${unit.bounds.top.round()},'
          '${unit.bounds.right.round()},${unit.bounds.bottom.round()}] '
          'chars=${unit.text.length} text="${_clip(unit.text, 60)}"',
        );
      }

      // --- 3. on-device translation ----------------------------------------
      final translation = createTranslationService();
      final TranslatedOverlay overlay;
      try {
        overlay = await translation.translateRegions(
          units,
          source:
              TranslationLanguages.byCode(_probeSourceCode) ??
              TranslationLanguages.hindi,
          target:
              TranslationLanguages.byCode(_probeTargetCode) ??
              TranslationLanguages.english,
        );
      } finally {
        await translation.dispose();
      }
      // ignore: avoid_print
      print(
        'TPROBE overlay regions=${overlay.regions.length} '
        'renderable=${overlay.renderableRegions.length} '
        'elapsed=${overlay.elapsed?.inMilliseconds}ms',
      );
      for (final region in overlay.regions) {
        // ignore: avoid_print
        print(
          'TPROBE REGION ${region.id} renderable=${region.isRenderable} '
          'srcChars=${region.sourceText.length} '
          'dstChars=${region.translatedText.length} '
          'bounds=[${region.bounds.left.round()},'
          '${region.bounds.top.round()},${region.bounds.right.round()},'
          '${region.bounds.bottom.round()}] '
          'out="${_clip(region.translatedText, 400)}"',
        );
      }

      // --- 4. the deck, at the sizes a phone actually gives it -------------
      final view = tester.view;
      final screen = view.physicalSize / view.devicePixelRatio;
      final style = DefaultTextStyle.of(
        tester.element(find.byType(Container)),
      ).style;
      // ignore: avoid_print
      print(
        'TPROBE screen=${screen.width.toStringAsFixed(0)}x'
        '${screen.height.toStringAsFixed(0)} '
        'fontSize=${style.fontSize} size=${style.fontSize}',
      );

      // The result screen gives the photo the space between the app bar and the
      // strip under it; 0.62 / 0.50 of the screen brackets that on a phone.
      final areas = <String, Size>{
        for (final fraction in <double>[0.62, 0.50, 0.40])
          'photo=${(fraction * 100).round()}%': Size(
            screen.width,
            screen.height * fraction,
          ),
      };

      for (final entry in areas.entries) {
        final viewport = entry.value;
        final mapper = OcrCoordinateMapper(
          imageWidth: result.sourceImage.width,
          imageHeight: result.sourceImage.height,
          viewportSize: viewport,
        );
        final imageRect = mapper.displayedOffset & mapper.displayedSize;
        final items = <TranslatedDeckItem>[
          for (final region in overlay.renderableRegions)
            if (!mapper.rectToScreen(region.bounds).isEmpty)
              TranslatedDeckItem(
                id: region.id,
                text: region.translatedText,
                sourceRect: mapper.rectToScreen(region.bounds),
                isParagraph: region.kind == TranslatedRegionKind.paragraph,
              ),
        ];
        final layout = TranslatedOverlayDeck.layout(
          items: items,
          imageRect: imageRect,
          style: style,
          lineCap: 48,
          maxSizeCeiling: TranslatedTextLayout.defaultMaxSize,
        );
        // ignore: avoid_print
        print(
          'TPROBE DECK ${entry.key} viewport=${viewport.width.toStringAsFixed(0)}'
          'x${viewport.height.toStringAsFixed(0)} '
          'image=${imageRect.width.toStringAsFixed(0)}x'
          '${imageRect.height.toStringAsFixed(0)} '
          'scale=${mapper.scale.toStringAsFixed(3)} '
          'blocks=${layout.blocks.length} hidden=${layout.hiddenRegionIds}',
        );
        for (final block in layout.blocks) {
          // ignore: avoid_print
          print(
            'TPROBE DECKBLOCK ${entry.key} id=${block.id} '
            'lines=${block.lines.length} '
            'box=[${block.box.left.toStringAsFixed(0)},'
            '${block.box.top.toStringAsFixed(0)},'
            '${block.box.right.toStringAsFixed(0)},'
            '${block.box.bottom.toStringAsFixed(0)}] '
            'coverage=[${block.coverage.left.toStringAsFixed(0)},'
            '${block.coverage.top.toStringAsFixed(0)},'
            '${block.coverage.right.toStringAsFixed(0)},'
            '${block.coverage.bottom.toStringAsFixed(0)}] '
            'font=${block.lines.first.layout.style.fontSize?.toStringAsFixed(1)} '
            'ellipsized=${block.lines.first.layout.ellipsized} '
            'maxLines=${block.lines.first.layout.maxLines} '
            'hidden=${block.hiddenRegionIds}',
          );
        }
      }

      // --- 5. why a region was dropped: its own fit at the real scale ------
      final viewport = areas['photo=62%']!;
      final mapper = OcrCoordinateMapper(
        imageWidth: result.sourceImage.width,
        imageHeight: result.sourceImage.height,
        viewportSize: viewport,
      );
      final imageRect = mapper.displayedOffset & mapper.displayedSize;
      for (final region in overlay.renderableRegions) {
        final rect = mapper.rectToScreen(region.bounds);
        final fit = TranslatedTextLayout.fit(
          text: region.translatedText,
          sourceRect: rect,
          imageRect: imageRect,
          style: style,
          lineCap: 48,
          heightGrowth: double.infinity,
          maxSizeCeiling: TranslatedTextLayout.defaultMaxSize,
        );
        // ignore: avoid_print
        print(
          'TPROBE FIT ${region.id} srcH=${rect.height.toStringAsFixed(1)} '
          'font=${fit.style.fontSize?.toStringAsFixed(1)} '
          'paint=${fit.paintText} lines=${fit.maxLines} '
          'boxH=${fit.box.height.toStringAsFixed(1)} '
          'needsH=${(fit.maxLines * (fit.style.fontSize ?? 7) * 1.2).toStringAsFixed(1)}',
        );
      }

      // --- 6. what a full-screen page would look like ----------------------
      final full = Size(screen.width, screen.height - 24);
      final fullMapper = OcrCoordinateMapper(
        imageWidth: result.sourceImage.width,
        imageHeight: result.sourceImage.height,
        viewportSize: full,
      );
      final fullRect = fullMapper.displayedOffset & fullMapper.displayedSize;
      final fullLayout = TranslatedOverlayDeck.layout(
        items: <TranslatedDeckItem>[
          for (final region in overlay.renderableRegions)
            TranslatedDeckItem(
              id: region.id,
              text: region.translatedText,
              sourceRect: fullMapper.rectToScreen(region.bounds),
              isParagraph: region.kind == TranslatedRegionKind.paragraph,
            ),
        ],
        imageRect: fullRect,
        style: style,
        lineCap: 48,
        maxSizeCeiling: TranslatedTextLayout.defaultMaxSize,
      );
      // ignore: avoid_print
      print(
        'TPROBE FULLSCREEN image=${fullRect.width.toStringAsFixed(0)}x'
        '${fullRect.height.toStringAsFixed(0)} blocks=${fullLayout.blocks.length} '
        'hidden=${fullLayout.hiddenRegionIds}',
      );
    });
  });
}

String _clip(String text, int max) {
  final clean = text.replaceAll(RegExp(r'\s+'), ' ').trim();
  return clean.length <= max ? clean : '${clean.substring(0, max)}…';
}
