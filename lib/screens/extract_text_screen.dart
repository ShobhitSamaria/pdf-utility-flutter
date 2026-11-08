import 'package:flutter/material.dart';

import '../app/app_theme.dart';

/// Where an OCR run starts from.
///
/// Returned by [ExtractTextScreen] to the caller, which owns the actual work:
/// the camera screen, the photo picker and the PDF import screen all already
/// exist, so this screen only answers "which one?".
enum ExtractTextSource { camera, gallery, importPdf }

/// The single question behind `OCR Scanner`: camera, gallery, or a PDF?
///
/// Deliberately a screen rather than a sheet: the three sources are the one
/// decision the main feature needs, and a full screen keeps them all visible
/// at any text scale without a modal stacked over Home.
class ExtractTextScreen extends StatelessWidget {
  const ExtractTextScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(title: const Text('OCR Scanner')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.xl,
            AppSpacing.lg,
            AppSpacing.xl,
            AppSpacing.xxl,
          ),
          children: [
            Text(
              'Choose a source',
              style: theme.textTheme.titleLarge?.copyWith(
                color: AppColors.ink,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: AppSpacing.xs),
            Text(
              'Scan a document, pick an image or open a PDF.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: AppColors.muted,
              ),
            ),
            const SizedBox(height: AppSpacing.xl),
            // Import PDF first and filled: reading a PDF is the primary way
            // into the app's text features, so it should not sit below the
            // two camera-roll options.
            _SourceTile(
              icon: Icons.upload_file_outlined,
              title: 'Import PDF',
              subtitle: 'Pick a PDF and select a page',
              primary: true,
              onTap: () =>
                  Navigator.of(context).pop(ExtractTextSource.importPdf),
            ),
            const SizedBox(height: AppSpacing.md),
            _SourceTile(
              icon: Icons.photo_camera_outlined,
              title: 'Camera',
              subtitle: 'Take a photo of a document',
              onTap: () => Navigator.of(context).pop(ExtractTextSource.camera),
            ),
            const SizedBox(height: AppSpacing.md),
            _SourceTile(
              icon: Icons.photo_library_outlined,
              title: 'Gallery',
              subtitle: 'Choose photos from your library',
              onTap: () => Navigator.of(context).pop(ExtractTextSource.gallery),
            ),
            const SizedBox(height: AppSpacing.xl),
            const _PrivacyNote(),
          ],
        ),
      ),
    );
  }
}

/// A short, honest reassurance under the three choices.
class _PrivacyNote extends StatelessWidget {
  const _PrivacyNote();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        const Icon(Icons.lock_outline, size: 15, color: AppColors.muted),
        const SizedBox(width: 6),
        Flexible(
          child: Text(
            'Your files stay on this device.',
            style: theme.textTheme.labelSmall,
          ),
        ),
      ],
    );
  }
}

/// One source: icon tile, title, explanation, chevron.
///
/// Same row rhythm as the app's action sheets, so the two surfaces read as one
/// design language rather than two.
class _SourceTile extends StatelessWidget {
  const _SourceTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
    this.primary = false,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  /// The filled brand treatment used for the one recommended source.
  final bool primary;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final foreground = primary ? Colors.white : null;
    final secondary = primary ? Colors.white70 : AppColors.muted;

    return Material(
      color: primary ? AppColors.primary : AppColors.rowTint,
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
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: primary ? Colors.white24 : AppColors.tile,
                  borderRadius: BorderRadius.circular(AppRadii.cardTile),
                ),
                child: Icon(
                  icon,
                  color: primary ? Colors.white : AppColors.primary,
                  size: 22,
                ),
              ),
              const SizedBox(width: AppSpacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      title,
                      style: theme.textTheme.titleSmall?.copyWith(
                        color: foreground,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: secondary,
                      ),
                    ),
                  ],
                ),
              ),
              Icon(
                Icons.chevron_right,
                color: primary ? Colors.white70 : AppColors.muted,
                size: 20,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
