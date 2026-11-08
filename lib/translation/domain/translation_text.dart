/// Pure text helpers shared by the translation layer.
///
/// Kept deliberately framework- and engine-agnostic so the rules about *what*
/// gets sent to the translator are unit-testable without any platform channel.
abstract final class TranslationText {
  static final RegExp _inlineWhitespace = RegExp(r'[ \t]+');
  static final RegExp _excessBlankLines = RegExp(r'\n{3,}');

  /// Whether [text] contains something worth translating.
  ///
  /// Deliberately *only* whitespace is rejected: a block that holds nothing but a
  /// danda (`।`), an ornament or a page-edge mark is still kept and still
  /// translated, so no recognized character is ever discarded by this layer. It
  /// draws a small pill of its own, which is the visible cost of not losing text.
  static bool isTranslatable(String? text) =>
      text != null && text.trim().isNotEmpty;

  /// Cleans up text for the translator without changing its meaning:
  ///
  /// * trims the ends,
  /// * collapses runs of spaces/tabs inside a line,
  /// * trims each line,
  /// * collapses 3+ consecutive newlines down to a blank line.
  ///
  /// Line breaks are preserved because OCR pages carry meaningful structure
  /// (paragraph and block breaks) that improves translation quality.
  static String normalize(String text) {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return '';
    final lines = trimmed
        .split('\n')
        .map((line) => line.replaceAll(_inlineWhitespace, ' ').trim())
        .join('\n');
    return lines.replaceAll(_excessBlankLines, '\n\n');
  }

  /// Joins [segments] into one block of text, dropping empty/whitespace-only
  /// entries.
  ///
  /// This is the "whole page" aggregation helper: pass the OCR page's lines
  /// (or a selection's words) and get back a single, engine-ready string.
  static String aggregate(
    Iterable<String> segments, {
    String separator = '\n',
  }) {
    final parts = <String>[];
    for (final segment in segments) {
      final trimmed = segment.trim();
      if (trimmed.isEmpty) continue;
      parts.add(trimmed);
    }
    return parts.join(separator);
  }
}
