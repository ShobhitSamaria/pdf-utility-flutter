import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../app/app_brand.dart';
import '../app/app_scope.dart';
import '../app/app_theme.dart';
import '../benchmark/presentation/benchmark_screen.dart';
import '../ocr/data/image_source_service.dart';
import '../ocr/domain/ocr_script_mode.dart';
import '../ocr/domain/ocr_service.dart';
import '../pdf/domain/pdf_creation.dart';
import '../pdf/domain/pdf_page_draft.dart';
import '../pdf/presentation/pdf_capture_screen.dart';
import '../pdf/presentation/pdf_import_screen.dart';
import '../pdf/presentation/pdf_review_screen.dart';
import 'extract_text_screen.dart';
import 'ocr_flow_screen.dart';
import 'widgets/app_bottom_sheet.dart';

/// Which source the `Create PDF` sheet was opened for.
enum _CreatePdfSource { camera, gallery }

/// Home — two choices, in priority order.
///
/// `OCR Scanner` is the product: a filled card at the top, one tap to the
/// source question and straight into the recogniser. `Create PDF` sits under it
/// as a quieter card, because a document is a by-product of a scan, not the
/// reason to open the app.
///
/// Everything else — importing a PDF, the searchable-PDF conversion, the OCR
/// benchmark — still exists and is still wired the same way; it is simply not
/// competing for the first screen. The script override moved into Settings,
/// where the header icon already led.
///
/// The reading itself is unchanged: the camera, the photo picker, the PDF
/// importer and the recogniser call are the same objects and the same calls as
/// before this screen was reduced.
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

  // --- OCR Scanner ------------------------------------------------------------

  /// Asks which source to read from, then runs that source's existing flow.
  Future<void> _openExtractText() async {
    final source = await Navigator.of(context).push<ExtractTextSource>(
      MaterialPageRoute<ExtractTextSource>(
        builder: (_) => const ExtractTextScreen(),
      ),
    );
    if (!mounted || source == null) return;

    switch (source) {
      case ExtractTextSource.camera:
      case ExtractTextSource.gallery:
        await _openOcrFlow(source);
      case ExtractTextSource.importPdf:
        await _openPdfImport();
    }
  }

  /// Runs the chosen image source inside a route that stays above Home.
  ///
  /// Keeping the flow on its own route is what removes the Home flash: the
  /// camera or picker is pushed over [OcrFlowScreen], and the completed read
  /// replaces that screen, so Home is never the visible screen in between.
  Future<void> _openOcrFlow(ExtractTextSource source) =>
      Navigator.of(context).push<void>(
        MaterialPageRoute<void>(
          builder: (_) => OcrFlowScreen(
            source: source,
            capturePage: widget.capturePage,
            pickFromGallery: widget.pickFromGallery,
          ),
        ),
      );

  /// Imports a PDF and reads it.
  ///
  /// The import screen owns that flow end to end — picking, page selection and
  /// the recognition run — because it is the only screen that knows which page
  /// is on screen, and therefore which file to read.
  Future<void> _openPdfImport() async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) =>
            const PdfImportScreen(autoPick: true, convertOnPick: true),
      ),
    );
  }

  // --- Create PDF -------------------------------------------------------------

  /// Camera or gallery? Both go to the existing PDF creation flow; only the
  /// source of the pages differs.
  Future<void> _openCreatePdfSheet() async {
    final source = await showAppActionSheet<_CreatePdfSource>(
      context: context,
      title: 'Create PDF',
      actions: const <SheetAction<_CreatePdfSource>>[
        SheetAction<_CreatePdfSource>(
          value: _CreatePdfSource.camera,
          icon: Icons.photo_camera_outlined,
          title: 'Camera',
          subtitle: 'Capture one or more pages',
        ),
        SheetAction<_CreatePdfSource>(
          value: _CreatePdfSource.gallery,
          icon: Icons.photo_library_outlined,
          title: 'Gallery',
          subtitle: 'Combine images into a PDF',
        ),
      ],
    );
    if (!mounted || source == null) return;

    switch (source) {
      case _CreatePdfSource.camera:
        await _createPdfFromCamera();
      case _CreatePdfSource.gallery:
        await _createPdfFromGallery();
    }
  }

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

  /// Choose images → Create PDF: pick several at once, then review them.
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
  /// Now the only way in, from the header icon: the `Script: Auto` footer is
  /// gone, because it duplicated this sheet and read as a dead label.
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
                    AppSpacing.xxl,
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        width: 88,
                        height: 88,
                        decoration: BoxDecoration(
                          color: AppColors.tile,
                          borderRadius: BorderRadius.circular(
                            AppRadii.heroTile,
                          ),
                        ),
                        child: const Center(child: _ScanGlyph()),
                      ),
                      const SizedBox(height: AppSpacing.xxl),
                      Text(
                        'Your documents,\nready to use.',
                        textAlign: TextAlign.center,
                        style: Theme.of(context).textTheme.headlineMedium,
                      ),
                      const SizedBox(height: AppSpacing.md),
                      Text(
                        'Scan, extract text and translate.\nAll in one place.',
                        textAlign: TextAlign.center,
                        style: Theme.of(context).textTheme.bodyMedium,
                      ),
                      const SizedBox(height: AppSpacing.xxl),
                      _HomeOptionCard(
                        key: const Key('home-extract-text'),
                        icon: Icons.text_snippet_outlined,
                        title: 'OCR Scanner',
                        subtitle: 'Scan photos or PDFs to extract text.',
                        primary: true,
                        onTap: _openExtractText,
                      ),
                      const SizedBox(height: AppSpacing.md),
                      _HomeOptionCard(
                        key: const Key('home-create-pdf'),
                        icon: Icons.picture_as_pdf_outlined,
                        title: 'Create PDF',
                        subtitle: 'Create PDF using camera or gallery images.',
                        primary: false,
                        onTap: _openCreatePdfSheet,
                      ),
                    ],
                  ),
                ),
              ),
            ),
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
          Image.asset(
            'assets/branding/logo_mark.png',
            width: 26,
            height: 26,
            filterQuality: FilterQuality.high,
            excludeFromSemantics: true,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              AppBrand.name,
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

/// One of the two Home choices.
///
/// The primary card is filled with the brand navy; the secondary one is a
/// hairline card on the page. Same shape, same icon tile, same tap target — the
/// hierarchy is carried by surface and weight, not by a different component.
class _HomeOptionCard extends StatelessWidget {
  const _HomeOptionCard({
    super.key,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.primary,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final bool primary;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    final foreground = primary ? Colors.white : AppColors.ink;
    final secondaryInk = primary ? Colors.white70 : AppColors.muted;

    return Material(
      color: primary ? AppColors.primary : AppColors.surface,
      borderRadius: BorderRadius.circular(AppRadii.card),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(AppRadii.card),
        child: Container(
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.lg,
            vertical: 18,
          ),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(AppRadii.card),
            border: primary ? null : Border.all(color: AppColors.hairline),
          ),
          child: Row(
            children: [
              Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(
                  color: primary ? Colors.white24 : AppColors.tile,
                  borderRadius: BorderRadius.circular(AppRadii.cardTile),
                ),
                child: Icon(
                  icon,
                  color: primary ? Colors.white : AppColors.primary,
                  size: 24,
                ),
              ),
              const SizedBox(width: AppSpacing.lg),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      title,
                      style: theme.textTheme.titleMedium?.copyWith(
                        color: foreground,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      subtitle,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: secondaryInk,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: AppSpacing.sm),
              Icon(
                Icons.chevron_right,
                size: 22,
                color: primary ? Colors.white70 : AppColors.muted,
              ),
            ],
          ),
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
            // App identity, so Settings doubles as the About screen. Kept at
            // the bottom and out of the way; the tagline lives here and on the
            // splash rather than on every screen.
            const SizedBox(height: AppSpacing.lg),
            const Divider(),
            const SizedBox(height: AppSpacing.md),
            Row(
              children: [
                Image.asset(
                  'assets/branding/logo_mark.png',
                  width: 36,
                  height: 36,
                  filterQuality: FilterQuality.high,
                  excludeFromSemantics: true,
                ),
                const SizedBox(width: AppSpacing.md),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(AppBrand.name, style: theme.textTheme.titleSmall),
                      const SizedBox(height: 2),
                      Text(
                        AppBrand.tagline,
                        style: theme.textTheme.bodySmall,
                      ),
                      const SizedBox(height: 2),
                      Text(
                        'Version ${AppBrand.version}',
                        style: theme.textTheme.labelSmall,
                      ),
                    ],
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
