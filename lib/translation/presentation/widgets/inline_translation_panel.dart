import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../app/app_theme.dart';
import '../../domain/translation_exception.dart';
import '../translation_controller.dart';
import '../translation_ui_state.dart';
import 'language_selector.dart';

/// The **inline** translation section of the OCR result screen.
///
/// It sits directly under the photo, so translating never leaves the image the
/// text came from. One compact card holds the whole job:
///
/// * `From` / `To` selectors and a swap control,
/// * one clear **Translate** action,
/// * the result — or the loading/error state — right underneath.
///
/// It draws only what the screen's [TranslationController] holds, so the same
/// result feeds the on-photo overlay and this panel; there is never a second
/// answer to the same request. The overlay stays **optional**: the switch only
/// appears once there is something to draw.
///
/// Failure handling is deliberately recoverable rather than apologetic. A
/// detection failure says which control to use and does not offer a pointless
/// retry of the same automatic request; the user picks a source, and the screen
/// immediately runs the translation with that explicit choice.
class InlineTranslationPanel extends StatelessWidget {
  const InlineTranslationPanel({
    super.key,
    required this.controller,
    required this.hasSourceText,
    required this.showOnPhoto,
    required this.onTranslate,
    required this.onShowOnPhotoChanged,
    required this.onLanguagesChanged,
    required this.onClose,
    this.onCopy,
  });

  final TranslationController controller;

  /// Whether the recognised page has any translatable text at all.
  final bool hasSourceText;

  /// Whether the translated regions are drawn over the photo.
  final bool showOnPhoto;

  /// Runs the translation for the current scope.
  final VoidCallback onTranslate;

  final ValueChanged<bool> onShowOnPhotoChanged;

  /// A language changed; the screen hides any overlay from the old pair.
  final VoidCallback onLanguagesChanged;

  /// Collapses the section (the photo gets the space back).
  final VoidCallback onClose;

  /// Overrides the clipboard write (used by tests).
  final void Function(String text)? onCopy;

  bool get _hasOverlay => controller.overlay != null;

  bool get _canSwap {
    final source = controller.source;
    return source.isConcrete &&
        source.code != controller.target.code &&
        !controller.isBusy;
  }

  bool get _canTranslate =>
      hasSourceText &&
      !controller.isBusy &&
      !controller.detectingSource &&
      controller.source.code != controller.target.code;

  void _copy(BuildContext context, String text) {
    final onCopy = this.onCopy;
    if (onCopy != null) {
      onCopy(text);
    } else {
      unawaited(Clipboard.setData(ClipboardData(text: text)));
    }
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('Translation copied')));
  }

  void _swap() {
    final source = controller.source;
    final target = controller.target;
    if (!source.isConcrete || source.code == target.code) return;
    // Order matters: selectSource clears the shown state, so the target is set
    // second and the pair is consistent by the time the screen reacts.
    controller.selectTarget(source);
    controller.selectSource(target);
    onLanguagesChanged();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) => Material(
        color: theme.colorScheme.surface,
        child: DecoratedBox(
          decoration: BoxDecoration(
            border: Border(
              top: BorderSide(color: theme.colorScheme.outlineVariant),
            ),
          ),
          child: SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(
                AppSpacing.md,
                AppSpacing.sm,
                AppSpacing.md,
                AppSpacing.sm,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _LanguageRow(
                    controller: controller,
                    canSwap: _canSwap,
                    onSwap: _swap,
                    onLanguagesChanged: onLanguagesChanged,
                    onClose: onClose,
                    onTranslate: onTranslate,
                  ),
                  const SizedBox(height: AppSpacing.sm),
                  _ActionRow(
                    canTranslate: _canTranslate,
                    showOnPhoto: showOnPhoto && _hasOverlay,
                    hasOverlay: _hasOverlay,
                    onTranslate: onTranslate,
                    onShowOnPhotoChanged: onShowOnPhotoChanged,
                  ),
                  _Status(
                    controller: controller,
                    hasSourceText: hasSourceText,
                    onCopy: (text) => _copy(context, text),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// `From [Auto-detect] ⇄ To [English]`, with a close affordance.
class _LanguageRow extends StatelessWidget {
  const _LanguageRow({
    required this.controller,
    required this.canSwap,
    required this.onSwap,
    required this.onLanguagesChanged,
    required this.onClose,
    required this.onTranslate,
  });

  final TranslationController controller;
  final bool canSwap;
  final VoidCallback onSwap;
  final VoidCallback onLanguagesChanged;
  final VoidCallback onClose;
  final VoidCallback onTranslate;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: LanguageSelector(
            caption: 'From',
            value: controller.source,
            options: controller.sourceOptions,
            enabled: !controller.isBusy,
            expanded: true,
            onSelected: (language) {
              // Picking a language after a detection failure *is* the retry:
              // the failed state is cleared by the screen, and the explicit
              // choice runs immediately instead of asking for a second tap.
              final state = controller.state;
              final wasDetectionFailure =
                  state is TranslationFailure &&
                  state.kind == TranslationErrorKind.detectionFailed;
              controller.selectSource(language);
              onLanguagesChanged();
              if (wasDetectionFailure && !language.isAuto) onTranslate();
            },
          ),
        ),
        IconButton(
          tooltip: 'Swap languages',
          visualDensity: VisualDensity.compact,
          onPressed: canSwap ? onSwap : null,
          icon: const Icon(Icons.swap_horiz, size: 20),
        ),
        Expanded(
          child: LanguageSelector(
            caption: 'To',
            value: controller.target,
            options: controller.targetOptions,
            enabled: !controller.isBusy,
            expanded: true,
            onSelected: (language) {
              controller.selectTarget(language);
              onLanguagesChanged();
            },
          ),
        ),
        IconButton(
          tooltip: 'Close translation',
          visualDensity: VisualDensity.compact,
          onPressed: onClose,
          icon: const Icon(Icons.close, size: 20),
        ),
      ],
    );
  }
}

/// The Translate action, plus the optional on-photo switch.
///
/// The action is [Expanded] rather than loose in the row because the app theme
/// gives `FilledButton` a full-width minimum ([Size.fromHeight]), and a loose
/// button in a `Row` is handed an unbounded width — which makes layout throw.
class _ActionRow extends StatelessWidget {
  const _ActionRow({
    required this.canTranslate,
    required this.showOnPhoto,
    required this.hasOverlay,
    required this.onTranslate,
    required this.onShowOnPhotoChanged,
  });

  final bool canTranslate;
  final bool showOnPhoto;
  final bool hasOverlay;
  final VoidCallback onTranslate;
  final ValueChanged<bool> onShowOnPhotoChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Row(
      children: [
        Expanded(
          child: FilledButton.icon(
            onPressed: canTranslate ? onTranslate : null,
            icon: const Icon(Icons.translate, size: 18),
            label: const Text('Translate'),
          ),
        ),
        if (hasOverlay)
          InkWell(
            borderRadius: BorderRadius.circular(AppRadii.cardTile),
            onTap: () => onShowOnPhotoChanged(!showOnPhoto),
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: AppSpacing.sm,
                vertical: AppSpacing.xs,
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    showOnPhoto
                        ? Icons.visibility_outlined
                        : Icons.visibility_off_outlined,
                    size: 16,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: 4),
                  Text('On photo', style: theme.textTheme.labelSmall),
                  const SizedBox(width: 2),
                  Switch.adaptive(
                    value: showOnPhoto,
                    onChanged: onShowOnPhotoChanged,
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }
}

/// Idle / detecting / working / done / failed, in the panel itself.
class _Status extends StatelessWidget {
  const _Status({
    required this.controller,
    required this.hasSourceText,
    required this.onCopy,
  });

  final TranslationController controller;
  final bool hasSourceText;
  final void Function(String text) onCopy;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final state = controller.state;

    if (!hasSourceText) {
      return _line(
        theme,
        'No text was recognised on this page, so there is nothing to translate.',
      );
    }

    return switch (state) {
      TranslationIdle() =>
        controller.detectingSource
            ? Padding(
                padding: const EdgeInsets.only(top: AppSpacing.sm),
                child: Row(
                  children: [
                    const SizedBox(
                      width: 12,
                      height: 12,
                      child: CircularProgressIndicator(strokeWidth: 1.6),
                    ),
                    const SizedBox(width: AppSpacing.sm),
                    Text(
                      'Detecting language…',
                      style: theme.textTheme.bodySmall,
                    ),
                  ],
                ),
              )
            : controller.source.code == controller.target.code
            ? _line(theme, 'Choose two different languages to translate.')
            : const SizedBox.shrink(),
      TranslationInProgress(:final message, :final progress) => Padding(
        padding: const EdgeInsets.only(top: AppSpacing.sm),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
                const SizedBox(width: AppSpacing.sm),
                Expanded(
                  child: Text(message, style: theme.textTheme.bodySmall),
                ),
              ],
            ),
            const SizedBox(height: 6),
            LinearProgressIndicator(
              value: progress,
              minHeight: 3,
              borderRadius: BorderRadius.circular(2),
            ),
          ],
        ),
      ),
      TranslationSuccess(:final result) => Padding(
        padding: const EdgeInsets.only(top: AppSpacing.sm),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    result.alreadyInTargetLanguage
                        ? 'Already in ${result.targetLanguage.englishName}'
                        : '${result.sourceLanguage.englishName} → '
                              '${result.targetLanguage.englishName}',
                    style: theme.textTheme.labelSmall,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                IconButton(
                  tooltip: 'Copy translation',
                  visualDensity: VisualDensity.compact,
                  onPressed: () => onCopy(result.translatedText),
                  icon: const Icon(Icons.copy_outlined, size: 18),
                ),
              ],
            ),
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 148),
              child: SingleChildScrollView(
                child: SelectableText(
                  result.translatedText,
                  style: theme.textTheme.bodyLarge?.copyWith(height: 1.4),
                ),
              ),
            ),
          ],
        ),
      ),
      TranslationFailure(:final message, :final retryable, :final kind) =>
        Padding(
          padding: const EdgeInsets.only(top: AppSpacing.sm),
          child: Container(
            padding: const EdgeInsets.all(AppSpacing.sm),
            decoration: BoxDecoration(
              color: theme.colorScheme.errorContainer.withValues(alpha: 0.35),
              borderRadius: BorderRadius.circular(AppRadii.cardTile),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(
                      Icons.error_outline,
                      size: 18,
                      color: theme.colorScheme.error,
                    ),
                    const SizedBox(width: AppSpacing.sm),
                    Expanded(
                      child: Text(message, style: theme.textTheme.bodySmall),
                    ),
                  ],
                ),
                if (kind == TranslationErrorKind.detectionFailed)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(
                      'Choose the source language above — translating starts '
                      'again as soon as you pick one.',
                      style: theme.textTheme.labelSmall,
                    ),
                  )
                else if (retryable)
                  Align(
                    alignment: AlignmentDirectional.centerEnd,
                    child: TextButton.icon(
                      onPressed: controller.retry,
                      icon: const Icon(Icons.refresh, size: 16),
                      label: const Text('Try again'),
                    ),
                  ),
              ],
            ),
          ),
        ),
    };
  }

  Widget _line(ThemeData theme, String text) => Padding(
    padding: const EdgeInsets.only(top: AppSpacing.sm),
    child: Text(text, style: theme.textTheme.bodySmall),
  );
}
