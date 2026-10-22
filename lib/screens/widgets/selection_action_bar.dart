import 'package:flutter/material.dart';

/// Lens-style **expandable selection panel** shown while OCR text is selected.
///
/// Two states, one surface:
/// * **Collapsed** (default) — a compact bottom bar: a two-line truncated preview
///   of the selection plus Copy / Search / Share and the word count.
/// * **Expanded** — swipe the bar up (or tap its header) and it grows into a
///   bottom sheet showing the **complete** selected text, wrapped and scrollable,
///   with the same actions still within reach. Swipe down (or tap the header)
///   to collapse.
///
/// It deliberately contains no technical/debug information — only the user's own
/// text and the actions.
///
/// The actions flow in a [Wrap] rather than a fixed [Row] so all four of them
/// (Copy / Search / Share / Translate) still fit on a narrow phone instead of
/// overflowing.
class SelectionActionBar extends StatefulWidget {
  const SelectionActionBar({
    super.key,
    required this.selectedText,
    required this.wordCount,
    required this.onCopy,
    required this.onSearch,
    this.onShare,
    this.onTranslate,
    this.onClear,
  });

  /// The text that would be copied/searched/translated.
  final String selectedText;

  /// Number of selected words (shown as context).
  final int wordCount;

  final VoidCallback onCopy;
  final VoidCallback onSearch;

  /// Opens the platform share sheet for the selected text. The action is hidden
  /// entirely when this is `null` (nothing on the device can share).
  final VoidCallback? onShare;

  /// Opens the on-device translation for the selected text. May be omitted to
  /// render the action as disabled.
  final VoidCallback? onTranslate;

  final VoidCallback? onClear;

  @override
  State<SelectionActionBar> createState() => _SelectionActionBarState();
}

class _SelectionActionBarState extends State<SelectionActionBar> {
  bool _expanded = false;

  /// Accumulated vertical drag of the current gesture, in logical pixels.
  double _dragDy = 0;

  void _toggle() => setState(() => _expanded = !_expanded);

  void _onDragUpdate(DragUpdateDetails details) => _dragDy += details.delta.dy;

  void _onDragEnd(DragEndDetails details) {
    final velocity = details.primaryVelocity ?? 0;
    if (_dragDy < -24 || velocity < -320) {
      setState(() => _expanded = true);
    } else if (_dragDy > 24 || velocity > 320) {
      setState(() => _expanded = false);
    }
    _dragDy = 0;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Material(
      elevation: 8,
      color: theme.colorScheme.surface,
      borderRadius: const BorderRadius.vertical(top: Radius.circular(18)),
      clipBehavior: Clip.antiAlias,
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _PanelHeader(
              expanded: _expanded,
              wordCount: widget.wordCount,
              onToggle: _toggle,
              onDragUpdate: _onDragUpdate,
              onDragEnd: _onDragEnd,
              onClear: widget.onClear,
            ),
            AnimatedSize(
              duration: const Duration(milliseconds: 180),
              curve: Curves.easeOutCubic,
              alignment: Alignment.bottomCenter,
              child: _expanded
                  ? _ExpandedText(text: widget.selectedText)
                  : _CollapsedPreview(text: widget.selectedText),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
              child: Wrap(
                spacing: 8,
                runSpacing: 4,
                children: [
                  _ActionButton(
                    icon: Icons.copy_outlined,
                    label: 'Copy',
                    onPressed: widget.onCopy,
                  ),
                  _ActionButton(
                    icon: Icons.search,
                    label: 'Search',
                    onPressed: widget.onSearch,
                  ),
                  if (widget.onShare != null)
                    _ActionButton(
                      icon: Icons.share_outlined,
                      label: 'Share',
                      onPressed: widget.onShare,
                    ),
                  _ActionButton(
                    icon: Icons.translate_outlined,
                    label: 'Translate',
                    onPressed: widget.onTranslate,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Drag handle + one-line status. The whole strip is the swipe target, so the
/// panel can be expanded or collapsed with a single upward/downward gesture.
class _PanelHeader extends StatelessWidget {
  const _PanelHeader({
    required this.expanded,
    required this.wordCount,
    required this.onToggle,
    required this.onDragUpdate,
    required this.onDragEnd,
    required this.onClear,
  });

  final bool expanded;
  final int wordCount;
  final VoidCallback onToggle;
  final ValueChanged<DragUpdateDetails> onDragUpdate;
  final ValueChanged<DragEndDetails> onDragEnd;
  final VoidCallback? onClear;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onToggle,
      onVerticalDragUpdate: onDragUpdate,
      onVerticalDragEnd: onDragEnd,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 36,
              height: 4,
              decoration: BoxDecoration(
                color: theme.colorScheme.outlineVariant,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Icon(
                  expanded ? Icons.expand_more : Icons.expand_less,
                  size: 20,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    expanded
                        ? 'Selected text'
                        : '$wordCount word${wordCount == 1 ? '' : 's'} selected',
                    style: theme.textTheme.labelLarge,
                  ),
                ),
                if (onClear != null)
                  IconButton(
                    tooltip: 'Clear selection',
                    visualDensity: VisualDensity.compact,
                    onPressed: onClear,
                    icon: const Icon(Icons.close, size: 20),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// One/two-line truncated preview shown while collapsed.
class _CollapsedPreview extends StatelessWidget {
  const _CollapsedPreview({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 2, 16, 10),
      child: Text(
        text,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: Theme.of(context).textTheme.bodyMedium,
      ),
    );
  }
}

/// The complete selection, wrapped and scrollable, shown while expanded.
///
/// Selectable so the text can also be copied by hand, and capped at a fraction
/// of the screen so the photo stays visible behind it.
class _ExpandedText extends StatelessWidget {
  const _ExpandedText({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final maxHeight = MediaQuery.sizeOf(context).height * 0.42;

    return ConstrainedBox(
      constraints: BoxConstraints(maxHeight: maxHeight),
      child: Scrollbar(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 14),
          child: SelectableText(
            text,
            style: theme.textTheme.bodyLarge?.copyWith(height: 1.45),
          ),
        ),
      ),
    );
  }
}

class _ActionButton extends StatelessWidget {
  const _ActionButton({
    required this.icon,
    required this.label,
    required this.onPressed,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return TextButton.icon(
      onPressed: onPressed,
      icon: Icon(icon, size: 18),
      label: Text(label),
    );
  }
}
