/// What went wrong with a PDF import, page render, or **creation**.
///
/// A cancelled picker is deliberately **not** here: cancelling is a normal
/// outcome, not a failure, so [PdfSourceService.pickPdf] answers `null` for it
/// and the screen simply stays where it was.
enum PdfErrorKind {
  /// The file could not be opened as a PDF at all: not a PDF, truncated, or
  /// locked with a password. Also covers a page image that has gone missing or
  /// cannot be decoded while creating a PDF.
  unreadable,

  /// No pages were supplied, so there is no document to produce.
  noPages,

  /// The pages were fine but the document could not be encoded or written:
  /// storage full, no permission to the destination, or an encoder failure.
  writeFailure,

  /// Opening or rasterising never answered within the app's budget.
  ///
  /// A large page on a slow device is real work, so this is generous — its job
  /// is to end an eternal spinner, not to rush the renderer.
  timeout,

  /// The document opened but a page could not be turned into an image
  /// (native failure, or not enough memory for the requested resolution).
  renderFailure,
}

/// A PDF failure that can be shown to the user.
///
/// Carries a message written for a person plus the underlying error, following
/// the same shape as `OcrException` so both features report failures the same
/// way.
class PdfException implements Exception {
  const PdfException(this.kind, this.message, {this.cause});

  final PdfErrorKind kind;

  /// User-facing explanation. Never raw platform noise.
  final String message;

  /// The original error/exception, kept for diagnostics.
  final Object? cause;

  /// Wraps an arbitrary error from the PDF stack into a [PdfException].
  ///
  /// Already-classified errors pass through unchanged, so a specific message
  /// raised deep in this feature is never replaced by a generic one.
  static PdfException from(Object error) {
    if (error is PdfException) return error;

    final raw = error.toString();
    final normalised = raw.toLowerCase();

    if (normalised.contains('password') || normalised.contains('encrypted')) {
      return PdfException(
        PdfErrorKind.unreadable,
        'This PDF is password protected. Unlock it first, then import it.',
        cause: error,
      );
    }

    if (normalised.contains('timeout') || normalised.contains('timed out')) {
      return PdfException(
        PdfErrorKind.timeout,
        'Opening that page took too long. Please try again.',
        cause: error,
      );
    }

    final looksCorrupt =
        normalised.contains('invalid') ||
        normalised.contains('corrupt') ||
        normalised.contains('format') ||
        normalised.contains('not a pdf') ||
        normalised.contains('open failed') ||
        normalised.contains('no such file');

    if (looksCorrupt) {
      return PdfException(
        PdfErrorKind.unreadable,
        'That file could not be opened. It may be damaged or not a PDF.',
        cause: error,
      );
    }

    if (normalised.contains('space left') ||
        normalised.contains('enospc') ||
        normalised.contains('permission')) {
      return PdfException(
        PdfErrorKind.writeFailure,
        'There was not enough space (or permission) to save the PDF. Free some '
        'space and try again.',
        cause: error,
      );
    }

    return PdfException(
      PdfErrorKind.renderFailure,
      'That page could not be prepared for reading. Please try another page.',
      cause: error,
    );
  }

  @override
  String toString() => message;
}
