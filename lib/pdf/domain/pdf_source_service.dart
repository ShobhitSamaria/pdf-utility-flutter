/// Picks a PDF document from the device.
///
/// The sibling of the OCR feature's `ImageSourceService`: a single platform
/// call, wrapped so the UI depends on an interface instead of a plugin.
abstract class PdfSourceService {
  /// Opens the system document picker and returns the chosen PDF's file path,
  /// or `null` if the user cancelled.
  ///
  /// Modern Android routes this through the Storage Access Framework document
  /// picker, so no storage permission is required — the platform hands back a
  /// readable file and this app never asks for broad access to the user's files.
  Future<String?> pickPdf();
}
