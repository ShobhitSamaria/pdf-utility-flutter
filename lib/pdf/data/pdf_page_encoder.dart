import 'dart:io';
import 'dart:typed_data';

import 'package:image/image.dart' as img;

import '../domain/pdf_creation.dart';

/// The one definition of "how a page image becomes PDF image data".
///
/// The writer and the size estimate both call in here. That is the whole point:
/// when the number on the review screen and the file on disk are produced by
/// different code, they drift — which is exactly what the estimate used to do
/// with its per-format magic ratios.
///
/// What the PDF writer actually embeds
/// -----------------------------------
/// * **Standard** hands `package:pdf` the source bytes. A JPEG is stored as-is
///   with `/DCTDecode`; any other format is decoded to RGB(A) and deflated.
/// * **Compress** replaces the page with the smallest of a few bounded JPEG
///   re-encodes (see [compress]).
///
/// [encodedStreamBytes] therefore reports the same quantity the writer will put
/// into the file: image-stream bytes, not file-system bytes. Page and document
/// structure are added separately by `PdfSizeEstimate`.
abstract final class PdfPageEncoder {
  /// Whether [bytes] is a JPEG. `package:pdf` keeps these bytes verbatim.
  static bool isJpeg(Uint8List bytes) =>
      bytes.length > 3 && bytes[0] == 0xFF && bytes[1] == 0xD8;

  /// The bytes the writer hands to `pw.MemoryImage` for [compression].
  ///
  /// Standard is the original data, untouched: the source file is never
  /// rewritten, and JPEG quality is preserved. Compress is the bounded
  /// re-encode from [compress].
  static Uint8List encode(Uint8List input, PdfCompression compression) =>
      compression == PdfCompression.compress ? compress(input) : input;

  /// Bounded re-encoding: EXIF rotation baked in, then the smallest of a few
  /// long-edge/quality attempts.
  ///
  /// 1400 px / quality 65 is the normal setting: comfortably above the ~1000 px
  /// an A4 page needs for readable body text, while dropping the high-frequency
  /// detail that makes phone photos large. Images that are already highly
  /// compressed (screenshots, exported scans) may not shrink at that setting, so
  /// the loop tries a little harder before giving up. The original bytes are the
  /// starting "best", which guarantees Compress can never produce a larger PDF
  /// page than Standard.
  static Uint8List compress(Uint8List input) {
    final decoded = img.decodeImage(input);
    if (decoded == null) {
      throw const FormatException('Unsupported image format');
    }
    final upright = img.bakeOrientation(decoded);
    var best = input;
    for (final (maxEdge, quality) in const [
      (1400, 65),
      (1200, 55),
      (1000, 45),
      (800, 40),
    ]) {
      final resized = upright.width > maxEdge || upright.height > maxEdge
          ? (upright.width >= upright.height
                ? img.copyResize(
                    upright,
                    width: maxEdge,
                    interpolation: img.Interpolation.average,
                  )
                : img.copyResize(
                    upright,
                    height: maxEdge,
                    interpolation: img.Interpolation.average,
                  ))
          : upright;
      final candidate = img.encodeJpg(resized, quality: quality);
      if (candidate.length < best.length) best = candidate;
    }
    return best;
  }

  /// How many bytes the PDF image stream(s) for [input] will occupy.
  ///
  /// * Compress: the re-encoded JPEG length.
  /// * Standard JPEG: the source length — the writer embeds it verbatim.
  /// * Standard other: RGB and alpha raster streams, deflated exactly as
  ///   `package:pdf` does, each falling back to raw bytes when deflate is not
  ///   smaller.
  ///
  /// An image that cannot be decoded is reported at its file length; creation
  /// will fail with a clear error long before the estimate matters.
  static int encodedStreamBytes(
    Uint8List input,
    PdfCompression compression,
  ) {
    if (compression == PdfCompression.compress) return compress(input).length;
    if (isJpeg(input)) return input.length;
    return _rasterStreamBytes(input);
  }

  static int _rasterStreamBytes(Uint8List input) {
    final decoded = img.decodeImage(input);
    if (decoded == null) return input.length;

    final rgba = decoded
        .convert(format: img.Format.uint8, numChannels: 4, noAnimation: true)
        .toUint8List();
    final pixels = decoded.width * decoded.height;
    final rgb = Uint8List(pixels * 3);
    final alpha = Uint8List(pixels);
    for (var i = 0; i < pixels; i++) {
      rgb[i * 3] = rgba[i * 4];
      rgb[i * 3 + 1] = rgba[i * 4 + 1];
      rgb[i * 3 + 2] = rgba[i * 4 + 2];
      alpha[i] = rgba[i * 4 + 3];
    }

    return _deflated(rgb) + _deflated(alpha);
  }

  /// `package:pdf` keeps the raw stream when compression would make it bigger.
  static int _deflated(Uint8List data) {
    final compressed = zlib.encode(data).length;
    return compressed < data.length ? compressed : data.length;
  }
}
