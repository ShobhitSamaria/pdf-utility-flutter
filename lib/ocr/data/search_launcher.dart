import 'package:url_launcher/url_launcher.dart';

/// Opens the device's default browser with a web search for selected OCR text.
///
/// Kept behind a tiny class (rather than calling `launchUrl` directly in the UI)
/// so it can be faked in tests and swapped for an in-app search later without
/// touching the screen.
class SearchLauncher {
  const SearchLauncher();

  /// Launches a Google search for [query].
  ///
  /// Returns `true` if a browser was launched, `false` otherwise (e.g. no
  /// browser installed, or the platform refused). Never throws.
  Future<bool> searchWeb(String query) async {
    final trimmed = query.trim();
    if (trimmed.isEmpty) return false;

    final uri = Uri.https('www.google.com', '/search', {'q': trimmed});
    try {
      return await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (_) {
      return false;
    }
  }
}
