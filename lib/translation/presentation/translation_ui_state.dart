import '../domain/translation_exception.dart';
import '../domain/translation_model_state.dart';
import '../domain/translation_result.dart';

/// What the translation panel is currently showing.
///
/// A sealed hierarchy so the UI can pattern-match exhaustively and can never
/// render a half-state (e.g. "loading" with no phase, or "success" with no
/// result).
sealed class TranslationUiState {
  const TranslationUiState();
}

/// Nothing has been requested yet.
final class TranslationIdle extends TranslationUiState {
  const TranslationIdle();
}

/// A translation is running.
final class TranslationInProgress extends TranslationUiState {
  const TranslationInProgress({
    required this.phase,
    this.languageLabel,
    this.completed,
    this.total,
  });

  final TranslationPhase phase;

  /// Human-readable language the current phase applies to, if any.
  final String? languageLabel;

  /// Regions finished / total, when translating a batch of image regions.
  final int? completed;
  final int? total;

  /// Whether a progress figure is meaningful for this tick: a batch of more
  /// than one region with at least one finished.
  ///
  /// A single region has no progress worth reporting, and the batch's opening
  /// tick (a total but nothing done yet) would only read "0%" — both report
  /// `null` and the UI falls back to an indeterminate bar.
  bool get hasCounter => completed != null && total != null && total! > 1;

  /// How far the batch has got, **0–100**, or `null` when there is nothing
  /// meaningful to report (see [hasCounter]).
  ///
  /// `((completed / total) * 100).round()` — the same figure the banner prints
  /// and the fraction the progress bar is drawn at.
  int? get percentage {
    if (!hasCounter) return null;
    return ((completed! / total!) * 100).round().clamp(0, 100).toInt();
  }

  /// [percentage] as a 0–1 value for a determinate progress indicator.
  double? get progress {
    final value = percentage;
    return value == null ? null : value / 100;
  }

  /// Friendly, internals-free status line.
  ///
  /// Note what is deliberately absent: no "downloading 30 MB", no model names,
  /// no ML Kit vocabulary — and no "10 of 29", which reads like a build log.
  /// Progress is expressed as a percentage because that is what the progress
  /// bar beside it is showing.
  String get message => switch (phase) {
    TranslationPhase.starting => 'Starting…',
    TranslationPhase.detectingLanguage => 'Detecting language…',
    TranslationPhase.preparingModel =>
      'Preparing ${languageLabel ?? 'translation'}…',
    TranslationPhase.translating =>
      hasCounter ? 'Translating… $percentage%' : 'Translating…',
  };
}

/// A translation finished.
final class TranslationSuccess extends TranslationUiState {
  const TranslationSuccess(this.result);

  final TranslationResult result;
}

/// A translation failed; [message] is already user-safe.
final class TranslationFailure extends TranslationUiState {
  const TranslationFailure({
    required this.message,
    this.retryable = true,
    this.details,
    this.kind,
  });

  final String message;

  /// Whether offering a "Try again" action makes sense.
  final bool retryable;

  /// Why it failed, when the service knows.
  ///
  /// The UI uses this to recover rather than merely apologise: a
  /// [TranslationErrorKind.detectionFailed] failure means the next useful
  /// action is picking a source language, not retrying the same automatic
  /// request.
  final TranslationErrorKind? kind;

  /// Raw diagnostic text (native exception code/message/details). Never shown as
  /// the headline — only behind a debug-only "Details" view so the real cause is
  /// recoverable on-device.
  final String? details;
}
