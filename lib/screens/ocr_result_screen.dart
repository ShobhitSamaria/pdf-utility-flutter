import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app/app_scope.dart';
import '../ocr/data/search_launcher.dart';
import '../ocr/data/text_sharer.dart';
import '../ocr/domain/ocr_document_layout.dart';
import '../ocr/domain/ocr_document_search.dart';
import '../ocr/domain/ocr_element.dart';
import '../ocr/domain/ocr_result.dart';
import '../ocr/domain/ocr_result_index.dart';
import '../ocr/domain/ocr_script_mode.dart';
import '../ocr/domain/ocr_selection.dart';
import '../ocr/presentation/ocr_failure_notice.dart';
import '../ocr/presentation/widgets/ocr_overlay.dart';
import '../translation/domain/translated_region.dart';
import '../translation/domain/translation_language.dart';
import '../translation/domain/translation_request.dart';
import '../translation/domain/translation_service.dart';
import '../translation/domain/translation_text.dart';
import '../translation/presentation/ocr_translation_regions.dart';
import '../translation/presentation/translation_controller.dart';
import '../translation/presentation/widgets/inline_translation_panel.dart';
import '../translation/presentation/widgets/translation_overlay.dart';
import 'widgets/extracted_text_view.dart';
import 'widgets/selection_action_bar.dart';

/// Displays the original image with OCR word geometry, Google Lens-like word
/// selection, in-document search, and on-device translation **drawn in place**.
///
/// Two modes, one image
/// --------------------
/// * **OCR mode** (default) — tap a word to select it, long-press to add more.
///   Copy / Search / Share / Translate act on the selection.
/// * **Translation mode** — the translated text is painted onto the photo at
///   each source region, and a compact bar offers the full text, a language
///   change, and the way back to OCR mode.
///
/// Translation is always available: it is a normal part of this screen in every
/// build, not something a build flag or a debug mode turns on.
///
/// The photo is always the primary surface: nothing ever replaces it and nothing
/// opens a full-screen panel over it. Progress and failures appear as a small
/// chip on the image; the readable/copyable text lives behind the strip's
/// **Read text** action.
///
/// Empty results are a **state, not an error**: the image is still shown, the
/// bottom strip explains what came back and offers the other script, so a wrong
/// script choice is recoverable without going back to the camera.
class OcrResultScreen extends StatefulWidget {
  const OcrResultScreen({
    super.key,
    required this.result,
    this.searchLauncher = const SearchLauncher(),
    this.translationService,
    this.textSharer = const TextSharer(),
  });

  final OcrResult result;

  /// Injectable so tests can avoid touching the platform browser launcher.
  final SearchLauncher searchLauncher;

  /// Optional override; falls back to the service provided by [AppScope].
  final TranslationService? translationService;

  /// Injectable so tests can avoid touching the platform share sheet.
  final TextSharer textSharer;

  @override
  State<OcrResultScreen> createState() => _OcrResultScreenState();
}

/// The colour behind the photograph when it does not fill the viewport.
///
/// A near-black navy rather than a light grey: it is the app's own palette, it
/// makes a photographed white sheet the brightest thing on screen, and — the
/// practical reason — a light letterbox made it impossible to tell where the
/// document ended and the app began.
const Color _photoSurround = Color(0xFF14161D);

class _OcrResultScreenState extends State<OcrResultScreen> {
  late OcrSelection _selection = OcrSelection.empty(widget.result);

  /// Built once: the result never changes in place (re-running a script replaces
  /// the whole screen), so the flattened words and their offsets are stable.
  late final OcrDocumentSearch _search = OcrDocumentSearch(widget.result);

  final TextEditingController _searchController = TextEditingController();
  bool _searchOpen = false;
  List<OcrSearchHit> _hits = const <OcrSearchHit>[];
  int _hitIndex = 0;

  /// True while the same image is being read again with another script.
  bool _rerunning = false;

  /// Owned by this screen so an in-flight translation survives a rebuild.
  TranslationController? _translationController;
  bool _translationServiceWired = false;

  /// Whether the image is showing translated text instead of the raw photo.
  bool _showTranslation = false;

  /// Whether the inline translation section under the photo is open.
  bool _translationOpen = false;

  /// What produced the current overlay, so the full-text view can label itself.
  TranslationScope _translationScope = TranslationScope.wholePage;

  /// Zoom/pan state of the photo.
  ///
  /// Owned by the screen (not rebuilt per frame) so a pinch survives the
  /// rebuilds that selection and translation cause, and so it can be reset when
  /// a result is re-read. The overlays live *inside* the transformed subtree, so
  /// image, word highlights and translated text all move together.
  final TransformationController _zoom = TransformationController();

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_translationServiceWired) return;
    _translationServiceWired = true;
    final service =
        widget.translationService ?? AppScope.of(context).translationService;
    // English is the default target for a scanned page: the common case is
    // reading Hindi/Marathi/etc. newspaper text in English. The service's own
    // default (Hindi) is unchanged for other callers.
    final controller = TranslationController(
      service: service,
      target: TranslationLanguages.english,
    );
    controller.addListener(_onTranslationChanged);
    _translationController = controller;
  }

  @override
  void dispose() {
    _searchController.dispose();
    _zoom.dispose();
    _translationController?.removeListener(_onTranslationChanged);
    _translationController?.dispose();
    super.dispose();
  }

  /// Shows the translation as soon as there is something to draw — including
  /// when a retry finally succeeds. The inline section is opened at the same
  /// time so the text is never available only as pixels on a photo.
  void _onTranslationChanged() {
    if (!mounted) return;
    final overlay = _translationController?.overlay;
    final hasResult = overlay != null && overlay.hasRenderableRegions;
    if (!hasResult || (_showTranslation && _translationOpen)) return;
    setState(() {
      _showTranslation = true;
      _translationOpen = true;
    });
  }

  // --- selection ------------------------------------------------------------

  /// The word a drag selection started from, fixed for the whole gesture.
  OcrElement? _rangeAnchor;

  void _onTapWord(OcrElement? element) {
    setState(() {
      // Tap on empty/letterbox area clears; tap on a word replaces the
      // selection with that single word.
      _selection = element == null
          ? _selection.clear()
          : _selection.only(element);
    });
  }

  /// Long-press anchors a Lens-style range at [element] (selecting just it until
  /// the finger moves).
  void _onSelectionStart(OcrElement element) {
    setState(() {
      _rangeAnchor = element;
      _selection = _selection.only(element);
    });
  }

  /// Drag update: extend the range from the anchor to the word under the finger.
  /// A `null` word (finger off the image) leaves the current range in place.
  void _onSelectionUpdate(OcrElement? element) {
    final anchor = _rangeAnchor;
    if (anchor == null || element == null) return;
    setState(() => _selection = _selection.range(anchor, element));
  }

  void _onSelectionEnd() => _rangeAnchor = null;

  Future<void> _copySelection() async {
    final text = _selection.text;
    if (text.isEmpty) return;
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('Copied to clipboard')));
  }

  Future<void> _searchSelection() async {
    final text = _selection.text;
    if (text.isEmpty) return;
    final launched = await widget.searchLauncher.searchWeb(text);
    if (!mounted) return;
    if (!launched) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Could not open a browser')));
    }
  }

  Future<void> _shareSelection() async {
    final text = _selection.text;
    if (text.isEmpty) return;
    final shown = await widget.textSharer.shareText(
      text,
      subject: _shareSubject(),
    );
    if (!mounted || shown) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('No app available to share with')),
    );
  }

  /// A short subject for the share sheet: the first non-blank line of the page,
  /// so a shared snippet arrives with some context instead of nothing.
  String? _shareSubject() {
    for (final line in widget.result.lines) {
      final text = line.text.trim();
      if (text.isEmpty) continue;
      return text.length <= 60 ? text : '${text.substring(0, 60)}…';
    }
    return null;
  }

  // --- in-document search ---------------------------------------------------

  void _toggleSearch() {
    setState(() {
      _searchOpen = !_searchOpen;
      if (!_searchOpen) {
        _searchController.clear();
        _hits = const <OcrSearchHit>[];
        _hitIndex = 0;
      }
    });
  }

  void _onSearchChanged(String query) {
    final hits = _search.find(query);
    setState(() {
      _hits = hits;
      _hitIndex = 0;
      // A match is shown using the *existing* selection highlight, so search
      // adds no new way of drawing over the photo.
      _selection = hits.isEmpty
          ? _selection.clear()
          : _selection.clear().addAll(hits.first.elements);
    });
  }

  /// Runs the in-document find from outside the screen — used by the readable
  /// text tab's *Show on photo*, so a query typed there lights up the same
  /// matches on the photo instead of being a second, unrelated search.
  void _findInPhoto(String query) {
    _searchController.text = query;
    setState(() => _searchOpen = true);
    _onSearchChanged(query);
  }

  /// Shows the page as readable, searchable, copyable text in a sheet.
  ///
  /// This used to be the **Extracted Text** tab. Removing the tab did not remove
  /// the capability: the sheet is the same `ExtractedTextView`, so find-in-text,
  /// copy-all, the match counter and *Show on photo* all still work — there is
  /// just no longer a second reading of the page competing with the photo.
  /// The only entry point is the strip's **Read text** action: the app bar does
  /// not repeat it, so the screen keeps one photo and one set of actions.
  void _openExtractedText() {
    unawaited(
      ExtractedTextView.show(
        context,
        result: widget.result,
        onSearchOnPhoto: _findInPhoto,
      ),
    );
  }

  /// A language was changed or swapped.
  ///
  /// The overlay from the previous pair is no longer an answer to the question
  /// on screen, so it is dropped rather than left to disagree with the panel.
  void _onLanguagesChanged() {
    final controller = _translationController;
    if (controller == null) return;
    setState(() => _showTranslation = false);
    controller.reset();
  }

  /// Steps to the next/previous match, wrapping at both ends.
  void _stepSearch(int delta) {
    if (_hits.isEmpty) return;
    final next = (_hitIndex + delta) % _hits.length;
    setState(() {
      _hitIndex = next;
      _selection = _selection.clear().addAll(_hits[next].elements);
    });
  }

  // --- re-running with another script ---------------------------------------

  /// Reads the **same image** again with a different script and replaces this
  /// screen with the new result.
  ///
  /// This is the app's answer to a mixed-script page that a single recognizer
  /// got half right: rather than guessing, the user picks the script and the
  /// page is re-read. Replacing the route (instead of mutating this screen)
  /// means the selection, search state and translation overlay are all rebuilt
  /// for the new result, so no stale geometry can survive the change.
  Future<void> _rerunAs(OcrScriptMode mode) async {
    if (_rerunning) return;

    final scope = AppScope.of(context);
    final navigator = Navigator.of(context);
    final path = widget.result.sourceImage.path;

    scope.ocrScriptMode.value = mode;
    setState(() => _rerunning = true);

    try {
      final result = await scope.ocrService.recognizeImage(path, mode: mode);
      if (!mounted) return;
      unawaited(
        navigator.pushReplacement(
          MaterialPageRoute<void>(
            builder: (_) => OcrResultScreen(
              result: result,
              searchLauncher: widget.searchLauncher,
              translationService: widget.translationService,
              textSharer: widget.textSharer,
            ),
          ),
        ),
      );
    } catch (error, stackTrace) {
      if (mounted) {
        showOcrFailure(
          context,
          error,
          stackTrace: stackTrace,
          where: 'OCR re-run (${mode.name})',
        );
      }
    } finally {
      if (mounted) setState(() => _rerunning = false);
    }
  }

  // --- translation ----------------------------------------------------------

  /// Whether the recognition produced any usable text, with or without usable
  /// word geometry. Text without geometry still has to be readable, which is
  /// what the strip's **Read text** action is for; the same flag decides whether
  /// there is anything to translate.
  bool get _hasPageText =>
      TranslationText.isTranslatable(widget.result.fullText) ||
      widget.result.lines.any(
        (line) => TranslationText.isTranslatable(line.text),
      );

  /// The page text used for detection.
  ///
  /// Detection runs on the page rather than on a two-word selection: a headline
  /// plus body copy is what makes language identification decidable. The text is
  /// assembled in the document's **reading order** (see [OcrDocumentLayout]), so
  /// a two-column page identifies as one language instead of alternating between
  /// fragments of two columns. The text that is translated still comes from the
  /// existing OCR output — nothing is re-recognised.
  String get _pageText {
    final text = TranslationText.aggregate(
      OcrDocumentLayout.blocks(widget.result).map((block) => block.text),
    );
    if (text.isNotEmpty) return text;
    return widget.result.fullText;
  }

  /// Opens the inline section under the photo and preselects the source
  /// language when detection is confident.
  void _openTranslation({TranslationScope scope = TranslationScope.wholePage}) {
    final controller = _translationController;
    if (controller == null) return;
    setState(() {
      _translationOpen = true;
      _translationScope = scope;
    });
    unawaited(controller.detectSource(_pageText));
  }

  Future<void> _translateSelection() async {
    if (_selection.isEmpty) return;
    final controller = _translationController;
    if (controller == null) return;
    setState(() {
      _translationOpen = true;
      _translationScope = TranslationScope.selection;
    });
    // One detection pass on the page, not on the selection: a selected word is
    // not enough text to identify a language reliably.
    await controller.detectSource(_pageText);
    if (!mounted) return;
    await _runTranslation(
      OcrTranslationRegions.fromSelection(_selection),
      TranslationScope.selection,
    );
  }

  Future<void> _translatePage() async {
    final controller = _translationController;
    if (controller == null) return;
    setState(() {
      _translationOpen = true;
      _translationScope = TranslationScope.wholePage;
    });
    await controller.detectSource(_pageText);
    if (!mounted) return;
    await _runTranslation(
      OcrTranslationRegions.fromPage(widget.result),
      TranslationScope.wholePage,
    );
  }

  /// The panel's Translate action.
  ///
  /// A selection translation is only re-run while that selection still exists;
  /// once it has been consumed, the explicit action means the whole page.
  Future<void> _translateCurrent() =>
      _translationScope == TranslationScope.selection && _selection.isNotEmpty
      ? _translateSelection()
      : _translatePage();

  Future<void> _runTranslation(
    List<TranslationUnit> units,
    TranslationScope scope,
  ) async {
    final controller = _translationController;
    if (controller == null) return;

    if (units.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('There is nothing to translate here.')),
      );
      return;
    }

    _translationScope = scope;
    await controller.translateUnits(units, scope: scope);
    if (!mounted) return;

    final overlay = controller.overlay;
    // A failure is already shown inline by the panel; there is nothing to add
    // and nothing to claim success about.
    if (overlay == null) return;
    if (!overlay.hasRenderableRegions) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Could not place the translation on the image.'),
        ),
      );
      return;
    }

    // A translated selection has served its purpose; clear it so the result is
    // not covered by the selection highlight.
    if (scope == TranslationScope.selection && _selection.isNotEmpty) {
      setState(() => _selection = _selection.clear());
    }
  }

  /// Shows one region's **full** translation, with the text it came from.
  ///
  /// This is the other half of keeping the boxes on the photo small: a
  /// translation that did not fit its source line is clamped and ellipsized in
  /// place (see `TranslatedOverlayDeck`) instead of being grown over the
  /// neighbouring lines, and the whole thing is read here on tap.
  void _openRegionTranslation(TranslatedRegion region) {
    final target = _translationController?.target;
    final messenger = ScaffoldMessenger.of(context);

    unawaited(
      showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        showDragHandle: true,
        builder: (sheetContext) => _RegionTranslationSheet(
          region: region,
          targetLabel: target?.label,
          onCopy: () {
            unawaited(
              Clipboard.setData(ClipboardData(text: region.translatedText)),
            );
            messenger.showSnackBar(
              const SnackBar(content: Text('Translation copied.')),
            );
          },
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scope = AppScope.of(context);
    final controller = _translationController;
    final hasOverlay = controller?.overlay != null;
    final hasWords = OcrResultIndex.of(
      widget.result,
    ).selectableElements.isNotEmpty;

    return Scaffold(
      appBar: AppBar(
        title: const Text('OCR Result'),
        actions: [
          IconButton(
            tooltip: _searchOpen ? 'Close search' : 'Find in text',
            // The matches are highlighted on the photo, so asking for them
            // means the photo is where the user is.
            onPressed: hasWords ? _toggleSearch : null,
            icon: Icon(_searchOpen ? Icons.search_off : Icons.search),
          ),
          // Translation is a normal, always-available action — never gated by a
          // build flag or a debug mode. It opens the inline section under the
          // photo; the section's own **Translate** button starts the work, so
          // the user always sees (and can correct) the language pair first.
          IconButton(
            tooltip: 'Translate',
            onPressed: _hasPageText ? () => _openTranslation() : null,
            icon: const Icon(Icons.g_translate),
          ),
          ValueListenableBuilder<OcrScriptMode>(
            valueListenable: scope.ocrScriptMode,
            builder: (context, mode, _) => _ScriptMenu(
              current: mode,
              busy: _rerunning,
              onSelected: (selected) => unawaited(_rerunAs(selected)),
            ),
          ),
          IconButton(
            tooltip: 'Toggle OCR geometry (debug)',
            onPressed: () =>
                scope.debugGeometry.value = !scope.debugGeometry.value,
            icon: const Icon(Icons.grid_on_outlined),
          ),
        ],
      ),
      // One surface, one reading: the photo. Translation and the readable text
      // are inline/sheets rather than tabs, so nothing on this screen is a
      // second, competing view of the same recognition.
      body: Column(
        children: [
          if (_rerunning) const LinearProgressIndicator(minHeight: 2),
          Expanded(
            child: _buildImage(
              scope,
              controller,
              hasOverlay: hasOverlay,
              hasWords: hasWords,
            ),
          ),
        ],
      ),
    );
  }

  /// The photo with word geometry, selection, find-on-photo, the optional
  /// translation drawn in place, and — directly beneath it — the inline
  /// translation section.
  ///
  /// The same stack, the same coordinate mapper (one overlay builds it, so both
  /// layers cannot disagree about where a word is) and the same bars as before;
  /// removing the tabs did not rewrite any of the OCR surface.
  Widget _buildImage(
    AppScope scope,
    TranslationController? controller, {
    required bool hasOverlay,
    required bool hasWords,
  }) {
    return Column(
      children: [
        if (_searchOpen)
          _SearchBar(
            controller: _searchController,
            matchCount: _hits.length,
            currentMatch: _hits.isEmpty ? 0 : _hitIndex + 1,
            onChanged: _onSearchChanged,
            onPrevious: _hits.isEmpty ? null : () => _stepSearch(-1),
            onNext: _hits.isEmpty ? null : () => _stepSearch(1),
            onClose: _toggleSearch,
          ),
        Expanded(
          // The whole surface is zoomable, and the overlays are *inside* this
          // transform rather than beside it: what is drawn, what is tapped and
          // what is translated therefore share one transform by construction.
          // That is what keeps a magnified page aligned — a separately scaled
          // overlay would drift off the words by exactly the zoom factor.
          // Zoom is **pinch and pan only**, deliberately. A double-tap handler
          // wrapped around this viewer was tried and removed: a parent
          // double-tap recognizer holds the gesture arena long enough that the
          // child's tap never resolves, and word selection stopped working
          // entirely (11 screen tests caught it). Pinch/zoom covers the need —
          // reading small print on a landscape page — without stealing taps.
          child: InteractiveViewer(
            transformationController: _zoom,
            minScale: 1,
            maxScale: 5,
            // Panning is what makes a landscape page usable on a portrait
            // phone: at fit scale the text is small, and the reader has to be
            // able to move to the part they are reading.
            panEnabled: true,
            scaleEnabled: true,
            child: Stack(
              fit: StackFit.expand,
              children: [
                // A deep, neutral surround instead of a white page margin: the
                // photographed sheet becomes the bright object on screen (the
                // Lens read), with the letterbox bands no longer reading as part
                // of the app's white surface. It is a backdrop only — the image,
                // its aspect ratio and every OCR coordinate are unchanged.
                ColoredBox(
                  color: _photoSurround,
                  child: ValueListenableBuilder<bool>(
                    valueListenable: scope.debugGeometry,
                    builder: (context, debug, _) => OcrOverlay(
                      result: widget.result,
                      selection: _selection,
                      debugGeometry: debug,
                      onElementTap: _onTapWord,
                      onSelectionStart: _onSelectionStart,
                      onSelectionUpdate: _onSelectionUpdate,
                      onSelectionEnd: _onSelectionEnd,
                    ),
                  ),
                ),
                if (controller != null)
                  ListenableBuilder(
                    listenable: controller,
                    builder: (context, _) {
                      final overlay = controller.overlay;
                      if (!_showTranslation || overlay == null) {
                        return const SizedBox.shrink();
                      }
                      // Interactive, but only over the translated boxes:
                      // everywhere else the taps fall straight through to the
                      // OCR layer, so word selection keeps working and the
                      // whole surface is back as soon as translation is turned
                      // off ("Show original").
                      return TranslationOverlay(
                        overlay: overlay,
                        imageWidth: widget.result.sourceImage.width,
                        imageHeight: widget.result.sourceImage.height,
                        onRegionTap: _openRegionTranslation,
                        // A page that could not hold every translation says so,
                        // and the notice reopens the inline section, where every
                        // line is readable as text.
                        onOverflowTap: () => _openTranslation(),
                      );
                    },
                  ),
              ],
            ),
          ),
        ),
        // The translation section sits **under** the photo, never in place of
        // it: the source words and the translated result stay visible together.
        if (controller != null && _translationOpen)
          InlineTranslationPanel(
            controller: controller,
            hasSourceText: _hasPageText,
            showOnPhoto: _showTranslation,
            onTranslate: () => unawaited(_translateCurrent()),
            onShowOnPhotoChanged: (value) =>
                setState(() => _showTranslation = value),
            onLanguagesChanged: _onLanguagesChanged,
            onClose: () => setState(() => _translationOpen = false),
          ),
        if (_selection.isNotEmpty)
          SelectionActionBar(
            selectedText: _selection.text,
            wordCount: _selection.length,
            onShare: () => unawaited(_shareSelection()),
            onCopy: _copySelection,
            onSearch: _searchSelection,
            onTranslate: () => unawaited(_translateSelection()),
            onClear: () => setState(() => _selection = _selection.clear()),
          )
        else if (!_translationOpen)
          // A read that found no words is a state, not an error: the photo
          // stays on screen and the strip offers the other script. A read that
          // produced text but no usable word geometry still gets the summary,
          // because its **Read text** action is the only way to see that text.
          _hasPageText
              ? _ResultSummary(
                  result: widget.result,
                  onReadText: _openExtractedText,
                  onTranslate: hasOverlay || _hasPageText
                      ? () => _openTranslation()
                      : null,
                )
              : ValueListenableBuilder<OcrScriptMode>(
                  valueListenable: scope.ocrScriptMode,
                  builder: (context, mode, _) => _EmptyResultNotice(
                    triedMode: mode,
                    busy: _rerunning,
                    onRetryWith: (selected) => unawaited(_rerunAs(selected)),
                  ),
                ),
      ],
    );
  }
}

/// App-bar menu that shows which script produced this result and re-reads the
/// same image with another one.
///
/// "Mixed" is presented as an experiment, not a fix: it runs the page through
/// both recognizers and merges the two readings, which roughly doubles the time
/// and whose accuracy is still unmeasured.
class _ScriptMenu extends StatelessWidget {
  const _ScriptMenu({
    required this.current,
    required this.busy,
    required this.onSelected,
  });

  final OcrScriptMode current;
  final bool busy;
  final ValueChanged<OcrScriptMode> onSelected;

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<OcrScriptMode>(
      tooltip: 'Text script',
      enabled: !busy,
      initialValue: current,
      onSelected: onSelected,
      icon: const Icon(Icons.language),
      itemBuilder: (context) => [
        for (final mode in OcrScriptMode.values)
          PopupMenuItem<OcrScriptMode>(
            value: mode,
            child: ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              title: Text(mode.label),
              subtitle: Text(mode.description),
              trailing: mode == current ? const Icon(Icons.check) : null,
            ),
          ),
      ],
    );
  }
}

/// In-document find bar: query field, match counter, previous/next, close.
class _SearchBar extends StatelessWidget {
  const _SearchBar({
    required this.controller,
    required this.matchCount,
    required this.currentMatch,
    required this.onChanged,
    required this.onPrevious,
    required this.onNext,
    required this.onClose,
  });

  final TextEditingController controller;

  /// Total matches in the document.
  final int matchCount;

  /// 1-based position of the match currently shown (`0` when there are none).
  final int currentMatch;

  final ValueChanged<String> onChanged;
  final VoidCallback? onPrevious;
  final VoidCallback? onNext;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Material(
      color: theme.colorScheme.surfaceContainerHighest,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 6, 4, 6),
        child: Row(
          children: [
            Expanded(
              child: TextField(
                controller: controller,
                autofocus: true,
                onChanged: onChanged,
                textInputAction: TextInputAction.search,
                decoration: const InputDecoration(
                  isDense: true,
                  border: InputBorder.none,
                  hintText: 'Find in this text',
                ),
              ),
            ),
            const SizedBox(width: 8),
            Text(
              matchCount == 0 ? 'No matches' : '$currentMatch / $matchCount',
              style: theme.textTheme.labelMedium,
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

/// Shown when the engine answered successfully but found no words.
///
/// This is a state, not a failure: the most common cause is the wrong script or
/// a photo that is blurred, tilted or dark — all of which the user can act on,
/// which is why the other scripts are offered inline and the image stays on
/// screen behind this strip.
class _EmptyResultNotice extends StatelessWidget {
  const _EmptyResultNotice({
    required this.triedMode,
    required this.busy,
    required this.onRetryWith,
  });

  final OcrScriptMode triedMode;
  final bool busy;
  final ValueChanged<OcrScriptMode> onRetryWith;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final alternatives = OcrScriptMode.values
        .where((mode) => mode != triedMode)
        .toList();

    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Icon(
                  Icons.search_off,
                  size: 20,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
                const SizedBox(width: 8),
                Text('No text found', style: theme.textTheme.titleSmall),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              'The image was read, but no words came back. That usually means '
              'the photo is blurred, tilted or dark — or the text is in a '
              'script that was not selected.',
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 10),
            Text(
              'Tried: ${triedMode.label}',
              style: theme.textTheme.labelSmall,
            ),
            const SizedBox(height: 4),
            Wrap(
              spacing: 8,
              runSpacing: 4,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                for (final mode in alternatives)
                  OutlinedButton(
                    onPressed: busy ? null : () => onRetryWith(mode),
                    child: Text('Try ${mode.label}'),
                  ),
                TextButton(
                  onPressed: busy
                      ? null
                      : () => Navigator.of(context).maybePop(),
                  child: const Text('Choose another image'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// One translated region, in full: the translation and the words it replaced.
///
/// Opened by tapping a box on the photo. Keeping it here — rather than letting
/// the box itself grow over its neighbours — is what keeps a dense page legible.
class _RegionTranslationSheet extends StatelessWidget {
  const _RegionTranslationSheet({
    required this.region,
    this.targetLabel,
    required this.onCopy,
  });

  final TranslatedRegion region;

  /// Language the region was translated into, when it is known.
  final String? targetLabel;

  final VoidCallback onCopy;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final label = targetLabel;

    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              label == null ? 'Translation' : 'Translation ($label)',
              style: theme.textTheme.titleMedium,
            ),
            const SizedBox(height: 12),
            // Long translations scroll instead of pushing the actions off
            // screen; the text stays selectable so it can be copied by hand.
            Flexible(
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Translated',
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: 2),
                    SelectableText(
                      region.translatedText,
                      style: theme.textTheme.bodyLarge,
                    ),
                    const SizedBox(height: 16),
                    Text(
                      'Original',
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: 2),
                    SelectableText(
                      region.sourceText,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 20),
            Row(
              children: [
                FilledButton.icon(
                  onPressed: onCopy,
                  icon: const Icon(Icons.copy_all_outlined),
                  label: const Text('Copy translation'),
                ),
                const SizedBox(width: 8),
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('Close'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// Bottom info strip shown when nothing is selected and translation is off.
class _ResultSummary extends StatelessWidget {
  const _ResultSummary({
    required this.result,
    required this.onReadText,
    this.onTranslate,
  });

  final OcrResult result;

  /// Opens the readable text view. Always present — the photo with boxes on it
  /// is not always the easiest thing to read.
  final VoidCallback onReadText;

  /// Opens the inline translation section under the photo.
  final VoidCallback? onTranslate;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            // One quiet fact instead of an engine/dimensions/timing readout:
            // the photo above is the result, and the numbers were never the
            // point of this screen. Per-run diagnostics still live in the
            // translation diagnostics screen and the OCR log.
            Text(
              '${result.elements.length} words',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Wrap(
                spacing: 8,
                runSpacing: 4,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  TextButton.icon(
                    onPressed: onReadText,
                    icon: const Icon(Icons.notes_outlined, size: 18),
                    label: const Text('Read text'),
                  ),
                  if (onTranslate != null)
                    TextButton.icon(
                      onPressed: onTranslate,
                      icon: const Icon(Icons.translate_outlined, size: 18),
                      label: const Text('Translate'),
                    ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                'Tap a word to select it, or press and drag to select several.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
