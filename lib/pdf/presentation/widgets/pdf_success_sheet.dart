import 'dart:async';

import 'package:flutter/material.dart';

import '../../../app/app_theme.dart';
import '../../data/pdf_file_exporter.dart';
import '../../domain/pdf_creation.dart';

/// What happened to a PDF that has just been written.
///
/// The sheet resolves to this **only when the user is finished**: a successful
/// *Save a copy*. Dismissing the sheet, or sharing instead, resolves to `null`
/// and leaves the user on the review screen, where the other action still is.
class PdfSuccessResult {
  const PdfSuccessResult({required this.savedTo});

  /// Where the copy actually landed, as the platform described it —
  /// `Downloads/Trip.pdf`. Read from the export that succeeded, never assumed.
  final String savedTo;
}

/// What the user can do with a PDF that has just been created.
///
/// Every fact on this sheet comes from the [CreatedPdf] the writer returned —
/// the name, the page count and the size are read back from the file that was
/// actually produced, not from what the screen intended to produce. That is the
/// point of the type: "success" here cannot be claimed for a document that was
/// never written.
///
/// Two ways out, and both report honestly:
/// * [share] opens the system share sheet (send, print, save to Drive, …);
/// * [saveToDownloads] writes a copy the user can find again and **finishes the
///   flow**: the sheet closes and the review screen goes Home. There is no
///   second "Done" to tap, because saving already was the last decision.
///
/// A failure of either never closes the sheet or claims success — it shows a
/// concise message and leaves the file in place so the other action can still be
/// used. In particular, Home is never reached before the copy exists on disk.
class PdfSuccessSheet extends StatefulWidget {
  const PdfSuccessSheet({super.key, required this.pdf, this.exporter});

  final CreatedPdf pdf;

  /// Injectable so tests can drive both outcomes without a platform.
  final PdfFileExporter? exporter;

  /// Opens the sheet.
  ///
  /// Resolves to a [PdfSuccessResult] when a copy was saved (so the caller can
  /// go Home), and to `null` when the user shared or dismissed it.
  static Future<PdfSuccessResult?> show(
    BuildContext context, {
    required CreatedPdf pdf,
    PdfFileExporter? exporter,
  }) {
    return showModalBottomSheet<PdfSuccessResult>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      isDismissible: true,
      builder: (_) => PdfSuccessSheet(pdf: pdf, exporter: exporter),
    );
  }

  @override
  State<PdfSuccessSheet> createState() => _PdfSuccessSheetState();
}

class _PdfSuccessSheetState extends State<PdfSuccessSheet> {
  late final PdfFileExporter _exporter =
      widget.exporter ?? const PdfFileExporter();

  bool _busy = false;

  Future<void> _share() async {
    if (_busy) return;
    setState(() => _busy = true);
    final shown = await _exporter.share(widget.pdf);
    if (!mounted) return;
    setState(() => _busy = false);
    if (!shown) {
      _say('No app on this device could open the share sheet.');
    }
  }

  /// Writes the copy, then finishes the flow.
  ///
  /// Order matters: the sheet is only closed **after** the platform reported
  /// where the file landed. A failed save keeps the sheet open with the file
  /// still in place, so the user can retry or share instead.
  Future<void> _save() async {
    if (_busy) return;
    setState(() => _busy = true);

    final location = await _exporter.saveToDownloads(widget.pdf);
    if (!mounted) return;

    if (location == null) {
      setState(() => _busy = false);
      _say(
        'Could not save a copy. Check the free space on this device and try '
        'again, or use Share.',
      );
      return;
    }

    Navigator.of(context).pop(PdfSuccessResult(savedTo: location));
  }

  void _say(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final pdf = widget.pdf;

    return PopScope(
      // No drag-to-dismiss and no back press while the copy is being written:
      // the user could otherwise leave mid-save and start a second one.
      canPop: !_busy,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.xl,
            AppSpacing.xs,
            AppSpacing.xl,
            AppSpacing.xl,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    width: 44,
                    height: 44,
                    decoration: BoxDecoration(
                      color: AppColors.tile,
                      borderRadius: BorderRadius.circular(AppRadii.cardTile),
                    ),
                    child: const Icon(
                      Icons.check_circle_outline,
                      color: AppColors.primary,
                    ),
                  ),
                  const SizedBox(width: AppSpacing.md),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text('PDF created', style: theme.textTheme.titleMedium),
                        const SizedBox(height: 2),
                        Text(
                          pdf.summaryLabel,
                          style: theme.textTheme.bodySmall,
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: AppSpacing.lg),
              Text(
                pdf.fileName,
                style: theme.textTheme.titleSmall,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              if (pdf.elapsed != null) ...[
                const SizedBox(height: 2),
                Text(
                  'Written in '
                  '${(pdf.elapsed!.inMilliseconds / 1000).toStringAsFixed(1)} s',
                  style: theme.textTheme.labelSmall,
                ),
              ],
              const SizedBox(height: AppSpacing.xl),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: _busy ? null : () => unawaited(_share()),
                      icon: const Icon(Icons.ios_share, size: 18),
                      label: const Text('Share'),
                    ),
                  ),
                  const SizedBox(width: AppSpacing.sm),
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: _busy ? null : () => unawaited(_save()),
                      icon: _busy
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Colors.white,
                              ),
                            )
                          : const Icon(Icons.download_outlined, size: 18),
                      label: Text(_busy ? 'Saving…' : 'Save a copy'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
