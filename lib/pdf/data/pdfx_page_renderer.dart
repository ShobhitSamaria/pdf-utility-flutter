import 'dart:io';
import 'dart:typed_data';

import 'package:pdfx/pdfx.dart' as pdfx;

import '../domain/pdf_document_info.dart';
import '../domain/pdf_exception.dart';
import '../domain/pdf_output_directory.dart';
import '../domain/pdf_page_raster.dart';
import '../domain/pdf_page_renderer.dart';
import '../domain/rendered_pdf_page.dart';
import 'native_pdf_output_directory.dart';

/// On-device [PdfPageRenderer] backed by PDFium (through `pdfx`).
///
/// The whole job happens locally: native PDFium rasterises the page, the PNG is
/// written into the app's cache directory, and the OCR engine reads that file.
/// No conversion service, no upload, no network at all.
///
/// Two details matter and are handled here rather than in the UI:
/// * **The background is forced white.** PDFx renders PNGs with a transparent
///   background by default; a transparent sheet is not what a page looks like,
///   and text recognition does better on the opaque page a reader would see.
/// * **Pages are closed after each render.** Android allows only one page to be
///   rendered at a time per document, so the page handle is released in a
///   `finally` — otherwise the next page in the document fails to open.
///
/// This is the ONLY file that imports `pdfx`; the rest of the app talks to
/// [PdfPageRenderer].
class PdfxPageRenderer implements PdfPageRenderer {
  PdfxPageRenderer({
    PdfPageRaster Function(double pageWidth, double pageHeight)? rasterFor,
    PdfOutputDirectory? outputDirectory,
  }) : _rasterFor =
           rasterFor ??
           ((pageWidth, pageHeight) => PdfPageRaster.forPage(
             pageWidth: pageWidth,
             pageHeight: pageHeight,
           )),
       _outputDirectory = outputDirectory ?? const NativePdfOutputDirectory();

  /// How a page of a given size in points becomes a pixel size. Injectable so
  /// resolution decisions can be tested without a device.
  final PdfPageRaster Function(double pageWidth, double pageHeight) _rasterFor;

  /// Where the rasterised pages are written. Defaults to the platform's own
  /// cache directory, obtained from the app's native channel — not
  /// `Directory.systemTemp`, which on Android resolves to a path the app cannot
  /// write to and would fail every "read text from this PDF page" with a
  /// storage error.
  final PdfOutputDirectory _outputDirectory;

  pdfx.PdfDocument? _document;
  PdfDocumentInfo? _info;

  @override
  String get engineName => 'PDFium (pdfx, on device)';

  @override
  Future<PdfDocumentInfo> open(String path) async {
    await close();

    if (!File(path).existsSync()) {
      throw const PdfException(
        PdfErrorKind.unreadable,
        'That file is no longer available. Please choose it again.',
      );
    }

    try {
      final document = await pdfx.PdfDocument.openFile(path);
      if (document.pagesCount <= 0) {
        await document.close();
        throw const PdfException(
          PdfErrorKind.unreadable,
          'That PDF has no pages to read.',
        );
      }
      _document = document;
      _info = PdfDocumentInfo(
        path: path,
        title: fileNameOf(path),
        pageCount: document.pagesCount,
      );
      return _info!;
    } catch (error) {
      throw PdfException.from(error);
    }
  }

  @override
  Future<RenderedPdfPage> renderPage(int pageNumber) async {
    final document = _document;
    final info = _info;
    if (document == null || info == null) {
      throw const PdfException(
        PdfErrorKind.unreadable,
        'No PDF is open. Please choose one again.',
      );
    }
    if (!info.hasPage(pageNumber)) {
      throw PdfException(
        PdfErrorKind.renderFailure,
        'This PDF has no page $pageNumber.',
      );
    }

    final stopwatch = Stopwatch()..start();
    pdfx.PdfPage? page;
    try {
      page = await document.getPage(pageNumber);
      final raster = _rasterFor(page.width, page.height);

      final image = await page.render(
        width: raster.width.toDouble(),
        height: raster.height.toDouble(),
        format: pdfx.PdfPageImageFormat.png,
        // A page is a white sheet, and OCR reads an opaque page better than a
        // transparent one. See the class docs.
        backgroundColor: '#FFFFFF',
      );
      if (image == null || image.bytes.isEmpty) {
        throw const PdfException(
          PdfErrorKind.renderFailure,
          'That page came back empty. Please try another page.',
        );
      }

      stopwatch.stop();
      return RenderedPdfPage(
        pageNumber: pageNumber,
        imagePath: await _writePagePng(image.bytes, pageNumber),
        width: image.width ?? raster.width,
        height: image.height ?? raster.height,
        elapsed: stopwatch.elapsed,
      );
    } catch (error) {
      throw PdfException.from(error);
    } finally {
      // Android renders one page at a time per document: release this one
      // whatever happened, or the next page cannot be rendered.
      await page?.close();
    }
  }

  @override
  Future<void> close() async {
    final document = _document;
    _document = null;
    _info = null;
    if (document == null) return;
    try {
      await document.close();
    } catch (_) {
      // Tearing down a session must never be the thing that fails a screen.
    }
  }

  /// Writes the rendered page into the app's cache directory.
  ///
  /// The name is unique per render, so re-reading a page never overwrites the
  /// file a result screen is still pointing at, and the directory is the
  /// operating system's to reclaim when space is needed.
  Future<String> _writePagePng(Uint8List bytes, int pageNumber) async {
    final directory = Directory(
      '${await _outputDirectory.resolve()}/pdf_pages',
    );
    await directory.create(recursive: true);
    final file = File(
      '${directory.path}/page_${pageNumber}_'
      '${DateTime.now().microsecondsSinceEpoch}.png',
    );
    await file.writeAsBytes(bytes, flush: true);
    return file.path;
  }

  /// The file name part of a path, which is what a user recognises.
  static String fileNameOf(String path) {
    final separator = path.lastIndexOf(RegExp(r'[\\/]'));
    return separator < 0 ? path : path.substring(separator + 1);
  }
}
