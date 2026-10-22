import 'dart:io';
import 'dart:typed_data';

// `package:pdf` exports a `PdfException` of its own, which describes a failure
// inside the encoder. This app's [PdfException] is the one the UI speaks, and
// hiding the package's keeps the two from being confused at every use site.
import 'package:pdf/pdf.dart' hide PdfException;
import 'package:pdf/widgets.dart' as pw;

import '../domain/pdf_creation.dart';
import '../domain/pdf_exception.dart';
import '../domain/pdf_output_directory.dart';
import '../domain/pdf_page_layout.dart';

/// [PdfCreationService] backed by the pure-Dart `pdf` package.
///
/// Why a library rather than a hand-written PDF emitter
/// ---------------------------------------------------
/// The bytes of a PDF (cross-reference table, object offsets, image filters) are
/// exactly the kind of thing that looks finished long before it is: a file that
/// opens in one viewer and not another, or a page count that is right until the
/// seventeenth page. `pdf` is pure Dart — no native code, no platform channels,
/// no Gradle surprises — and it writes a document that standard viewers open, so
/// the risky part is somebody else's well-tested code.
///
/// What this class adds on top is the app's own decisions:
/// * **Order is the document.** Pages are embedded in the order given, always.
/// * **Shape is preserved.** Each page takes its image's aspect ratio, fitted to
///   A4's longest edge ([PdfPageLayout]) — no squashing, no cropping, no bands.
/// * **Memory stays bounded.** Images are handed over one at a time and the
///   document is written to disk, rather than holding every page's pixels in
///   memory at once, which matters for a dozen phone photos.
/// * **Nothing is claimed that did not happen.** The [CreatedPdf] is only
///   returned after the bytes are on disk, with the real size read back.
///
/// This is the ONLY file that imports `pdf`; the rest of the app talks to
/// [PdfCreationService].
class PdfLibraryCreationService implements PdfCreationService {
  const PdfLibraryCreationService({
    this.directoryName = 'created_pdfs',
    this.outputDirectory = const SystemTempPdfOutputDirectory(),
  });

  /// Sub-directory of the app's cache directory the exports are written to.
  ///
  /// The cache is deliberate: the file is a hand-off, and the operating system
  /// is allowed to reclaim it. A copy the user wants to keep goes to Downloads
  /// or another app through the export path.
  final String directoryName;

  /// Where the file is written. The composition root injects the platform's
  /// cache directory; tests and the verification script point it at a temporary
  /// directory they control (see `PdfOutputDirectory`).
  final PdfOutputDirectory outputDirectory;

  @override
  String get engineName => 'pdf (pure Dart, on device)';

  @override
  Future<CreatedPdf> create({
    required List<String> pageImagePaths,
    String fileName = PdfCreationService.defaultFileName,
    void Function(int completed, int total)? onProgress,
  }) async {
    if (pageImagePaths.isEmpty) {
      throw const PdfException(
        PdfErrorKind.noPages,
        'Add at least one page before creating a PDF.',
      );
    }

    final name = sanitizePdfFileName(fileName);
    final stopwatch = Stopwatch()..start();
    final document = pw.Document(title: name, creator: 'PDF Utility');

    for (var index = 0; index < pageImagePaths.length; index++) {
      final bytes = await _readPage(pageImagePaths[index], index);
      document.addPage(
        pw.Page(
          pageFormat: _formatFor(bytes),
          // Full bleed: the page is the picture.
          margin: pw.EdgeInsets.zero,
          build: (context) =>
              pw.Image(pw.MemoryImage(bytes), fit: pw.BoxFit.contain),
        ),
      );
      onProgress?.call(index + 1, pageImagePaths.length);
    }

    final Uint8List encoded;
    try {
      // `enableEventLoopBalancing` yields between objects so a long document does
      // not freeze the UI while it is being encoded.
      encoded = await document.save(enableEventLoopBalancing: true);
    } catch (error) {
      throw PdfException(
        PdfErrorKind.writeFailure,
        'The PDF could not be prepared. Please try again.',
        cause: error,
      );
    }

    try {
      // Resolved fresh for each document rather than cached: the platform can
      // hand out a different cache path after an app update, and a stale
      // directory would turn every export into a write failure.
      final directory = Directory(
        '${await outputDirectory.resolve()}/$directoryName',
      );
      await directory.create(recursive: true);
      final output = File('${directory.path}/$name');
      await output.writeAsBytes(encoded, flush: true);
      stopwatch.stop();

      return CreatedPdf(
        path: output.path,
        fileName: name,
        pageCount: pageImagePaths.length,
        byteSize: encoded.length,
        elapsed: stopwatch.elapsed,
      );
    } catch (error) {
      throw PdfException(
        PdfErrorKind.writeFailure,
        'The PDF could not be saved on this device. Check the available storage '
        'and try again.',
        cause: error,
      );
    }
  }

  /// Reads one page image, translating a missing or empty file into a message
  /// that names the page the user would recognise.
  Future<Uint8List> _readPage(String path, int index) async {
    final Uint8List bytes;
    try {
      bytes = await File(path).readAsBytes();
    } catch (error) {
      throw PdfException(
        PdfErrorKind.unreadable,
        'Page ${index + 1} is no longer available. Please add it again.',
        cause: error,
      );
    }

    if (bytes.isEmpty) {
      throw PdfException(
        PdfErrorKind.unreadable,
        'Page ${index + 1} could not be read. Please add it again.',
      );
    }

    return bytes;
  }

  /// The page size for an image, read from its **header** rather than by
  /// decoding it: `MemoryImage` reports the pixel dimensions (honouring EXIF
  /// orientation, so a portrait photo does not become a landscape page) after
  /// reading a few dozen bytes.
  PdfPageFormat _formatFor(Uint8List bytes) {
    int? width;
    int? height;
    try {
      final image = pw.MemoryImage(bytes);
      width = image.width;
      height = image.height;
    } catch (_) {
      // An unreadable header is not fatal here: `MemoryImage` will fail with a
      // clear error when the page is built, and until then A4 is a safe page.
      width = null;
      height = null;
    }

    final size = PdfPageLayout.forPixels(width ?? 0, height ?? 0);
    return PdfPageFormat(size.width, size.height);
  }
}
