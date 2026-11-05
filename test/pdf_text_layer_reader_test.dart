import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pdf/pdf.dart' hide PdfException;
import 'package:pdf/widgets.dart' as pw;
import 'package:pdf_utility_flutter/pdf/data/pdf_text_layer_reader.dart';
import 'package:pdf_utility_flutter/pdf/domain/pdf_text_layer.dart';
import 'package:pdf_utility_flutter/pdf/domain/pdf_text_search.dart';

/// Writes the same kind of page the converter writes: a sheet with invisible
/// text positioned by OCR-style boxes, Latin and Devanagari lines.
Future<Uint8List> _samplePdf() async {
  final latin = pw.Font.helvetica();
  final devanagari = pw.Font.ttf(
    ByteData.sublistView(
      await File('assets/fonts/NotoSansDevanagari-Regular.ttf').readAsBytes(),
    ),
  );
  final document = pw.Document();

  document.addPage(
    pw.Page(
      pageFormat: const PdfPageFormat(400, 300),
      build: (context) => pw.Stack(
        children: [
          pw.Positioned(
            left: 20,
            top: 40,
            child: pw.Text(
              'Total 120',
              style: pw.TextStyle(
                font: latin,
                fontSize: 18,
                renderingMode: PdfTextRenderingMode.invisible,
              ),
            ),
          ),
          pw.Positioned(
            left: 20,
            top: 90,
            child: pw.Text(
              'पवन सामरिया',
              style: pw.TextStyle(
                font: devanagari,
                fontSize: 18,
                renderingMode: PdfTextRenderingMode.invisible,
              ),
            ),
          ),
          pw.Positioned(
            left: 20,
            top: 140,
            child: pw.Text(
              'Department: Revenue',
              style: pw.TextStyle(
                font: latin,
                fontSize: 18,
                renderingMode: PdfTextRenderingMode.invisible,
              ),
            ),
          ),
        ],
      ),
    ),
  );

  return Uint8List.fromList(await document.save());
}

/// A small, hand-written PDF with one text run at a known position.
///
/// Hand-written rather than produced by `package:pdf` because `/Rotate` and
/// `/CropBox` are exactly what is under test, and the reader deliberately needs
/// no xref or object streams for this shape: it scans the objects.
Uint8List _pagePdf({
  double x = 50,
  double y = 40,
  double fontSize = 20,
  String mediaBox = '[0 0 200 100]',
  String? cropBox,
  String? rotate,
  String? content,
  bool inheritAttributes = false,
}) {
  final contentText = content ?? 'BT /F1 $fontSize Tf $x $y Td (Hello) Tj ET';
  final attributes = <String>[
    if (cropBox != null) '/CropBox $cropBox',
    if (rotate != null) '/Rotate $rotate',
  ].join(' ');
  final inherited = inheritAttributes ? attributes : '';
  final pageAttributes = inheritAttributes ? '' : attributes;

  final pdf =
      '''
%PDF-1.4
1 0 obj
<< /Type /Catalog /Pages 2 0 R >>
endobj
2 0 obj
<< /Type /Pages /Kids [3 0 R] /Count 1 $inherited >>
endobj
3 0 obj
<< /Type /Page /Parent 2 0 R /MediaBox $mediaBox /Contents 4 0 R /Resources << /Font << /F1 5 0 R >> >> $pageAttributes >>
endobj
4 0 obj
<< /Length ${contentText.length} >>
stream
$contentText
endstream
endobj
5 0 obj
<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>
endobj
trailer
<< /Root 1 0 R >>
%%EOF
''';
  return Uint8List.fromList(latin1.encode(pdf));
}

PdfTextRun _hello(PdfTextLayer layer) =>
    layer.pages.single.runs.firstWhere((run) => run.text.contains('Hello'));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('reads the invisible text layer, both scripts, with geometry', () async {
    final layer = const PdfTextLayerReader().readBytes(await _samplePdf());

    expect(layer.pageCount, 1);
    final page = layer.pages.single;
    expect(page.width, 400);
    expect(page.height, 300);
    expect(page.hasText, isTrue);

    // What a viewer would copy out of the file: Latin and Devanagari.
    expect(page.text, contains('Total 120'));
    expect(page.text, contains('पवन सामरिया'));
    expect(page.text, contains('Department: Revenue'));

    for (final run in page.runs) {
      expect(run.left, inInclusiveRange(0, 1));
      expect(run.top, inInclusiveRange(0, 1));
      expect(run.right, greaterThanOrEqualTo(run.left));
      expect(run.bottom, greaterThanOrEqualTo(run.top));
      expect(run.width, greaterThan(0));
      expect(run.height, greaterThan(0));
    }

    // The first line sits near the top, as it was placed.
    final total = page.runs.firstWhere((run) => run.text.contains('Total'));
    expect(total.top, lessThan(0.35));
    expect(total.left, lessThan(0.2));
  });

  test('search finds Hindi and English in that layer', () async {
    final layer = const PdfTextLayerReader().readBytes(await _samplePdf());
    const search = PdfTextSearch();

    expect(search.find(layer, 'Total 120'), hasLength(1));
    expect(search.find(layer, 'total 120'), hasLength(1));
    expect(search.find(layer, 'पवन'), hasLength(1));
    expect(search.find(layer, 'सामरिया'), hasLength(1));
    expect(search.find(layer, 'Revenue').single.pageNumber, 1);
    expect(search.find(layer, 'missing word'), isEmpty);
    expect(search.find(layer, '   '), isEmpty);
  });

  group('page /Rotate and /CropBox', () {
    test('an ordinary page reads as the media box, unrotated', () {
      final layer = const PdfTextLayerReader().readBytes(_pagePdf());

      final page = layer.pages.single;
      expect(page.width, 200);
      expect(page.height, 100);

      final run = _hello(layer);
      expect(run.left, closeTo(0.25, 0.001));
      expect(run.right, closeTo(0.5, 0.001));
      expect(run.top, closeTo(0.4, 0.001));
      expect(run.bottom, closeTo(0.65, 0.001));
    });

    test('/Rotate 90 swaps the displayed size and turns the run', () {
      final layer = const PdfTextLayerReader().readBytes(
        _pagePdf(rotate: '90'),
      );

      final page = layer.pages.single;
      expect(page.width, 100);
      expect(page.height, 200);

      final run = _hello(layer);
      expect(run.left, closeTo(0.35, 0.001));
      expect(run.right, closeTo(0.6, 0.001));
      expect(run.top, closeTo(0.25, 0.001));
      expect(run.bottom, closeTo(0.5, 0.001));
    });

    test('/Rotate 180 mirrors the run and keeps the page shape', () {
      final layer = const PdfTextLayerReader().readBytes(
        _pagePdf(rotate: '180'),
      );

      final page = layer.pages.single;
      expect(page.width, 200);
      expect(page.height, 100);

      final run = _hello(layer);
      expect(run.left, closeTo(0.5, 0.001));
      expect(run.right, closeTo(0.75, 0.001));
      expect(run.top, closeTo(0.35, 0.001));
      expect(run.bottom, closeTo(0.6, 0.001));
    });

    test('/Rotate 270 swaps the displayed size the other way', () {
      final layer = const PdfTextLayerReader().readBytes(
        _pagePdf(rotate: '270'),
      );

      final page = layer.pages.single;
      expect(page.width, 100);
      expect(page.height, 200);

      final run = _hello(layer);
      expect(run.left, closeTo(0.4, 0.001));
      expect(run.right, closeTo(0.65, 0.001));
      expect(run.top, closeTo(0.5, 0.001));
      expect(run.bottom, closeTo(0.75, 0.001));
    });

    test('a CropBox is intersected with the MediaBox and becomes the page', () {
      final layer = const PdfTextLayerReader().readBytes(
        _pagePdf(cropBox: '[10 20 210 120]'),
      );

      final page = layer.pages.single;
      // The crop extends past the media box, so the visible width stops at 200.
      expect(page.width, 190);
      expect(page.height, 80);

      final run = _hello(layer);
      expect(run.left, closeTo(40 / 190, 0.001));
      expect(run.right, closeTo(90 / 190, 0.001));
      expect(run.top, closeTo(0.5, 0.001));
      expect(run.bottom, closeTo(0.8125, 0.001));
    });

    test(
      'a CropBox entirely outside the MediaBox falls back to the media box',
      () {
        final layer = const PdfTextLayerReader().readBytes(
          _pagePdf(cropBox: '[-50 -50 -10 -10]'),
        );

        final page = layer.pages.single;
        expect(page.width, 200);
        expect(page.height, 100);

        final run = _hello(layer);
        expect(run.left, closeTo(0.25, 0.001));
        expect(run.top, closeTo(0.4, 0.001));
      },
    );

    test('inherited /Rotate and /CropBox are read from the page tree', () {
      final layer = const PdfTextLayerReader().readBytes(
        _pagePdf(
          x: 20,
          cropBox: '[0 0 100 100]',
          rotate: '90',
          inheritAttributes: true,
        ),
      );

      final page = layer.pages.single;
      expect(page.width, 100);
      expect(page.height, 100);

      final run = _hello(layer);
      expect(run.left, closeTo(0.35, 0.001));
      expect(run.right, closeTo(0.6, 0.001));
      expect(run.top, closeTo(0.2, 0.001));
      expect(run.bottom, closeTo(0.7, 0.001));
    });

    test('an unsupported rotation is ignored rather than guessed at', () {
      final layer = const PdfTextLayerReader().readBytes(
        _pagePdf(rotate: '45'),
      );

      final page = layer.pages.single;
      expect(page.width, 200);
      expect(page.height, 100);

      final run = _hello(layer);
      expect(run.left, closeTo(0.25, 0.001));
      expect(run.top, closeTo(0.4, 0.001));
    });

    test('a run rotated by its text matrix keeps its sideways geometry', () {
      // `Tm` [0 1 -1 0 100 50] turns the baseline ninety degrees anticlockwise:
      // local +x becomes page +y. "Hello" at 20 pt therefore runs up the page,
      // from y=50 to about y=95, at x≈100. The old reader took only the
      // baseline endpoints and added the ascent in page y, which gave this run
      // zero width and dropped it entirely.
      final layer = const PdfTextLayerReader().readBytes(
        _pagePdf(content: 'BT /F1 20 Tf 0 1 -1 0 100 50 Tm (Hello) Tj ET'),
      );

      final run = _hello(layer);
      expect(run.height, greaterThan(run.width * 3));
      expect(run.left, closeTo(0.4, 0.02));
      expect(run.right, closeTo(0.53, 0.02));
      // The hand-written font has no /Widths, so the reader advances five
      // 500-unit glyphs at 20 pt: the run reaches the top edge of the page.
      expect(run.top, closeTo(0.0, 0.02));
      expect(run.bottom, closeTo(0.5, 0.02));
    });
  });

  test('a file that is not a PDF is reported, not guessed at', () {
    expect(
      () => const PdfTextLayerReader().readBytes(
        Uint8List.fromList('this is not a pdf'.codeUnits),
      ),
      throwsA(isA<Exception>()),
    );
  });
}
