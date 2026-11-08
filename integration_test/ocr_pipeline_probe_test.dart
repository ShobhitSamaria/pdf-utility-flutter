import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:pdf_utility_flutter/main.dart' show createOcrService;
import 'package:pdf_utility_flutter/ocr/domain/ocr_document_layout.dart';
import 'package:pdf_utility_flutter/ocr/domain/ocr_result.dart';
import 'package:pdf_utility_flutter/ocr/domain/ocr_script_mode.dart';

/// Where the page under test lives.
///
/// On a **device** the test process runs on the phone, so a repository-relative
/// path does not exist there; push the image first and point the run at it:
///
/// ```
/// adb push page.png /data/local/tmp/ocr_page.png
/// flutter test integration_test/ocr_pipeline_probe_test.dart \
///   -d <device> --dart-define=PROBE_IMAGE=/data/local/tmp/ocr_page.png
/// ```
///
/// On the host (`flutter test integration_test/...` without `-d`) the
/// repository copy is used, because the working directory *is* the package root.
const String _probeImageOverride = String.fromEnvironment('PROBE_IMAGE');

/// Diagnostic only: measures real ML Kit recall on the supplied newspaper page
/// under several strategies. Never part of the shipped suite.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  final probeDir = Directory.systemTemp.createTempSync('ocr_probe_');
  final page = File('${probeDir.path}/page.png');
  final report = <Map<String, Object?>>[];

  Future<ui.Image> decode(String path) async {
    final buffer = await ui.ImmutableBuffer.fromFilePath(path);
    final codec = await ui.instantiateImageCodecFromBuffer(buffer);
    final frame = await codec.getNextFrame();
    codec.dispose();
    return frame.image;
  }

  Future<String> savePng(ui.Image image, String name) async {
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    final file = File('${probeDir.path}/$name');
    await file.writeAsBytes(data!.buffer.asUint8List(), flush: true);
    return file.path;
  }

  Future<String> scaled(String path, String name, double scale) async {
    final source = await decode(path);
    final width = (source.width * scale).round();
    final height = (source.height * scale).round();
    final recorder = ui.PictureRecorder();
    Canvas(recorder).drawImageRect(
      source,
      Rect.fromLTWH(0, 0, source.width.toDouble(), source.height.toDouble()),
      Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
      Paint()..filterQuality = FilterQuality.high,
    );
    final picture = recorder.endRecording();
    final image = await picture.toImage(width, height);
    picture.dispose();
    source.dispose();
    final saved = await savePng(image, name);
    image.dispose();
    return saved;
  }

  Future<String> crop(
    String path,
    String name,
    Rect sourceRect,
    double scale,
  ) async {
    final source = await decode(path);
    final width = (sourceRect.width * scale).round();
    final height = (sourceRect.height * scale).round();
    final recorder = ui.PictureRecorder();
    Canvas(recorder).drawImageRect(
      source,
      sourceRect,
      Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
      Paint()..filterQuality = FilterQuality.high,
    );
    final picture = recorder.endRecording();
    final image = await picture.toImage(width, height);
    picture.dispose();
    source.dispose();
    final saved = await savePng(image, name);
    image.dispose();
    return saved;
  }

  int devanagariCount(String text) => text.runes
      .where(
        (r) => (r >= 0x0900 && r <= 0x0963) || (r >= 0x0971 && r <= 0x097F),
      )
      .length;

  String norm(String text) => text.replaceAll(RegExp(r'\s+'), '');

  Map<String, Object?> measure(String label, OcrResult result) => {
    'label': label,
    'engine': result.engineName,
    'lines': result.lines.length,
    'words': result.elements.length,
    'textLength': result.fullText.length,
    'devanagari': devanagariCount(result.fullText),
    'elapsedMs': result.elapsed?.inMilliseconds,
    'dims': '${result.sourceImage.width}x${result.sourceImage.height}',
    'blockCount': result.blocks.length,
    'linesInOrder': [
      for (var b = 0; b < result.blocks.length; b++) ...[
        for (final line in result.blocks[b].lines)
          {
            'text': line.text,
            'x': line.boundingBox.left.round(),
            'y': line.boundingBox.top.round(),
            'w': line.boundingBox.width.round(),
            'h': line.boundingBox.height.round(),
            'block': b,
            'blockLines': result.blocks[b].lines.length,
            'blockX': result.blocks[b].boundingBox.left.round(),
            'blockY': result.blocks[b].boundingBox.top.round(),
            'blockW': result.blocks[b].boundingBox.width.round(),
            'blockH': result.blocks[b].boundingBox.height.round(),
          },
      ],
    ],
  };

  Future<OcrResult> run(
    String label,
    String path, {
    OcrScriptMode mode = OcrScriptMode.devanagari,
  }) async {
    final service = createOcrService();
    try {
      final result = await service.recognizeImage(path, mode: mode);
      final entry = measure(label, result);
      final layout = OcrDocumentLayout.blocks(result);
      final layoutLines = layout.fold<int>(0, (n, b) => n + b.lines.length);
      entry['layoutBlocks'] = layout.length;
      entry['layoutLines'] = layoutLines;
      entry['layoutDropped'] = result.lines.length - layoutLines;
      entry['layoutTexts'] = [for (final b in layout) b.text];
      // A compact reading-order trace: one line per layout block, so the order
      // can be judged from a device log without the whole result.
      for (var i = 0; i < layout.length; i++) {
        final block = layout[i];
        final box = block.bounds;
        // ignore: avoid_print
        print(
          'PROBE LAYOUT $label #$i lines=${block.lines.length} '
          'x=${box.left.round()} y=${box.top.round()} '
          'w=${box.width.round()} h=${box.height.round()} '
          'chars=${block.text.length} '
          'first="${block.text.length > 45 ? block.text.substring(0, 45) : block.text}"',
        );
      }
      report.add(entry);
      // ignore: avoid_print
      print(
        'PROBE $label: lines=${entry['lines']} words=${entry['words']} '
        'chars=${entry['textLength']} devanagari=${entry['devanagari']} '
        'elapsed=${entry['elapsedMs']}ms layoutBlocks=${layout.length} '
        'layoutLines=$layoutLines dropped=${entry['layoutDropped']}',
      );
      return result;
    } finally {
      await service.dispose();
    }
  }

  testWidgets('probe real newspaper page', (tester) async {
    await tester.runAsync(() async {
      // Read from the repository rather than `rootBundle`: the test photographs
      // are deliberately not bundled into the app, so a release build does not
      // carry them. `flutter test integration_test` runs with the package root
      // as its working directory.
      final source = _probeImageOverride.isEmpty
          ? 'test/assets/real/newspaper_hindi_three_columns.png'
          : _probeImageOverride;
      // ignore: avoid_print
      print('PROBE image source=$source');
      final bytes = await File(source).readAsBytes();
      await page.writeAsBytes(bytes, flush: true);
      final auto = await run(
        'auto/original',
        page.path,
        mode: OcrScriptMode.auto,
      );
      final deva = await run('devanagari/original', page.path);
      final latin = await run(
        'latin/original',
        page.path,
        mode: OcrScriptMode.latin,
      );

      final x2 = await scaled(page.path, 'page_2x.png', 2);
      final deva2x = await run('devanagari/2x', x2);

      final x3 = await scaled(page.path, 'page_3x.png', 3);
      final deva3x = await run('devanagari/3x', x3);

      // Three body columns of the page, each at 2x. Ranges read off the image.
      final crops = <String, Rect>{
        'col1': const Rect.fromLTWH(40, 540, 345, 760),
        'col2': const Rect.fromLTWH(375, 540, 345, 760),
        'col3': const Rect.fromLTWH(700, 540, 345, 760),
      };
      final cropResults = <String, OcrResult>{};
      for (final entry in crops.entries) {
        final path = await crop(
          page.path,
          'crop_${entry.key}.png',
          entry.value,
          2,
        );
        cropResults[entry.key] = await run(
          'devanagari/crop-${entry.key}',
          path,
        );
      }

      // Generic 2x2 tiles with 10% overlap, the candidate fix.
      final w = deva2x.sourceImage.width.toDouble();
      final h = deva2x.sourceImage.height.toDouble();
      final tiles = <String, Rect>{
        'tl': Rect.fromLTWH(0, 0, w * 0.55, h * 0.55),
        'tr': Rect.fromLTWH(w * 0.45, 0, w * 0.55, h * 0.55),
        'bl': Rect.fromLTWH(0, h * 0.45, w * 0.55, h * 0.55),
        'br': Rect.fromLTWH(w * 0.45, h * 0.45, w * 0.55, h * 0.55),
      };
      final tileText = StringBuffer();
      var tileWords = 0;
      var tileLines = 0;
      for (final entry in tiles.entries) {
        final path = await crop(x2, 'tile_${entry.key}.png', entry.value, 1);
        final result = await run('devanagari/tile-${entry.key}', path);
        tileText.writeln(result.fullText);
        tileWords += result.elements.length;
        tileLines += result.lines.length;
      }
      report.add({
        'label': 'tiles/2x aggregate',
        'words': tileWords,
        'lines': tileLines,
        'text': tileText.toString(),
      });
      // ignore: avoid_print
      print('PROBE tiles/2x: lines=$tileLines words=$tileWords');

      final joined = norm(
        [
          deva.fullText,
          deva2x.fullText,
          deva3x.fullText,
          for (final r in cropResults.values) r.fullText,
        ].join(' '),
      );
      const expected = <String, List<String>>{
        'headline': ['एजेंसीसेवठेकेपरलगे', 'राहत', 'नियम2022'],
        'col1': ['राजस्थानहाईकोर्ट', 'जस्टिसमुखर्जी', 'बड़ीराहत'],
        'col2': ['महाधिवक्ताओं', 'कॉन्ट्रैक्चुअल', 'नियम2022'],
        'col3': ['प्रत्यक्षचयन', 'दायरेमेंनहीं', 'उल्लंघन'],
      };

      Map<String, Object?> score(OcrResult result) {
        final text = norm(result.fullText);
        return {
          for (final entry in expected.entries)
            entry.key: [
              for (final phrase in entry.value) text.contains(norm(phrase)),
            ],
          'auto': auto.engineName,
          'latinEngine': latin.engineName,
          'chars': deva.fullText.length,
          'chars2x': deva2x.fullText.length,
          'chars3x': deva3x.fullText.length,
        };
      }

      final scores = score(deva);
      final scores2x = score(deva2x);
      final scores3x = score(deva3x);
      report.add({
        'label': 'scores',
        'original': scores,
        '2x': scores2x,
        '3x': scores3x,
      });
      // ignore: avoid_print
      print('PROBE SCORES original=$scores');
      // ignore: avoid_print
      print('PROBE SCORES 2x=$scores2x');
      // ignore: avoid_print
      print('PROBE SCORES 3x=$scores3x');
      // ignore: avoid_print
      print('PROBE joinedLength=${joined.length}');

      final encoded = jsonEncode(report);
      // ignore: avoid_print
      print('PROBE_JSON_BEGIN length=${encoded.length}');
      const chunk = 1500;
      for (var i = 0; i < encoded.length; i += chunk) {
        // ignore: avoid_print
        print(
          'PROBE_CHUNK ${encoded.substring(i, i + chunk > encoded.length ? encoded.length : i + chunk)}',
        );
      }
      // ignore: avoid_print
      print('PROBE_JSON_END');
    });
  });
}
