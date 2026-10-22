import 'package:flutter/services.dart';

/// Hands text to the platform's share sheet.
///
/// Why a native channel instead of a package
/// -----------------------------------------
/// The obvious Dart answer is `share_plus`, but this phase is explicitly
/// dependency-free, and text sharing is a five-line native call: build an
/// `ACTION_SEND` intent with `text/plain` and let Android show the chooser.
/// That is handled by `MainActivity` on the existing Flutter engine, so nothing
/// new is installed, and the app keeps working with no share target present.
///
/// The class is shaped like `SearchLauncher` on purpose: a tiny, overridable
/// seam so a widget test can substitute a recorder without touching a platform
/// channel, and a `bool` result so callers never have to handle a throw.
class TextSharer {
  const TextSharer({this.channel = const MethodChannel('pdf_utility/share')});

  /// The native channel. Overridable so tests can stub it.
  final MethodChannel channel;

  /// Opens the share sheet with [text].
  ///
  /// [subject] is used as the chooser title and as `EXTRA_SUBJECT`, so the
  /// receiving app can prefill a title when it supports one.
  ///
  /// Returns `true` only when a chooser was actually shown. Blank text, a
  /// missing native handler, or a device with nothing able to receive
  /// `text/plain` all return `false` rather than throwing — the caller decides
  /// how to tell the user.
  Future<bool> shareText(String text, {String? subject}) async {
    if (text.trim().isEmpty) return false;
    try {
      final shown = await channel.invokeMethod<bool>(
        'shareText',
        <String, dynamic>{'text': text, 'subject': ?subject},
      );
      return shown ?? false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }
}
