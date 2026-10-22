import 'dart:io';

import 'package:flutter/services.dart';

import '../domain/pdf_output_directory.dart';

/// [PdfOutputDirectory] backed by the platform's own cache directory.
///
/// Why a channel call instead of a package
/// ---------------------------------------
/// `Directory.systemTemp` consults the process's `TMPDIR` and otherwise falls
/// back to `/tmp`, which an Android app process cannot write to — so the Dart
/// answer to "where can I write a file?" is not trustworthy on the platform
/// this app actually ships to. The alternatives were a plugin (`path_provider`)
/// or two lines on the native side. The app already owns the
/// `pdf_utility/share` channel for handing files to other apps, and
/// `Context.getCacheDir()` is precisely the directory that channel's
/// FileProvider serves from, so the cache path comes from there: one channel,
/// no new dependency, and the writer and the share sheet cannot disagree about
/// where the file is.
///
/// Never throws. A missing native handler (a widget test, a desktop build)
/// falls back to [SystemTempPdfOutputDirectory], so only the *location* is
/// degraded — never the ability to create a PDF.
class NativePdfOutputDirectory implements PdfOutputDirectory {
  const NativePdfOutputDirectory({
    this.channel = const MethodChannel('pdf_utility/share'),
  });

  /// The native channel. Overridable so tests can stub it.
  final MethodChannel channel;

  @override
  Future<String> resolve() async {
    try {
      final path = await channel.invokeMethod<String>('cacheDirectory');
      final trimmed = path?.trim();
      if (trimmed != null && trimmed.isNotEmpty) return trimmed;
    } on MissingPluginException {
      // No native side (tests, desktop): fall through.
    } on PlatformException {
      // Reported by the platform as unavailable: fall through.
    }
    return const SystemTempPdfOutputDirectory().resolve();
  }
}

/// Creates (if needed) and returns the directory created PDFs are written into,
/// under [PdfOutputDirectory].
///
/// Kept out of the writer so that a failed `mkdir` is reported once, as a
/// storage problem the user can act on, rather than as an encoder failure.
Future<Directory> ensurePdfDirectory(
  PdfOutputDirectory outputDirectory, {
  String directoryName = 'created_pdfs',
}) async {
  final base = await outputDirectory.resolve();
  final directory = Directory('$base/$directoryName');
  await directory.create(recursive: true);
  return directory;
}
