import 'package:flutter/material.dart';

import '../../app/app_scope.dart';
import '../../app/app_theme.dart';
import '../data/file_picker_pdf_source.dart';
import '../data/pdfx_page_renderer.dart';
import '../data/searchable_pdf_converter.dart';
import '../domain/pdf_exception.dart';
import '../domain/pdf_source_service.dart';
import 'searchable_pdf_preview_screen.dart';

/// The way in: choose a scan, then the document itself takes over (see
/// [SearchablePdfPreviewScreen]).
///
/// One screen, one decision. There is nothing to configure here — no language
/// picker, no options — because the only choices that matter are which file, and
/// then whether its preview looks like the document the user expects.
class SearchablePdfScreen extends StatefulWidget {
  const SearchablePdfScreen({
    super.key,
    this.source,
    this.converter,
    this.previewBuilder,
  });

  /// Injectable so tests never open the platform document picker.
  final PdfSourceService? source;

  /// Handed to the preview screen; built from the app's OCR service when
  /// omitted.
  final SearchablePdfConverter? converter;

  /// Injectable so a test can drive the hand-off without a native PDF engine.
  final Widget Function(BuildContext context, String path)? previewBuilder;

  @override
  State<SearchablePdfScreen> createState() => _SearchablePdfScreenState();
}

class _SearchablePdfScreenState extends State<SearchablePdfScreen> {
  late final PdfSourceService _source =
      widget.source ?? const FilePickerPdfSource();

  String? _error;
  bool _busy = false;

  Future<void> _choose() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final path = await _source.pickPdf();
      if (!mounted) return;
      if (path == null) return; // cancelled: not an error
      final builder = widget.previewBuilder;
      await Navigator.of(context).push<void>(
        MaterialPageRoute<void>(
          builder: (context) =>
              builder?.call(context, path) ??
              SearchablePdfPreviewScreen(
                path: path,
                converter: _converter(context),
              ),
        ),
      );
    } on PdfException catch (error) {
      if (!mounted) return;
      setState(() => _error = error.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  SearchablePdfConverter _converter(BuildContext context) =>
      widget.converter ??
      SearchablePdfConverter(
        renderer: PdfxPageRenderer(),
        ocr: AppScope.of(context).ocrService,
      );

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      backgroundColor: AppColors.page,
      appBar: AppBar(
        title: const Text('Make Searchable PDF'),
        backgroundColor: AppColors.page,
        surfaceTintColor: Colors.transparent,
      ),
      body: SafeArea(
        top: false,
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(AppSpacing.xxl),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 88,
                  height: 88,
                  decoration: const BoxDecoration(
                    color: AppColors.tile,
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(
                    Icons.manage_search_outlined,
                    size: 40,
                    color: AppColors.primary,
                  ),
                ),
                const SizedBox(height: AppSpacing.xl),
                Text(
                  'Choose a PDF to make searchable',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.titleLarge?.copyWith(
                    color: AppColors.ink,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: AppSpacing.sm),
                Text(
                  'Every page is read on this device and gets an invisible text '
                  'layer. The pages look exactly the same — and become '
                  'searchable and copyable.',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: AppColors.muted,
                    height: 1.4,
                  ),
                ),
                const SizedBox(height: AppSpacing.xxl),
                FilledButton.icon(
                  onPressed: _busy ? null : _choose,
                  icon: const Icon(Icons.upload_file_outlined, size: 20),
                  label: const Text('Choose PDF'),
                  style: FilledButton.styleFrom(
                    backgroundColor: AppColors.primary,
                    minimumSize: const Size(220, 52),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14),
                    ),
                  ),
                ),
                if (_error != null) ...[
                  const SizedBox(height: AppSpacing.lg),
                  Text(
                    _error!,
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.error,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
