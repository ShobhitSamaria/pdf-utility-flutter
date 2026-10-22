import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import '../../app/app_theme.dart';
import '../../ocr/data/image_source_service.dart';
import '../data/pdf_creation_services.dart';
import '../data/pdf_file_exporter.dart';
import '../domain/pdf_creation.dart';
import '../domain/pdf_exception.dart';
import '../domain/pdf_page_draft.dart';
import 'pdf_capture_screen.dart';
import 'widgets/pdf_success_sheet.dart';

/// Adds pages to a draft from the gallery or the capture screen.
///
/// The two seams the screen needs are pulled out as typedefs so a widget test
/// can supply pages without starting a camera or opening a platform picker —
/// the same convention the Home screen already uses for its camera and gallery
/// actions.
typedef PdfCapturePages = Future<List<String>> Function(BuildContext context);
typedef PdfPickImages = Future<List<String>> Function();

/// The **review** step of PDF creation: the pages, in order, with everything the
/// user is allowed to change before the file is written.
///
/// What it does
/// ------------
/// * shows every page as a thumbnail, numbered, in document order;
/// * deletes a page, or reorders it by dragging it onto another page;
/// * adds more pages — from the camera (a whole capture session) or the gallery
///   (a multi-select);
/// * lets the output file name be edited, showing the exact name that will be
///   written;
/// * writes the document, then offers the finished file to the rest of the
///   device (share sheet, or a copy in Downloads).
///
/// Why the order lives in one place
/// --------------------------------
/// The page list is a [PdfDraft] — an immutable value object that owns add,
/// delete, reorder and rename as pure functions. The screen only ever replaces
/// its draft, so "the order in the thumbnails" and "the order in the file" are
/// the same list by construction, and every ordering rule is unit-tested
/// without a widget.
///
/// Nothing is reported as created until the file exists: the success sheet is
/// built from the [CreatedPdf] the writer returned, which is only produced once
/// the bytes are on disk.
class PdfReviewScreen extends StatefulWidget {
  const PdfReviewScreen({
    super.key,
    this.pages = const <PdfPageDraft>[],
    this.initialFileName,
    this.creationService,
    this.capturePages,
    this.pickImages,
    this.exporter,
  });

  /// Pages to start from (a capture session, a gallery multi-select, or the
  /// pages selected in an imported PDF).
  final List<PdfPageDraft> pages;

  /// Starting file name, if the flow already knows one.
  ///
  /// Usually `null`: the field starts **empty**, with a hint, so the name is
  /// always something the user typed rather than a default that gets saved
  /// without them noticing.
  final String? initialFileName;

  /// The writer. Injectable so a test can assert on the document it is asked to
  /// produce without touching the filesystem.
  final PdfCreationService? creationService;

  /// Injectable camera seam. Defaults to [PdfCaptureScreen].
  final PdfCapturePages? capturePages;

  /// Injectable gallery seam. Defaults to the platform multi-image picker.
  final PdfPickImages? pickImages;

  /// Hands the finished file to the rest of the device (share sheet, copy in
  /// Downloads). Injectable so a test can drive both outcomes.
  final PdfFileExporter? exporter;

  /// Convenience for the common case: a list of image paths, all from one
  /// source.
  static PdfReviewScreen fromPaths(
    List<String> imagePaths, {
    required PdfPageOrigin origin,
    String? fileName,
  }) => PdfReviewScreen(
    pages: <PdfPageDraft>[
      for (var index = 0; index < imagePaths.length; index++)
        PdfPageDraft(
          id: index + 1,
          imagePath: imagePaths[index],
          origin: origin,
        ),
    ],
    initialFileName: fileName,
  );

  @override
  State<PdfReviewScreen> createState() => _PdfReviewScreenState();
}

class _PdfReviewScreenState extends State<PdfReviewScreen> {
  final ImageSourceService _images = ImageSourceService();

  late PdfDraft _draft = PdfDraft(
    pages: widget.pages,
    fileName: widget.initialFileName ?? '',
    nextId: widget.pages.length + 1,
  );

  late final TextEditingController _fileName = TextEditingController(
    text: _draft.fileName,
  );

  /// Whether a document is being written right now.
  bool _creating = false;
  int _written = 0;
  int _total = 0;

  PdfCreationService get _writer =>
      widget.creationService ?? createPdfCreationService();

  @override
  void dispose() {
    _fileName.dispose();
    super.dispose();
  }

  void _replace(PdfDraft next) {
    if (next == _draft) return;
    setState(() => _draft = next);
  }

  // --- editing ---------------------------------------------------------------

  void _delete(int index) {
    _replace(_draft.removeAt(index));
  }

  void _dragTo(int from, int to) => _replace(_draft.moveTo(from, to));

  Future<void> _addFromCamera() async {
    final capture = widget.capturePages ?? _pushCaptureScreen;
    final pages = await capture(context);
    if (!mounted || pages.isEmpty) return;
    _replace(_draft.addAll(pages, origin: PdfPageOrigin.camera));
    _reportAdded(pages.length);
  }

  Future<List<String>> _pushCaptureScreen(BuildContext context) async {
    final pages = await Navigator.of(context).push<List<String>>(
      MaterialPageRoute<List<String>>(builder: (_) => const PdfCaptureScreen()),
    );
    return pages ?? const <String>[];
  }

  Future<void> _addFromGallery() async {
    final pick = widget.pickImages ?? _images.pickMultipleFromGallery;
    final pages = await pick();
    if (!mounted || pages.isEmpty) return;
    _replace(_draft.addAll(pages, origin: PdfPageOrigin.gallery));
    _reportAdded(pages.length);
  }

  void _reportAdded(int count) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(count == 1 ? '1 page added' : '$count pages added'),
      ),
    );
  }

  // --- creation --------------------------------------------------------------

  Future<void> _create() async {
    if (_creating || !_draft.canCreate) return;

    setState(() {
      _creating = true;
      _written = 0;
      _total = _draft.pageCount;
    });

    CreatedPdf created;
    try {
      created = await _writer.create(
        pageImagePaths: _draft.pageImagePaths,
        fileName: _draft.resolvedFileName,
        onProgress: (completed, total) {
          if (!mounted) return;
          setState(() {
            _written = completed;
            _total = total;
          });
        },
      );
    } on PdfException catch (error) {
      _finishCreation();
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(error.message)));
      }
      return;
    } catch (error) {
      _finishCreation();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(PdfException.from(error).message)),
        );
      }
      return;
    }

    _finishCreation();
    if (!mounted) return;

    final result = await PdfSuccessSheet.show(
      context,
      pdf: created,
      exporter: widget.exporter,
    );
    if (!mounted || result == null) return;

    // A copy is on disk, so the flow is over: finish it rather than asking for
    // one more tap. `popUntil(isFirst)` goes Home from *either* way in — the
    // camera/gallery review and the imported-PDF page selection both end in this
    // screen, and both should land on Home, not back on a screen whose work is
    // already done.
    final messenger = ScaffoldMessenger.of(context);
    Navigator.of(context).popUntil((route) => route.isFirst);
    // Replace any earlier message (a failed attempt, for instance) rather than
    // queueing this one behind it: by the time Home is visible, the last thing
    // that happened is the save that succeeded.
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text('Saved to ${result.savedTo}')));
  }

  void _finishCreation() {
    if (!mounted) return;
    setState(() => _creating = false);
  }

  // --- view ------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final pageCount = _draft.pageCount;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Review pages'),
        actions: [
          if (pageCount > 0)
            Padding(
              padding: const EdgeInsets.only(right: AppSpacing.md),
              child: Center(
                child: Text(
                  pageCount == 1 ? '1 page' : '$pageCount pages',
                  style: theme.textTheme.labelMedium,
                ),
              ),
            ),
        ],
      ),
      body: Stack(
        children: [
          Column(
            children: [
              Expanded(
                child: pageCount == 0
                    ? _EmptyDraft(
                        onCamera: () => unawaited(_addFromCamera()),
                        onGallery: () => unawaited(_addFromGallery()),
                      )
                    : _PageGrid(
                        draft: _draft,
                        onDelete: _delete,
                        onDragTo: _dragTo,
                        onAddCamera: () => unawaited(_addFromCamera()),
                        onAddGallery: () => unawaited(_addFromGallery()),
                      ),
              ),
              _CreatePanel(
                controller: _fileName,
                resolvedName: _draft.resolvedFileName,
                hasFileName: _draft.hasFileName,
                pageCount: pageCount,
                creating: _creating,
                onChanged: (value) => _replace(_draft.withFileName(value)),
                onCreate: () => unawaited(_create()),
              ),
            ],
          ),
          if (_creating) _CreationOverlay(written: _written, total: _total),
        ],
      ),
    );
  }
}

/// Placeholder shown before the first page is added: the two ways to start.
class _EmptyDraft extends StatelessWidget {
  const _EmptyDraft({required this.onCamera, required this.onGallery});

  final VoidCallback onCamera;
  final VoidCallback onGallery;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.xxl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 76,
              height: 76,
              decoration: BoxDecoration(
                color: AppColors.tile,
                borderRadius: BorderRadius.circular(AppRadii.heroTile),
              ),
              child: const Icon(
                Icons.picture_as_pdf_outlined,
                color: AppColors.primary,
                size: 32,
              ),
            ),
            const SizedBox(height: AppSpacing.xl),
            Text('No pages yet', style: theme.textTheme.titleMedium),
            const SizedBox(height: AppSpacing.sm),
            Text(
              'Add pages from the camera or your gallery. You can reorder and '
              'delete them before creating the PDF.',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: AppSpacing.xl),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: onCamera,
                icon: const Icon(Icons.photo_camera_outlined, size: 20),
                label: const Text('Capture pages'),
              ),
            ),
            const SizedBox(height: AppSpacing.sm),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: onGallery,
                icon: const Icon(Icons.image_outlined, size: 20),
                label: const Text('Choose images'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The pages as a grid of numbered thumbnails.
///
/// Reordering is drag-and-drop: press a page, drop it on the page it should
/// take the place of. That is a deliberate choice over up/down arrows — the
/// order of a document is spatial, and the grid is where the user can see it.
class _PageGrid extends StatelessWidget {
  const _PageGrid({
    required this.draft,
    required this.onDelete,
    required this.onDragTo,
    required this.onAddCamera,
    required this.onAddGallery,
  });

  final PdfDraft draft;
  final void Function(int index) onDelete;
  final void Function(int from, int to) onDragTo;
  final VoidCallback onAddCamera;
  final VoidCallback onAddGallery;

  /// Longest edge of a decoded thumbnail, in physical pixels.
  ///
  /// A phone photo is a 12-megapixel file; decoding one per tile at full size is
  /// how a review screen runs a phone out of memory. The thumbnail is drawn at
  /// well under this, so the pixels above it were never going to be seen.
  static const int _thumbnailDecodeWidth = 320;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        // Fixed three columns on a phone, more on a tablet-width screen: the
        // tiles stay finger-sized rather than stretching.
        final columns = (constraints.maxWidth / 150).floor().clamp(2, 5);
        const spacing = AppSpacing.md;
        final tileWidth =
            (constraints.maxWidth - spacing * (columns - 1)) / columns;

        return SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.lg,
            AppSpacing.lg,
            AppSpacing.lg,
            AppSpacing.lg,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Pages', style: Theme.of(context).textTheme.titleSmall),
              const SizedBox(height: 2),
              Text(
                'Press and drag a page to change the order.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: AppSpacing.md),
              Wrap(
                spacing: spacing,
                runSpacing: spacing,
                children: [
                  for (var index = 0; index < draft.pages.length; index++)
                    SizedBox(
                      width: tileWidth,
                      child: _DraggablePageTile(
                        page: draft.pages[index],
                        index: index,
                        decodeWidth: _thumbnailDecodeWidth,
                        onDelete: () => onDelete(index),
                        onDragTo: onDragTo,
                      ),
                    ),
                ],
              ),
              const SizedBox(height: AppSpacing.xl),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: onAddCamera,
                      icon: const Icon(Icons.add_a_photo_outlined, size: 18),
                      label: const Text('Add pages'),
                    ),
                  ),
                  const SizedBox(width: AppSpacing.sm),
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: onAddGallery,
                      icon: const Icon(
                        Icons.add_photo_alternate_outlined,
                        size: 18,
                      ),
                      label: const Text('Add images'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        );
      },
    );
  }
}

/// One page: its thumbnail, its number, a delete control, and the drop target
/// that reorders it.
class _DraggablePageTile extends StatelessWidget {
  const _DraggablePageTile({
    required this.page,
    required this.index,
    required this.decodeWidth,
    required this.onDelete,
    required this.onDragTo,
  });

  final PdfPageDraft page;
  final int index;
  final int decodeWidth;
  final VoidCallback onDelete;
  final void Function(int from, int to) onDragTo;

  @override
  Widget build(BuildContext context) {
    final tile = _PageTile(
      page: page,
      index: index,
      decodeWidth: decodeWidth,
      onDelete: onDelete,
    );

    return DragTarget<int>(
      // Only an actual move is a drop: dropping a page onto itself would be a
      // no-op that still looked like work.
      onWillAcceptWithDetails: (details) => details.data != index,
      onAcceptWithDetails: (details) => onDragTo(details.data, index),
      builder: (context, candidateData, rejectedData) {
        final highlighted = candidateData.isNotEmpty;
        return LongPressDraggable<int>(
          data: index,
          // A smaller copy of the tile follows the finger, so the grid itself
          // stays legible while dragging. Only its width is constrained: a tile
          // is a thumbnail plus a caption, and a fixed height would clip one of
          // them instead of letting the tile be what it is.
          feedback: Material(
            color: Colors.transparent,
            child: Opacity(
              opacity: 0.9,
              child: SizedBox(
                width: 96,
                child: _PageTile(
                  page: page,
                  index: index,
                  decodeWidth: 128,
                  onDelete: null,
                  dragHandleOnly: true,
                ),
              ),
            ),
          ),
          childWhenDragging: Opacity(opacity: 0.35, child: tile),
          child: DecoratedBox(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(AppRadii.card),
              border: Border.all(
                color: highlighted ? AppColors.primary : Colors.transparent,
                width: 2,
              ),
            ),
            child: tile,
          ),
        );
      },
    );
  }
}

/// The visual tile: image, page number, source, delete button.
class _PageTile extends StatelessWidget {
  const _PageTile({
    required this.page,
    required this.index,
    required this.decodeWidth,
    required this.onDelete,
    this.dragHandleOnly = false,
  });

  final PdfPageDraft page;
  final int index;
  final int decodeWidth;

  /// `null` in the drag feedback, where there is no delete to offer.
  final VoidCallback? onDelete;

  final bool dragHandleOnly;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        AspectRatio(
          // Portrait, like the pages themselves. `cover` is right here: this is
          // a preview of which page it is, not of the page's exact shape.
          aspectRatio: 0.74,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(AppRadii.card),
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: AppColors.rowTint,
                border: Border.all(color: AppColors.hairline),
                borderRadius: BorderRadius.circular(AppRadii.card),
              ),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  Image.file(
                    File(page.imagePath),
                    fit: BoxFit.cover,
                    cacheWidth: decodeWidth,
                    // A page whose file has gone (a cleared camera cache) shows
                    // a broken-image placeholder rather than crashing the grid.
                    errorBuilder: (context, error, stack) => const Center(
                      child: Icon(
                        Icons.broken_image_outlined,
                        color: AppColors.muted,
                      ),
                    ),
                  ),
                  if (onDelete != null && !dragHandleOnly)
                    Positioned(
                      top: 2,
                      right: 2,
                      child: Material(
                        color: Colors.black.withValues(alpha: 0.55),
                        shape: const CircleBorder(),
                        child: InkWell(
                          customBorder: const CircleBorder(),
                          onTap: onDelete,
                          child: const Padding(
                            padding: EdgeInsets.all(5),
                            child: Icon(
                              Icons.close,
                              size: 15,
                              color: Colors.white,
                              semanticLabel: 'Delete page',
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
        const SizedBox(height: 6),
        Row(
          children: [
            Text('Page ${index + 1}', style: theme.textTheme.labelMedium),
            const SizedBox(width: 6),
            Flexible(
              child: Text(
                page.originLabel,
                style: theme.textTheme.labelSmall,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ],
    );
  }
}

/// The bottom panel: output file name and the create action.
///
/// The name field is the one thing this panel has to get exactly right, because
/// the file is named from it. It therefore:
/// * starts **empty** with an `Enter file name` hint — no pre-filled
///   `document.pdf` that could be saved by accident;
/// * uses explicit dark ink on a light fill rather than relying on the ambient
///   theme, so it stays readable on Android whatever the platform's text colour
///   resolution does;
/// * keeps **Create PDF** disabled until there is a page *and* a usable name;
/// * shows the exact name that will be written, so sanitising is never a
///   silent surprise.
class _CreatePanel extends StatelessWidget {
  const _CreatePanel({
    required this.controller,
    required this.resolvedName,
    required this.hasFileName,
    required this.pageCount,
    required this.creating,
    required this.onChanged,
    required this.onCreate,
  });

  final TextEditingController controller;

  /// The name exactly as it will be written — sanitised, with the extension.
  final String resolvedName;

  /// Whether the field holds a name that can actually be written.
  final bool hasFileName;

  final int pageCount;
  final bool creating;
  final ValueChanged<String> onChanged;
  final VoidCallback onCreate;

  /// Round corners shared by the field's four border states.
  static OutlineInputBorder _border(Color color, {double width = 1}) =>
      OutlineInputBorder(
        borderRadius: BorderRadius.circular(AppRadii.cardTile),
        borderSide: BorderSide(color: color, width: width),
      );

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final canCreate = pageCount > 0 && hasFileName && !creating;

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
              TextField(
                controller: controller,
                onChanged: onChanged,
                enabled: !creating,
                keyboardType: TextInputType.text,
                textInputAction: TextInputAction.done,
                cursorColor: AppColors.primary,
                // Explicit ink, not an inherited colour: this is the field the
                // file is named from, and it must be legible on Android.
                style: theme.textTheme.bodyLarge?.copyWith(
                  color: AppColors.ink,
                  fontWeight: FontWeight.w600,
                ),
                decoration: InputDecoration(
                  isDense: true,
                  labelText: 'File name',
                  hintText: 'Enter file name',
                  labelStyle: const TextStyle(
                    color: AppColors.ink,
                    fontWeight: FontWeight.w600,
                  ),
                  floatingLabelStyle: const TextStyle(
                    color: AppColors.primary,
                    fontWeight: FontWeight.w600,
                  ),
                  hintStyle: const TextStyle(color: AppColors.muted),
                  prefixIcon: const Icon(
                    Icons.description_outlined,
                    size: 20,
                    color: AppColors.primary,
                  ),
                  filled: true,
                  // A light fill, so the field reads as a field against the
                  // white panel instead of disappearing into it.
                  fillColor: AppColors.rowTint,
                  enabledBorder: _border(AppColors.hairline),
                  disabledBorder: _border(AppColors.hairline),
                  focusedBorder: _border(AppColors.primary, width: 2),
                ),
              ),
              const SizedBox(height: 6),
              if (hasFileName)
                // Showing the resolved name is the honest version of
                // validation: a name that had to be adjusted is visible here
                // rather than silently different from what was typed.
                Text(
                  'Will be saved as $resolvedName',
                  style: theme.textTheme.labelSmall,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                )
              else
                Text(
                  pageCount == 0
                      ? 'Add a page, then name the file.'
                      : 'Enter a file name to create the PDF.',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: AppColors.muted,
                  ),
                ),
              const SizedBox(height: AppSpacing.md),
              FilledButton.icon(
                onPressed: canCreate ? onCreate : null,
                icon: const Icon(Icons.picture_as_pdf_outlined, size: 20),
                label: Text(
                  pageCount == 0
                      ? 'Add a page first'
                      : (pageCount == 1
                            ? 'Create PDF (1 page)'
                            : 'Create PDF ($pageCount pages)'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Blocks the screen while the document is being written, and says how far
/// along it is.
///
/// Encoding page images is the slow part of creating a PDF on a phone, so the
/// screen reports the real page count rather than spinning anonymously.
class _CreationOverlay extends StatelessWidget {
  const _CreationOverlay({required this.written, required this.total});

  final int written;
  final int total;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final showProgress = total > 0;

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
                  SizedBox(
                    width: 26,
                    height: 26,
                    child: CircularProgressIndicator(
                      strokeWidth: 3,
                      value: showProgress && written > 0
                          ? written / total
                          : null,
                    ),
                  ),
                  const SizedBox(height: AppSpacing.lg),
                  Text('Creating PDF…', style: theme.textTheme.titleSmall),
                  const SizedBox(height: 4),
                  Text(
                    showProgress
                        ? 'Page $written of $total'
                        : 'Preparing pages…',
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
