import 'translation_language.dart';

/// Availability of the on-device model for a single language.
///
/// This is the engine-independent view of ML Kit's `ModelManager` state, so the
/// UI can talk about "preparing translation" without knowing anything about
/// downloads.
enum TranslationModelStatus {
  /// Not checked yet, or the check itself failed in a non-fatal way.
  unknown,

  /// This device/engine has no model for the language at all.
  unsupported,

  /// Supported, but the model is not on the device yet (needs provisioning).
  notAvailable,

  /// The model is being provisioned right now.
  downloading,

  /// Ready to translate.
  available,

  /// The last attempt to check or provision failed.
  failed,
}

/// Immutable snapshot of one language's model state.
class TranslationModelState {
  const TranslationModelState({
    required this.language,
    required this.status,
    this.message,
  });

  const TranslationModelState.unknown(this.language)
    : status = TranslationModelStatus.unknown,
      message = null;

  const TranslationModelState.available(this.language)
    : status = TranslationModelStatus.available,
      message = null;

  final TranslationLanguage language;
  final TranslationModelStatus status;

  /// Optional diagnostic detail. Not intended for direct display.
  final String? message;

  /// Whether translation can run right now for this language.
  bool get isAvailable => status == TranslationModelStatus.available;

  /// Whether the model still has to be fetched before translating.
  bool get needsProvisioning =>
      status == TranslationModelStatus.notAvailable ||
      status == TranslationModelStatus.unknown;

  /// Whether this language cannot be used on this device at all.
  bool get isUnsupported => status == TranslationModelStatus.unsupported;

  bool get isFailed => status == TranslationModelStatus.failed;

  TranslationModelState copyWith({
    TranslationLanguage? language,
    TranslationModelStatus? status,
    String? message,
  }) => TranslationModelState(
    language: language ?? this.language,
    status: status ?? this.status,
    message: message ?? this.message,
  );

  @override
  bool operator ==(Object other) =>
      other is TranslationModelState &&
      other.language == language &&
      other.status == status &&
      other.message == message;

  @override
  int get hashCode => Object.hash(language, status, message);

  @override
  String toString() =>
      'TranslationModelState(${language.code}: ${status.name})';
}

/// The stages a translation can report while it runs.
///
/// Deliberately coarse: the UI surfaces a friendly progress line, never raw
/// download internals.
enum TranslationPhase {
  /// The request has been accepted but the engine has not reported anything
  /// yet.
  ///
  /// Emitted by the UI layer (never by the service) so that a translation which
  /// is already running can never be rendered as idle — which would let the
  /// user fire the same request twice.
  starting,

  /// Working out what language the text is in.
  detectingLanguage,

  /// Fetching the on-device model(s) needed for this pair.
  preparingModel,

  /// Running the on-device translator.
  translating,
}

/// A single progress tick emitted while a translation runs.
class TranslationProgress {
  const TranslationProgress(
    this.phase, {
    this.language,
    this.message,
    this.completed,
    this.total,
  });

  final TranslationPhase phase;

  /// The language the phase applies to (e.g. the model being prepared).
  final TranslationLanguage? language;

  /// Optional detail; UI should prefer its own friendly copy keyed off [phase].
  final String? message;

  /// How many regions of the batch have finished, when translating several at
  /// once. `null` for single-text translations.
  final int? completed;

  /// How many regions the batch contains, when translating several at once.
  final int? total;

  @override
  String toString() =>
      'TranslationProgress(${phase.name}${language == null ? '' : ', '
                '${language!.code}'}${total == null ? '' : ', '
                '${completed ?? 0}/$total'})';
}
