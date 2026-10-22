/// What is known about an opened PDF, before anything is rendered.
///
/// Deliberately tiny: the UI needs to name the document and know how many pages
/// there are, and nothing else about the file has any business in the widget
/// layer.
class PdfDocumentInfo {
  const PdfDocumentInfo({
    required this.path,
    required this.title,
    required this.pageCount,
  });

  /// Absolute path of the PDF on disk, as the platform picker reported it.
  final String path;

  /// Display name — the file name, never the whole path.
  final String title;

  /// Number of pages. Always at least 1 for a successfully opened document.
  final int pageCount;

  /// Whether the page number is inside the document (numbers are 1-based).
  bool hasPage(int pageNumber) => pageNumber >= 1 && pageNumber <= pageCount;

  /// `1 page` / `12 pages`.
  String get pageCountLabel => pageCount == 1 ? '1 page' : '$pageCount pages';

  @override
  String toString() => 'PdfDocumentInfo("$title", $pageCount pages, $path)';
}
