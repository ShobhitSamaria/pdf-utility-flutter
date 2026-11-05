import 'dart:io';

import 'package:flutter/material.dart';
import 'package:pdfx/pdfx.dart' as pdfx;

import '../../app/app_scope.dart';
import '../../app/app_theme.dart';
import '../data/pdf_file_exporter.dart';
import '../data/pdfx_page_renderer.dart';
import '../data/searchable_pdf_converter.dart';
import '../domain/pdf_creation.dart';
import '../domain/pdf_exception.dart';
import 'searchable_pdf_viewer_screen.dart';

/// Runs the conversion. A seam, so a widget test can drive every state of this
/// screen without PDFium, ML Kit or a real encoder.
typedef SearchablePdfRunner =
    Future<CreatedPdf> Function({
      required String inputPath,
      void Function(int completed, int total)? onProgress,
    });

/// The document surface, as a seam — the same shape `PdfViewerScreen` uses, so
/// the screen's own decisions are testable and the only untested part is the
/// package's page rendering.
typedef SearchablePdfSurface =
    Widget Function(
      BuildContext context, {
      required ValueChanged<int> onLoaded,
      required ValueChanged<int> onPageChanged,
    });

/// The document, then the button. Nothing else.
///
/// Layout
/// ------
/// * A compact header names the file and says what it is — pages and size — in
///   one muted line, so the document itself is the thing that fills the screen.
/// * The page view is `pdfx`'s own scrolling view, vertical, which rasterises
///   only the pages around the viewport: a 200-page scan costs the same memory
///   as a two-page one. Pages keep their own aspect ratio; the neutral page
///   colour behind them is what makes a white sheet read as paper.
/// * One sticky action at the bottom. While it runs, that same strip becomes the
///   progress readout, so the percentage appears exactly where the finger
///   already is instead of in a popup. When it finishes, the strip becomes the
///   hand-off: the new file's name, its size, Save and Share.
///
/// A floating chip reports the page you are on (`Page 3 of 9`), which is the one
/// piece of chrome worth keeping over a document preview.
class SearchablePdfPreviewScreen extends StatefulWidget {
  const SearchablePdfPreviewScreen({
    super.key,
    required this.path,
    this.converter,
    this.exporter,
    this.convert,
    this.surface,
    this.onConverted,
  });

  /// Absolute path of the selected PDF.
  final String path;

  /// Built from the app's OCR service when omitted.
  final SearchablePdfConverter? converter;

  /// Injectable so tests never reach the native share channel.
  final PdfFileExporter? exporter;

  /// Injectable runner; defaults to [converter]'s own `convert`.
  final SearchablePdfRunner? convert;

  /// Injectable document surface, so the screen's states can be tested without
  /// a native PDF engine (see `PdfViewerScreen`'s identical seam).
  final SearchablePdfSurface? surface;

  /// Where the finished file is handed over. Defaults to opening it in the
  /// searchable viewer, which is the point: the user can search what was made
  /// before deciding whether to save it. Tests inject a no-op so the success
  /// state can be inspected on its own.
  final void Function(BuildContext context, CreatedPdf pdf)? onConverted;

  @override
  State<SearchablePdfPreviewScreen> createState() =>
      _SearchablePdfPreviewScreenState();
}

class _SearchablePdfPreviewScreenState
    extends State<SearchablePdfPreviewScreen> {
  late final PdfFileExporter _exporter =
      widget.exporter ?? const PdfFileExporter();

  SearchablePdfConverter? _converter;
  SearchablePdfRunner? _run;

  int _pageCount = 0;
  int _currentPage = 1;
  int? _byteSize;

  bool _busy = false;
  int _completed = 0;
  int _total = 0;
  CreatedPdf? _result;
  String? _error;

  String get _fileName {
    final separator = widget.path.lastIndexOf(RegExp(r'[\\/]'));
    return separator < 0 ? widget.path : widget.path.substring(separator + 1);
  }

  double get _fraction => _total <= 0 ? 0 : _completed / _total;

  @override
  void initState() {
    super.initState();
    _readFileSize();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_run != null) return;
    if (widget.convert != null) {
      _run = widget.convert;
      return;
    }
    _converter ??=
        widget.converter ??
        SearchablePdfConverter(
          renderer: PdfxPageRenderer(),
          ocr: AppScope.of(context).ocrService,
        );
    _run = _converter!.convert;
  }

  void _onLoaded(int count) {
    if (!mounted) return;
    setState(() => _pageCount = count);
  }

  void _onPage(int page) {
    if (!mounted) return;
    setState(() => _currentPage = page);
  }

  Future<void> _readFileSize() async {
    try {
      final size = await File(widget.path).length();
      if (!mounted) return;
      setState(() => _byteSize = size);
    } catch (_) {
      // Not knowing the size is not a failure: the header simply omits it.
    }
  }

  Future<void> _convert() async {
    // A second tap while the first run is in flight would OCR the whole
    // document twice and race two writers at the same output name.
    if (_busy) return;
    final run = _run;
    if (run == null) return;

    setState(() {
      _busy = true;
      _error = null;
      _result = null;
      _completed = 0;
      _total = _pageCount;
    });

    try {
      final pdf = await run(
        inputPath: widget.path,
        onProgress: (completed, total) {
          if (!mounted) return;
          setState(() {
            _completed = completed;
            _total = total;
          });
        },
      );
      if (!mounted) return;
      setState(() => _result = pdf);

      // Straight into the document. Save and Share live there (and on the
      // success state behind it), so nothing has to be saved to be searched.
      final onConverted = widget.onConverted;
      if (onConverted != null) {
        onConverted(context, pdf);
      } else {
        await Navigator.of(context).push<void>(
          MaterialPageRoute<void>(
            builder: (_) => SearchablePdfViewerScreen(
              path: pdf.path,
              title: pdf.fileName,
              exporter: _exporter,
            ),
          ),
        );
      }
    } on PdfException catch (error) {
      if (!mounted) return;
      setState(() => _error = error.message);
    } catch (_) {
      if (!mounted) return;
      setState(
        () =>
            _error = 'This PDF could not be made searchable. Please try again.',
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _save() async {
    final pdf = _result;
    if (pdf == null) return;
    final location = await _exporter.saveToDownloads(pdf);
    if (!mounted) return;
    _say(
      location == null
          ? 'Could not save the PDF to this device.'
          : 'Saved to $location',
    );
  }

  Future<void> _share() async {
    final pdf = _result;
    if (pdf == null) return;
    final shown = await _exporter.share(pdf);
    if (!mounted) return;
    if (!shown) _say('No app on this device can receive the PDF.');
  }

  void _say(String message) => ScaffoldMessenger.of(
    context,
  ).showSnackBar(SnackBar(content: Text(message)));

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final result = _result;

    return Scaffold(
      backgroundColor: AppColors.page,
      appBar: AppBar(
        // "Preview", not the action's name: the button already says what the
        // screen is for, and a title that repeated it made the header read as
        // two identical commands.
        title: const Text('Preview'),
        backgroundColor: AppColors.page,
        surfaceTintColor: Colors.transparent,
      ),
      body: SafeArea(
        top: false,
        child: Column(
          children: [
            _DocumentHeader(
              fileName: _fileName,
              pageCount: _pageCount,
              byteSize: _byteSize,
            ),
            Expanded(
              child: result != null && !_busy
                  ? _SuccessView(result: result, onSave: _save, onShare: _share)
                  : Stack(
                      children: [
                        Positioned.fill(
                          child: ColoredBox(
                            // The paper needs a surface behind it that is not
                            // the page's own white, or the sheet's edges vanish.
                            color: const Color(0xFFEFF0F6),
                            child:
                                widget.surface?.call(
                                  context,
                                  onLoaded: _onLoaded,
                                  onPageChanged: _onPage,
                                ) ??
                                _PdfSurface(
                                  path: widget.path,
                                  onLoaded: _onLoaded,
                                  onPageChanged: _onPage,
                                ),
                          ),
                        ),
                        if (_pageCount > 0 && result == null)
                          Positioned(
                            top: AppSpacing.md,
                            right: AppSpacing.md,
                            child: _PageChip(
                              page: _currentPage,
                              pageCount: _pageCount,
                            ),
                          ),
                        if (_busy)
                          // Dimmed, not hidden: the document stays the subject
                          // while the text layer is being written.
                          const Positioned.fill(
                            child: IgnorePointer(
                              child: ColoredBox(color: Color(0x33000000)),
                            ),
                          ),
                      ],
                    ),
            ),
            // Once there is a result, the hand-off owns the screen: a second,
            // disabled bar underneath it would only be furniture.
            if (result == null)
              _ActionBar(
                busy: _busy,
                completed: _completed,
                total: _total,
                fraction: _fraction,
                error: _error,
                onConvert: _run == null ? null : _convert,
                style: theme.textTheme,
              ),
          ],
        ),
      ),
    );
  }
}

/// `Report.pdf` and, underneath, `9 pages · 1.6 MB`.
class _DocumentHeader extends StatelessWidget {
  const _DocumentHeader({
    required this.fileName,
    required this.pageCount,
    required this.byteSize,
  });

  final String fileName;
  final int pageCount;
  final int? byteSize;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final parts = <String>[
      if (pageCount > 0) pageCount == 1 ? '1 page' : '$pageCount pages',
      if (byteSize != null) _sizeLabel(byteSize!),
    ];

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.xl,
        AppSpacing.sm,
        AppSpacing.xl,
        AppSpacing.md,
      ),
      color: AppColors.page,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            fileName,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.titleMedium?.copyWith(
              color: AppColors.ink,
              fontWeight: FontWeight.w600,
            ),
          ),
          if (parts.isNotEmpty) ...[
            const SizedBox(height: 2),
            Text(
              parts.join('  ·  '),
              style: theme.textTheme.bodySmall?.copyWith(
                color: AppColors.muted,
              ),
            ),
          ],
        ],
      ),
    );
  }

  static String _sizeLabel(int bytes) {
    if (bytes < 1024) return '$bytes B';
    final kb = bytes / 1024;
    if (kb < 1024) return '${kb.toStringAsFixed(0)} KB';
    return '${(kb / 1024).toStringAsFixed(1)} MB';
  }
}

/// `Page 3 of 9`, floating over the paper.
class _PageChip extends StatelessWidget {
  const _PageChip({required this.page, required this.pageCount});

  final int page;
  final int pageCount;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: AppColors.ink.withValues(alpha: 0.72),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        child: Text(
          'Page $page of $pageCount',
          style: Theme.of(
            context,
          ).textTheme.labelSmall?.copyWith(color: Colors.white),
        ),
      ),
    );
  }
}

/// The single bottom strip: call to action, then progress, then hand-off.
class _ActionBar extends StatelessWidget {
  const _ActionBar({
    required this.busy,
    required this.completed,
    required this.total,
    required this.fraction,
    required this.error,
    required this.onConvert,
    required this.style,
  });

  final bool busy;
  final int completed;
  final int total;
  final double fraction;
  final String? error;
  final VoidCallback? onConvert;
  final TextTheme style;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return Material(
      color: AppColors.surface,
      elevation: 12,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.xl,
            AppSpacing.md,
            AppSpacing.xl,
            AppSpacing.md,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (error != null) ...[
                Row(
                  children: [
                    Icon(Icons.error_outline, size: 18, color: scheme.error),
                    const SizedBox(width: AppSpacing.sm),
                    Expanded(
                      child: Text(
                        error!,
                        style: style.bodySmall?.copyWith(color: scheme.error),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: AppSpacing.md),
              ],
              if (busy)
                _ProgressBlock(
                  completed: completed,
                  total: total,
                  fraction: fraction,
                )
              else ...[
                FilledButton(
                  onPressed: onConvert,
                  style: FilledButton.styleFrom(
                    backgroundColor: AppColors.primary,
                    minimumSize: const Size.fromHeight(52),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14),
                    ),
                  ),
                  child: const Text('Make Searchable PDF'),
                ),
                const SizedBox(height: AppSpacing.sm),
                Text(
                  'Adds an invisible text layer · recognised on this device',
                  textAlign: TextAlign.center,
                  style: style.bodySmall?.copyWith(color: AppColors.muted),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// `64%` and `Processing page 6 of 9`, with the bar between them.
class _ProgressBlock extends StatelessWidget {
  const _ProgressBlock({
    required this.completed,
    required this.total,
    required this.fraction,
  });

  final int completed;
  final int total;
  final double fraction;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final percent = (fraction * 100).round();

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Text(
              // Page 1 is being read before any page has finished, so the count
              // starts at 1 rather than claiming "page 0".
              total > 0
                  ? 'Processing page ${completed < 1 ? 1 : completed} of $total'
                  : 'Preparing…',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: AppColors.ink,
                fontWeight: FontWeight.w600,
              ),
            ),
            const Spacer(),
            Text(
              '$percent%',
              style: theme.textTheme.titleMedium?.copyWith(
                color: AppColors.primary,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
        const SizedBox(height: AppSpacing.sm),
        ClipRRect(
          borderRadius: BorderRadius.circular(3),
          child: LinearProgressIndicator(
            value: total > 0 ? fraction : null,
            minHeight: 6,
            backgroundColor: AppColors.tile,
            valueColor: const AlwaysStoppedAnimation<Color>(AppColors.primary),
          ),
        ),
        const SizedBox(height: AppSpacing.sm),
        Text(
          'Keep this screen open until it finishes.',
          style: theme.textTheme.bodySmall?.copyWith(color: AppColors.muted),
        ),
      ],
    );
  }
}

/// What you get: the new file's name and size, Save, Share.
class _SuccessView extends StatelessWidget {
  const _SuccessView({
    required this.result,
    required this.onSave,
    required this.onShare,
  });

  final CreatedPdf result;
  final VoidCallback onSave;
  final VoidCallback onShare;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(AppSpacing.xxl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 72,
              height: 72,
              decoration: const BoxDecoration(
                color: AppColors.tile,
                shape: BoxShape.circle,
              ),
              child: const Icon(
                Icons.check_rounded,
                size: 36,
                color: AppColors.primary,
              ),
            ),
            const SizedBox(height: AppSpacing.xl),
            Text(
              'Searchable PDF ready',
              textAlign: TextAlign.center,
              style: theme.textTheme.titleLarge?.copyWith(
                color: AppColors.ink,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: AppSpacing.sm),
            Text(
              result.fileName,
              textAlign: TextAlign.center,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodyMedium?.copyWith(color: AppColors.ink),
            ),
            const SizedBox(height: 2),
            Text(
              result.summaryLabel,
              style: theme.textTheme.bodySmall?.copyWith(
                color: AppColors.muted,
              ),
            ),
            const SizedBox(height: AppSpacing.xxl),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: onSave,
                    icon: const Icon(Icons.download_outlined, size: 18),
                    label: const Text('Save PDF'),
                    style: OutlinedButton.styleFrom(
                      minimumSize: const Size.fromHeight(48),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: AppSpacing.md),
                Expanded(
                  child: FilledButton.icon(
                    onPressed: onShare,
                    icon: const Icon(Icons.share_outlined, size: 18),
                    label: const Text('Share PDF'),
                    style: FilledButton.styleFrom(
                      backgroundColor: AppColors.primary,
                      minimumSize: const Size.fromHeight(48),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// Vertical, zoomable, lazily rasterised page view.
class _PdfSurface extends StatefulWidget {
  const _PdfSurface({
    required this.path,
    required this.onLoaded,
    required this.onPageChanged,
  });

  final String path;
  final ValueChanged<int> onLoaded;
  final ValueChanged<int> onPageChanged;

  @override
  State<_PdfSurface> createState() => _PdfSurfaceState();
}

class _PdfSurfaceState extends State<_PdfSurface> {
  late final pdfx.PdfController _controller = pdfx.PdfController(
    document: pdfx.PdfDocument.openFile(widget.path),
  );

  @override
  void initState() {
    super.initState();
    _controller.loadingState.addListener(_onLoadingState);
  }

  void _onLoadingState() {
    if (_controller.loadingState.value case pdfx.PdfLoadingState.success) {
      widget.onLoaded(_controller.pagesCount ?? 0);
    }
  }

  @override
  void dispose() {
    _controller.loadingState.removeListener(_onLoadingState);
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return pdfx.PdfView(
      controller: _controller,
      // Vertical reading, like a document — not a carousel of slides.
      scrollDirection: Axis.vertical,
      // Zoomed pages must not snap back mid-gesture on a phone.
      pageSnapping: false,
      onPageChanged: widget.onPageChanged,
      builders: pdfx.PdfViewBuilders<pdfx.DefaultBuilderOptions>(
        options: const pdfx.DefaultBuilderOptions(),
        documentLoaderBuilder: (context) =>
            const Center(child: CircularProgressIndicator()),
        pageLoaderBuilder: (context) => const Center(
          child: SizedBox(
            width: 22,
            height: 22,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
        errorBuilder: (context, error) =>
            const Center(child: Text('This document could not be displayed.')),
      ),
    );
  }
}
