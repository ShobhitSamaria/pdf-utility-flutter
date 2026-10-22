import 'dart:io';

/// Where a created PDF is written.
///
/// An interface rather than a hard-coded path because the answer is different
/// on every platform, and because every test and every command-line tool that
/// exercises this feature needs to point the writer at a directory it controls:
///
/// * on Android, the app's own cache directory — obtained from the platform
///   (see `NativePdfOutputDirectory`), which is the only reliably writable
///   location and is also what the share sheet's FileProvider serves from;
/// * everywhere else (tests, desktop, the verification script), a temporary
///   directory.
///
/// Deliberately **not** the user's Documents folder: a created PDF is a
/// hand-off, and it becomes a file the user keeps when they share or export it
/// (see `PdfFileExporter`). Writing to shared storage would need permissions
/// and would leave orphaned files behind.
abstract class PdfOutputDirectory {
  /// A directory path that exists or can be created, absolute where the
  /// platform provides one.
  ///
  /// Implementations never throw: a platform that cannot answer falls back to a
  /// temporary directory, because failing to *find* a directory must not be
  /// reported to the user as failing to *create* their PDF.
  Future<String> resolve();
}

/// The fallback: the process's temporary directory.
///
/// Correct on desktop and in `flutter test`; on Android the composition root
/// injects the platform's cache directory instead.
class SystemTempPdfOutputDirectory implements PdfOutputDirectory {
  const SystemTempPdfOutputDirectory();

  @override
  Future<String> resolve() async => Directory.systemTemp.path;
}
