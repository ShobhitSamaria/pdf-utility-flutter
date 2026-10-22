import 'dart:io';

import 'package:file_picker/file_picker.dart';

import '../domain/pdf_exception.dart';
import '../domain/pdf_source_service.dart';

/// [PdfSourceService] backed by the platform document picker via `file_picker`.
///
/// `FileType.custom` with a `pdf` extension list is what narrows the picker to
/// PDFs — and, just as importantly, on Android `file_picker` copies the chosen
/// document into the app's cache and hands back a real file path, so the
/// rasteriser can open it directly instead of the app requesting broad storage
/// access to read a `content://` URI itself.
///
/// This is the ONLY file that imports `file_picker`; the UI talks to
/// [PdfSourceService].
class FilePickerPdfSource implements PdfSourceService {
  const FilePickerPdfSource();

  @override
  Future<String?> pickPdf() async {
    final file = await FilePicker.pickFile(
      dialogTitle: 'Choose a PDF',
      type: FileType.custom,
      allowedExtensions: const <String>['pdf'],
    );

    // Cancelled: a normal outcome, not a failure.
    final path = file?.path;
    if (path == null) return null;

    if (!File(path).existsSync()) {
      throw const PdfException(
        PdfErrorKind.unreadable,
        'That file is no longer available. Please choose it again.',
      );
    }

    return path;
  }
}
