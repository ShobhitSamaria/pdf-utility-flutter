import 'package:flutter/material.dart';

import '../../domain/translation_language.dart';

/// Compact inline language picker used by the translation panel.
///
/// Extensible by construction: it renders whatever options it is handed, so
/// adding languages is a registry change (`TranslationLanguages`), not a UI
/// change.
class LanguageSelector extends StatelessWidget {
  const LanguageSelector({
    super.key,
    required this.caption,
    required this.value,
    required this.options,
    required this.onSelected,
    this.enabled = true,
    this.expanded = false,
  });

  /// Short label shown before the dropdown, e.g. `'From'`.
  final String caption;

  /// Currently selected language.
  final TranslationLanguage value;

  /// Selectable languages.
  final List<TranslationLanguage> options;

  final ValueChanged<TranslationLanguage> onSelected;

  final bool enabled;

  /// Whether the dropdown may take the full width it is given.
  ///
  /// `false` (the default) keeps the selector its natural size, which is what a
  /// compact bar wants. `true` is for a selector placed inside an `Expanded`:
  /// the dropdown then fills that space and its label **ellipsizes** instead of
  /// overflowing, which matters because a language name can be long
  /// (`Bahasa Indonesia`) and the phone is narrow.
  final bool expanded;

  /// Longest form of a language's display name, so the dropdown does not ask
  /// for more room than its own label needs.
  static const int _maxLabelLines = 1;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    if (options.isEmpty) return const SizedBox.shrink();

    // Defensive: never crash if the value falls outside the offered options.
    final selected = options.firstWhere(
      (language) => language.code == value.code,
      orElse: () => options.first,
    );

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(caption, style: theme.textTheme.labelSmall),
        const SizedBox(width: 6),
        Flexible(
          child: DropdownButton<TranslationLanguage>(
            value: selected,
            isDense: true,
            isExpanded: expanded,
            borderRadius: BorderRadius.circular(12),
            style: theme.textTheme.labelLarge,
            underline: const SizedBox.shrink(),
            onChanged: enabled
                ? (language) {
                    if (language != null) onSelected(language);
                  }
                : null,
            items: [
              for (final language in options)
                DropdownMenuItem<TranslationLanguage>(
                  value: language,
                  child: Text(
                    language.label,
                    maxLines: _maxLabelLines,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}
