import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:pdf_utility_flutter/main.dart' show createOcrService;
import 'package:pdf_utility_flutter/pdf/data/native_pdf_output_directory.dart';
import 'package:pdf_utility_flutter/pdf/data/pdf_file_exporter.dart';
import 'package:pdf_utility_flutter/pdf/data/pdfx_page_renderer.dart';
import 'package:pdf_utility_flutter/pdf/data/searchable_pdf_converter.dart';

/// Diagnostic only: converts a real PDF with the real device pipeline — PDFium
/// rasterising, ML Kit reading, the `pdf` writer embedding — so a conversion
/// that only fails on hardware (memory, native engine, font embedding) is not
/// discovered by a user.
///
/// ```
/// adb push demo.pdf /data/local/tmp/demo.pdf
/// flutter test integration_test/searchable_pdf_probe_test.dart \
///   -d <device> --dart-define=PROBE_PDF=/data/local/tmp/demo.pdf
/// ```
///
/// The finished file is written through [NativePdfOutputDirectory], so it lands
/// in the app's cache and can be pulled for inspection:
///
/// ```
/// adb exec-out run-as com.shobhit.pdfutility.pdf_utility_flutter \
///   cat cache/created_pdfs/<name>.pdf > out.pdf
/// ```
///
/// Never part of the shipped suite.
const String _probePdf = String.fromEnvironment('PROBE_PDF');

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('probe: a real PDF becomes searchable on device', (tester) async {
    await tester.runAsync(() async {
      final path = _probePdf.isEmpty ? '/data/local/tmp/demo.pdf' : _probePdf;
      // ignore: avoid_print
      print('PPROBE input=$path exists=${File(path).existsSync()}');

      final ocr = createOcrService();
      final converter = SearchablePdfConverter(
        renderer: PdfxPageRenderer(),
        ocr: ocr,
      );
      try {
        final progress = <String>[];
        final stopwatch = Stopwatch()..start();
        final pdf = await converter.convert(
          inputPath: path,
          onProgress: (done, total) {
            progress.add('$done/$total');
            // ignore: avoid_print
            print('PPROBE page $done of $total (${(done / total * 100).round()}%)');
          },
        );
        stopwatch.stop();

        // ignore: avoid_print
        print(
          'PPROBE result pages=${pdf.pageCount} size=${pdf.byteSize} '
          'name=${pdf.fileName} path=${pdf.path} '
          'elapsed=${stopwatch.elapsedMilliseconds}ms',
        );
        // ignore: avoid_print
        print('PPROBE progress=%{${progress.join(',')}}');

        expect(File(pdf.path).existsSync(), isTrue);
        expect(pdf.pageCount, greaterThan(0));
        expect(progress.length, pdf.pageCount);
        expect(progress.last, '${pdf.pageCount}/${pdf.pageCount}');
        expect(pdf.byteSize, greaterThan(1000));

        // The searchable layer is only real if the encoder wrote an embedded
        // font and a Unicode map; a page of drawn glyphs would look identical
        // and be unsearchable. Checked here, on the file the device produced.
        final bytes = await File(pdf.path).readAsBytes();
        final raw = String.fromCharCodes(bytes);
        final pages = RegExp(r'/Type\s*/Page[^s]').allMatches(raw).length;
        final hasFont = raw.contains('/FontFile2');
        final hasToUnicode = raw.contains('/ToUnicode');
        // ignore: avoid_print
        print(
          'PPROBE layers pages=$pages fontEmbedded=$hasFont '
          'toUnicode=$hasToUnicode header=${raw.startsWith('%PDF')}',
        );
        expect(pages, pdf.pageCount);
        expect(hasFont, isTrue);
        expect(hasToUnicode, isTrue);

        // And through the same path the Save button uses, so the file can be
        // inspected by an ordinary PDF reader on this machine.
        const exporter = PdfFileExporter();
        final saved = await exporter.saveToDownloads(pdf);
        // ignore: avoid_print
        print('PPROBE saved=$saved');
        final shared = await exporter.share(pdf);
        // ignore: avoid_print
        print('PPROBE shareSheetShown=$shared');
      } finally {
        await ocr.dispose();
      }
    });
  });
}
