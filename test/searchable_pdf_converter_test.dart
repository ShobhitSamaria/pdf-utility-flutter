import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as image;
import 'package:pdf_utility_flutter/ocr/domain/document_orientation.dart';
import 'package:pdf_utility_flutter/ocr/domain/ocr_block.dart';
import 'package:pdf_utility_flutter/ocr/domain/ocr_element.dart';
import 'package:pdf_utility_flutter/ocr/domain/ocr_line.dart';
import 'package:pdf_utility_flutter/ocr/domain/ocr_rect.dart';
import 'package:pdf_utility_flutter/ocr/domain/ocr_result.dart';
import 'package:pdf_utility_flutter/ocr/domain/ocr_script_mode.dart';
import 'package:pdf_utility_flutter/ocr/domain/ocr_service.dart';
import 'package:pdf_utility_flutter/pdf/data/pdf_text_layer_reader.dart';
import 'package:pdf_utility_flutter/pdf/data/searchable_pdf_converter.dart';
import 'package:pdf_utility_flutter/pdf/domain/pdf_document_info.dart';
import 'package:pdf_utility_flutter/pdf/domain/pdf_output_directory.dart';
import 'package:pdf_utility_flutter/pdf/domain/pdf_page_renderer.dart';
import 'package:pdf_utility_flutter/pdf/domain/pdf_text_layer.dart';
import 'package:pdf_utility_flutter/pdf/domain/rendered_pdf_page.dart';

/// A renderer that "rasterises" pages by writing a real PNG, so the converter's
/// image embedding, cleanup and progress can all be exercised without PDFium.
class _FakeRenderer implements PdfPageRenderer {
  _FakeRenderer({
    required this.directory,
    required this.pageCount,
    this.sizes,
    this.pixels,
  });

  final Directory directory;
  final int pageCount;

  /// Optional page sizes in points, index 0 for page 1. Used to prove a mixed
  /// portrait/landscape document keeps each page's own shape.
  final List<(double, double)>? sizes;

  /// Optional raster pixel sizes, index 0 for page 1. Separate from [sizes] so
  /// a test can reproduce a renderer whose raster is in a different orientation
  /// from the page size it declares.
  final List<(int, int)>? pixels;
  final List<int> rendered = <int>[];
  bool closed = false;

  @override
  String get engineName => 'fake';

  @override
  Future<PdfDocumentInfo> open(String path) async =>
      PdfDocumentInfo(path: path, title: 'scan.pdf', pageCount: pageCount);

  @override
  Future<RenderedPdfPage> renderPage(int pageNumber) async {
    rendered.add(pageNumber);
    final size = sizes?[pageNumber - 1] ?? (0.0, 0.0);
    // The raster keeps the page's shape, which is what the real PDFium
    // renderer does too, unless a test asks for a deliberately different one.
    final configured = pixels?[pageNumber - 1];
    final pixelWidth = configured?.$1 ?? 200;
    final pixelHeight =
        configured?.$2 ??
        (size.$1 <= 0 ? 300 : (pixelWidth * size.$2 / size.$1).round());
    final file = File('${directory.path}/page_$pageNumber.png');
    final png = image.encodePng(
      image.Image(width: pixelWidth, height: pixelHeight),
    );
    await file.writeAsBytes(png);
    return RenderedPdfPage(
      pageNumber: pageNumber,
      imagePath: file.path,
      width: pixelWidth,
      height: pixelHeight,
      pageWidth: size.$1,
      pageHeight: size.$2,
    );
  }

  @override
  Future<void> close() async => closed = true;
}

/// Returns a fixed reading: one English line and one Hindi line per page.
class _FakeOcr implements OcrService {
  _FakeOcr({
    required this.texts,
    this.boxes,
    this.elementBoxes,
    this.orientation = DocumentOrientation.upright,
    this.sourceWidth = 200,
    this.sourceHeight = 300,
  });

  final List<String> texts;

  /// Optional line boxes, in the OCR frame, index 0 for the first line.
  final List<OcrRect>? boxes;

  /// Optional word boxes, in the OCR frame, index 0 for the first line.
  ///
  /// Word order is what tells the converter which way a sideways line reads,
  /// so a test that needs a direction supplies at least two boxes here.
  final List<List<OcrRect>>? elementBoxes;

  /// The turn the OCR service applied before reading; its boxes are in that
  /// upright frame.
  final DocumentOrientation orientation;
  final int sourceWidth;
  final int sourceHeight;
  final List<String> read = <String>[];

  @override
  String get engineName => 'fake';

  @override
  Future<OcrResult> recognizeImage(
    String imagePath, {
    OcrScriptMode mode = OcrScriptMode.defaultMode,
  }) async {
    read.add(imagePath);
    final lines = <OcrLine>[
      for (var i = 0; i < texts.length; i++)
        OcrLine(
          text: texts[i],
          boundingBox:
              boxes?[i] ??
              OcrRect.fromLTRB(10, 20.0 + i * 40, 190, 50.0 + i * 40),
          elements: [
            for (final (j, elementBox)
                in (elementBoxes?[i] ?? const <OcrRect>[]).indexed)
              OcrElement(text: 'w$j', boundingBox: elementBox),
          ],
        ),
    ];
    return OcrResult(
      sourceImage: SourceImageInfo(
        path: imagePath,
        width: sourceWidth,
        height: sourceHeight,
      ),
      fullText: texts.join('\n'),
      blocks: <OcrBlock>[
        OcrBlock(
          text: texts.join('\n'),
          boundingBox: OcrRect.fromLTRB(10, 20, 190, 90),
          lines: lines,
        ),
      ],
      orientation: orientation,
    );
  }

  @override
  Future<void> dispose() async {}
}

class _TempDirectory implements PdfOutputDirectory {
  _TempDirectory(this.path);

  final String path;

  @override
  Future<String> resolve() async => path;
}

PdfTextRun _runContaining(PdfTextLayer layer, String text) =>
    layer.pages.single.runs.firstWhere((run) => run.text.contains(text));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory work;
  late _TempDirectory output;

  setUp(() async {
    work = await Directory.systemTemp.createTemp('searchable_pdf_test');
    output = _TempDirectory(work.path);
    await Directory('${work.path}/rasters').create(recursive: true);
  });

  tearDown(() async {
    if (work.existsSync()) await work.delete(recursive: true);
  });

  SearchablePdfConverter converterFor(_FakeRenderer renderer, _FakeOcr ocr) =>
      SearchablePdfConverter(
        renderer: renderer,
        ocr: ocr,
        outputDirectory: output,
        assetLoader: (key) async =>
            ByteData.sublistView(await File(key).readAsBytes()),
      );

  test(
    'the Devanagari face is bundled, so a release build can embed Hindi',
    () async {
      final data = await rootBundle.load(
        SearchablePdfConverter.devanagariFontAsset,
      );
      expect(data.lengthInBytes, greaterThan(50000));
    },
  );

  test('every page gets a text layer and the scan stays the page', () async {
    final rasters = await Directory(
      '${work.path}/rasters',
    ).create(recursive: true);
    final renderer = _FakeRenderer(directory: rasters, pageCount: 3);
    final ocr = _FakeOcr(texts: <String>['Ship To', 'पवन सामरिया']);
    final converter = converterFor(renderer, ocr);

    final progress = <(int, int)>[];
    final pdf = await converter.convert(
      inputPath: '${work.path}/scan.pdf',
      onProgress: (done, total) => progress.add((done, total)),
    );

    // Real file, real size, real page count.
    expect(File(pdf.path).existsSync(), isTrue);
    expect(pdf.byteSize, greaterThan(1000));
    expect(pdf.pageCount, 3);
    expect(pdf.fileName, 'scan (searchable).pdf');

    // Progress is page-driven: 1/3, 2/3, 3/3 and nothing else.
    expect(progress, <(int, int)>[(1, 3), (2, 3), (3, 3)]);

    // Every page was rasterised and read exactly once, in order.
    expect(renderer.rendered, <int>[1, 2, 3]);
    expect(ocr.read.length, 3);

    // The PDF is a real document with three pages.
    final bytes = await File(pdf.path).readAsBytes();
    final latin1 = String.fromCharCodes(bytes);
    expect(latin1.startsWith('%PDF'), isTrue);
    expect(RegExp(r'/Type\s*/Page[^s]').allMatches(latin1).length, 3);

    // A searchable layer is not just text drawn on a page: the font has to be
    // embedded and have a Unicode mapping, or a viewer can neither search it
    // nor copy Devanagari out of it.
    expect(latin1, contains('/FontFile2'));
    expect(latin1, contains('/ToUnicode'));
  });

  test('temporary page rasters are deleted, whatever happened', () async {
    final rasters = await Directory(
      '${work.path}/rasters',
    ).create(recursive: true);
    final renderer = _FakeRenderer(directory: rasters, pageCount: 2);
    final converter = converterFor(
      renderer,
      _FakeOcr(texts: <String>['Only line']),
    );

    await converter.convert(inputPath: '${work.path}/scan.pdf');

    expect(
      rasters.listSync(),
      isEmpty,
      reason: 'page rasters must be cleaned up',
    );
    expect(renderer.closed, isTrue, reason: 'the document must be closed');
  });

  test('a single-page document reports 1 page, not a range', () async {
    final rasters = await Directory(
      '${work.path}/rasters',
    ).create(recursive: true);
    final converter = converterFor(
      _FakeRenderer(directory: rasters, pageCount: 1),
      _FakeOcr(texts: <String>['Total 120']),
    );

    final pdf = await converter.convert(inputPath: '${work.path}/one.pdf');

    expect(pdf.pageCount, 1);
    expect(pdf.pageCountLabel, '1 page');
    expect(pdf.fileName, 'one (searchable).pdf');
  });

  test('a page with no recognised text still becomes a page', () async {
    final rasters = await Directory(
      '${work.path}/rasters',
    ).create(recursive: true);
    final converter = converterFor(
      _FakeRenderer(directory: rasters, pageCount: 2),
      _FakeOcr(texts: const <String>[]),
    );

    final pdf = await converter.convert(inputPath: '${work.path}/blank.pdf');

    expect(pdf.pageCount, 2);
    expect(File(pdf.path).existsSync(), isTrue);
  });

  test('each page keeps its own portrait or landscape shape', () async {
    final rasters = await Directory(
      '${work.path}/rasters',
    ).create(recursive: true);
    final renderer = _FakeRenderer(
      directory: rasters,
      pageCount: 3,
      // portrait, landscape, portrait — the mixed document this must support.
      sizes: const [(200, 300), (300, 200), (200, 300)],
    );
    final converter = converterFor(
      renderer,
      _FakeOcr(texts: <String>['Total 120']),
    );

    final pdf = await converter.convert(inputPath: '${work.path}/mixed.pdf');

    // Read the geometry back out of the written file, so this asserts what the
    // PDF actually declares rather than what the code intended.
    final layer = const PdfTextLayerReader().readBytes(
      await File(pdf.path).readAsBytes(),
    );
    expect(layer.pageCount, 3);
    expect(layer.pages[0].width, lessThan(layer.pages[0].height));
    expect(layer.pages[1].width, greaterThan(layer.pages[1].height));
    expect(layer.pages[2].width, lessThan(layer.pages[2].height));
    expect(layer.pages[1].width, closeTo(300, 0.5));
    expect(layer.pages[1].height, closeTo(200, 0.5));
  });

  group('rotated OCR readings', () {
    Future<PdfTextLayer> convertOne({
      required Directory rasters,
      required DocumentOrientation orientation,
      required int sourceWidth,
      required int sourceHeight,
      required OcrRect box,
    }) async {
      final renderer = _FakeRenderer(
        directory: rasters,
        pageCount: 1,
        sizes: const [(200, 100)],
        pixels: const [(200, 100)],
      );
      final converter = converterFor(
        renderer,
        _FakeOcr(
          texts: const ['Hello'],
          boxes: [box],
          orientation: orientation,
          sourceWidth: sourceWidth,
          sourceHeight: sourceHeight,
        ),
      );

      final pdf = await converter.convert(inputPath: '${work.path}/scan.pdf');
      return const PdfTextLayerReader().readBytes(
        await File(pdf.path).readAsBytes(),
      );
    }

    test('90° upright boxes go back to the stored pixels', () async {
      final rasters = await Directory(
        '${work.path}/rasters',
      ).create(recursive: true);

      final layer = await convertOne(
        rasters: rasters,
        orientation: const DocumentOrientation(1),
        sourceWidth: 100,
        sourceHeight: 200,
        // Measured on the 100 × 200 upright copy.
        box: const OcrRect(left: 10, top: 20, right: 30, bottom: 80),
      );

      // The stored raster and the page are 200 × 100: the box lands at
      // (20, 70)..(80, 90), not at the upright coordinates.
      final run = _runContaining(layer, 'Hello');
      expect(layer.pages.single.width, 200);
      expect(layer.pages.single.height, 100);
      expect(run.left, closeTo(0.1, 0.005));
      // The reader's line box includes full ascent and descent, so its top is
      // a font metric below the widget's top edge; the position, not the
      // metric, is what this test pins down.
      expect(run.top, closeTo(0.7, 0.02));
    });

    test('180° upright boxes are mirrored back', () async {
      final rasters = await Directory(
        '${work.path}/rasters',
      ).create(recursive: true);

      final layer = await convertOne(
        rasters: rasters,
        orientation: const DocumentOrientation(2),
        sourceWidth: 200,
        sourceHeight: 100,
        box: const OcrRect(left: 10, top: 20, right: 30, bottom: 80),
      );

      final run = _runContaining(layer, 'Hello');
      expect(run.left, closeTo(0.85, 0.005));
      expect(run.top, closeTo(0.2, 0.02));
    });

    test('270° upright boxes go back to the stored pixels', () async {
      final rasters = await Directory(
        '${work.path}/rasters',
      ).create(recursive: true);

      final layer = await convertOne(
        rasters: rasters,
        orientation: const DocumentOrientation(3),
        sourceWidth: 100,
        sourceHeight: 200,
        box: const OcrRect(left: 10, top: 20, right: 30, bottom: 80),
      );

      final run = _runContaining(layer, 'Hello');
      expect(run.left, closeTo(0.6, 0.005));
      expect(run.top, closeTo(0.1, 0.02));
    });
  });

  test('the raster is fitted, not stretched, and text follows it', () async {
    final rasters = await Directory(
      '${work.path}/rasters',
    ).create(recursive: true);
    final renderer = _FakeRenderer(
      directory: rasters,
      pageCount: 1,
      sizes: const [(400, 400)],
      // A landscape scan on a square sheet: fit means letterboxing, not
      // squashing the scan to fill the square.
      pixels: const [(200, 100)],
    );
    final converter = converterFor(
      renderer,
      _FakeOcr(
        texts: const ['Hello'],
        boxes: const [OcrRect(left: 10, top: 20, right: 190, bottom: 50)],
        sourceWidth: 200,
        sourceHeight: 100,
      ),
    );

    final pdf = await converter.convert(inputPath: '${work.path}/scan.pdf');
    final layer = const PdfTextLayerReader().readBytes(
      await File(pdf.path).readAsBytes(),
    );

    expect(layer.pages.single.width, 400);
    expect(layer.pages.single.height, 400);

    // scale = min(400/200, 400/100) = 2; a 200 × 100 raster becomes
    // 400 × 200, centred with 100 pt above and below. The OCR box therefore
    // starts at (20, 140) in page points.
    final run = _runContaining(layer, 'Hello');
    expect(run.left, closeTo(0.05, 0.005));
    expect(run.top, closeTo(0.35, 0.02));
  });

  test(
    'when source and destination aspects match, placement is unchanged',
    () async {
      final rasters = await Directory(
        '${work.path}/rasters',
      ).create(recursive: true);
      final renderer = _FakeRenderer(
        directory: rasters,
        pageCount: 1,
        sizes: const [(200, 100)],
        pixels: const [(200, 100)],
      );
      final converter = converterFor(
        renderer,
        _FakeOcr(
          texts: const ['Hello'],
          boxes: const [OcrRect(left: 10, top: 20, right: 190, bottom: 50)],
          sourceWidth: 200,
          sourceHeight: 100,
        ),
      );

      final pdf = await converter.convert(inputPath: '${work.path}/scan.pdf');
      final layer = const PdfTextLayerReader().readBytes(
        await File(pdf.path).readAsBytes(),
      );

      final run = _runContaining(layer, 'Hello');
      expect(run.left, closeTo(0.05, 0.005));
      expect(run.top, closeTo(0.2, 0.02));
    },
  );

  test('a rotated raster keeps the visible page orientation', () async {
    final rasters = await Directory(
      '${work.path}/rasters',
    ).create(recursive: true);
    final renderer = _FakeRenderer(
      directory: rasters,
      pageCount: 1,
      // The renderer declares the pre-rotation MediaBox...
      sizes: const [(200, 100)],
      // ...while the raster is the page as displayed: portrait.
      pixels: const [(100, 200)],
    );
    final converter = converterFor(
      renderer,
      _FakeOcr(
        texts: const ['Hello'],
        boxes: const [OcrRect(left: 10, top: 20, right: 40, bottom: 50)],
        sourceWidth: 100,
        sourceHeight: 200,
      ),
    );

    final pdf = await converter.convert(inputPath: '${work.path}/scan.pdf');
    final layer = const PdfTextLayerReader().readBytes(
      await File(pdf.path).readAsBytes(),
    );

    // The output page is portrait, like the raster the user saw — not the
    // landscape MediaBox the renderer reported.
    expect(layer.pages.single.width, 100);
    expect(layer.pages.single.height, 200);

    final run = _runContaining(layer, 'Hello');
    expect(run.left, closeTo(0.1, 0.005));
    expect(run.top, closeTo(0.1, 0.02));
  });

  group('text orientation in the stored raster', () {
    Future<PdfTextLayer> convertPage({
      required Directory rasters,
      required DocumentOrientation orientation,
      required int sourceWidth,
      required int sourceHeight,
      required List<String> texts,
      required List<OcrRect> boxes,
      List<List<OcrRect>>? elementBoxes,
      double pageWidth = 200,
      double pageHeight = 100,
    }) async {
      final renderer = _FakeRenderer(
        directory: rasters,
        pageCount: 1,
        sizes: [(pageWidth, pageHeight)],
        pixels: [(pageWidth.round(), pageHeight.round())],
      );
      final converter = converterFor(
        renderer,
        _FakeOcr(
          texts: texts,
          boxes: boxes,
          elementBoxes: elementBoxes,
          orientation: orientation,
          sourceWidth: sourceWidth,
          sourceHeight: sourceHeight,
        ),
      );

      final pdf = await converter.convert(inputPath: '${work.path}/scan.pdf');
      return const PdfTextLayerReader().readBytes(
        await File(pdf.path).readAsBytes(),
      );
    }

    test('a portrait line stays horizontal, as it always was', () async {
      final rasters = await Directory(
        '${work.path}/rasters',
      ).create(recursive: true);

      final layer = await convertPage(
        rasters: rasters,
        orientation: DocumentOrientation.upright,
        sourceWidth: 200,
        sourceHeight: 300,
        texts: const ['Hello'],
        boxes: const [OcrRect(left: 10, top: 20, right: 190, bottom: 50)],
        pageWidth: 200,
        pageHeight: 300,
      );

      final run = _runContaining(layer, 'Hello');
      expect(run.height, lessThan(run.width * 0.5));
      expect(run.left, closeTo(0.05, 0.01));
    });

    test('a sideways line on a landscape page is drawn vertically', () async {
      final rasters = await Directory(
        '${work.path}/rasters',
      ).create(recursive: true);

      final layer = await convertPage(
        rasters: rasters,
        // The raster is landscape 200 × 100; the recogniser read an upright
        // 100 × 200 copy, so its 80 × 20 line is 20 × 80 once put back.
        orientation: const DocumentOrientation(1),
        sourceWidth: 100,
        sourceHeight: 200,
        texts: const ['Hello'],
        boxes: const [OcrRect(left: 10, top: 20, right: 90, bottom: 40)],
      );

      final run = _runContaining(layer, 'Hello');
      // The old converter drew this as a horizontal band: its height came from
      // the box's 80-pixel *height*, which made a 64 pt font lying across the
      // page. A vertical run is the whole point of the fix.
      expect(run.height, greaterThan(run.width * 2.5));
      expect(run.left, closeTo(0.1, 0.03));
      // Upwards text starts at the bottom edge of its OCR rectangle.
      expect(run.bottom, closeTo(0.9, 0.05));
    });

    test('word order picks downwards when the page reads that way', () async {
      final rasters = await Directory(
        '${work.path}/rasters',
      ).create(recursive: true);

      final layer = await convertPage(
        rasters: rasters,
        orientation: const DocumentOrientation(3),
        sourceWidth: 100,
        sourceHeight: 200,
        texts: const ['Hello'],
        boxes: const [OcrRect(left: 10, top: 20, right: 90, bottom: 40)],
        // Reading order in the upright copy maps to increasing y here, so the
        // restored line must read downwards.
        elementBoxes: const [
          [
            OcrRect(left: 10, top: 20, right: 30, bottom: 40),
            OcrRect(left: 70, top: 20, right: 90, bottom: 40),
          ],
        ],
      );

      final run = _runContaining(layer, 'Hello');
      expect(run.height, greaterThan(run.width * 2.5));
      // Downwards text starts at the top edge of its OCR rectangle.
      expect(run.top, closeTo(0.1, 0.05));
    });

    test('one page can carry both upright and sideways lines', () async {
      final rasters = await Directory(
        '${work.path}/rasters',
      ).create(recursive: true);

      final layer = await convertPage(
        rasters: rasters,
        orientation: DocumentOrientation.upright,
        sourceWidth: 200,
        sourceHeight: 300,
        texts: const ['Across', 'Down'],
        boxes: const [
          OcrRect(left: 20, top: 20, right: 180, bottom: 50),
          // A rotated table header on an otherwise portrait page.
          OcrRect(left: 100, top: 100, right: 130, bottom: 260),
        ],
        elementBoxes: const [
          [
            OcrRect(left: 20, top: 20, right: 60, bottom: 50),
            OcrRect(left: 140, top: 20, right: 180, bottom: 50),
          ],
          [
            OcrRect(left: 100, top: 100, right: 130, bottom: 130),
            OcrRect(left: 100, top: 230, right: 130, bottom: 260),
          ],
        ],
        pageWidth: 200,
        pageHeight: 300,
      );

      final across = layer.pages.single.runs.firstWhere(
        (run) => run.text.contains('Across'),
      );
      final down = layer.pages.single.runs.firstWhere(
        (run) => run.text.contains('Down'),
      );

      expect(across.width, greaterThan(across.height * 3));
      // `PdfTextRun` is normalised to the page, and this page is taller than
      // it is wide, so compare the run's own axes rather than a page-relative
      // ratio: a vertical run is taller than it is wide.
      expect(down.height, greaterThan(down.width));
      expect(down.left, closeTo(0.5, 0.03));
    });
  });

  test('names are sanitised and keep the .pdf extension', () {
    expect(
      SearchablePdfConverter.fileNameFor('/tmp/report.final.pdf'),
      'report.final (searchable).pdf',
    );
    expect(
      SearchablePdfConverter.fileNameFor('/tmp/a/b:c.pdf'),
      'b_c (searchable).pdf',
    );
    expect(
      SearchablePdfConverter.fileNameFor('/tmp/scan.PDF'),
      'scan (searchable).pdf',
    );
  });
}
