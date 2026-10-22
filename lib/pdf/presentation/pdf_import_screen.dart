import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../app/app_scope.dart';
import '../../ocr/presentation/ocr_failure_notice.dart';
import '../../screens/ocr_result_screen.dart';
import '../data/file_picker_pdf_source.dart';
import '../data/pdfx_page_renderer.dart';
import '../domain/pdf_document_info.dart';
import '../domain/pdf_exception.dart';
import '../domain/pdf_page_renderer.dart';
import '../domain/pdf_source_service.dart';
import '../domain/rendered_pdf_page.dart';

/// Pick a PDF, choose a page, read it with the same on-device OCR the photo
/// path uses.
///
/// Why a page has to be re-rendered instead of handed over as-is
/// ------------------------------------------------------------
/// A PDF is not an image: it is a description of marks on a page, usually at 72
/// dpi. Text recognition needs roughly an order of magnitude more pixels per line
/// than that to be reliable, so the page is rasterised at a resolution chosen for
/// reading (see [PdfPageRaster]) — locally, by PDFium, on the device.
///
/// What the user sees is therefore **the exact image that will be read**, not an
/// approximation of the page: the preview and the OCR call take the same file.
/// If a page looks too coarse or too light, that is a preview-time problem, not
/// something discovered after a failed read.
///
/// Nothing leaves the device at any point — no upload, no conversion service.
class PdfImportScreen extends StatefulWidget {
  const PdfImportScreen({super.key, this.source, this.renderer});

  /// Injectable so tests never open the platform document picker.
  final PdfSourceService? source;

  /// Injectable so tests never touch native PDFium.
  final PdfPageRenderer? renderer;

  @override
  State<PdfImportScreen> createState() => _PdfImportScreenState();
}

class _PdfImportScreenState extends State<PdfImportScreen> {
  late final PdfSourceService _source =
      widget.source ?? const FilePickerPdfSource();
  late final PdfPageRenderer _renderer = widget.renderer ?? PdfxPageRenderer();

  /// The open document, once one has been chosen.
  PdfDocumentInfo? _document;

  /// The page currently rendered and shown, which is also the page read.
  RenderedPdfPage? _page;

  /// Which page is being prepared, so the header can say so before the image
  /// behind it is replaced.
  int _pendingPageNumber = 0;

  bool _busy = false;
  String _busyLabel = '';
  PdfException? _error;

  /// Ticks while the renderer or the recognizer is working, so the wait reports
  /// how long the device has actually been busy instead of spinning anonymously.
  Timer? _ticker;
  Duration _elapsed = Duration.zero;
  static const Duration _tick = Duration(milliseconds: 200);

  @override
  void dispose() {
    _ticker?.cancel();
    // Releases the open PDF. Detached from the widget tree, so no state is set.
    unawaited(_renderer.close());
    super.dispose();
  }

  void _startBusy(String label) {
    _ticker?.cancel();
    _elapsed = Duration.zero;
    if (mounted) {
      setState(() {
        _busy = true;
        _busyLabel = label;
        _error = null;
      });
    }
    _ticker = Timer.periodic(_tick, (_) {
      if (!mounted) return;
      setState(() => _elapsed += _tick);
    });
  }

  void _stopBusy() {
    _ticker?.cancel();
    _ticker = null;
    if (mounted) setState(() => _busy = false);
  }

  void _fail(PdfException error) {
    _ticker?.cancel();
    _ticker = null;
    if (!mounted) return;
    setState(() {
      _busy = false;
      _error = error;
    });
  }

  // --- flow ------------------------------------------------------------------

  /// One tap from the picker to a readable page: choose, open, render page 1.
  Future<void> _choosePdf() async {
    if (_busy) return;
    setState(() => _error = null);

    try {
      final path = await _source.pickPdf();
      // Cancelled is a normal outcome: leave the screen exactly as it was.
      if (path == null || !mounted) return;
      await _open(path);
    } on PdfException catch (error) {
      _fail(error);
    } catch (error) {
      _fail(PdfException.from(error));
    }
  }

  Future<void> _open(String path) async {
    _startBusy('Opening PDF…');
    try {
      final document = await _renderer.open(path);
      if (!mounted) return;
      setState(() {
        _document = document;
        _page = null;
      });
      await _showPage(1);
    } on PdfException catch (error) {
      if (mounted) {
        setState(() {
          _document = null;
          _page = null;
        });
      }
      _fail(error);
    } catch (error) {
      if (mounted) setState(() => _document = null);
      _fail(PdfException.from(error));
    }
  }

  Future<void> _showPage(int pageNumber) async {
    final document = _document;
    if (document == null || !document.hasPage(pageNumber)) return;

    _startBusy('Preparing page $pageNumber…');
    setState(() => _pendingPageNumber = pageNumber);

    try {
      final page = await _renderer.renderPage(pageNumber);
      if (!mounted) return;
      setState(() => _page = page);
    } on PdfException catch (error) {
      _fail(error);
    } catch (error) {
      _fail(PdfException.from(error));
    } finally {
      _stopBusy();
    }
  }

  /// Reads the rendered page with the app's OCR service.
  ///
  /// The file handed to the recognizer is the very one on screen, so what is
  /// read is what was previewed.
  Future<void> _readPage() async {
    final page = _page;
    if (page == null || _busy) return;

    final scope = AppScope.of(context);
    final navigator = Navigator.of(context);
    final mode = scope.ocrScriptMode.value;

    _startBusy('Reading text on page ${page.pageNumber}…');
    try {
      final result = await scope.ocrService.recognizeImage(
        page.imagePath,
        mode: mode,
      );
      _stopBusy();
      if (!mounted) return;
      await navigator.push(
        MaterialPageRoute<void>(
          builder: (_) => OcrResultScreen(result: result),
        ),
      );
    } catch (error, stackTrace) {
      // Same reporter as the camera and gallery paths, so all three entry
      // points phrase and log an OCR failure identically.
      if (mounted) {
        showOcrFailure(
          context,
          error,
          stackTrace: stackTrace,
          where: 'PDF page OCR',
        );
      }
    } finally {
      _stopBusy();
    }
  }

  // --- view ------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final document = _document;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Import PDF'),
        actions: [
          if (document != null)
            IconButton(
              tooltip: 'Choose another PDF',
              onPressed: _busy ? null : _choosePdf,
              icon: const Icon(Icons.folder_open_outlined),
            ),
        ],
      ),
      body: SafeArea(
        child: document == null
            ? _EmptyState(
                error: _error,
                busy: _busy,
                busyLabel: _busyLabel,
                elapsed: _elapsed,
                onChoose: _choosePdf,
              )
            : Column(
                children: [
                  _DocumentHeader(
                    document: document,
                    page: _page,
                    pendingPageNumber: _pendingPageNumber,
                    busy: _busy,
                    onPrevious: () => unawaited(
                      _showPage((_page?.pageNumber ?? _pendingPageNumber) - 1),
                    ),
                    onNext: () => unawaited(
                      _showPage((_page?.pageNumber ?? _pendingPageNumber) + 1),
                    ),
                  ),
                  Expanded(
                    child: _PagePreview(
                      page: _page,
                      busy: _busy,
                      busyLabel: _busyLabel,
                      elapsed: _elapsed,
                      error: _error,
                      onRetry: () => unawaited(
                        _showPage(
                          _pendingPageNumber == 0 ? 1 : _pendingPageNumber,
                        ),
                      ),
                    ),
                  ),
                  _ActionBar(
                    page: _page,
                    busy: _busy,
                    onRead: () => unawaited(_readPage()),
                    onChooseAnother: _choosePdf,
                  ),
                ],
              ),
      ),
    );
  }
}

/// Nothing chosen yet: one clear action and the honest explanation of where the
/// work happens.
class _EmptyState extends StatelessWidget {
  const _EmptyState({
    required this.error,
    required this.busy,
    required this.busyLabel,
    required this.elapsed,
    required this.onChoose,
  });

  final PdfException? error;
  final bool busy;
  final String busyLabel;
  final Duration elapsed;
  final VoidCallback onChoose;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.picture_as_pdf_outlined, size: 72),
            const SizedBox(height: 12),
            Text('Read a PDF', style: theme.textTheme.titleLarge),
            const SizedBox(height: 8),
            Text(
              'Pick a PDF and each page is rendered on this device, then read '
              'with the same on-device OCR used for photos. Nothing is uploaded.',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 24),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: busy ? null : onChoose,
                icon: const Icon(Icons.upload_file_outlined),
                label: const Text('Choose PDF'),
              ),
            ),
            if (busy) ...[
              const SizedBox(height: 20),
              const CircularProgressIndicator(),
              const SizedBox(height: 10),
              Text(
                '$busyLabel ${(elapsed.inMilliseconds / 1000).toStringAsFixed(1)} s',
                style: theme.textTheme.bodySmall,
              ),
            ],
            if (error != null) ...[
              const SizedBox(height: 20),
              _ErrorNotice(error: error!, onRetry: onChoose),
            ],
          ],
        ),
      ),
    );
  }
}

/// File name, page position, and the page stepper.
class _DocumentHeader extends StatelessWidget {
  const _DocumentHeader({
    required this.document,
    required this.page,
    required this.pendingPageNumber,
    required this.busy,
    required this.onPrevious,
    required this.onNext,
  });

  final PdfDocumentInfo document;
  final RenderedPdfPage? page;
  final int pendingPageNumber;
  final bool busy;
  final VoidCallback onPrevious;
  final VoidCallback onNext;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final current = page?.pageNumber ?? pendingPageNumber;
    final label = current < 1
        ? document.pageCountLabel
        : 'Page $current of ${document.pageCount}';

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 8, 4),
      child: Row(
        children: [
          const Icon(Icons.picture_as_pdf, size: 20),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  document.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleSmall,
                ),
                Text(label, style: theme.textTheme.bodySmall),
              ],
            ),
          ),
          IconButton(
            tooltip: 'Previous page',
            onPressed: busy || current <= 1 ? null : onPrevious,
            icon: const Icon(Icons.chevron_left),
          ),
          IconButton(
            tooltip: 'Next page',
            onPressed: busy || current >= document.pageCount ? null : onNext,
            icon: const Icon(Icons.chevron_right),
          ),
        ],
      ),
    );
  }
}

/// The rendered page — literally the image that will be read.
class _PagePreview extends StatelessWidget {
  const _PagePreview({
    required this.page,
    required this.busy,
    required this.busyLabel,
    required this.elapsed,
    required this.error,
    required this.onRetry,
  });

  final RenderedPdfPage? page;
  final bool busy;
  final String busyLabel;
  final Duration elapsed;
  final PdfException? error;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final rendered = page;

    if (error != null && rendered == null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: _ErrorNotice(error: error!, onRetry: onRetry),
        ),
      );
    }

    return Stack(
      fit: StackFit.expand,
      children: [
        if (rendered != null)
          Padding(
            padding: const EdgeInsets.all(12),
            child: Image.file(
              File(rendered.imagePath),
              fit: BoxFit.contain,
              // The preview is a preview: decoding a full 1600 px page for the
              // screen would cost memory for no visible gain.
              cacheWidth: 1200,
              errorBuilder: (context, _, _) => Center(
                child: Text(
                  'That page could not be shown. Try another page.',
                  style: theme.textTheme.bodyMedium,
                ),
              ),
            ),
          ),
        if (rendered == null && !busy)
          Center(
            child: Text(
              'No page is prepared yet.',
              style: theme.textTheme.bodyMedium,
            ),
          ),
        if (busy)
          ColoredBox(
            color: theme.colorScheme.surface.withValues(alpha: 0.7),
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const CircularProgressIndicator(),
                  const SizedBox(height: 12),
                  Text(
                    '$busyLabel '
                    '${(elapsed.inMilliseconds / 1000).toStringAsFixed(1)} s',
                    style: theme.textTheme.bodySmall,
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }
}

/// The read action, plus what exactly is about to be read.
class _ActionBar extends StatelessWidget {
  const _ActionBar({
    required this.page,
    required this.busy,
    required this.onRead,
    required this.onChooseAnother,
  });

  final RenderedPdfPage? page;
  final bool busy;
  final VoidCallback onRead;
  final VoidCallback onChooseAnother;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final rendered = page;

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (rendered != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(
                'Page ${rendered.pageNumber} rendered at '
                '${rendered.width} × ${rendered.height} px'
                '${rendered.elapsed == null ? '' : ' in '
                          '${(rendered.elapsed!.inMilliseconds / 1000).toStringAsFixed(1)} s'}'
                ' — this is the image that will be read.',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodySmall,
              ),
            ),
          // Stacked full-width actions rather than a crowded row: the primary
          // action keeps its whole label on a phone and at large text scales.
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: busy || rendered == null ? null : onRead,
              icon: const Icon(Icons.text_fields_outlined),
              label: const Text('Read this page'),
            ),
          ),
          const SizedBox(height: 8),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: busy ? null : onChooseAnother,
              icon: const Icon(Icons.folder_open_outlined),
              label: const Text('Change PDF'),
            ),
          ),
        ],
      ),
    );
  }
}

/// A failure is a state the user can act on, never a silently dropped future.
class _ErrorNotice extends StatelessWidget {
  const _ErrorNotice({required this.error, required this.onRetry});

  final PdfException error;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Card(
      color: theme.colorScheme.errorContainer,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 12, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  Icons.error_outline,
                  color: theme.colorScheme.onErrorContainer,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    error.message,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onErrorContainer,
                    ),
                  ),
                ),
              ],
            ),
            // The actions get their own line, and wrap if they have to: a
            // failure message is longer than one line on a phone and at large
            // text scales, and squeezing buttons beside it truncates both.
            Align(
              alignment: Alignment.centerRight,
              child: Wrap(
                alignment: WrapAlignment.end,
                children: [
                  if (kDebugMode)
                    TextButton(
                      onPressed: () => _showPdfErrorDetails(context, error),
                      child: const Text('Details'),
                    ),
                  TextButton(
                    onPressed: onRetry,
                    child: const Text('Try again'),
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

/// Debug-only: the raw error from the PDF stack, so a device failure can be read
/// without logcat. Same shape as the translation feature's details dialog.
void _showPdfErrorDetails(BuildContext context, PdfException error) {
  showDialog<void>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: const Text('PDF error details'),
      content: SingleChildScrollView(
        child: SelectableText(
          '${error.kind.name}\n${error.cause ?? error.message}',
          style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(),
          child: const Text('Close'),
        ),
      ],
    ),
  );
}
