import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:pdfx/pdfx.dart' as pdfx;

import '../../app/app_theme.dart';
import '../data/pdf_file_exporter.dart';
import '../data/pdf_text_layer_reader.dart';
import '../domain/pdf_creation.dart';
import '../domain/pdf_text_layer.dart';
import '../domain/pdf_text_search.dart';
import 'widgets/searchable_pdf_page.dart';

/// The document surface, as a seam — the same shape the other PDF screens use,
/// so search, navigation and the states of this screen are testable without a
/// native PDF engine.
typedef SearchablePdfViewerSurface =
    Widget Function(
      BuildContext context, {
      required String path,
      required int? requestedPage,
      required ValueChanged<int> onLoaded,
      required ValueChanged<int> onPageChanged,
      required ValueChanged<Object> onError,
    });

/// The generated searchable PDF, opened **before** it is saved.
///
/// What it is for
/// --------------
/// * To show that the file is what the user asked for: the same pages, with
///   their own portrait or landscape shape, scrollable.
/// * To search the **file's own text layer**. The index is read back out of the
///   PDF with [PdfTextLayerReader], not handed over from the OCR run, so a hit
///   here means a hit after the file is shared.
/// * To navigate: a result jumps to its page and marks the line it was found on.
///
/// Save and Share are optional from here. The document already exists in the
/// app's cache, so a user who only wanted to search it can simply go back.
class SearchablePdfViewerScreen extends StatefulWidget {
  const SearchablePdfViewerScreen({
    super.key,
    required this.path,
    this.title,
    this.exporter,
    this.reader,
    this.textLayer,
    this.surface,
    this.initialQuery,
    this.search = const PdfTextSearch(),
  });

  /// Absolute path of the generated PDF.
  final String path;

  /// Display title; defaults to the file name.
  final String? title;

  /// Injectable so tests never reach the native share channel.
  final PdfFileExporter? exporter;

  /// Injectable text-layer source; defaults to [PdfTextLayerReader].
  final PdfTextLayerReader? reader;

  /// A preloaded layer, used by tests (and by callers that already have it).
  final PdfTextLayer? textLayer;

  /// Injectable document surface.
  final SearchablePdfViewerSurface? surface;

  /// Opens with the search panel already filled in and its first hit selected.
  /// Used when a document is opened *at* a search, and by the device probe that
  /// verifies the generated text layer end to end.
  final String? initialQuery;

  final PdfTextSearch search;

  @override
  State<SearchablePdfViewerScreen> createState() =>
      _SearchablePdfViewerScreenState();
}

class _SearchablePdfViewerScreenState extends State<SearchablePdfViewerScreen> {
  late final PdfFileExporter _exporter =
      widget.exporter ?? const PdfFileExporter();
  final TextEditingController _query = TextEditingController();
  final FocusNode _searchFocus = FocusNode();

  PdfTextLayer? _layer;
  bool _readingLayer = true;
  String? _layerError;

  bool _searching = false;
  List<PdfTextMatch> _matches = const <PdfTextMatch>[];
  int _activeMatch = -1;

  int _page = 1;
  int _pageCount = 0;
  int? _requestedPage;
  Object? _error;

  String get _title => widget.title ?? widget.path.split(RegExp(r'[\\/]')).last;

  PdfTextMatch? get _match =>
      _activeMatch >= 0 && _activeMatch < _matches.length
      ? _matches[_activeMatch]
      : null;

  @override
  void initState() {
    super.initState();
    unawaited(_readLayer());
  }

  Future<void> _readLayer() async {
    final preloaded = widget.textLayer;
    if (preloaded != null) {
      if (mounted) {
        setState(() {
          _layer = preloaded;
          _readingLayer = false;
        });
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _applyInitialQuery();
        });
      }
      return;
    }

    try {
      final layer = await (widget.reader ?? const PdfTextLayerReader())
          .readFile(widget.path);
      if (!mounted) return;
      setState(() {
        _layer = layer;
        _readingLayer = false;
      });
      // After the frame that has the search field in it: the field and the
      // results panel are built from this state, so applying the query in the
      // same synchronous turn as the layer arrives can land before either
      // exists on screen.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _applyInitialQuery();
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _readingLayer = false;
        _layerError = error.toString();
      });
    }
  }

  @override
  void dispose() {
    _query.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  // --- search ---------------------------------------------------------------

  /// Fills the search panel from [SearchablePdfViewerScreen.initialQuery] and
  /// selects the first hit, so the document opens on the page it was asked for.
  void _applyInitialQuery() {
    final query = widget.initialQuery?.trim();
    final layer = _layer;
    if (query == null || query.isEmpty || layer == null) return;
    setState(() {
      _searching = true;
      _query.text = query;
      _matches = widget.search.find(layer, query);
      _activeMatch = -1;
    });
    if (_matches.isNotEmpty) _goToMatch(0);
  }

  void _toggleSearch() {
    if (_searching) {
      _closeSearch();
      return;
    }
    setState(() => _searching = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _searchFocus.requestFocus();
    });
  }

  void _closeSearch() {
    _searchFocus.unfocus();
    _query.clear();
    setState(() {
      _searching = false;
      _matches = const <PdfTextMatch>[];
      _activeMatch = -1;
    });
  }

  void _onQueryChanged(String value) {
    final layer = _layer;
    if (layer == null) return;
    final matches = widget.search.find(layer, value);
    setState(() {
      _matches = matches;
      _activeMatch = -1;
    });
  }

  void _goToMatch(int index) {
    if (index < 0 || index >= _matches.length) return;
    final match = _matches[index];
    _searchFocus.unfocus();
    setState(() {
      _activeMatch = index;
      _page = match.pageNumber;
      _requestedPage = match.pageNumber;
    });
  }

  void _stepMatch(int delta) {
    if (_matches.isEmpty) return;
    final next = (_activeMatch + delta) % _matches.length;
    _goToMatch(next < 0 ? next + _matches.length : next);
  }

  // --- export ---------------------------------------------------------------

  Future<void> _save(CreatedPdf pdf) async {
    final location = await _exporter.saveToDownloads(pdf);
    if (!mounted) return;
    _say(
      location == null
          ? 'Could not save the PDF to this device.'
          : 'Saved to $location',
    );
  }

  Future<void> _share(CreatedPdf pdf) async {
    final shown = await _exporter.share(pdf);
    if (!mounted) return;
    if (!shown) _say('No app on this device can receive the PDF.');
  }

  CreatedPdf _createdPdf() => CreatedPdf(
    path: widget.path,
    fileName: _title,
    pageCount: _pageCount == 0 ? (_layer?.pageCount ?? 0) : _pageCount,
    byteSize: 0,
  );

  void _say(String message) => ScaffoldMessenger.of(
    context,
  ).showSnackBar(SnackBar(content: Text(message)));

  // --- view -----------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final layer = _layer;
    final match = _match;

    return Scaffold(
      backgroundColor: AppColors.page,
      appBar: AppBar(
        backgroundColor: AppColors.page,
        surfaceTintColor: Colors.transparent,
        title: Text(_title, maxLines: 1, overflow: TextOverflow.ellipsis),
        actions: [
          IconButton(
            // A disabled search button still has to say why: a file with no
            // text layer (or one whose layer could not be read) is a different
            // situation from a search that found nothing.
            tooltip: layer == null || layer.isEmpty
                ? (_layerError == null
                      ? 'No searchable text found'
                      : 'Text layer could not be read')
                : 'Search',
            onPressed: layer == null || layer.isEmpty ? null : _toggleSearch,
            icon: Icon(_searching ? Icons.search_off : Icons.search),
          ),
          PopupMenuButton<String>(
            tooltip: 'Save or share',
            onSelected: (value) {
              final pdf = _createdPdf();
              if (value == 'save') unawaited(_save(pdf));
              if (value == 'share') unawaited(_share(pdf));
            },
            itemBuilder: (context) => const [
              PopupMenuItem<String>(
                value: 'save',
                child: ListTile(
                  leading: Icon(Icons.download_outlined),
                  title: Text('Save PDF'),
                  contentPadding: EdgeInsets.zero,
                ),
              ),
              PopupMenuItem<String>(
                value: 'share',
                child: ListTile(
                  leading: Icon(Icons.share_outlined),
                  title: Text('Share PDF'),
                  contentPadding: EdgeInsets.zero,
                ),
              ),
            ],
          ),
        ],
      ),
      body: SafeArea(
        top: false,
        child: Column(
          children: [
            if (_searching)
              _SearchField(
                controller: _query,
                focusNode: _searchFocus,
                reading: _readingLayer,
                onChanged: _onQueryChanged,
                onClose: _closeSearch,
              ),
            Expanded(
              child: Stack(
                children: [
                  Positioned.fill(
                    child: ColoredBox(
                      color: const Color(0xFF2F3448),
                      child: _error != null
                          ? _OpenProblem(
                              detail: kDebugMode
                                  ? _error.toString()
                                  : 'The file may have been moved or damaged. '
                                        'Try opening it again.',
                            )
                          : (widget.surface?.call(
                                  context,
                                  path: widget.path,
                                  requestedPage: _requestedPage,
                                  onLoaded: (count) {
                                    if (mounted) {
                                      setState(() {
                                        _pageCount = count;
                                        _error = null;
                                      });
                                    }
                                  },
                                  onPageChanged: (page) {
                                    if (mounted) setState(() => _page = page);
                                  },
                                  onError: (error) {
                                    if (mounted) setState(() => _error = error);
                                  },
                                ) ??
                                _PdfSurface(
                                  path: widget.path,
                                  // The highlight lives inside each page now, so
                                  // the surface needs the page geometry and the
                                  // active match, not the viewport.
                                  layer: layer,
                                  match: match,
                                  requestedPage: _requestedPage,
                                  onLoaded: (count) {
                                    if (mounted) {
                                      setState(() {
                                        _pageCount = count;
                                        _error = null;
                                      });
                                    }
                                  },
                                  onPageChanged: (page) {
                                    if (mounted) setState(() => _page = page);
                                  },
                                  onError: (error) {
                                    if (mounted) setState(() => _error = error);
                                  },
                                )),
                    ),
                  ),
                  if (_pageCount > 0 && _error == null)
                    Positioned(
                      top: AppSpacing.md,
                      right: AppSpacing.md,
                      child: _PageChip(page: _page, pageCount: _pageCount),
                    ),
                  if (_searching && _query.text.trim().isNotEmpty)
                    Positioned(
                      left: AppSpacing.md,
                      right: AppSpacing.md,
                      bottom: AppSpacing.md,
                      child: _ResultsCard(
                        query: _query.text.trim(),
                        matches: _matches,
                        active: _activeMatch,
                        onTap: _goToMatch,
                        onPrevious: _matches.isEmpty
                            ? null
                            : () => _stepMatch(-1),
                        onNext: _matches.isEmpty ? null : () => _stepMatch(1),
                      ),
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

/// The search field, under the title bar.
class _SearchField extends StatelessWidget {
  const _SearchField({
    required this.controller,
    required this.focusNode,
    required this.reading,
    required this.onChanged,
    required this.onClose,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final bool reading;
  final ValueChanged<String> onChanged;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Material(
      color: AppColors.surface,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          AppSpacing.lg,
          AppSpacing.sm,
          AppSpacing.sm,
          AppSpacing.md,
        ),
        child: Row(
          children: [
            Expanded(
              child: TextField(
                controller: controller,
                focusNode: focusNode,
                autofocus: true,
                textInputAction: TextInputAction.search,
                onChanged: onChanged,
                decoration: InputDecoration(
                  isDense: true,
                  hintText: reading
                      ? 'Reading the text layer…'
                      : 'Search this PDF',
                  hintStyle: theme.textTheme.bodyMedium?.copyWith(
                    color: AppColors.muted,
                  ),
                  prefixIcon: const Icon(Icons.search, size: 20),
                  filled: true,
                  fillColor: AppColors.rowTint,
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: AppSpacing.md,
                    vertical: AppSpacing.md,
                  ),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(AppRadii.button),
                    borderSide: BorderSide.none,
                  ),
                ),
              ),
            ),
            IconButton(
              tooltip: 'Close search',
              onPressed: onClose,
              icon: const Icon(Icons.close),
            ),
          ],
        ),
      ),
    );
  }
}

/// Results, plus previous/next through them.
class _ResultsCard extends StatelessWidget {
  const _ResultsCard({
    required this.query,
    required this.matches,
    required this.active,
    required this.onTap,
    required this.onPrevious,
    required this.onNext,
  });

  final String query;
  final List<PdfTextMatch> matches;
  final int active;
  final ValueChanged<int> onTap;
  final VoidCallback? onPrevious;
  final VoidCallback? onNext;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Material(
      color: AppColors.surface,
      elevation: 12,
      borderRadius: BorderRadius.circular(AppRadii.card),
      clipBehavior: Clip.antiAlias,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxHeight: 236),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(
                AppSpacing.lg,
                AppSpacing.md,
                AppSpacing.sm,
                AppSpacing.sm,
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      matches.isEmpty
                          ? 'No matches for “$query”'
                          : '${matches.length} '
                                '${matches.length == 1 ? 'match' : 'matches'}',
                      style: theme.textTheme.titleSmall,
                    ),
                  ),
                  IconButton(
                    tooltip: 'Previous match',
                    onPressed: onPrevious,
                    icon: const Icon(Icons.keyboard_arrow_up),
                  ),
                  IconButton(
                    tooltip: 'Next match',
                    onPressed: onNext,
                    icon: const Icon(Icons.keyboard_arrow_down),
                  ),
                ],
              ),
            ),
            if (matches.isNotEmpty)
              Flexible(
                child: ListView.separated(
                  shrinkWrap: true,
                  itemCount: matches.length,
                  separatorBuilder: (_, _) =>
                      const Divider(height: 1, indent: AppSpacing.lg),
                  itemBuilder: (context, index) {
                    final match = matches[index];
                    final selected = index == active;
                    return ListTile(
                      dense: true,
                      selected: selected,
                      selectedTileColor: AppColors.tile,
                      title: Text(
                        match.snippet,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: AppColors.ink,
                        ),
                      ),
                      subtitle: Text(
                        'Page ${match.pageNumber}',
                        style: theme.textTheme.labelSmall,
                      ),
                      onTap: () => onTap(index),
                    );
                  },
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// `Page 3 of 12`, floating over the paper.
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

/// The box drawn over the matched line used to live here, positioned from the
/// viewport's size and the page's aspect ratio. That was only correct while the
/// page happened to be `contain`-fitted to the whole viewport, which `pdfx`'s
/// scrolling, padded, zoomable `PhotoView` gallery is not. The marker is now
/// drawn inside the page itself; see [SearchablePdfPage].

class _OpenProblem extends StatelessWidget {
  const _OpenProblem({required this.detail});

  final String detail;

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
              detail,
              textAlign: TextAlign.center,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: Colors.white70, fontSize: 13),
            ),
          ],
        ),
      ),
    );
  }
}

/// Vertical, lazily rasterised, every page in its own shape.
///
/// Each page is built as a [SearchablePdfPage]: the scan and the search marker
/// share one coordinate system, so `PhotoView`'s zoom and pan move them
/// together. The alternative — drawing the marker in this widget's viewport —
/// can only be right while the page happens to fill that viewport.
class _PdfSurface extends StatefulWidget {
  const _PdfSurface({
    required this.path,
    required this.requestedPage,
    required this.onLoaded,
    required this.onPageChanged,
    required this.onError,
    this.layer,
    this.match,
  });

  final String path;
  final int? requestedPage;
  final ValueChanged<int> onLoaded;
  final ValueChanged<int> onPageChanged;
  final ValueChanged<Object> onError;

  /// The document's own text layer, used for each page's size and for placing
  /// the active match. `null` until the layer has been read (or if it cannot),
  /// in which case pages open without a marker.
  final PdfTextLayer? layer;

  /// The hit currently being shown, if any.
  final PdfTextMatch? match;

  @override
  State<_PdfSurface> createState() => _PdfSurfaceState();
}

class _PdfSurfaceState extends State<_PdfSurface> {
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
        final count = _controller.pagesCount ?? 0;
        widget.onLoaded(count);
        // A jump requested while the document was still opening (opening at a
        // search, for instance) is applied here: the controller refuses to
        // animate before a page has been laid out.
        final target = widget.requestedPage;
        if (target != null && count > 0) {
          unawaited(
            _controller.animateToPage(
              target.clamp(1, count),
              duration: const Duration(milliseconds: 220),
              curve: Curves.easeOut,
            ),
          );
        }
      case pdfx.PdfLoadingState.error:
        widget.onError(_loadingError ?? 'The document could not be opened.');
      case pdfx.PdfLoadingState.loading:
        break;
    }
  }

  @override
  void didUpdateWidget(covariant _PdfSurface oldWidget) {
    super.didUpdateWidget(oldWidget);
    final target = widget.requestedPage;
    if (target != null && target != oldWidget.requestedPage) {
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

  /// One page option: the page image, plus the match box when it belongs here.
  ///
  /// `childSize` is the page's own point size. It is not cosmetic: `photo_view`
  /// gives a custom child exactly this size, and it is what makes the image and
  /// the marker scale as one object. The layer's page size is used because the
  /// text search already read it from the same file `pdfx` renders.
  pdfx.PhotoViewGalleryPageOptions _pageOptions(
    BuildContext context,
    Future<pdfx.PdfPageImage> pageImage,
    int index,
    pdfx.PdfDocument document,
  ) {
    final pageNumber = index + 1;
    final page = widget.layer?.page(pageNumber);
    final image = pdfx.PdfPageImageProvider(pageImage, index, document.id);

    // No known page geometry (text layer still loading, or unreadable): show
    // the page exactly as before, just without a marker.
    if (page == null || page.width <= 0 || page.height <= 0) {
      return pdfx.PhotoViewGalleryPageOptions(
        imageProvider: image,
        minScale: pdfx.PhotoViewComputedScale.contained,
        maxScale: pdfx.PhotoViewComputedScale.contained * 3.0,
        initialScale: pdfx.PhotoViewComputedScale.contained,
      );
    }

    final match = widget.match;
    final bounds = match != null && match.pageNumber == pageNumber
        ? match.bounds
        : null;

    final pageSize = Size(page.width, page.height);
    return pdfx.PhotoViewGalleryPageOptions.customChild(
      child: SearchablePdfPage(
        image: image,
        pageSize: pageSize,
        highlight: bounds,
      ),
      childSize: pageSize,
      minScale: pdfx.PhotoViewComputedScale.contained,
      maxScale: pdfx.PhotoViewComputedScale.contained * 3.0,
      initialScale: pdfx.PhotoViewComputedScale.contained,
    );
  }

  @override
  Widget build(BuildContext context) {
    return pdfx.PdfView(
      controller: _controller,
      scrollDirection: Axis.vertical,
      pageSnapping: false,
      onPageChanged: widget.onPageChanged,
      onDocumentError: (error) {
        _loadingError = error;
        widget.onError(error);
      },
      builders: pdfx.PdfViewBuilders<pdfx.DefaultBuilderOptions>(
        options: const pdfx.DefaultBuilderOptions(),
        pageBuilder: _pageOptions,
        documentLoaderBuilder: (context) =>
            const Center(child: CircularProgressIndicator()),
        pageLoaderBuilder: (context) => const Center(
          child: SizedBox(
            width: 22,
            height: 22,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
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
