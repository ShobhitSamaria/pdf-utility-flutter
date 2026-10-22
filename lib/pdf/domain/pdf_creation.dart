/// A PDF the app has just written to disk.
///
/// [path] is a real file the platform can share; [byteSize] and [pageCount] are
/// carried so the UI can state what was produced instead of just claiming
/// success.
class CreatedPdf {
  const CreatedPdf({
    required this.path,
    required this.fileName,
    required this.pageCount,
    required this.byteSize,
    this.elapsed,
  });

  /// Absolute path of the written file.
  final String path;

  /// File name including the `.pdf` extension, as shown to the user.
  final String fileName;

  /// How many pages the document has.
  final int pageCount;

  /// Size of the file in bytes.
  final int byteSize;

  /// How long creation took, when measured.
  final Duration? elapsed;

  /// `832 bytes` / `1.2 MB` — one short line for a success message.
  String get byteSizeLabel {
    if (byteSize < 1024) return '$byteSize bytes';
    final kb = byteSize / 1024;
    if (kb < 1024) return '${kb.toStringAsFixed(0)} KB';
    return '${(kb / 1024).toStringAsFixed(1)} MB';
  }

  /// `1 page` / `7 pages`.
  String get pageCountLabel => pageCount == 1 ? '1 page' : '$pageCount pages';

  /// `7 pages · 1.2 MB`.
  String get summaryLabel => '$pageCountLabel · $byteSizeLabel';

  @override
  String toString() => 'CreatedPdf($fileName, $summaryLabel, $path)';
}

/// Builds a PDF from a list of page images.
///
/// The sibling of `PdfPageRenderer`, which runs the other way: that one turns a
/// PDF into images for OCR, this one turns images into a PDF. Both are
/// interfaces so no screen imports a PDF package, and the engine is chosen in
/// one place.
abstract class PdfCreationService {
  /// Human-readable name of the underlying engine (diagnostics/logging).
  String get engineName;

  /// Writes a PDF containing [pageImagePaths], **in the order given** — the
  /// order is the document, so it is never sorted or de-duplicated here.
  ///
  /// [fileName] is the user's chosen name; it is passed through
  /// [sanitizePdfFileName] before it reaches the filesystem, so an unusable name
  /// becomes a safe one instead of failing the export.
  ///
  /// [onProgress] reports `(completed, total)` after each page is embedded, which
  /// is the slow part on a phone.
  ///
  /// Throws `PdfException` when there is nothing to write, when a page image
  /// cannot be read, or when the document cannot be written.
  Future<CreatedPdf> create({
    required List<String> pageImagePaths,
    String fileName = defaultFileName,
    void Function(int completed, int total)? onProgress,
  });

  /// The name used when the user has not chosen one.
  static const String defaultFileName = 'document.pdf';
}

/// Turns arbitrary user input into a file name that is safe to write.
///
/// Never throws and never returns an empty name: a blank or unusable entry
/// becomes [PdfCreationService.defaultFileName]. Directory separators, control
/// characters and the reserved Windows set are removed rather than rejected, so
/// typing `my/holiday: photos` still produces a usable export instead of an
/// error the user cannot act on.
///
/// The extension is appended exactly once. `report`, `report.pdf`, `report.PDF`
/// and `report.pdf.pdf` all become `report.pdf` — a duplicated extension is a
/// typo, not a file called `report.pdf.pdf`.
String sanitizePdfFileName(String raw) {
  final stem = pdfFileNameStem(raw);
  return stem.isEmpty ? PdfCreationService.defaultFileName : '$stem.pdf';
}

/// Whether [raw] names a document that can actually be written.
///
/// Used to keep **Create PDF** disabled until the user has typed something
/// usable. A field holding spaces, slashes or only `.pdf` is empty for every
/// practical purpose, so it does not count as a name.
bool isUsablePdfFileName(String raw) => pdfFileNameStem(raw).isNotEmpty;

/// The sanitised name **without** its `.pdf` extension, or `''` when nothing
/// usable is left.
///
/// Kept separate from [sanitizePdfFileName] because "is there a name here?" and
/// "what file do we write?" are different questions: the first must be able to
/// say *no*, while the writer always needs a name and therefore falls back to
/// `document.pdf`.
String pdfFileNameStem(String raw) {
  var name = raw.trim();

  // Keep the last path segment if someone pasted a path. This is a name, not a
  // destination, so nothing may escape the export directory.
  final lastSeparator = name.lastIndexOf(RegExp(r'[/\\]'));
  if (lastSeparator >= 0) name = name.substring(lastSeparator + 1);

  // Drop characters no common filesystem accepts, and collapse whitespace.
  name = name.replaceAll(RegExp(r'[\x00-\x1f\x7f<>:"|?*]'), ' ');
  name = name.replaceAll(RegExp(r'\s+'), ' ').trim();

  // A trailing dot is not part of a name (and confuses Windows), so remove
  // those first; otherwise `report.pdf.` would slip past the extension strip
  // below and become `report.pdf.pdf`.
  name = name.replaceAll(RegExp(r'\.+$'), '').trim();

  // Strip any number of `.pdf` suffixes, case-insensitively. A name that is
  // only an extension (`.pdf`, `pdf.pdf`) has no stem and is therefore not a
  // name at all.
  while (name.toLowerCase().endsWith('.pdf')) {
    name = name.substring(0, name.length - 4);
    name = name.replaceAll(RegExp(r'\s+'), ' ').trim();
    name = name.replaceAll(RegExp(r'\.+$'), '').trim();
  }

  // A leading dot would hide the file.
  name = name.replaceAll(RegExp(r'^\.+'), '').trim();

  // Keep names a filesystem (and the share sheet) can display: 76 characters
  // plus `.pdf` stays inside the 80-character budget this app has always used.
  const maxStemLength = 76;
  if (name.length > maxStemLength) {
    name = name.substring(0, maxStemLength).trimRight();
    name = name.replaceAll(RegExp(r'\.+$'), '').trimRight();
  }

  return name;
}
