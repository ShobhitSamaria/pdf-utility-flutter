import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../app/app_scope.dart';
import '../app/app_theme.dart';
import '../benchmark/presentation/benchmark_screen.dart';
import '../ocr/data/image_source_service.dart';
import '../ocr/domain/ocr_script_mode.dart';
import '../ocr/domain/ocr_service.dart';
import '../ocr/presentation/ocr_failure_notice.dart';
import '../pdf/domain/pdf_creation.dart';
import '../pdf/domain/pdf_page_draft.dart';
import '../pdf/presentation/pdf_capture_screen.dart';
import '../pdf/presentation/pdf_import_screen.dart';
import '../pdf/presentation/pdf_review_screen.dart';
import 'camera_capture_screen.dart';
import 'ocr_result_screen.dart';
import 'widgets/app_bottom_sheet.dart';

/// What the user picked in a Home action sheet.
///
/// One enum for all three sheets, because `Scan document`, `Choose image` and
/// `Import PDF` offer overlapping work with different wording: the wording
/// belongs to the sheet (it is presentation), the behaviour belongs here.
enum HomeAction {
  /// Read text with the on-device recogniser — a photo, or a PDF page.
  extractText,

  /// Build a new PDF from captured or chosen pages: capture (or pick) the
  /// pages, review and reorder them, name the file, then write it.
  createPdf,
}

/// The three ways into the app, with the exact sheet each one shows.
///
/// Keeping the sheet contents in the enum means the three entry points cannot
/// drift apart: they are one component ([showAppActionSheet]) with three sets
/// of rows, exactly as the design has them.
enum _EntryPoint {
  scan(
    sheetTitle: 'Scan document',
    actionLabel: 'Scan document',
    actionIcon: Icons.photo_camera_outlined,
    actions: <SheetAction<HomeAction>>[
      SheetAction<HomeAction>(
        value: HomeAction.extractText,
        icon: Icons.text_snippet_outlined,
        title: 'Extract Text (OCR)',
        subtitle: 'Scan, copy and translate',
      ),
      SheetAction<HomeAction>(
        value: HomeAction.createPdf,
        icon: Icons.picture_as_pdf_outlined,
        title: 'Create PDF',
        subtitle: 'Capture one or more pages',
      ),
    ],
  ),

  image(
    sheetTitle: 'Choose image',
    actionLabel: 'Choose image',
    actionIcon: Icons.image_outlined,
    actions: <SheetAction<HomeAction>>[
      SheetAction<HomeAction>(
        value: HomeAction.extractText,
        icon: Icons.text_snippet_outlined,
        title: 'Extract Text',
        subtitle: 'Read text from an image',
      ),
      SheetAction<HomeAction>(
        value: HomeAction.createPdf,
        icon: Icons.picture_as_pdf_outlined,
        title: 'Create PDF',
        subtitle: 'Combine images into a PDF',
      ),
    ],
  ),

  pdf(
    sheetTitle: 'Import PDF',
    actionLabel: 'Import PDF',
    actionIcon: Icons.upload_file_outlined,
    actions: <SheetAction<HomeAction>>[
      // One action, deliberately: importing a PDF is for reading it. The
      // separate viewer and page-selection screens still exist for the flows
      // that use them, but "View PDF" is no longer offered from Home — it was
      // a second, differently-shaped way into the same document and it only
      // made the choice harder.
      SheetAction<HomeAction>(
        value: HomeAction.extractText,
        icon: Icons.text_snippet_outlined,
        title: 'Extract Text',
        subtitle: 'Choose a page to recognize',
      ),
    ],
  );

  const _EntryPoint({
    required this.sheetTitle,
    required this.actionLabel,
    required this.actionIcon,
    required this.actions,
  });

  /// Title shown at the top of the bottom sheet.
  final String sheetTitle;

  /// Label of the Home control that opens it.
  final String actionLabel;

  /// Icon of the Home control that opens it.
  final IconData actionIcon;

  /// The rows offered by this entry point's sheet.
  final List<SheetAction<HomeAction>> actions;
}

/// Home — the app's single entry screen, to the approved design
/// ([Figma `2:1119`], with the three sheets [`7:1423`, `7:1500`, `7:1577`]).
///
/// The screen is deliberately thin: it presents three ways in and asks nothing
/// else of the user. The script is **not** a question they have to answer —
/// [OcrScriptMode.auto] decides from the photo itself — so it is reduced to a
/// quiet `Script: Auto` row that opens the same settings sheet as the header's
/// sliders icon.
///
/// Nothing about *how* text is read changed here: the camera, the gallery
/// picker, the recogniser call, the elapsed-time reporting and the PDF import
/// route are the same objects and the same calls as before this redesign.
class HomeScreen extends StatefulWidget {
  const HomeScreen({
    super.key,
    this.pickFromGallery,
    this.capturePage,
    this.capturePages,
    this.pickImages,
    this.openPdfReview,
  });

  /// Gallery picker: returns the chosen image's path, or `null` when the user
  /// cancels. Injectable so a widget test never opens a platform picker.
  final Future<String?> Function()? pickFromGallery;

  /// Captures one still with the camera and returns its path, or `null` when the
  /// user backs out. Injectable so a widget test never starts a camera.
  final Future<String?> Function(BuildContext context)? capturePage;

  /// Captures a **session** of pages for a PDF and returns their paths (empty
  /// when the user backs out). Injectable, same reason as [capturePage].
  final Future<List<String>> Function(BuildContext context)? capturePages;

  /// Multi-image gallery picker for PDF creation: returns the chosen images'
  /// paths in the order they were chosen (empty when cancelled). Injectable.
  final Future<List<String>> Function()? pickImages;

  /// Opens the page-review step of PDF creation. Injectable so a widget test can
  /// assert on the pages that reach it without writing a document.
  final Future<void> Function(BuildContext context, List<PdfPageDraft> pages)?
  openPdfReview;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final ImageSourceService _imageSource = ImageSourceService();

  bool _busy = false;

  /// Ticks while a recognition call is in flight, so the progress indicator
  /// reports how long the phone has actually been working instead of spinning
  /// anonymously.
  Timer? _readingTimer;
  Duration _elapsed = Duration.zero;

  static const _tick = Duration(milliseconds: 200);

  @override
  void dispose() {
    _readingTimer?.cancel();
    super.dispose();
  }

  void _startReadingTimer() {
    _readingTimer?.cancel();
    _elapsed = Duration.zero;
    _readingTimer = Timer.periodic(_tick, (_) {
      if (!mounted) return;
      setState(() => _elapsed += _tick);
    });
  }

  void _stopReadingTimer() {
    _readingTimer?.cancel();
    _readingTimer = null;
  }

  /// Reads [imagePath] with the on-device recogniser and opens the result.
  ///
  /// Unchanged from before the redesign: the script comes from the shared
  /// [AppScope] (auto by default), failures reach the user as a sentence, and
  /// the progress ticker stops the moment the work does.
  Future<void> _runOcrOn(String? imagePath) async {
    if (imagePath == null || !mounted) return;

    final scope = AppScope.of(context);
    final navigator = Navigator.of(context);
    final mode = scope.ocrScriptMode.value;

    setState(() => _busy = true);
    _startReadingTimer();
    try {
      final result = await scope.ocrService.recognizeImage(
        imagePath,
        mode: mode,
      );
      // Stop reporting progress as soon as the work is done; the push below
      // waits for the result screen to be popped, which is not work.
      _stopReadingTimer();
      if (!mounted) return;
      setState(() => _busy = false);

      await navigator.push(
        MaterialPageRoute<void>(
          builder: (_) => OcrResultScreen(result: result),
        ),
      );
    } catch (error, stackTrace) {
      // One reporter for every OCR entry point: it keeps the original error for
      // the debug log and Details view, and shows the user a plain sentence.
      if (mounted) showOcrFailure(context, error, stackTrace: stackTrace);
    } finally {
      _stopReadingTimer();
      if (mounted && _busy) setState(() => _busy = false);
    }
  }

  // --- the three ways in -----------------------------------------------------

  Future<void> _openSheet(_EntryPoint entry) async {
    if (_busy) return;

    final action = await showAppActionSheet<HomeAction>(
      context: context,
      title: entry.sheetTitle,
      actions: entry.actions,
    );
    if (!mounted || action == null) return;

    switch (action) {
      case HomeAction.extractText:
        await _extractText(entry);
      // One "Create PDF" action, two sources: the sheet the user came from is
      // what decides whether the pages come from the camera or the gallery.
      case HomeAction.createPdf:
        switch (entry) {
          case _EntryPoint.scan:
            await _createPdfFromCamera();
          case _EntryPoint.image:
            await _createPdfFromGallery();
          case _EntryPoint.pdf:
            // Not offered by this sheet (see _EntryPoint.pdf), so nothing to do.
            break;
        }
    }
  }

  Future<void> _extractText(_EntryPoint entry) async {
    switch (entry) {
      case _EntryPoint.scan:
        await _extractTextFromCamera();
      case _EntryPoint.image:
        await _extractTextFromGallery();
      case _EntryPoint.pdf:
        await _openPdfImport();
    }
  }

  Future<void> _extractTextFromCamera() async {
    final capture =
        widget.capturePage ??
        (BuildContext context) => Navigator.of(context).push<String>(
          MaterialPageRoute<String>(
            builder: (_) => const CameraCaptureScreen(),
          ),
        );
    final path = await capture(context);
    await _runOcrOn(path);
  }

  Future<void> _extractTextFromGallery() async {
    final pick = widget.pickFromGallery ?? _imageSource.pickFromGallery;
    final path = await pick();
    await _runOcrOn(path);
  }

  /// Imports a PDF and reads it.
  ///
  /// The import screen owns that flow end to end — picking, page selection and
  /// the recognition run — because it is the only screen that knows which page
  /// is on screen, and therefore which file to read.
  Future<void> _openPdfImport() async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(builder: (_) => const PdfImportScreen()),
    );
  }

  // --- PDF creation and viewing ---------------------------------------------

  /// Scan document → Create PDF: capture a session of pages, then review them.
  Future<void> _createPdfFromCamera() async {
    final capture =
        widget.capturePages ??
        (BuildContext context) => Navigator.of(context)
            .push<List<String>>(
              MaterialPageRoute<List<String>>(
                builder: (_) => const PdfCaptureScreen(),
              ),
            )
            .then((pages) => pages ?? const <String>[]);

    final pages = await capture(context);
    if (!mounted || pages.isEmpty) return;
    await _reviewPages(pages, PdfPageOrigin.camera);
  }

  /// Choose image → Create PDF: pick several images at once, then review them.
  Future<void> _createPdfFromGallery() async {
    final pick = widget.pickImages ?? _imageSource.pickMultipleFromGallery;
    final pages = await pick();
    if (!mounted || pages.isEmpty) return;
    await _reviewPages(pages, PdfPageOrigin.gallery);
  }

  /// Hands the chosen pages to the review step, where they are ordered, named
  /// and written.
  Future<void> _reviewPages(
    List<String> imagePaths,
    PdfPageOrigin origin,
  ) async {
    final pages = <PdfPageDraft>[
      for (var index = 0; index < imagePaths.length; index++)
        PdfPageDraft(
          id: index + 1,
          imagePath: imagePaths[index],
          origin: origin,
        ),
    ];

    final openReview = widget.openPdfReview ?? _pushPdfReview;
    await openReview(context, pages);
  }

  Future<void> _pushPdfReview(BuildContext context, List<PdfPageDraft> pages) =>
      Navigator.of(context).push<CreatedPdf>(
        MaterialPageRoute<CreatedPdf>(
          builder: (_) => PdfReviewScreen(pages: pages),
        ),
      );

  // --- settings --------------------------------------------------------------

  /// Opens the settings sheet: the script choice, plus the developer tools in a
  /// debug build only.
  ///
  /// Reachable from two places on purpose — the header's sliders icon and the
  /// quiet `Script: Auto` row — because they are the same question.
  Future<void> _openSettingsSheet() async {
    final scope = AppScope.of(context);
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _SettingsSheet(
        scriptMode: scope.ocrScriptMode,
        debugGeometry: scope.debugGeometry,
        ocrService: scope.ocrService,
      ),
    );
  }

  // --- view ------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final scope = AppScope.of(context);

    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            _HomeHeader(onOpenSettings: _openSettingsSheet),
            Expanded(
              child: Center(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(
                    AppSpacing.xl,
                    AppSpacing.lg,
                    AppSpacing.xl,
                    AppSpacing.lg,
                  ),
                  child: _Hero(
                    busy: _busy,
                    elapsed: _elapsed,
                    scriptMode: scope.ocrScriptMode,
                    onOpenSheet: _openSheet,
                  ),
                ),
              ),
            ),
            _ScriptRow(mode: scope.ocrScriptMode, onTap: _openSettingsSheet),
            const SizedBox(height: AppSpacing.md),
          ],
        ),
      ),
    );
  }
}

/// Header: the app's mark, its name, and one way into settings.
class _HomeHeader extends StatelessWidget {
  const _HomeHeader({required this.onOpenSettings});

  final VoidCallback onOpenSettings;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.xl,
        AppSpacing.sm,
        AppSpacing.md,
        0,
      ),
      child: Row(
        children: [
          const Icon(
            Icons.document_scanner_outlined,
            size: 22,
            color: AppColors.primary,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              'PDF Utility',
              style: theme.textTheme.titleMedium?.copyWith(fontSize: 17),
            ),
          ),
          IconButton(
            tooltip: 'Settings',
            onPressed: onOpenSettings,
            icon: const Icon(Icons.tune, color: AppColors.primary),
          ),
        ],
      ),
    );
  }
}

/// The centred hero: glyph tile, headline, subtitle, the primary action and the
/// two quieter ones.
class _Hero extends StatelessWidget {
  const _Hero({
    required this.busy,
    required this.elapsed,
    required this.scriptMode,
    required this.onOpenSheet,
  });

  final bool busy;
  final Duration elapsed;
  final ValueNotifier<OcrScriptMode> scriptMode;
  final void Function(_EntryPoint entry) onOpenSheet;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 88,
          height: 88,
          decoration: BoxDecoration(
            color: AppColors.tile,
            borderRadius: BorderRadius.circular(AppRadii.heroTile),
          ),
          child: const Center(child: _ScanGlyph()),
        ),
        const SizedBox(height: AppSpacing.xxl),
        Text(
          'Your documents,\nready to use.',
          textAlign: TextAlign.center,
          style: theme.textTheme.headlineMedium,
        ),
        const SizedBox(height: AppSpacing.md),
        Text(
          'Scan, extract text and translate.\nAll in one place.',
          textAlign: TextAlign.center,
          style: theme.textTheme.bodyMedium,
        ),
        const SizedBox(height: AppSpacing.xxl),
        SizedBox(
          width: double.infinity,
          child: FilledButton.icon(
            onPressed: busy ? null : () => onOpenSheet(_EntryPoint.scan),
            icon: Icon(_EntryPoint.scan.actionIcon, size: 20),
            label: Text(_EntryPoint.scan.actionLabel),
          ),
        ),
        const SizedBox(height: AppSpacing.md),
        // A `Wrap`, not a `Row`: the two labels sit side by side on a normal
        // phone but must stack rather than overflow on a narrow screen or at a
        // large text scale.
        Wrap(
          alignment: WrapAlignment.center,
          spacing: AppSpacing.md,
          runSpacing: AppSpacing.xs,
          children: [
            _GhostAction(
              entry: _EntryPoint.image,
              onPressed: busy ? null : () => onOpenSheet(_EntryPoint.image),
            ),
            _GhostAction(
              entry: _EntryPoint.pdf,
              onPressed: busy ? null : () => onOpenSheet(_EntryPoint.pdf),
            ),
          ],
        ),
        if (busy) ...[
          const SizedBox(height: AppSpacing.xl),
          _ReadingProgress(elapsed: elapsed, scriptMode: scriptMode),
        ],
      ],
    );
  }
}

/// A secondary entry point: icon and label, no border, no fill.
class _GhostAction extends StatelessWidget {
  const _GhostAction({required this.entry, required this.onPressed});

  final _EntryPoint entry;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return TextButton.icon(
      onPressed: onPressed,
      icon: Icon(entry.actionIcon, size: 18),
      label: Text(entry.actionLabel),
      style: TextButton.styleFrom(
        foregroundColor: AppColors.primary,
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.sm,
          vertical: AppSpacing.sm,
        ),
        textStyle: Theme.of(context).textTheme.titleSmall,
      ),
    );
  }
}

/// The elapsed-time report while a recognition call is running.
///
/// Kept from the pre-redesign screen: it is the only evidence the user gets that
/// the phone is working, and it is the honest place to say that Auto may read
/// the page twice.
class _ReadingProgress extends StatelessWidget {
  const _ReadingProgress({required this.elapsed, required this.scriptMode});

  final Duration elapsed;
  final ValueNotifier<OcrScriptMode> scriptMode;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.lg,
        vertical: AppSpacing.md,
      ),
      decoration: BoxDecoration(
        color: AppColors.rowTint,
        borderRadius: BorderRadius.circular(AppRadii.card),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          const SizedBox(width: AppSpacing.md),
          ValueListenableBuilder<OcrScriptMode>(
            valueListenable: scriptMode,
            builder: (context, mode, _) => Text(
              'Reading text… '
              '${(elapsed.inMilliseconds / 1000).toStringAsFixed(1)} s'
              '${mode.mayReadTwice ? ' (up to two passes)' : ''}',
              style: theme.textTheme.bodySmall,
            ),
          ),
        ],
      ),
    );
  }
}

/// The bottom line: `Script: Auto`, opening the same sheet as the sliders icon.
class _ScriptRow extends StatelessWidget {
  const _ScriptRow({required this.mode, required this.onTap});

  final ValueNotifier<OcrScriptMode> mode;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return ValueListenableBuilder<OcrScriptMode>(
      valueListenable: mode,
      builder: (context, current, _) => TextButton(
        onPressed: onTap,
        style: TextButton.styleFrom(
          foregroundColor: AppColors.primary,
          minimumSize: const Size(0, 44),
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('Script: ', style: theme.textTheme.bodySmall),
            // Flexible, not fixed: a long override label (`Hindi / Devanagari`)
            // or a large text scale must ellipsize rather than overflow.
            Flexible(
              child: Text(
                current.isAuto ? 'Auto' : current.label,
                style: theme.textTheme.labelMedium,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const SizedBox(width: 2),
            const Icon(Icons.expand_more, size: 18, color: AppColors.primary),
          ],
        ),
      ),
    );
  }
}

/// The document glyph: a rounded square holding three ruled lines.
///
/// Drawn rather than imported, because the design's mark is a specific shape
/// (rounded square, three lines, middle one shorter) that no Material icon
/// matches closely.
class _ScanGlyph extends StatelessWidget {
  const _ScanGlyph();

  /// Side of the square the glyph is drawn inside, in logical pixels.
  static const double _size = 44;

  static const Color _ink = AppColors.primary;

  @override
  Widget build(BuildContext context) {
    Widget line(double width) => Container(
      width: _size * width,
      height: 2.4,
      decoration: BoxDecoration(
        color: _ink,
        borderRadius: BorderRadius.circular(2),
      ),
    );

    return SizedBox(
      width: _size,
      height: _size,
      child: DecoratedBox(
        decoration: BoxDecoration(
          border: Border.all(color: _ink, width: 2.2),
          borderRadius: BorderRadius.circular(_size * 0.3),
        ),
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              line(0.5),
              const SizedBox(height: 4),
              line(0.3),
              const SizedBox(height: 4),
              line(0.5),
            ],
          ),
        ),
      ),
    );
  }
}

/// Settings: the script choice, and — in a debug build — the developer tools.
///
/// The script selector is the same control as before the redesign (one
/// prominent automatic choice, manual overrides behind a disclosure). It moved
/// into a sheet because the Home screen should ask nothing before it can be
/// used; it was not simplified or removed, and Auto is still the default.
class _SettingsSheet extends StatefulWidget {
  const _SettingsSheet({
    required this.scriptMode,
    required this.debugGeometry,
    required this.ocrService,
  });

  final ValueNotifier<OcrScriptMode> scriptMode;
  final ValueNotifier<bool> debugGeometry;
  final OcrService ocrService;

  @override
  State<_SettingsSheet> createState() => _SettingsSheetState();
}

class _SettingsSheetState extends State<_SettingsSheet> {
  /// Whether the user has opened the override list themselves.
  bool _overridesOpen = false;

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
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text('Settings', style: theme.textTheme.titleMedium),
                ),
                IconButton(
                  tooltip: 'Close',
                  onPressed: () => Navigator.of(context).pop(),
                  icon: const Icon(Icons.close, color: AppColors.muted),
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.sm),
            ValueListenableBuilder<OcrScriptMode>(
              valueListenable: widget.scriptMode,
              builder: (context, current, _) => _ScriptSection(
                current: current,
                overridesOpen: _overridesOpen,
                onToggleOverrides: () =>
                    setState(() => _overridesOpen = !_overridesOpen),
                onSelect: (mode) => widget.scriptMode.value = mode,
              ),
            ),
            // Everything below is development-only tooling, gated on
            // [kDebugMode] so a release build carries none of it.
            //
            // The translation diagnostics screen is deliberately **not**
            // reachable from anywhere in the app: it was a test-only entry
            // point, and translation is a normal feature now. The screen and its
            // self-tests stay in the tree for the case where ML Kit itself has
            // to be isolated from the app.
            if (kDebugMode) ...[
              const SizedBox(height: AppSpacing.lg),
              const Divider(),
              const SizedBox(height: AppSpacing.md),
              Text('Developer', style: theme.textTheme.titleSmall),
              const SizedBox(height: AppSpacing.xs),
              _DebugGeometryToggle(debugGeometry: widget.debugGeometry),
              const SizedBox(height: AppSpacing.sm),
              // Measure before changing anything: this reads the real service
              // over a fixed dataset, so an accuracy or latency claim can be
              // backed by a number instead of an impression.
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) =>
                          BenchmarkScreen(ocrService: widget.ocrService),
                    ),
                  ),
                  icon: const Icon(Icons.speed_outlined),
                  label: const Text('OCR benchmark (debug)'),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Script chooser: one prominent automatic choice, plus the manual overrides
/// behind a disclosure.
///
/// The manual modes cannot be deleted — automatic detection is a heuristic (see
/// `OcrScriptDetector`) and "Mixed" is still an unmeasured experiment — but they
/// should not be the first thing a user has to reason about either.
class _ScriptSection extends StatelessWidget {
  const _ScriptSection({
    required this.current,
    required this.overridesOpen,
    required this.onToggleOverrides,
    required this.onSelect,
  });

  final OcrScriptMode current;
  final bool overridesOpen;
  final VoidCallback onToggleOverrides;
  final ValueChanged<OcrScriptMode> onSelect;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // A manual selection always keeps the override list visible, so the active
    // choice is never hidden behind a collapsed disclosure.
    final showOverrides = overridesOpen || !current.isAuto;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Text script', style: theme.textTheme.labelLarge),
        const SizedBox(height: AppSpacing.sm),
        Align(
          alignment: Alignment.centerLeft,
          child: ChoiceChip(
            label: Text(OcrScriptMode.auto.label),
            selected: current.isAuto,
            onSelected: (_) => onSelect(OcrScriptMode.auto),
          ),
        ),
        const SizedBox(height: AppSpacing.sm),
        Text(current.description, style: theme.textTheme.bodySmall),
        if (current.isAuto) ...[
          const SizedBox(height: AppSpacing.xs),
          Text(
            'Reads the page with the Latin recognizer first and only runs a '
            'second recognizer when the result is Hindi or mixed, so an '
            'English page costs nothing extra.',
            style: theme.textTheme.bodySmall?.copyWith(color: AppColors.muted),
          ),
        ],
        if (current.isMixed) ...[
          const SizedBox(height: AppSpacing.sm),
          Text(
            'Experimental: the page is read twice (Latin, then Devanagari) '
            'and the two readings are merged. Roughly twice as slow, and '
            'its accuracy has not been measured yet.',
            style: theme.textTheme.bodySmall?.copyWith(color: AppColors.muted),
          ),
        ],
        const SizedBox(height: AppSpacing.xs),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            onPressed: onToggleOverrides,
            icon: Icon(
              showOverrides ? Icons.expand_less : Icons.expand_more,
              size: 18,
            ),
            label: Text(
              showOverrides ? 'Hide script overrides' : 'Choose a script',
            ),
          ),
        ),
        if (showOverrides) ...[
          const SizedBox(height: AppSpacing.xs),
          Wrap(
            spacing: AppSpacing.sm,
            runSpacing: AppSpacing.xs,
            children: [
              for (final option in OcrScriptMode.manualModes)
                ChoiceChip(
                  label: Text(option.label),
                  selected: option == current,
                  onSelected: (_) => onSelect(option),
                ),
            ],
          ),
        ],
      ],
    );
  }
}

/// Development-only switch that turns OCR geometry visualisation on/off.
/// Starts OFF; see `AppScope.debugGeometry`.
class _DebugGeometryToggle extends StatelessWidget {
  const _DebugGeometryToggle({required this.debugGeometry});

  final ValueNotifier<bool> debugGeometry;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: debugGeometry,
      builder: (context, value, _) => SwitchListTile(
        dense: true,
        contentPadding: EdgeInsets.zero,
        value: value,
        onChanged: (v) => debugGeometry.value = v,
        title: const Text('Show OCR geometry (debug)'),
        subtitle: const Text('Off by default — draws bounding boxes'),
      ),
    );
  }
}
