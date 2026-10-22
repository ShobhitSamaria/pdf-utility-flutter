/// The seam between [TranslationEngine]'s model provisioning and whatever
/// actually talks to ML Kit's model management.
///
/// Kept separate from the engine so the provisioning strategy — how many
/// attempts, what deadlines, which native channel — is swappable and testable
/// on its own, while the engine only ever sees "is it there / get it".
///
/// Implementations MUST bound every native call they make. The Play Services
/// `Task`s behind ML Kit model management complete through listeners with no
/// timeout of their own: a `Task` that never completes leaves the Dart future
/// pending forever, which is exactly the "downloadModel(hi) never returned"
/// hang this seam exists to prevent. A caller must never be able to wait on
/// this interface indefinitely.
abstract class TranslationModelManager {
  /// Whether the on-device model for BCP-47 [code] is present right now.
  ///
  /// Cheap on a healthy device (tens of milliseconds). Implementations bound
  /// it and throw if the native side does not answer in time.
  Future<bool> isModelDownloaded(String code);

  /// Provisions the on-device model for BCP-47 [code].
  ///
  /// Returns true when the model is on the device after the call (downloaded
  /// by it, or already present). Throws when every bounded attempt has failed —
  /// carrying the per-attempt outcomes so a diagnostic can name the exact
  /// native failure instead of a generic sentence.
  Future<bool> downloadModel(String code);
}
