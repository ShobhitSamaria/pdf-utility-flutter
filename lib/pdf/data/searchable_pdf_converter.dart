import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' show Size;

import 'package:flutter/services.dart' show ByteData, rootBundle;

// `package:pdf` exports a `PdfException` of its own; this app's is the one the UI
// speaks, so the package's is hidden here for the same reason as in
// `pdf_library_creation_service.dart`.
import 'package:pdf/pdf.dart' hide PdfException;
import 'package:pdf/widgets.dart' as pw;

import '../../app/app_brand.dart';
import '../../ocr/domain/document_orientation.dart';
import '../../ocr/domain/ocr_line.dart';
import '../../ocr/domain/ocr_orientation_transform.dart';
import '../../ocr/domain/ocr_script_mode.dart';
import '../../ocr/domain/ocr_service.dart';
import '../domain/pdf_creation.dart';
import '../domain/pdf_exception.dart';
import '../domain/pdf_output_directory.dart';
import '../domain/pdf_page_layout.dart';
import '../domain/pdf_page_renderer.dart';
import 'native_pdf_output_directory.dart';

/// Turns a scanned (image-only) PDF into a **searchable** one.
///
/// What it does, per page, in order
/// --------------------------------
/// 1. Rasterise the page with the existing [PdfPageRenderer] (PDFium, on device).
/// 2. Read it with the existing [OcrService] — the same pipeline the photo and
///    single-page paths use, so Hindi/English behaviour is identical.
/// 3. Write a **new** page whose background is the original page image and whose
///    text is the recognised text, drawn in
///    [PdfTextRenderingMode.invisible] at the recognised coordinates.
///
/// The page therefore looks pixel-identical to the scan, and a viewer can
/// select, copy and search the text that sits invisibly on top of it.
///
/// Why the image is re-embedded instead of copying the original page
/// ----------------------------------------------------------------
/// There is no PDF object-level merge here (`pdfx` reads no page content, and
/// `pdf` cannot import foreign page objects). Re-embedding the raster is what
/// makes this honest: the output is a real document built entirely from pieces
/// this app controls, at the cost of the page being an image rather than vector
/// content. The visible result is the same; the file is larger.
///
/// Text encoding
/// -------------
/// Latin runs use the built-in Helvetica. Devanagari runs use an embedded Noto
/// Sans Devanagari (the `pdf` package writes a `/ToUnicode` CMap for an embedded
/// TrueType font, which is what makes Hindi copyable and searchable). A line that
/// mixes scripts is split into script runs so no character is asked of a font
/// that cannot encode it.
///
/// What is NOT implemented (reported rather than papered over)
/// ----------------------------------------------------------
/// Pages that *already* have a text layer are not detected: `pdfx` exposes no
/// text extraction, and without page-level text there is no way to keep the
/// existing layer while rebuilding the page. Those pages are therefore OCR'd
/// again, which leaves them searchable (their text appears once from OCR).
/// Detecting and re-embedding an existing layer is the next step; it needs a
/// PDF text-extraction dependency.
class SearchablePdfConverter {
  SearchablePdfConverter({
    required this.renderer,
    required this.ocr,
    // The platform's own directory, not `Directory.systemTemp` — on Android that
    // resolves to `code_cache`, which no FileProvider root covers, so the file
    // would be created but impossible to share (`shareFile` answered false).
    // See `NativePdfOutputDirectory`.
    this.outputDirectory = const NativePdfOutputDirectory(),
    this.directoryName = 'created_pdfs',
    Future<ByteData> Function(String key)? assetLoader,
  }) : _loadAsset = assetLoader ?? rootBundle.load;

  /// Rasterises pages of the source document.
  final PdfPageRenderer renderer;

  /// Reads the rasterised pages. Same service the rest of the app uses.
  final OcrService ocr;

  /// Where the finished file is written (the app's cache on device).
  final PdfOutputDirectory outputDirectory;

  /// Sub-directory of [outputDirectory] the file lands in.
  final String directoryName;

  final Future<ByteData> Function(String key) _loadAsset;

  /// The embedded Devanagari face. Declared as a Flutter asset; ~215 KB, which
  /// is the whole cost of searchable Hindi in a PDF.
  static const String devanagariFontAsset =
      'assets/fonts/NotoSansDevanagari-Regular.ttf';

  /// `report.pdf` → `report (searchable).pdf`.
  static String fileNameFor(String inputPath) {
    final separator = inputPath.lastIndexOf(RegExp(r'[\\/]'));
    final base = separator < 0 ? inputPath : inputPath.substring(separator + 1);
    final dot = base.lastIndexOf('.');
    final stem = dot <= 0 ? base : base.substring(0, dot);
    // Sanitised *without* the extension: `_sanitize` adds it, and doing both
    // would produce `scan.pdf (searchable).pdf`.
    return _sanitize('$stem (searchable)');
  }

  /// Converts every page of [inputPath].
  ///
  /// [onProgress] is called **after each finished page** with the number of
  /// pages done and the document's total, which is what a real percentage needs
  /// — there is no timer and no estimate here.
  ///
  /// Temporary page rasters are deleted in a `finally`, so a failure halfway
  /// through a 200-page scan leaves nothing behind.
  Future<CreatedPdf> convert({
    required String inputPath,
    String? fileName,
    void Function(int completed, int total)? onProgress,
  }) async {
    final stopwatch = Stopwatch()..start();
    final info = await renderer.open(inputPath);
    final total = info.pageCount;
    final name = _sanitize(fileName ?? fileNameFor(inputPath));

    final latin = pw.Font.helvetica();
    final devanagari = pw.Font.ttf(await _loadAsset(devanagariFontAsset));
    final document = pw.Document(title: name, creator: AppBrand.name);

    final rasters = <String>[];
    try {
      for (var pageNumber = 1; pageNumber <= total; pageNumber++) {
        final page = await renderer.renderPage(pageNumber);
        rasters.add(page.imagePath);
        final image = await File(page.imagePath).readAsBytes();
        final reading = await ocr.recognizeImage(
          page.imagePath,
          // Mixed runs both recognisers and keeps whichever reads each line:
          // a scanned invoice is exactly the case where a Hindi line and an
          // English address share a page.
          mode: OcrScriptMode.mixed,
        );

        // The recogniser may have read an upright copy of the page (the
        // orientation decorator rotates a sideways scan before OCR). Put every
        // box back on the original raster — the image embedded below — so the
        // invisible text lands on the pixels it describes.
        final sourceSize = Size(page.width.toDouble(), page.height.toDouble());
        final readingSize = Size(
          reading.sourceImage.width.toDouble(),
          reading.sourceImage.height.toDouble(),
        );
        final transform = OcrOrientationTransform(reading.orientation);
        final lines = <OcrLine>[
          for (final line in reading.lines)
            transform.toSourceLine(
              line,
              uprightSize: readingSize,
              sourceSize: sourceSize,
            ),
        ];

        document.addPage(
          _buildPage(
            image: image,
            pixelWidth: page.width,
            pixelHeight: page.height,
            // The page's own geometry, so a mixed document keeps its portrait
            // and landscape pages instead of everything being re-fitted.
            pageWidth: page.pageWidth,
            pageHeight: page.pageHeight,
            lines: lines,
            // The turn the recogniser applied to read this page. Lines that
            // are ambiguous on their own (one word, no word order to read)
            // fall back to it, so a sideways page still gets a direction.
            pageOrientation: reading.orientation,
            latin: latin,
            devanagari: devanagari,
          ),
        );
        onProgress?.call(pageNumber, total);
      }

      final saved = await document.save();
      final file = await _write(saved, name);
      stopwatch.stop();
      return CreatedPdf(
        path: file.path,
        fileName: name,
        pageCount: total,
        byteSize: await file.length(),
        elapsed: stopwatch.elapsed,
      );
    } on PdfException {
      rethrow;
    } catch (error) {
      throw PdfException.from(error);
    } finally {
      await renderer.close();
      for (final path in rasters) {
        try {
          await File(path).delete();
        } catch (_) {
          // The OS reclaims the cache anyway; a failed delete must not turn a
          // finished conversion into a failure.
        }
      }
    }
  }

  /// One output page: the scan, plus its invisible text layer.
  pw.Page _buildPage({
    required Uint8List image,
    required int pixelWidth,
    required int pixelHeight,
    required double pageWidth,
    required double pageHeight,
    required List<OcrLine> lines,
    required DocumentOrientation pageOrientation,
    required pw.Font latin,
    required pw.Font devanagari,
  }) {
    // Each page takes its own source geometry: a 16-page document can be nine
    // portrait sheets, five landscape ones and two portrait again, and no page
    // is allowed to be pushed into another page's shape.
    //
    // The renderer's declared page size is preferred, but it is not blindly
    // trusted: `pdfx` reports the MediaBox on some platforms, which is the
    // *pre-rotation* size, while the raster it returns is the page as displayed.
    // When the two disagree about which side is longer, the raster wins — it is
    // what the user sees — so the output page keeps the visible orientation.
    final size = _pageSizeFor(
      pixelWidth: pixelWidth,
      pixelHeight: pixelHeight,
      pageWidth: pageWidth,
      pageHeight: pageHeight,
    );

    // Fit the raster into the page without changing its shape. One uniform
    // scale for both axes is the whole point: independent X/Y scales silently
    // stretched a page whose declared size and raster disagreed, which is
    // exactly what a rotated scan used to do. When the aspects already match,
    // this rect is the full page and the output is byte-for-byte what it was.
    final imageWidth = pixelWidth > 0 ? pixelWidth.toDouble() : size.width;
    final imageHeight = pixelHeight > 0 ? pixelHeight.toDouble() : size.height;
    final scale = math.min(size.width / imageWidth, size.height / imageHeight);
    final drawWidth = imageWidth * scale;
    final drawHeight = imageHeight * scale;
    final drawLeft = (size.width - drawWidth) / 2;
    final drawTop = (size.height - drawHeight) / 2;

    return pw.Page(
      pageFormat: PdfPageFormat(size.width, size.height),
      // Stated, not inferred: `natural` already behaves, but naming the shape
      // keeps a landscape page landscape if the page theme ever changes.
      orientation: size.width > size.height
          ? pw.PageOrientation.landscape
          : pw.PageOrientation.portrait,
      build: (context) {
        final children = <pw.Widget>[
          pw.Positioned(
            left: drawLeft,
            top: drawTop,
            child: pw.Image(
              pw.MemoryImage(image),
              width: drawWidth,
              height: drawHeight,
              // The destination rect has the image's own aspect, so filling it
              // cannot distort the scan; `contain` is already in the numbers.
              fit: pw.BoxFit.fill,
            ),
          ),
        ];

        for (final line in lines) {
          final text = line.text.trim();
          if (text.isEmpty) continue;
          final box = line.boundingBox;
          if (box.width <= 0 || box.height <= 0) continue;

          final flow = _flowOf(line, pageOrientation);
          final left = drawLeft + box.left * scale;
          final top = drawTop + box.top * scale;
          final width = box.width * scale;
          final height = box.height * scale;
          final right = left + width;
          final bottom = top + height;

          // A line's *short* side is its glyph thickness and its *long* side is
          // the direction it reads. For sideways text those axes are swapped:
          // taking the point size from the box height would make a 34 × 392
          // vertical word use a 313 pt font, a highlight thicker than the page
          // is long. Thickness is always the short side.
          final thickness = flow.isSideways ? width : height;
          // A little under the box thickness: the point size of a printed line
          // is smaller than its ink extent, and this keeps selection highlights
          // inside the printed line rather than bulging over its neighbours.
          var fontSize = (thickness * 0.8).clamp(1.0, 200.0);

          // Shrink to the page edge if the line would not fit, in whichever
          // direction it reads. A line that runs past the page is not merely
          // ugly — everything past the trim is lost from the extraction layer,
          // which is how a full address came back as "PANAG DUTTA, C 62 Sha".
          // Invisible text can be small; it cannot be missing.
          final available = switch (flow) {
            _TextFlow.right => size.width - left,
            _TextFlow.left => right,
            _TextFlow.down => size.height - top,
            _TextFlow.up => bottom,
          };
          final estimated = _estimatedWidth(text, fontSize);
          if (estimated > available && estimated > 0) {
            fontSize = (fontSize * (available / estimated)).clamp(1.0, 200.0);
          }

          if (flow == _TextFlow.right) {
            var x = left;
            for (final run in _scriptRuns(text)) {
              children.add(
                // Positioned by its top-left corner and given no width, so the
                // text lays out at its natural length: a fixed-width box clipped
                // long lines ("PANAG DUTTA, C 62 Sha") *and* wrapped them, and
                // both faults reach the extraction layer as missing or reordered
                // text. Nothing is visible here, so a line running past its OCR
                // rectangle costs nothing.
                pw.Positioned(
                  left: x,
                  top: top,
                  child: pw.Text(
                    run.$1,
                    maxLines: 1,
                    softWrap: false,
                    style: pw.TextStyle(
                      font: run.$2 ? devanagari : latin,
                      fontSize: fontSize,
                      renderingMode: PdfTextRenderingMode.invisible,
                    ),
                  ),
                ),
              );
              // Invisible text needs to be *extractable*, not pretty: advancing
              // by an estimate keeps the runs in reading order on the line
              // without measuring glyphs.
              x += run.$1.length * fontSize * 0.55;
            }
            continue;
          }

          // Sideways and upside-down lines are laid out as one run sequence and
          // turned as a whole, so every run shares the line's baseline and
          // direction. `rotateBox` lays out the rotated bounding box, which is
          // what `Positioned` places against the corresponding edge of the OCR
          // rectangle. Pinning the edge the text reads *from* — bottom for
          // upwards, right for leftwards — starts the invisible run on the
          // printed word instead of in the middle of its box.
          final runs = <pw.Widget>[
            for (final run in _scriptRuns(text))
              pw.Text(
                run.$1,
                maxLines: 1,
                softWrap: false,
                style: pw.TextStyle(
                  font: run.$2 ? devanagari : latin,
                  fontSize: fontSize,
                  renderingMode: PdfTextRenderingMode.invisible,
                ),
              ),
          ];
          final rotated = pw.Transform.rotateBox(
            angle: switch (flow) {
              // Positive angles are anticlockwise in the PDF's y-up space:
              // +90° reads up the page, -90° down it, 180° right-to-left.
              _TextFlow.up => math.pi / 2,
              _TextFlow.down => -math.pi / 2,
              _TextFlow.left => math.pi,
              _TextFlow.right => 0.0,
            },
            child: runs.length == 1
                ? runs.single
                : pw.Row(mainAxisSize: pw.MainAxisSize.min, children: runs),
          );

          children.add(switch (flow) {
            _TextFlow.left => pw.Positioned(
              right: size.width - right,
              top: top,
              child: rotated,
            ),
            _TextFlow.up => pw.Positioned(
              left: left,
              bottom: size.height - bottom,
              child: rotated,
            ),
            // downward reads from the top edge, like ordinary text
            _TextFlow.down => pw.Positioned(
              left: left,
              top: top,
              child: rotated,
            ),
            _TextFlow.right => pw.Positioned(
              left: left,
              top: top,
              child: rotated,
            ),
          });
        }

        return pw.Stack(children: children);
      },
    );
  }

  /// Which way a recognised line reads in the **stored raster**.
  ///
  /// The recogniser reads an upright copy of a sideways page, so after
  /// [OcrOrientationTransform] a line of that text is vertical, while ordinary
  /// text stays horizontal. The line's own word order is the reliable direction
  /// signal: ML Kit reports elements in reading order, and the inverse turn
  /// moves every box without reordering them. Only when that order is unusable
  /// does the page turn decide, and an even turn cannot have made a horizontal
  /// line vertical, so that case keeps the original horizontal placement.
  static _TextFlow _flowOf(OcrLine line, DocumentOrientation pageTurn) {
    final box = line.boundingBox;
    if (box.height > box.width * _tallLineRatio) {
      return _verticalFlow(line) ??
          switch (pageTurn.quarterTurnsClockwise) {
            1 => _TextFlow.up,
            3 => _TextFlow.down,
            _ => _TextFlow.right,
          };
    }

    return _horizontalFlow(line) ??
        (pageTurn.quarterTurnsClockwise == 2
            ? _TextFlow.left
            : _TextFlow.right);
  }

  /// How much taller than wide a box must be before it is sideways text.
  ///
  /// The same threshold the existing page-orientation detector uses: real
  /// prose is 1:12 or flatter, while a nearly square short word must not
  /// flip a line. See `DocumentOrientationDetector.tallLineRatio`.
  static const double _tallLineRatio = 1.15;

  static _TextFlow? _verticalFlow(OcrLine line) {
    final elements = line.elements;
    if (elements.length < 2) return null;
    final firstY = elements.first.boundingBox.centerY;
    final lastY = elements.last.boundingBox.centerY;
    if ((lastY - firstY).abs() < 1) return null;
    return lastY > firstY ? _TextFlow.down : _TextFlow.up;
  }

  static _TextFlow? _horizontalFlow(OcrLine line) {
    final elements = line.elements;
    if (elements.length < 2) return null;
    final firstX = elements.first.boundingBox.centerX;
    final lastX = elements.last.boundingBox.centerX;
    if ((lastX - firstX).abs() < 1) return null;
    return lastX < firstX ? _TextFlow.left : null;
  }

  /// The output page's size, with the visible orientation winning.
  ///
  /// A rotated page is the reason this is not just "use the declared size":
  /// `pdfx` returns the MediaBox on some platforms, which does not include
  /// `/Rotate`. The raster it rendered *does*, so its aspect is the page the
  /// user saw. Swapping the declared width and height when — and only when —
  /// that matches the raster keeps the output upright instead of letterboxing
  /// a portrait scan into a landscape sheet.
  ///
  /// A page whose declared shape matches neither the raster nor its swap (a
  /// crop, say) keeps the declared page and is fitted inside it by
  /// [_buildPage]; it is never stretched.
  static PdfPageSize _pageSizeFor({
    required int pixelWidth,
    required int pixelHeight,
    required double pageWidth,
    required double pageHeight,
  }) {
    final declared = pageWidth > 0 && pageHeight > 0
        ? PdfPageSize(pageWidth, pageHeight)
        : PdfPageLayout.forPixels(pixelWidth, pixelHeight);

    if (pixelWidth <= 0 || pixelHeight <= 0) return declared;

    final raster = pixelWidth / pixelHeight;
    if (_sameAspect(raster, declared.aspectRatio)) return declared;

    final swapped = PdfPageSize(declared.height, declared.width);
    if (_sameAspect(raster, swapped.aspectRatio)) return swapped;

    return declared;
  }

  /// Whether two page aspects are the same within rounding, not exactly.
  ///
  /// Rasterisation rounds pixels, so a 595.276 × 841.89 pt page never has an
  /// exactly equal pixel ratio. One percent is far tighter than the 90° case
  /// (which differs by the square of the ratio) and loose enough for rounding.
  static bool _sameAspect(double a, double b) {
    if (a <= 0 || b <= 0) return false;
    return (a - b).abs() <= math.max(a, b) * 0.01;
  }

  /// Which font a character needs: `true` for Devanagari, `false` for Latin,
  /// and `null` for anything that belongs to neither (punctuation, spaces).
  static bool? _scriptOf(int rune) {
    if (rune >= 0x0900 && rune <= 0x097F) return true;
    final isLatin =
        (rune >= 0x41 && rune <= 0x5A) ||
        (rune >= 0x61 && rune <= 0x7A) ||
        (rune >= 0x30 && rune <= 0x39);
    return isLatin ? false : null;
  }

  /// Rough advance width of [text] at [fontSize], in points.
  ///
  /// Deliberately an estimate: the alternative is measuring every glyph of every
  /// line of a 200-page scan through the PDF layout engine. The two factors are
  /// per-script averages (Latin is narrower than Devanagari), which is accurate
  /// enough to decide *whether* a line needs shrinking, and the result is only
  /// ever used to make text fit, never to place visibly-inked glyphs.
  static double _estimatedWidth(String text, double fontSize) {
    var em = 0.0;
    for (final rune in text.runes) {
      em += rune >= 0x0900 && rune <= 0x097F ? 0.62 : 0.5;
    }
    return em * fontSize;
  }

  /// Splits [text] into (run, isDevanagari) pairs.
  ///
  /// Needed because a single font cannot encode both scripts: handing a Latin
  /// word to a Devanagari face (or the reverse) either drops characters or
  /// throws. Splitting keeps every character in a font that has it.
  static List<(String, bool)> _scriptRuns(String text) {
    final runs = <(String, bool)>[];
    final buffer = StringBuffer();
    bool? current;
    for (final rune in text.runes) {
      final script = _scriptOf(rune);
      // Neutral characters (spaces, punctuation, digits) do not switch the run:
      // splitting "जयपुर," into a Devanagari run and a Latin comma run made
      // viewers report "जयपुर ," with a space that is not in the document.
      if (script != null && current != null && current != script) {
        runs.add((buffer.toString(), current));
        buffer.clear();
      }
      current = script ?? current ?? false;
      buffer.writeCharCode(rune);
    }
    if (buffer.isNotEmpty && current != null) {
      runs.add((buffer.toString(), current));
    }
    return runs;
  }

  Future<File> _write(Uint8List bytes, String name) async {
    final directory = Directory(
      '${await outputDirectory.resolve()}/$directoryName',
    );
    await directory.create(recursive: true);
    final file = File('${directory.path}/$name');
    await file.writeAsBytes(bytes, flush: true);
    return file;
  }

  static String _sanitize(String name) {
    final cleaned = name
        .replaceAll(RegExp(r'[\\/:*?"<>|]'), '_')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    final safe = cleaned.isEmpty ? 'Searchable' : cleaned;
    return safe.toLowerCase().endsWith('.pdf') ? safe : '$safe.pdf';
  }
}

/// The direction a line's glyphs advance in the stored image frame.
///
/// [right] is ordinary horizontal text (the only direction the converter drew
/// before rotated pages were supported); [left] is 180° text, and [up]/[down]
/// are the two sideways readings of a quarter-turned page.
enum _TextFlow {
  right,
  left,
  up,
  down;

  /// Whether the text runs along the box's long (vertical) axis.
  bool get isSideways => this == up || this == down;
}
