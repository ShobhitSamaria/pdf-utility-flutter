import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:pdfx/pdfx.dart' as pdfx;

import '../../app/app_theme.dart';
import '../domain/pdf_creation.dart';
import 'pdf_page_selection_screen.dart';

/// The document surface, as a seam.
///
/// Widget tests have no PDFium — there is no native side in `flutter test` — so
/// the screen's own logic (page state, navigation, error reporting, the
/// Select-pages action) is expressed against this builder and the real `pdfx`
/// view is one implementation of it. Everything the screen decides can
/// therefore be tested, and the one part that cannot is exactly the part that
/// is somebody else's code.
typedef PdfDocumentSurface =
    Widget Function(
      BuildContext context, {
      required int? requestedPage,
      required ValueChanged<int> onPageChanged,
      required ValueChanged<int> onLoaded,
      required ValueChanged<Object> onError,
    });

/// Reads a PDF the user imported.
///
/// What it is for
/// --------------
/// * page navigation over the original document, exactly as it is;
/// * the way into **Select pages**, which creates a *new* PDF from chosen pages.
///
/// The original is opened read-only and never rewritten: selecting pages
/// produces a separate document, so a page the user did not choose cannot go
/// missing from the file they imported.
///
/// Rendering is `pdfx`'s own scrolling, zoomable page view, which rasterises
/// only the pages near the viewport — a 300-page document does not want 300
/// bitmaps in memory, and a page-selection grid of thumbnails in this app is
/// rendered separately (see `PdfPageSelectionScreen`) precisely so the two
/// needs do not have to share one rasterisation strategy.
class PdfViewerScreen extends StatefulWidget {
  const PdfViewerScreen({
    super.key,
    required this.path,
    this.title,
    this.surface,
    this.onSelectPages,
  });

  /// Absolute path of the PDF to show.
  final String path;

  /// Display title; defaults to the file name.
  final String? title;

  /// Injectable document surface (see [PdfDocumentSurface]).
  final PdfDocumentSurface? surface;

  /// Injectable Select-pages seam. Defaults to pushing
  /// [PdfPageSelectionScreen] and ignoring its result: this screen stays where
  /// it is, so the document the user imported is still there to read after they
  /// have created something else from part of it.
  final Future<void> Function(BuildContext context)? onSelectPages;

  @override
  State<PdfViewerScreen> createState() => _PdfViewerScreenState();
}

class _PdfViewerScreenState extends State<PdfViewerScreen> {
  int _page = 1;
  int _pageCount = 0;

  /// Page the user has asked to jump to, handed to the surface declaratively.
  /// The surface owns the actual scrolling; this is only the request.
  int? _requestedPage;

  Object? _error;

  String get _title => widget.title ?? _fileNameOf(widget.path);

  static String _fileNameOf(String path) {
    final separator = path.lastIndexOf(RegExp(r'[\\/]'));
    return separator < 0 ? path : path.substring(separator + 1);
  }

  void _onLoaded(int pageCount) {
    if (!mounted) return;
    setState(() {
      _pageCount = pageCount;
      _error = null;
    });
  }

  void _onError(Object error) {
    if (!mounted) return;
    setState(() => _error = error);
  }

  void _jump(int page) {
    final target = page.clamp(1, _pageCount == 0 ? 1 : _pageCount);
    setState(() => _requestedPage = target);
  }

  /// Opens the page-selection grid, where pages of this document are chosen and
  /// a new PDF is created from them.
  Future<void> _selectPages() async {
    final select =
        widget.onSelectPages ??
        (BuildContext context) async {
          await Navigator.of(context).push<CreatedPdf>(
            MaterialPageRoute<CreatedPdf>(
              builder: (_) =>
                  PdfPageSelectionScreen(path: widget.path, title: _title),
            ),
          );
        };

    await select(context);
  }

  @override
  Widget build(BuildContext context) {
    final surfaceBuilder = widget.surface ?? _pdfxSurface;

    return Scaffold(
      appBar: AppBar(
        title: Text(_title, maxLines: 1, overflow: TextOverflow.ellipsis),
        actions: [
          IconButton(
            tooltip: 'Select pages',
            // Only meaningful once the document is known to have pages.
            onPressed: _error == null && _pageCount > 0
                ? () => unawaited(_selectPages())
                : null,
            icon: const Icon(Icons.checklist_rtl),
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: ColoredBox(
              color: const Color(0xFF3A3F51),
              child: _error != null
                  ? _ViewerProblem(
                      detail: _error.toString(),
                      onClose: () => Navigator.of(context).maybePop(),
                    )
                  : surfaceBuilder(
                      context,
                      requestedPage: _requestedPage,
                      onPageChanged: (page) {
                        if (mounted) setState(() => _page = page);
                      },
                      onLoaded: _onLoaded,
                      onError: _onError,
                    ),
            ),
          ),
          _PageBar(
            page: _page,
            pageCount: _pageCount,
            onPrevious: _page > 1 ? () => _jump(_page - 1) : null,
            onNext: _pageCount > 0 && _page < _pageCount
                ? () => _jump(_page + 1)
                : null,
          ),
        ],
      ),
    );
  }

  /// The real surface: `pdfx`'s scrolling page view.
  Widget _pdfxSurface(
    BuildContext context, {
    required int? requestedPage,
    required ValueChanged<int> onPageChanged,
    required ValueChanged<int> onLoaded,
    required ValueChanged<Object> onError,
  }) => _PdfxSurface(
    path: widget.path,
    requestedPage: requestedPage,
    onPageChanged: onPageChanged,
    onLoaded: onLoaded,
    onError: onError,
  );
}

/// [PdfDocumentSurface] backed by `pdfx`.
///
/// This is one of only two places in the app that touches `pdfx`'s viewer (the
/// other being the renderer used for OCR), so the rest of the UI stays free of
/// the package.
class _PdfxSurface extends StatefulWidget {
  const _PdfxSurface({
    required this.path,
    required this.requestedPage,
    required this.onPageChanged,
    required this.onLoaded,
    required this.onError,
  });

  final String path;
  final int? requestedPage;
  final ValueChanged<int> onPageChanged;
  final ValueChanged<int> onLoaded;
  final ValueChanged<Object> onError;

  @override
  State<_PdfxSurface> createState() => _PdfxSurfaceState();
}

class _PdfxSurfaceState extends State<_PdfxSurface> {
  late final pdfx.PdfController _controller = pdfx.PdfController(
    document: pdfx.PdfDocument.openFile(widget.path),
  );

  Object? _loadingError;

  @override
  void initState() {
    super.initState();
    _controller.loadingState.addListener(_onLoadingState);
  }

  void _onLoadingState() {
    switch (_controller.loadingState.value) {
      case pdfx.PdfLoadingState.success:
        widget.onLoaded(_controller.pagesCount ?? 0);
      case pdfx.PdfLoadingState.error:
        widget.onError(_loadingError ?? 'The document could not be opened.');
      case pdfx.PdfLoadingState.loading:
        break;
    }
  }

  @override
  void didUpdateWidget(covariant _PdfxSurface oldWidget) {
    super.didUpdateWidget(oldWidget);
    final target = widget.requestedPage;
    if (target != null && target != oldWidget.requestedPage) {
      // Guarded: the controller's page view only exists once a page has been
      // laid out, and a jump requested before that would throw.
      final count = _controller.pagesCount ?? 0;
      if (count > 0) {
        unawaited(
          _controller.animateToPage(
            target.clamp(1, count),
            duration: const Duration(milliseconds: 220),
            curve: Curves.easeOut,
          ),
        );
      }
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
      scrollDirection: Axis.vertical,
      onPageChanged: widget.onPageChanged,
      onDocumentError: (error) {
        _loadingError = error;
        widget.onError(error);
      },
      // Only the loading and error surfaces are overridden: the page builder
      // itself (zoom/pan over a rasterised page) is left to the package, whose
      // default is exactly what a reader expects.
      builders: pdfx.PdfViewBuilders<pdfx.DefaultBuilderOptions>(
        options: const pdfx.DefaultBuilderOptions(),
        documentLoaderBuilder: (context) =>
            const Center(child: CircularProgressIndicator()),
        pageLoaderBuilder: (context) =>
            const Center(child: CircularProgressIndicator()),
        errorBuilder: (context, error) => const Center(
          child: Text(
            'This page could not be rendered.',
            style: TextStyle(color: Colors.white70),
          ),
        ),
      ),
    );
  }
}

/// `Page 4 of 12` with previous/next, under the document.
class _PageBar extends StatelessWidget {
  const _PageBar({
    required this.page,
    required this.pageCount,
    required this.onPrevious,
    required this.onNext,
  });

  final int page;
  final int pageCount;
  final VoidCallback? onPrevious;
  final VoidCallback? onNext;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Material(
      color: AppColors.surface,
      elevation: 8,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.sm,
            vertical: 2,
          ),
          child: Row(
            children: [
              IconButton(
                tooltip: 'Previous page',
                onPressed: onPrevious,
                icon: const Icon(Icons.chevron_left),
              ),
              Expanded(
                child: Center(
                  child: Text(
                    pageCount == 0 ? 'Opening…' : 'Page $page of $pageCount',
                    style: theme.textTheme.labelMedium,
                  ),
                ),
              ),
              IconButton(
                tooltip: 'Next page',
                onPressed: onNext,
                icon: const Icon(Icons.chevron_right),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Shown in place of the document when it cannot be opened or rendered.
class _ViewerProblem extends StatelessWidget {
  const _ViewerProblem({required this.detail, required this.onClose});

  final String detail;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.xxl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.error_outline, color: Colors.white70, size: 40),
            const SizedBox(height: AppSpacing.lg),
            const Text(
              'This PDF could not be opened',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: Colors.white,
                fontSize: 17,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: AppSpacing.sm),
            Text(
              'It may be damaged, or protected by a password.',
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white70, fontSize: 13.5),
            ),
            const SizedBox(height: AppSpacing.xl),
            OutlinedButton(onPressed: onClose, child: const Text('Go back')),
          ],
        ),
      ),
    );
  }
}

/// Whether a path still looks like a readable PDF.
///
/// A cheap pre-check used before opening a document: it catches the common
/// failure (the picker's temporary copy was cleaned up) with a clear message
/// instead of a native error.
bool pdfFileLooksReadable(String path) {
  final file = File(path);
  return file.existsSync() && file.lengthSync() > 0;
}
