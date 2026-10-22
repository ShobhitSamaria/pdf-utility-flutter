import 'pdf_document_info.dart';
import 'pdf_exception.dart';
import 'rendered_pdf_page.dart';

/// Turns a PDF file into page images this app's OCR can read.
///
/// This is the ONLY PDF type the UI layer references. It hides the rasteriser —
/// which library, which native engine, where the temporary file is written — so
/// screens never import a PDF package and swapping the engine is one line in
/// the import screen. The same split the OCR and translation features already
/// use.
///
/// A renderer instance is a **session** for one document: [open] first, then any
/// number of [renderPage] calls, then [close]. Rendering is intentionally
/// one-at-a-time with a caller-supplied size target, because a page rasterised
/// too small is unreadable to OCR and one rasterised too large can exhaust memory
/// on a phone.
abstract class PdfPageRenderer {
  /// Opens the document at [path] and reports its page count.
  ///
  /// Throws [PdfException] when the file cannot be opened — including the
  /// password-protected case, which is reported as such rather than as a
  /// generic failure.
  Future<PdfDocumentInfo> open(String path);

  /// Rasterises [pageNumber] (1-based) to an image file on disk.
  ///
  /// The returned file is deliberately left in place: the result screen re-runs
  /// OCR from that same path when the user picks another script, and the
  /// directory it lives in belongs to the operating system to reclaim.
  Future<RenderedPdfPage> renderPage(int pageNumber);

  /// Releases the open document. Safe to call when nothing is open, and safe to
  /// call twice.
  Future<void> close();

  /// Human-readable name of the underlying rasteriser (diagnostics/logging).
  String get engineName;
}
