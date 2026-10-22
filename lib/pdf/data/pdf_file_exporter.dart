import 'package:flutter/services.dart';

import '../domain/pdf_creation.dart';

/// Hands a finished PDF to the rest of the device.
///
/// Two ways out, because they answer different questions:
/// * [share] opens the system share sheet — send it to Drive, Gmail, Files,
///   WhatsApp, or print it. This is the one that works everywhere.
/// * [saveToDownloads] writes a copy the user can find again on their own,
///   returning where it landed.
///
/// Why a native channel instead of a package
/// -----------------------------------------
/// The obvious Dart answers (`share_plus`, `path_provider`, `printing`) are
/// three plugins and three sets of platform code, for what is a couple of
/// intents on the Android side. The app already talks to `MainActivity` for text
/// sharing, so this reuses that channel and that convention: no new plugin, and
/// the same shape — an overridable channel plus a `bool`/`String?` result, so a
/// widget test can drive it without a platform.
///
/// Nothing here throws. A device with no share target, a missing native handler
/// and a failed write all report `false`/`null` and let the screen decide how to
/// say so.
class PdfFileExporter {
  const PdfFileExporter({
    this.channel = const MethodChannel('pdf_utility/share'),
  });

  /// The native channel. Overridable so tests can stub it.
  final MethodChannel channel;

  /// Opens the share sheet for [pdf].
  ///
  /// Returns `true` only when a chooser was actually shown.
  Future<bool> share(CreatedPdf pdf, {String? subject}) async {
    try {
      final shown = await channel.invokeMethod<bool>('shareFile', <
        String,
        dynamic
      >{
        'path': pdf.path,
        'mimeType': 'application/pdf',
        // The file name is the fallback subject: a sheet titled "document.pdf"
        // is more use than one with no title at all.
        'subject': subject ?? pdf.fileName,
      });
      return shown ?? false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }

  /// Saves a copy of [pdf] somewhere the user can open later.
  ///
  /// Returns a short, user-facing description of where it went (e.g.
  /// `Downloads/Newspaper.pdf`), or `null` when the platform could not write it
  /// — which the screen reports as a failure rather than as success.
  Future<String?> saveToDownloads(CreatedPdf pdf) async {
    try {
      final location = await channel.invokeMethod<String>(
        'exportFile',
        <String, dynamic>{
          'path': pdf.path,
          'fileName': pdf.fileName,
          'mimeType': 'application/pdf',
        },
      );
      final trimmed = location?.trim();
      return (trimmed == null || trimmed.isEmpty) ? null : trimmed;
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    }
  }
}
