import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../ocr/domain/ocr_result.dart';
import '../../ocr/domain/ocr_document_layout.dart';
import '../../ocr/domain/ocr_text_finder.dart';

/// The page as **text**: everything OCR read, in reading order, selectable,
/// copyable, and searchable.
///
/// Why this exists
/// ---------------
/// The photo with word geometry on it is the right surface for choosing which
/// words to copy, but it is a poor surface for *reading*: the text is drawn at
/// whatever size the photo happens to have, it may be sideways, and the
/// geometry is only as good as the recognition. This is the fallback the user
/// reaches for when the overlay is not enough — and it is deliberately
/// independent of translation, so it is available in every build.
///
/// Search here is **in-document search over the text**, distinct from the
/// find-on-photo search on the result screen. Where both are available it
/// offers *Show on photo*, which hands the current query back to the screen so
/// the matches are highlighted on the image itself.
///
/// Two shapes, one implementation
/// -----------------------------
/// * [ExtractedTextBody] is the content itself.
/// * [ExtractedTextView] is the bottom-sheet presentation of the same content
///   (it adds a height cap and closes itself after *Show on photo*).
///
/// Note which of the two is on a path today: the OCR result screen has no text
/// **tab**, so the sheet is the shipped surface — reached from the strip's
/// **Read text** action — and [ExtractedTextBody] has no caller of its own. There
/// is exactly one implementation behind both: one find field, one set of match
/// counters, one copy action in the codebase.
class ExtractedTextView extends StatelessWidget {
  const ExtractedTextView({
    super.key,
    required this.result,
    this.onSearchOnPhoto,
  });

  /// The recognition result to display.
  final OcrResult result;

  /// Called with the current query when the user asks to see the match on the
  /// photo. The sheet closes itself afterwards; the caller owns what that means.
  final ValueChanged<String>? onSearchOnPhoto;

  /// Opens this view as a bottom sheet.
  static Future<void> show(
    BuildContext context, {
    required OcrResult result,
    ValueChanged<String>? onSearchOnPhoto,
  }) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) =>
          ExtractedTextView(result: result, onSearchOnPhoto: onSearchOnPhoto),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ConstrainedBox(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.sizeOf(context).height * 0.72,
      ),
      child: ExtractedTextBody(
        result: result,
        onSearchOnPhoto: onSearchOnPhoto,
        closeAfterShowOnPhoto: true,
      ),
    );
  }
}

/// The readable text of a recognition result, with in-text search.
///
/// Works in a bounded box (the tab, the sheet) or standing alone: the line list
/// scrolls, the header and the actions do not.
class ExtractedTextBody extends StatefulWidget {
  const ExtractedTextBody({
    super.key,
    required this.result,
    this.onSearchOnPhoto,
    this.closeAfterShowOnPhoto = false,
  });

  /// The recognition result to display.
  final OcrResult result;

  /// Called with the current query when the user asks to see the match on the
  /// photo. When `null`, the action is not offered at all.
  final ValueChanged<String>? onSearchOnPhoto;

  /// Whether *Show on photo* should also close the surrounding route. `true` in
  /// the sheet (which has served its purpose), `false` in the result screen —
  /// popping there would close the result the user is looking at.
  final bool closeAfterShowOnPhoto;

  @override
  State<ExtractedTextBody> createState() => _ExtractedTextBodyState();
}

/// One match, resolved against the line it was found in.
class _ResolvedMatch {
  const _ResolvedMatch(this.lineIndex, this.match);

  final int lineIndex;
  final OcrTextMatch match;
}

class _ExtractedTextBodyState extends State<ExtractedTextBody> {
  static const _finder = OcrTextFinder();

  final TextEditingController _controller = TextEditingController();

  /// One key per *built* line, so the current match can be scrolled to exactly.
  final Map<int, GlobalKey> _lineKeys = <int, GlobalKey>{};

  List<_ResolvedMatch> _matches = const <_ResolvedMatch>[];
  int _current = 0;

  /// The page text split into display lines, in **reading order**.
  ///
  /// The order comes from [OcrDocumentLayout], not from the engine's block
  /// order: `fullText` and raw block order can list a right-hand column before
  /// the left one on a multi-column page. Falls back to splitting `fullText`,
  /// so a result that produced text but no structured lines still reads.
  late final List<String> _lines = _buildLines(widget.result);

  /// The whole page as text, with paragraph breaks, for copy-all.
  late final String _pageText = _buildPageText(widget.result, _lines);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  static List<String> _buildLines(OcrResult result) {
    final fromLayout = [
      for (final block in OcrDocumentLayout.blocks(result))
        for (final line in block.lines)
          if (line.text.trim().isNotEmpty) line.text,
    ];
    if (fromLayout.isNotEmpty) return fromLayout;
    return [
      for (final line in result.fullText.split('\n'))
        if (line.trim().isNotEmpty) line,
    ];
  }

  static String _buildPageText(OcrResult result, List<String> lines) {
    final paragraphs = [
      for (final block in OcrDocumentLayout.blocks(result))
        if (block.paragraph.trim().isNotEmpty) block.paragraph.trim(),
    ];
    if (paragraphs.isNotEmpty) return paragraphs.join('\n\n');
    if (result.fullText.trim().isNotEmpty) return result.fullText.trim();
    return lines.join('\n');
  }

  void _onQueryChanged(String query) {
    final matches = <_ResolvedMatch>[];
    for (var index = 0; index < _lines.length; index++) {
      for (final match in _finder.findIn(_lines[index], query)) {
        matches.add(_ResolvedMatch(index, match));
      }
    }
    setState(() {
      _matches = matches;
      _current = 0;
    });
    _scrollToCurrent();
  }

  /// Steps to the next/previous match, wrapping at both ends.
  void _step(int delta) {
    if (_matches.isEmpty) return;
    setState(() => _current = (_current + delta) % _matches.length);
    _scrollToCurrent();
  }

  void _scrollToCurrent() {
    if (_matches.isEmpty) return;
    final key = _lineKeys[_matches[_current].lineIndex];
    final context = key?.currentContext;
    if (context == null) return;
    // After the frame that renders the new highlight, so the scroll target has
    // real geometry.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final target = key?.currentContext;
      if (target == null) return;
      Scrollable.ensureVisible(
        target,
        alignment: 0.3,
        duration: const Duration(milliseconds: 180),
      );
    });
  }

  Future<void> _copyAll() async {
    final text = _pageText;
    if (text.trim().isEmpty) return;
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('Copied to clipboard')));
  }

  void _showOnPhoto() {
    final callback = widget.onSearchOnPhoto;
    if (callback == null || _controller.text.isEmpty) return;
    callback(_controller.text);
    if (widget.closeAfterShowOnPhoto) Navigator.of(context).maybePop();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hasText = _lines.isNotEmpty;

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
          child: Text('Extracted text', style: theme.textTheme.titleMedium),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: Text(
            '${widget.result.blocks.length} blocks • '
            '${widget.result.elements.length} words • '
            '${widget.result.sourceImage.width}×'
            '${widget.result.sourceImage.height}',
            style: theme.textTheme.bodySmall,
          ),
        ),
        if (hasText) _buildFindRow(theme),
        if (!hasText)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
            child: Text(
              'No text was extracted from this image.',
              style: theme.textTheme.bodyMedium,
            ),
          )
        else
          Flexible(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (var index = 0; index < _lines.length; index++)
                    Padding(
                      key: _lineKeys.putIfAbsent(index, GlobalKey.new),
                      padding: const EdgeInsets.only(bottom: 6),
                      child: _LineView(
                        text: _lines[index],
                        matches: _matchesFor(index),
                        activeMatch: _activeMatchIn(index),
                        style: theme.textTheme.bodyLarge?.copyWith(
                          height: 1.45,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
            child: Row(
              children: [
                TextButton.icon(
                  onPressed: hasText ? _copyAll : null,
                  icon: const Icon(Icons.copy_all_outlined, size: 18),
                  label: const Text('Copy all'),
                ),
                const Spacer(),
                if (widget.onSearchOnPhoto != null)
                  TextButton.icon(
                    onPressed: _controller.text.isEmpty ? null : _showOnPhoto,
                    icon: const Icon(Icons.image_search, size: 18),
                    label: const Text('Show on photo'),
                  ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildFindRow(ThemeData theme) {
    final hasQuery = _controller.text.isNotEmpty;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 4, 0),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: _controller,
              onChanged: _onQueryChanged,
              textInputAction: TextInputAction.search,
              decoration: const InputDecoration(
                isDense: true,
                border: InputBorder.none,
                hintText: 'Find in this text',
              ),
            ),
          ),
          const SizedBox(width: 8),
          Text(
            !hasQuery
                ? ''
                : (_matches.isEmpty
                      ? 'No matches'
                      : '${_current + 1} / ${_matches.length}'),
            style: theme.textTheme.labelMedium,
          ),
          IconButton(
            tooltip: 'Previous match',
            onPressed: _matches.isEmpty ? null : () => _step(-1),
            icon: const Icon(Icons.keyboard_arrow_up),
          ),
          IconButton(
            tooltip: 'Next match',
            onPressed: _matches.isEmpty ? null : () => _step(1),
            icon: const Icon(Icons.keyboard_arrow_down),
          ),
        ],
      ),
    );
  }

  /// Matches that fall inside line [index].
  List<OcrTextMatch> _matchesFor(int index) => [
    for (final resolved in _matches)
      if (resolved.lineIndex == index) resolved.match,
  ];

  /// The single match in line [index] that is currently selected, if any.
  OcrTextMatch? _activeMatchIn(int index) {
    if (_matches.isEmpty) return null;
    final active = _matches[_current];
    return active.lineIndex == index ? active.match : null;
  }
}

/// One line of extracted text, with search hits highlighted.
class _LineView extends StatelessWidget {
  const _LineView({
    required this.text,
    required this.matches,
    required this.activeMatch,
    this.style,
  });

  final String text;
  final List<OcrTextMatch> matches;
  final OcrTextMatch? activeMatch;
  final TextStyle? style;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    if (matches.isEmpty) {
      return SelectableText(text, style: style);
    }

    final spans = <InlineSpan>[];
    var cursor = 0;
    for (final match in matches) {
      if (match.start > cursor) {
        spans.add(TextSpan(text: text.substring(cursor, match.start)));
      }
      spans.add(
        TextSpan(
          text: text.substring(match.start, match.end),
          style: TextStyle(
            // The current hit is the one the arrows are on, so it is stronger
            // than the rest — same idea as find-in-page anywhere else.
            backgroundColor: match == activeMatch
                ? scheme.primary.withValues(alpha: 0.55)
                : scheme.primary.withValues(alpha: 0.22),
            fontWeight: match == activeMatch ? FontWeight.w600 : null,
          ),
        ),
      );
      cursor = match.end;
    }
    if (cursor < text.length) {
      spans.add(TextSpan(text: text.substring(cursor)));
    }

    return SelectableText.rich(TextSpan(style: style, children: spans));
  }
}
