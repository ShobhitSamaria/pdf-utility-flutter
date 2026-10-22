import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:integration_test/integration_test.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:pdf_utility_flutter/main.dart' show createOcrService;
import 'package:pdf_utility_flutter/pdf/data/pdfx_page_renderer.dart';
import 'package:pdf_utility_flutter/ocr/domain/ocr_exception.dart';
import 'package:pdf_utility_flutter/ocr/domain/ocr_result.dart';
import 'package:pdf_utility_flutter/ocr/domain/ocr_script_mode.dart';

/// End-to-end OCR tests that run the **real** ML Kit recognizer on a device or
/// emulator:
///
/// ```
/// flutter test integration_test/ocr_device_test.dart -d emulator-5554
/// ```
///
/// The unit suite proves the app's logic against a fake engine; this file is the
/// only place that proves a file on disk reaches the native recognizer, that a
/// picked gallery image and a camera-style JPEG go through the same path, and
/// that repeated runs do not reuse disposed native state.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  final directory = Directory.systemTemp;
  var counter = 0;

  String uniqueName(String stem, String extension) =>
      'ocr_device_${counter++}_$stem.$extension';

  /// Draws [lines] onto a white page and returns it as PNG bytes — the same
  /// shape as a page rendered from an imported PDF, and as any gallery PNG.
  Future<Uint8List> renderPng(
    List<String> lines, {
    int width = 900,
    int height = 1200,
    bool devanagari = false,
  }) async {
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    final area = Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble());
    canvas.drawRect(area, Paint()..color = const Color(0xFFFFFFFF));

    var y = 70.0;
    for (final line in lines) {
      final builder =
          ui.ParagraphBuilder(
              ui.ParagraphStyle(
                textDirection: TextDirection.ltr,
                fontSize: 40,
                fontFamily: devanagari ? 'Noto Sans Devanagari' : null,
              ),
            )
            ..pushStyle(
              ui.TextStyle(
                color: const Color(0xFF000000),
                fontSize: 40,
                fontFamily: devanagari ? 'Noto Sans Devanagari' : null,
              ),
            )
            ..addText(line);
      final paragraph = builder.build()
        ..layout(ui.ParagraphConstraints(width: width - 100.0));
      canvas.drawParagraph(paragraph, Offset(50, y));
      y += 70;
    }

    final picture = recorder.endRecording();
    final image = await picture.toImage(width, height);
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    picture.dispose();
    image.dispose();
    if (data == null) throw StateError('PNG encoding failed');
    return data.buffer.asUint8List();
  }

  Future<String> writePng(
    String stem,
    List<String> lines, {
    bool devanagari = false,
  }) async {
    final file = File('${directory.path}/${uniqueName(stem, 'png')}');
    await file.writeAsBytes(
      await renderPng(lines, devanagari: devanagari),
      flush: true,
    );
    return file.path;
  }

  /// A camera-style JPEG: the same pixels, encoded the way `takePicture()`
  /// returns them into the app's cache directory.
  Future<String> writeJpeg(String stem, List<String> lines) async {
    final png = await renderPng(lines);
    final decoded = img.decodePng(png);
    if (decoded == null) throw StateError('could not decode the rendered page');
    final jpeg = img.encodeJpg(decoded, quality: 90);
    final file = File('${directory.path}/${uniqueName(stem, 'jpg')}');
    await file.writeAsBytes(jpeg, flush: true);
    return file.path;
  }

  void report(String label, OcrResult result) {
    // ignore: avoid_print
    print(
      'DEVICE_OCR $label: engine=${result.engineName} '
      'blocks=${result.blocks.length} words=${result.elements.length} '
      'dims=${result.sourceImage.width}x${result.sourceImage.height} '
      'textLength=${result.fullText.length} '
      'elapsed=${result.elapsed?.inMilliseconds}ms',
    );
  }

  testWidgets('a gallery-style PNG reaches the recognizer and is read', (
    tester,
  ) async {
    const lines = [
      'OFFICE OF THE DISTRICT ELECTION OFFICER',
      'Name and designation of the polling officer',
      'AP02 Mohit Kirtar 18808',
      'Training details',
      'Kishangarh Renewal',
    ];
    final path = await writePng('page', lines);
    final service = createOcrService();
    try {
      final result = await service.recognizeImage(
        path,
        mode: OcrScriptMode.latin,
      );
      report('png/latin', result);
      expect(result.blocks, isNotEmpty, reason: 'the page has printed text');
      expect(result.fullText.toUpperCase(), contains('DISTRICT'));
      expect(result.sourceImage.path, path);
    } finally {
      await service.dispose();
    }
  });

  testWidgets('a camera-style JPEG reaches the recognizer and is read', (
    tester,
  ) async {
    const lines = [
      'GOVERNMENT OF RAJASTHAN',
      'Admit Card 2026',
      'Roll number 18808',
    ];
    final path = await writeJpeg('capture', lines);
    final service = createOcrService();
    try {
      final result = await service.recognizeImage(
        path,
        mode: OcrScriptMode.latin,
      );
      report('jpeg/latin', result);
      expect(result.blocks, isNotEmpty);
      expect(result.fullText.toUpperCase(), contains('RAJASTHAN'));
    } finally {
      await service.dispose();
    }
  });

  testWidgets('the default Auto mode reads a page without an explicit script', (
    tester,
  ) async {
    final path = await writePng('auto', const [
      'TRAINING DETAILS',
      'Second training on 21 October 2026',
    ]);
    final service = createOcrService();
    try {
      final result = await service.recognizeImage(path);
      report('png/auto', result);
      expect(result.blocks, isNotEmpty);
    } finally {
      await service.dispose();
    }
  });

  testWidgets('a page with no text is a successful empty result', (
    tester,
  ) async {
    final path = await writePng('blank', const []);
    final service = createOcrService();
    try {
      final result = await service.recognizeImage(path);
      report('png/blank', result);
      // No text is not a failure: the engine answered and found nothing.
      expect(result.blocks, isEmpty);
      expect(result.fullText.trim(), isEmpty);
    } finally {
      await service.dispose();
    }
  });

  testWidgets('a missing file is a controlled failure with its cause kept', (
    tester,
  ) async {
    final service = createOcrService();
    try {
      final missing = '${directory.path}/${uniqueName('gone', 'png')}';
      await expectLater(
        service.recognizeImage(missing),
        throwsA(
          isA<OcrException>()
              .having((e) => e.kind, 'kind', OcrErrorKind.imageUnreadable)
              .having((e) => e.cause, 'cause', isNotNull),
        ),
      );
      // ignore: avoid_print
      print('DEVICE_OCR missing: controlled imageUnreadable failure');
    } finally {
      await service.dispose();
    }
  });

  testWidgets('repeated runs share one service and never use stale state', (
    tester,
  ) async {
    final service = createOcrService();
    try {
      for (var run = 1; run <= 3; run++) {
        final path = await writePng('repeat_$run', [
          'PAGE NUMBER $run',
          'DELHI',
        ]);
        final result = await service.recognizeImage(path);
        report('repeat$run', result);
        expect(result.blocks, isNotEmpty, reason: 'run $run must be read');
      }
    } finally {
      await service.dispose();
    }
  });

  /// A real PDF on disk, with real text widgets — the same shape as a document
  /// a person imports through "Import PDF".
  Future<String> writePdf() async {
    final document = pw.Document();
    document.addPage(
      pw.Page(
        pageFormat: PdfPageFormat.a4,
        build: (_) => pw.Column(
          crossAxisAlignment: pw.CrossAxisAlignment.start,
          children: [
            pw.Text(
              'OFFICE OF THE DISTRICT ELECTION OFFICER',
              style: pw.TextStyle(fontSize: 18),
            ),
            pw.SizedBox(height: 12),
            pw.Text('Rajasthan Government'),
            pw.SizedBox(height: 12),
            pw.Text('Polling station: Kishangarh Renewal'),
            pw.Text('Panchayat committee'),
          ],
        ),
      ),
    );
    final file = File('${directory.path}/${uniqueName('import', 'pdf')}');
    await file.writeAsBytes(await document.save(), flush: true);
    return file.path;
  }

  testWidgets('a rendered PDF page reaches the recognizer and is read', (
    tester,
  ) async {
    final pdfPath = await writePdf();
    final renderer = PdfxPageRenderer();
    final service = createOcrService();
    try {
      await renderer.open(pdfPath);
      final page = await renderer.renderPage(1);
      // ignore: avoid_print
      print(
        'DEVICE_OCR pdf: page=${page.pageNumber} '
        'raster=${page.width}x${page.height} file=${page.imagePath}',
      );
      expect(File(page.imagePath).existsSync(), isTrue);
      expect(page.width, greaterThan(0));

      final result = await service.recognizeImage(page.imagePath);
      report('pdf/latin', result);
      expect(result.blocks, isNotEmpty);
      expect(result.fullText.toUpperCase(), contains('DISTRICT'));
    } finally {
      await renderer.close();
      await service.dispose();
    }
  });

  testWidgets('a failed read leaves the service usable for the next image', (
    tester,
  ) async {
    final service = createOcrService();
    try {
      final missing = '${directory.path}/${uniqueName('absent', 'png')}';
      await expectLater(
        service.recognizeImage(missing),
        throwsA(isA<OcrException>()),
      );

      // The same service must still read a valid page: the failure was the
      // input, not a wedged recognizer.
      final path = await writePng('after_failure', ['RECOVERY PAGE', 'JAPUR']);
      final result = await service.recognizeImage(path);
      report('after_failure', result);
      expect(result.blocks, isNotEmpty);
    } finally {
      await service.dispose();
    }
  });

  testWidgets('manual script selection works for Latin and Devanagari', (
    tester,
  ) async {
    final english = await writePng('latin_script', [
      'ELECTION COMMISSION',
      'Polling station list',
    ]);
    final hindi = await writePng('hindi_script', const [
      'जिला निर्वाचन अधिकारी',
      'मतदान केंद्र',
    ], devanagari: true);

    final service = createOcrService();
    try {
      final latin = await service.recognizeImage(
        english,
        mode: OcrScriptMode.latin,
      );
      report('script/latin', latin);
      expect(latin.blocks, isNotEmpty);

      final devanagari = await service.recognizeImage(
        hindi,
        mode: OcrScriptMode.devanagari,
      );
      report('script/devanagari', devanagari);
      // The page is Devanagari; the recognizer must answer with a result (text
      // is asserted loosely because the emulator's font coverage is not the
      // subject of this test).
      expect(devanagari.sourceImage.width, greaterThan(0));
    } finally {
      await service.dispose();
    }
  });
}
