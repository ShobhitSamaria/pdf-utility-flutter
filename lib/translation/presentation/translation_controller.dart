import 'package:flutter/foundation.dart';

import '../domain/translated_region.dart';
import '../domain/translation_exception.dart';
import '../domain/translation_language.dart';
import '../domain/translation_model_state.dart';
import '../domain/translation_request.dart';
import '../domain/translation_service.dart';
import '../translation_log.dart';
import 'translation_ui_state.dart';

/// Drives the translation UI for one screen.
///
/// Uses plain [ChangeNotifier] (Flutter SDK only — no state-management package)
/// so the flow is unit-testable without pumping widgets, and so the widgets are
/// thin, dumb views over [state] / [overlay].
///
/// The controller owns the language *choices*; the caller owns the *text* and
/// the OCR geometry (as [TranslationUnit]s).
class TranslationController extends ChangeNotifier {
  TranslationController({
    required this.service,
    TranslationLanguage? source,
    TranslationLanguage? target,
  }) : _source =
           source ??
           service.sourceLanguages.firstWhere(
             (language) => language.isAuto,
             orElse: () => TranslationLanguages.auto,
           ),
       _target = target ?? service.defaultTargetLanguage;

  final TranslationService service;

  TranslationLanguage _source;
  TranslationLanguage _target;
  TranslationUiState _state = const TranslationIdle();
  TranslationRequest? _lastRequest;
  List<TranslationUnit>? _lastUnits;
  TranslationScope? _lastScope;
  TranslatedOverlay? _overlay;
  TranslationLanguage? _detectedSource;
  bool _detectingSource = false;
  bool _sourceChosenByUser = false;
  bool _disposed = false;

  /// Selected source language (may be auto-detect).
  TranslationLanguage get source => _source;

  /// Selected target language. Defaults to Hindi.
  TranslationLanguage get target => _target;

  TranslationUiState get state => _state;

  /// The translated regions currently drawn over the image, if any.
  ///
  /// Survives a language change and a re-run, so the photo keeps showing the
  /// previous translation while a new one is being produced instead of
  /// flickering back to the original.
  TranslatedOverlay? get overlay => _overlay;

  /// Source options offered by the service, auto-detect first.
  List<TranslationLanguage> get sourceOptions => service.sourceLanguages;

  /// Target options offered by the service.
  List<TranslationLanguage> get targetOptions => service.targetLanguages;

  /// The request behind the current result/failure, if any.
  TranslationRequest? get lastRequest => _lastRequest;

  /// The regions behind the current overlay, if any (used by [rerun]).
  List<TranslationUnit>? get lastUnits => _lastUnits;

  /// Whether a translation is currently running.
  bool get isBusy => _state is TranslationInProgress;

  /// The language auto-detection proposed, if it found one.
  ///
  /// Kept separately from [source] so the UI can say "Detected Hindi" even after
  /// the detection result has become the selected source (which is what makes
  /// the request explicit and skips a second detection inside the service).
  TranslationLanguage? get detectedSource => _detectedSource;

  /// Whether a detection pass is in flight. The inline Translate action waits
  /// for it rather than starting a second, competing auto-detect.
  bool get detectingSource => _detectingSource;

  /// Whether the user picked a language themselves.
  ///
  /// An explicit choice is never second-guessed: [detectSource] becomes a no-op
  /// and the service receives a concrete source, so it does not run language
  /// identification either.
  bool get sourceChosenByUser => _sourceChosenByUser;

  /// Detects the language of [text] and preselects it, unless the user has
  /// already chosen a source.
  ///
  /// Detection is advisory and never throws: when it fails the source stays
  /// [TranslationLanguages.auto] and the UI offers a manual choice. The detected
  /// language, when found, is committed to [source] so the eventual translation
  /// request is explicit and detection runs at most once.
  Future<void> detectSource(String text) async {
    if (_disposed || _sourceChosenByUser || !_source.isAuto) return;
    if (text.trim().isEmpty) return;

    _detectingSource = true;
    notifyListeners();

    TranslationLanguage? detected;
    try {
      detected = await service.detectSource(text);
    } catch (error) {
      _log('detectSource failed: $error');
      detected = null;
    }
    if (_disposed) return;

    _detectingSource = false;
    if (detected != null && !_sourceChosenByUser) {
      _detectedSource = detected;
      _source = detected;
      // A recognised page can already be in the default target language. Then
      // the pair would be a no-op, so the target falls back to the service's
      // default (Hindi) rather than presenting a disabled Translate button.
      if (_source.code == _target.code) {
        final fallback = service.defaultTargetLanguage;
        if (fallback.code != _source.code) _target = fallback;
      }
    }
    notifyListeners();
  }

  /// Changes the source language. The displayed *state* is cleared because it
  /// describes the old configuration; the on-image overlay is kept (see
  /// [overlay]) so nothing flashes away mid-session.
  ///
  /// Choosing a concrete language marks the choice as **manual**, which disables
  /// further auto-detection. Choosing [TranslationLanguages.auto] explicitly
  /// hands control back to detection.
  void selectSource(TranslationLanguage language) {
    if (language.code == _source.code) return;
    _source = language;
    _sourceChosenByUser = !language.isAuto;
    if (language.isAuto) _detectedSource = null;
    _clearResult();
  }

  /// Changes the target language, clearing the stale state but keeping the
  /// overlay visible until the re-run replaces it.
  void selectTarget(TranslationLanguage language) {
    if (language.code == _target.code) return;
    _target = language;
    _clearResult();
  }

  /// Translates a single block of text using the currently selected languages.
  Future<void> translate({
    required String text,
    TranslationScope scope = TranslationScope.selection,
  }) => _run(
    TranslationRequest(
      text: text,
      source: _source,
      target: _target,
      scope: scope,
    ),
  );

  /// Translates several image regions at once, producing the on-image overlay.
  ///
  /// Each unit keeps its own OCR rectangle, so the result can be painted back
  /// onto the region it came from.
  Future<void> translateUnits(
    List<TranslationUnit> units, {
    required TranslationScope scope,
  }) async {
    _lastUnits = units;
    _lastScope = scope;
    _lastRequest = null;
    // A distinct "just started" phase, so the UI never shows an idle action
    // while the service is still warming up.
    _set(const TranslationInProgress(phase: TranslationPhase.starting));

    try {
      final overlay = await service.translateRegions(
        units,
        source: _source,
        target: _target,
        onProgress: _onProgress,
      );
      _overlay = overlay;
      _set(TranslationSuccess(overlay.asResult(scope)));
    } on TranslationException catch (error) {
      _fail(error);
    } catch (error, stack) {
      // Anything unexpected still becomes a friendly, retryable message — the
      // UI never shows a raw exception, but the raw cause is kept for the
      // debug "Details" view and logged.
      _failUnexpected(error, stack);
    }
  }

  /// Re-translates the most recent regions with the current languages.
  ///
  /// Does nothing when the last operation was a plain text translation.
  Future<void> rerun() async {
    final units = _lastUnits;
    final scope = _lastScope;
    if (units == null || scope == null) return;
    await translateUnits(units, scope: scope);
  }

  /// Re-runs the most recent operation (used by the retry action).
  Future<void> retry() async {
    if (_lastUnits != null) return rerun();
    final request = _lastRequest;
    if (request == null) return;
    await _run(request);
  }

  /// Returns to the initial state, dropping the result **and** the overlay.
  void reset() {
    _lastRequest = null;
    _lastUnits = null;
    _lastScope = null;
    _overlay = null;
    _set(const TranslationIdle());
  }

  Future<void> _run(TranslationRequest request) async {
    _lastRequest = request;
    _lastUnits = null;
    _lastScope = null;
    _set(const TranslationInProgress(phase: TranslationPhase.starting));

    try {
      final result = await service.translate(request, onProgress: _onProgress);
      _set(TranslationSuccess(result));
    } on TranslationException catch (error) {
      _fail(error);
    } catch (error, stack) {
      _failUnexpected(error, stack);
    }
  }

  void _fail(TranslationException error) {
    _log(
      'failed (${error.kind.name}): ${error.userMessage}\n'
      '${error.details ?? error.cause ?? ''}',
    );
    _set(
      TranslationFailure(
        message: error.userMessage,
        retryable: error.isRetryable,
        kind: error.kind,
        details:
            error.details ??
            (error.cause == null
                ? null
                : TranslationException.describe(error.cause!)),
      ),
    );
  }

  void _failUnexpected(Object error, StackTrace stack) {
    _log('failed (unexpected): $error\n$stack');
    _set(
      TranslationFailure(
        message: 'Something went wrong while translating. Please try again.',
        details: TranslationException.describe(error, stack),
      ),
    );
  }

  void _onProgress(TranslationProgress progress) {
    _set(
      TranslationInProgress(
        phase: progress.phase,
        languageLabel: progress.language?.englishName,
        completed: progress.completed,
        total: progress.total,
      ),
    );
  }

  /// Clears the transient state but keeps the overlay, so a language change can
  /// be followed by [rerun] without the image flashing empty.
  void _clearResult() {
    _lastRequest = null;
    _state = const TranslationIdle();
    notifyListeners();
  }

  void _set(TranslationUiState next) {
    if (_disposed) return;
    _state = next;
    notifyListeners();
  }

  void _log(String message) => translationLog('controller: $message');

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
