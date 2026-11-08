/// The product's public identity.
///
/// Kept in one place so the name and tagline cannot drift between the Home
/// header, Settings, the launcher label, PDF metadata and the store listing.
/// The Android label and splash artwork are not generated from this file —
/// update `android/app/src/main/AndroidManifest.xml` and re-run
/// `tool/generate_brand_assets.py` when the name or tagline changes.
abstract final class AppBrand {
  static const String name = 'OCR PDF Studio';

  static const String tagline = 'Scan. Extract. Convert.';

  /// Mirrors `version:` in pubspec.yaml (versionName+versionCode). Update both
  /// together; the app intentionally has no package_info dependency just to
  /// read a value that is fixed at build time.
  static const String version = '1.0.0';
}
