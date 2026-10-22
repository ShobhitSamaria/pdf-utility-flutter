import 'package:flutter_test/flutter_test.dart';
import 'package:pdf_utility_flutter/pdf/domain/pdf_exception.dart';

void main() {
  test('a password-protected PDF says so, rather than failing generically', () {
    final error = PdfException.from(
      Exception('Failed to open document: password required'),
    );

    expect(error.kind, PdfErrorKind.unreadable);
    expect(error.message, contains('password protected'));
  });

  test('a damaged file is reported as unreadable', () {
    for (final raw in const [
      'InvalidPDFException: invalid pdf header',
      'FormatError: not a PDF',
      'Failed to open file: no such file or directory',
      'The document is corrupt',
    ]) {
      final error = PdfException.from(Exception(raw));
      expect(
        error.kind,
        PdfErrorKind.unreadable,
        reason: '"$raw" should read as unreadable',
      );
      expect(error.message, contains('could not be opened'));
    }
  });

  test('a stalled open is reported as a timeout, not a corrupt file', () {
    final error = PdfException.from(Exception('TimeoutException after 30s'));

    expect(error.kind, PdfErrorKind.timeout);
    expect(error.message, contains('took too long'));
  });

  test('anything else is a render failure with an actionable message', () {
    final error = PdfException.from(StateError('out of memory'));

    expect(error.kind, PdfErrorKind.renderFailure);
    expect(error.message, contains('try another page'));
  });

  test('an already-classified error passes through untouched', () {
    const original = PdfException(
      PdfErrorKind.unreadable,
      'That file could not be opened. It may be damaged or not a PDF.',
    );

    expect(PdfException.from(original), same(original));
  });

  test('the cause is kept for the debug details view', () {
    final cause = StateError('native renderer exploded');
    final error = PdfException.from(cause);

    expect(error.cause, same(cause));
  });

  test('the message is what the user sees', () {
    const error = PdfException(PdfErrorKind.unreadable, 'Something to read.');

    expect(error.toString(), 'Something to read.');
  });
}
