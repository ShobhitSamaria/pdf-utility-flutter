import 'package:flutter/material.dart';

import '../../app/app_theme.dart';

/// One action offered by an [showAppActionSheet].
///
/// The sheet is generic over [T] so a caller can `switch` on a real enum value
/// instead of matching the label it just rendered — the string the user reads
/// and the branch the code takes cannot drift apart.
@immutable
class SheetAction<T> {
  const SheetAction({
    required this.value,
    required this.icon,
    required this.title,
    required this.subtitle,
    this.pending = false,
  });

  /// What the caller receives when this row is tapped.
  final T value;

  final IconData icon;

  /// Row title, e.g. `Extract Text (OCR)`.
  final String title;

  /// One line under the title, e.g. `Scan, copy and translate`.
  final String subtitle;

  /// `true` when the action is **not implemented yet**.
  ///
  /// The row is still shown, because the approved design shows it, but it is
  /// badged and its tap reports the truth rather than opening something that
  /// does nothing. See `HomeScreen` for the Phase-3 work these stand for.
  final bool pending;
}

/// The shared bottom sheet used by all three Home entry points.
///
/// One component for `Scan document`, `Choose image` and `Import PDF`
/// ([Figma `7:1423`, `7:1500`, `7:1577`]): the same rounded sheet, the same
/// close control, the same row rhythm — only the title and rows differ.
///
/// Returns the tapped action's [SheetAction.value], or `null` when the sheet is
/// dismissed. It deliberately does **not** run a callback itself: the caller
/// navigates after the sheet has closed, which avoids popping a route out from
/// under an in-flight navigation.
Future<T?> showAppActionSheet<T>({
  required BuildContext context,
  required String title,
  required List<SheetAction<T>> actions,
}) {
  assert(actions.isNotEmpty, 'A sheet with no actions has nothing to offer.');
  return showModalBottomSheet<T>(
    context: context,
    // The rows are comfortable tap targets at any text scale, and the sheet
    // grows to its content rather than being clipped.
    isScrollControlled: true,
    builder: (sheetContext) =>
        _AppActionSheet<T>(title: title, actions: actions),
  );
}

class _AppActionSheet<T> extends StatelessWidget {
  const _AppActionSheet({required this.title, required this.actions});

  final String title;
  final List<SheetAction<T>> actions;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return SafeArea(
      top: false,
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(
          AppSpacing.xl,
          AppSpacing.xs,
          AppSpacing.xl,
          AppSpacing.xxl,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(title, style: theme.textTheme.titleMedium),
                ),
                IconButton(
                  tooltip: 'Close',
                  onPressed: () => Navigator.of(context).pop(),
                  icon: const Icon(Icons.close, color: AppColors.muted),
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.md),
            for (final action in actions) ...[
              SheetActionTile<T>(
                action: action,
                onTap: () => Navigator.of(context).pop(action.value),
              ),
              const SizedBox(height: AppSpacing.md),
            ],
          ],
        ),
      ),
    );
  }
}

/// A single row in an action sheet: icon tile, title, one line of explanation,
/// and a chevron (or a `Coming soon` badge for an [SheetAction.pending] row).
///
/// Public so widget tests can assert the row itself rather than only its text.
class SheetActionTile<T> extends StatelessWidget {
  const SheetActionTile({super.key, required this.action, required this.onTap});

  final SheetAction<T> action;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Material(
      color: AppColors.rowTint,
      borderRadius: BorderRadius.circular(AppRadii.card),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(AppRadii.card),
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.lg,
            vertical: 14,
          ),
          child: Row(
            children: [
              Container(
                width: 42,
                height: 42,
                decoration: BoxDecoration(
                  color: AppColors.tile,
                  borderRadius: BorderRadius.circular(AppRadii.cardTile),
                ),
                child: Icon(action.icon, size: 21, color: AppColors.primary),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(action.title, style: theme.textTheme.titleSmall),
                    const SizedBox(height: 2),
                    Text(action.subtitle, style: theme.textTheme.bodySmall),
                  ],
                ),
              ),
              const SizedBox(width: AppSpacing.sm),
              if (action.pending)
                const _PendingBadge()
              else
                const Icon(
                  Icons.chevron_right,
                  size: 22,
                  color: AppColors.muted,
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Honest marker for a row whose feature is not built yet.
///
/// This exists so the app never offers a control that silently does nothing:
/// the row is part of the approved design, so it stays, but it says what it is.
class _PendingBadge extends StatelessWidget {
  const _PendingBadge();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: AppColors.hairline),
      ),
      child: const Text(
        'Coming soon',
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w600,
          color: AppColors.muted,
        ),
      ),
    );
  }
}
