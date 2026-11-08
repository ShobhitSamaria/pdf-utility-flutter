import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import '../data/pdf_page_encoder.dart';
import 'pdf_creation.dart';

/// How many bytes the PDF the review screen is about to write will occupy.
///
/// Why this used to be wrong
/// -------------------------
/// The old estimate multiplied the *file-system* size of each source by a
/// per-format ratio (`0.60` for camera JPEGs, `0.05` for PNG scans, …). Those
/// ratios are averages at best: the real output depends on the image's content,
/// its resolution and which re-encode wins. The review screen could therefore
/// promise 4 MB and write 1.2 MB.
///
/// What it does now
/// ----------------
/// It asks [PdfPageEncoder] — the same code the writer uses — how many bytes each
/// page's image stream will take, then adds the document's own structure
/// overhead:
///
/// ```
/// estimate = sum(encoded image streams) + document overhead + per-page overhead
/// ```
///
/// For a JPEG in Standard mode the image term is exact (the bytes are embedded
/// verbatim). For Compress it is exact too, because the writer embeds the same
/// re-encoded JPEG. The remaining difference is the PDF's structure — objects,
/// content streams and the cross-reference table — which is stable at a few
/// kilobytes and is covered by the two overhead constants below.
///
/// Cost
/// ----
/// The estimate is async and runs in an isolate, so the review screen never
/// decodes a photo on the UI isolate. Results are cached per file (path +
/// modification time) and per mode, so switching Standard ↔ Compress after the
/// first calculation is instant. A page that cannot be read contributes nothing;
/// creation will report it with a proper message before the estimate matters.
class PdfSizeEstimate {
  const PdfSizeEstimate._();

  /// Document catalog, metadata, xref table and trailer.
  ///
  /// Measured on this writer's own output: 1–4 page JPEG documents held at
  /// ~590 bytes plus ~510 bytes per page beyond their image streams.
  static const int documentOverheadBytes = 600;

  /// Page object, content stream and image object dictionary, per page.
  ///
  /// Measured from the same output; the image stream itself is counted by
  /// [PdfPageEncoder].
  static const int pageOverheadBytes = 520;

  /// Per-page encoded image-stream lengths, keyed by file identity and mode.
  static final Map<String, int> _cache = <String, int>{};

  /// Tests reset this between generated fixtures.
  static void clearCache() => _cache.clear();

  /// Estimates the finished file's size for [pageImagePaths].
  static Future<int> bytes({
    required List<String> pageImagePaths,
    PdfCompression compression = PdfCompression.standard,
  }) async {
    var total =
        documentOverheadBytes + pageOverheadBytes * pageImagePaths.length;
    if (pageImagePaths.isEmpty) return 0;

    final pendingPaths = <String>[];
    final pendingKeys = <String>[];
    for (final path in pageImagePaths) {
      final key = _cacheKey(path, compression);
      final cached = _cache[key];
      if (cached != null) {
        total += cached;
      } else {
        pendingPaths.add(path);
        pendingKeys.add(key);
      }
    }
    if (pendingPaths.isEmpty) return total;

    final sizes = await Isolate.run(
      () => _measureAll(pendingPaths, compression),
    );
    for (var i = 0; i < sizes.length; i++) {
      total += sizes[i];
      // Only cache what was actually readable: a transient failure should not
      // freeze a wrong number for the rest of the session.
      if (sizes[i] > 0) _cache[pendingKeys[i]] = sizes[i];
    }
    return total;
  }

  /// Runs on a background isolate: no file I/O or image decoding on the UI
  /// isolate, which is what keeps scrolling and the compression toggle smooth.
  static List<int> _measureAll(
    List<String> paths,
    PdfCompression compression,
  ) {
    return <int>[
      for (final path in paths) _measureOne(path, compression),
    ];
  }

  static int _measureOne(String path, PdfCompression compression) {
    try {
      final Uint8List bytes = File(path).readAsBytesSync();
      if (bytes.isEmpty) return 0;
      return PdfPageEncoder.encodedStreamBytes(bytes, compression);
    } catch (_) {
      return 0;
    }
  }

  static String _cacheKey(String path, PdfCompression compression) {
    try {
      final stat = FileStat.statSync(path);
      return '$path|${stat.size}|${stat.modified.millisecondsSinceEpoch}'
          '|${compression.name}';
    } catch (_) {
      return '$path|missing|${compression.name}';
    }
  }

  /// `~850 KB` / `~8.5 MB` — a short label, never a promise.
  static String format(int bytes) {
    if (bytes < 1024) return '$bytes bytes';
    final kb = bytes / 1024;
    if (kb < 1024) return '${kb.toStringAsFixed(0)} KB';
    final mb = kb / 1024;
    return '${mb.toStringAsFixed(mb < 10 ? 1 : 0)} MB';
  }
}
