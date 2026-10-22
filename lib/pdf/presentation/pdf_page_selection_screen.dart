import 'dart:async';
import 'dart:collection';
import 'dart:io';

import 'package:flutter/material.dart';

import '../../app/app_theme.dart';
import '../data/pdfx_page_renderer.dart';
import '../domain/pdf_creation.dart';
import '../domain/pdf_exception.dart';
import '../domain/pdf_page_draft.dart';
import '../domain/pdf_page_raster.dart';
import '../domain/pdf_page_renderer.dart';
import 'pdf_review_screen.dart';

/// Builds a renderer with a given raster policy.
///
/// The selection screen needs **two** policies for the same document — small
/// images for the grid, full-size ones for the pages the user actually chose —
/// so the renderer is built through a factory rather than handed in ready-made.
/// Injected in tests, where a fake answers with known image paths.
typedef PdfRendererFactory =
    PdfPageRenderer Function(
      PdfPageRaster Function(double pageWidth, double pageHeight) rasterFor,
    );

/// Builds the review screen for the chosen pages, and answers with the document
/// it created (`null` when the user backed out). Injected in tests.
typedef PdfOpenReview =
    Future<CreatedPdf?> Function(
      BuildContext context,
      List<PdfPageDraft> pages,
    );

/// Chooses pages from an imported PDF and creates a **new** PDF from them.
///
/// What it does
/// ------------
/// * shows every page of the document as a thumbnail, each with its number;
/// * lets pages be selected and deselected, and shows **how many** are selected;
/// * numbers each selected page in the order it was selected, so the order the
///   new document will have is visible before it is created;
/// * creates the new PDF from exactly those pages, in that order.
///
/// The original file is never modified: this screen only ever reads it, and the
/// new document is written to a separate file (see `PdfReviewScreen`).
///
/// Two raster policies, on purpose
/// -------------------------------
/// Thumbnails are rendered small (~420 px wide) because a grid of a dozen
/// full-resolution pages is a lot of memory and a lot of disk for images that
/// are drawn 100 px wide. When the user asks for the PDF, the **chosen** pages
/// are re-rendered at reading quality (the same 1600 px policy OCR uses) one at
/// a time, so the document that is produced does not inherit the thumbnail's
/// resolution. That is why creation takes a moment: it is doing real work, and
/// it says so page by page rather than spinning.
///
/// Pages are rendered sequentially rather than in parallel: PDFium renders one
/// page at a time per document, and a burst of parallel renders is how this
/// screen would exhaust memory on a large file.
class PdfPageSelectionScreen extends StatefulWidget {
  const PdfPageSelectionScreen({
    super.key,
    required this.path,
    this.title,
    this.rendererFactory,
    this.openReview,
  });

  /// Absolute path of the imported PDF.
  final String path;

  /// Display title; defaults to the file name.
  final String? title;

  /// Injectable renderer factory (see [PdfRendererFactory]).
  final PdfRendererFactory? rendererFactory;

  /// Injectable review-screen seam (see [PdfOpenReview]).
  final PdfOpenReview? openReview;

  @override
  State<PdfPageSelectionScreen> createState() => _PdfPageSelectionScreenState();
}

class _PdfPageSelectionScreenState extends State<PdfPageSelectionScreen> {
  /// Thumbnail raster: small enough to be cheap, large enough to recognise a
  /// page by. Roughly a phone-sized preview.
  static PdfPageRaster _thumbRaster(double pageWidth, double pageHeight) =>
      PdfPageRaster.forPage(
        pageWidth: pageWidth,
        pageHeight: pageHeight,
        maxWidth: 420,
        maxHeight: 600,
      );

  PdfPageRenderer get _renderer =>
      (widget.rendererFactory ?? _defaultRendererFactory)(_thumbRaster);

  static PdfPageRenderer _defaultRendererFactory(
    PdfPageRaster Function(double pageWidth, double pageHeight) rasterFor,
  ) => PdfxPageRenderer(rasterFor: rasterFor);

  PdfPageRenderer? _session;

  bool _opening = true;
  String? _openError;

  int _pageCount = 0;

  /// Thumbnail image path per page number. `null` means that page failed to
  /// render; the tile stays visible and says so.
  final Map<int, String?> _thumbnails = <int, String?>{};

  /// Pages waiting for a thumbnail, and whether a render is in flight.
  ///
  /// Thumbnails are rendered **on demand and one at a time**: the grid only
  /// asks for the pages it is about to draw, so opening a 300-page document
  /// costs two renders rather than three hundred, and PDFium — which renders
  /// one page at a time per document anyway — is never asked for a burst of
  /// parallel work it cannot do.
  final Queue<int> _thumbnailQueue = Queue<int>();
  bool _rendering = false;

  /// Selected page numbers, **in the order they were selected**.
  final List<int> _selected = <int>[];

  /// Pages that are currently being assembled into a document.
  bool _assembling = false;
  int _assembled = 0;

  String get _title => widget.title ?? _fileNameOf(widget.path);

  static String _fileNameOf(String path) {
    final separator = path.lastIndexOf(RegExp(r'[\\/]'));
    return separator < 0 ? path : path.substring(separator + 1);
  }

  @override
  void initState() {
    super.initState();
    unawaited(_open());
  }

  @override
  void dispose() {
    // Closing the session releases the native document; a screen that forgot
    // this would keep a file handle and its raster buffers alive.
    final session = _session;
    _session = null;
    unawaited(session?.close() ?? Future<void>.value());
    super.dispose();
  }

  /// Opens the document. Thumbnails follow on demand (see [_requestThumbnail]).
  Future<void> _open() async {
    final session = _renderer;
    _session = session;

    try {
      final info = await session.open(widget.path);
      if (!mounted) return;
      setState(() {
        _pageCount = info.pageCount;
        _opening = false;
      });
    } on PdfException catch (error) {
      if (!mounted) return;
      setState(() {
        _openError = error.message;
        _opening = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _openError = PdfException.from(error).message;
        _opening = false;
      });
    }
  }

  /// Whether a page's thumbnail failed to render (as opposed to not being
  /// rendered yet — the difference between "unavailable" and "one moment").
  bool _pageFailed(int page) =>
      _thumbnails.containsKey(page) && _thumbnails[page] == null;

  /// Asks for a page's thumbnail, if it is not already there or already queued.
  void _requestThumbnail(int page) {
    if (_thumbnails.containsKey(page) || _thumbnailQueue.contains(page)) return;
    _thumbnailQueue.add(page);
    unawaited(_drainThumbnailQueue());
  }

  Future<void> _drainThumbnailQueue() async {
    if (_rendering) return;
    _rendering = true;
    try {
      while (mounted && _thumbnailQueue.isNotEmpty) {
        final session = _session;
        if (session == null) return;
        final page = _thumbnailQueue.removeFirst();
        try {
          final rendered = await session.renderPage(page);
          if (!mounted) return;
          setState(() => _thumbnails[page] = rendered.imagePath);
        } catch (_) {
          // One unrenderable page must not take the grid with it: the page is
          // marked unavailable and every other page stays usable.
          if (!mounted) return;
          setState(() => _thumbnails[page] = null);
        }
      }
    } finally {
      _rendering = false;
    }
  }

  void _toggle(int page) {
    setState(() {
      if (_selected.contains(page)) {
        _selected.remove(page);
      } else {
        _selected.add(page);
      }
    });
  }

  /// Adds every page that has not failed to render, in document order.
  ///
  /// Pages whose thumbnails have not been rendered yet are included: they are
  /// perfectly good pages, and a page only becomes unselectable when the
  /// renderer actually reported that it could not be read.
  void _selectAll() {
    setState(() {
      _selected
        ..clear()
        ..addAll(<int>[
          for (var page = 1; page <= _pageCount; page++)
            if (!_pageFailed(page)) page,
        ]);
    });
  }

  void _clear() => setState(_selected.clear);

  /// Renders the selected pages at reading quality and opens the review step.
  Future<void> _createFromSelection() async {
    if (_assembling || _selected.isEmpty) return;

    final selection = List<int>.unmodifiable(_selected);
    setState(() {
      _assembling = true;
      _assembled = 0;
    });

    // A fresh session with the *reading* raster policy: the thumbnails are too
    // small to become pages of a document.
    final full = (widget.rendererFactory ?? _defaultRendererFactory)(
      (pageWidth, pageHeight) =>
          PdfPageRaster.forPage(pageWidth: pageWidth, pageHeight: pageHeight),
    );

    final drafts = <PdfPageDraft>[];
    String? failure;
    try {
      await full.open(widget.path);
      for (var index = 0; index < selection.length; index++) {
        final rendered = await full.renderPage(selection[index]);
        drafts.add(
          PdfPageDraft(
            id: index + 1,
            imagePath: rendered.imagePath,
            origin: PdfPageOrigin.importedPage,
          ),
        );
        if (!mounted) return;
        setState(() => _assembled = index + 1);
      }
    } on PdfException catch (error) {
      failure = error.message;
    } catch (error) {
      failure = PdfException.from(error).message;
    } finally {
      await full.close();
    }

    if (!mounted) return;
    setState(() => _assembling = false);

    if (failure != null) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(failure)));
      return;
    }
    if (drafts.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Those pages could not be prepared.')),
      );
      return;
    }

    final openReview = widget.openReview ?? _pushReview;
    final created = await openReview(context, drafts);
    if (!mounted || created == null) return;

    // A new document exists: hand it back to whoever opened this screen.
    Navigator.of(context).pop(created);
  }

  Future<CreatedPdf?> _pushReview(
    BuildContext context,
    List<PdfPageDraft> pages,
  ) => Navigator.of(context).push<CreatedPdf>(
    MaterialPageRoute<CreatedPdf>(
      builder: (_) =>
          PdfReviewScreen(pages: pages, initialFileName: _suggestedFileName()),
    ),
  );

  /// `holiday.pdf` → `holiday-selected.pdf`, so the new document does not
  /// silently claim to be the original.
  String _suggestedFileName() {
    final name = _title;
    final dot = name.lastIndexOf('.');
    final base = dot <= 0 ? name : name.substring(0, dot);
    return '${base.isEmpty ? 'document' : base}-selected.pdf';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_title, maxLines: 1, overflow: TextOverflow.ellipsis),
        actions: [
          if (_pageCount > 0) ...[
            TextButton(
              onPressed: _assembling ? null : _selectAll,
              child: const Text('All'),
            ),
            TextButton(
              onPressed: _assembling || _selected.isEmpty ? null : _clear,
              child: const Text('Clear'),
            ),
          ],
        ],
      ),
      body: Stack(
        children: [
          Column(
            children: [
              Expanded(child: _buildBody()),
              _SelectionBar(
                selected: _selected.length,
                pageCount: _pageCount,
                assembling: _assembling,
                onSelectAll: _assembling ? null : _selectAll,
                onCreate: _selected.isEmpty
                    ? null
                    : () => unawaited(_createFromSelection()),
              ),
            ],
          ),
          if (_assembling)
            _AssemblingOverlay(done: _assembled, total: _selected.length),
        ],
      ),
    );
  }

  Widget _buildBody() {
    if (_opening) {
      return const Center(child: CircularProgressIndicator());
    }

    final error = _openError;
    if (error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.xxl),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.error_outline, size: 36, color: AppColors.muted),
              const SizedBox(height: AppSpacing.lg),
              Text(
                'This PDF could not be opened',
                style: Theme.of(context).textTheme.titleSmall,
              ),
              const SizedBox(height: AppSpacing.sm),
              Text(
                error,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: AppSpacing.xl),
              FilledButton(
                onPressed: () => Navigator.of(context).maybePop(),
                child: const Text('Go back'),
              ),
            ],
          ),
        ),
      );
    }

    return GridView.builder(
      padding: const EdgeInsets.all(AppSpacing.lg),
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 170,
        mainAxisSpacing: AppSpacing.md,
        crossAxisSpacing: AppSpacing.md,
        childAspectRatio: 0.66,
      ),
      itemCount: _pageCount,
      itemBuilder: (context, index) {
        final page = index + 1;
        // Building the tile is what requests its thumbnail: the grid asks only
        // for what it is about to draw.
        _requestThumbnail(page);
        return _PageThumbnail(
          page: page,
          imagePath: _thumbnails[page],
          rendering: !_thumbnails.containsKey(page),
          selectionIndex: _selected.indexOf(page),
          // A page can be chosen before its thumbnail arrives; only a page that
          // failed to render cannot.
          onTap: _pageFailed(page) ? null : () => _toggle(page),
        );
      },
    );
  }
}

/// One page in the grid: thumbnail, page number, and its position in the
/// selection (or a tick when it is not selected).
class _PageThumbnail extends StatelessWidget {
  const _PageThumbnail({
    required this.page,
    required this.imagePath,
    required this.rendering,
    required this.selectionIndex,
    required this.onTap,
  });

  final int page;
  final String? imagePath;

  /// Whether this page's thumbnail is still being rendered.
  final bool rendering;

  /// Position in the selection, or `-1` when not selected.
  final int selectionIndex;

  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final selected = selectionIndex >= 0;

    // The whole tile is the target, caption included: the thumbnail is the
    // obvious thing to tap and the page number is what the user is reading when
    // they tap it, so both must do the same thing.
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: AppColors.rowTint,
                borderRadius: BorderRadius.circular(AppRadii.card),
                border: Border.all(
                  color: selected ? AppColors.primary : AppColors.hairline,
                  width: selected ? 2.5 : 1,
                ),
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(AppRadii.card),
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    _buildImage(),
                    Positioned(
                      top: 6,
                      left: 6,
                      child: _Badge(
                        text: selected ? '${selectionIndex + 1}' : '$page',
                        filled: selected,
                      ),
                    ),
                    if (selected)
                      const Positioned(
                        top: 6,
                        right: 6,
                        child: Icon(
                          Icons.check_circle,
                          size: 20,
                          color: AppColors.primary,
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(height: 4),
          Text(
            'Page $page',
            style: theme.textTheme.labelSmall,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );
  }

  Widget _buildImage() {
    if (rendering) {
      return const Center(
        child: SizedBox(
          width: 18,
          height: 18,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      );
    }

    final path = imagePath;
    if (path == null) {
      return const Center(
        child: Icon(Icons.broken_image_outlined, color: AppColors.muted),
      );
    }

    return Image.file(
      File(path),
      fit: BoxFit.cover,
      // The tile is ~150 logical pixels wide, so decoding 4× that is already
      // generous on a 3× screen; the rest of the page's pixels would never be
      // drawn and would only cost memory.
      cacheWidth: 600,
      errorBuilder: (context, error, stack) => const Center(
        child: Icon(Icons.broken_image_outlined, color: AppColors.muted),
      ),
    );
  }
}

/// Small round label: page number, or the position in the selection.
class _Badge extends StatelessWidget {
  const _Badge({required this.text, required this.filled});

  final String text;
  final bool filled;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: filled ? AppColors.primary : Colors.black.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        text,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 11,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

/// The bottom bar: how many are selected, in what order, and the create action.
class _SelectionBar extends StatelessWidget {
  const _SelectionBar({
    required this.selected,
    required this.pageCount,
    required this.assembling,
    required this.onSelectAll,
    required this.onCreate,
  });

  final int selected;
  final int pageCount;
  final bool assembling;
  final VoidCallback? onSelectAll;
  final VoidCallback? onCreate;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Material(
      color: AppColors.surface,
      elevation: 8,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.lg,
            AppSpacing.md,
            AppSpacing.lg,
            AppSpacing.lg,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      selected == 0
                          ? 'Tap pages to select them'
                          : (selected == 1
                                ? '1 page selected'
                                : '$selected pages selected'),
                      style: theme.textTheme.labelLarge,
                    ),
                  ),
                  if (pageCount > 0)
                    Text(
                      pageCount == 1 ? 'of 1' : 'of $pageCount',
                      style: theme.textTheme.labelSmall,
                    ),
                ],
              ),
              const SizedBox(height: 2),
              Text(
                'Pages are added in the order you select them (the number on '
                'each page).',
                style: theme.textTheme.labelSmall,
              ),
              const SizedBox(height: AppSpacing.md),
              FilledButton.icon(
                onPressed: assembling ? null : onCreate,
                icon: const Icon(Icons.picture_as_pdf_outlined, size: 20),
                label: Text(
                  selected == 0
                      ? 'Select pages first'
                      : (selected == 1
                            ? 'Create PDF from 1 page'
                            : 'Create PDF from $selected pages'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Progress while the chosen pages are re-rendered at reading quality.
class _AssemblingOverlay extends StatelessWidget {
  const _AssemblingOverlay({required this.done, required this.total});

  final int done;
  final int total;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Positioned.fill(
      child: ColoredBox(
        color: Colors.black.withValues(alpha: 0.45),
        child: Center(
          child: Material(
            borderRadius: BorderRadius.circular(AppRadii.card),
            color: AppColors.surface,
            child: Padding(
              padding: const EdgeInsets.all(AppSpacing.xl),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const SizedBox(
                    width: 26,
                    height: 26,
                    child: CircularProgressIndicator(strokeWidth: 3),
                  ),
                  const SizedBox(height: AppSpacing.lg),
                  Text('Preparing pages…', style: theme.textTheme.titleSmall),
                  const SizedBox(height: 4),
                  Text(
                    total == 0 ? '' : 'Page $done of $total',
                    style: theme.textTheme.bodySmall,
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
