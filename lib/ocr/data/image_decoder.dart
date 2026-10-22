import 'dart:ui' as ui;

/// Decodes just enough of an image file to learn its **upright** pixel size.
///
/// ML Kit reports its bounding boxes in the coordinate space of the decoded
/// bitmap, which is already rotated according to EXIF orientation. We therefore
/// must report the same upright dimensions, otherwise the overlay scale would
/// be computed from the pre-rotation width/height and every box would be wrong
/// on portrait photos taken with the rear camera.
///
/// Flutter's image codec applies EXIF orientation while decoding, so
/// `frame.image.width/height` are exactly the upright dimensions we need — no
/// third-party EXIF library required.
///
/// Why the bytes are *mapped* rather than *read*
/// --------------------------------------------
/// This used to be `File(path).readAsBytes()` followed by
/// `ui.instantiateImageCodec(bytes)`, which copied the entire encoded file into
/// the Dart heap just to learn two integers. `ui.instantiateImageCodec` is
/// implemented as `ImmutableBuffer.fromUint8List(list)` +
/// `instantiateImageCodecFromBuffer(buffer)`, so mapping the file straight into
/// a codec with [ui.ImmutableBuffer.fromFilePath] reaches **the identical decode
/// path** — same codec, same EXIF handling, same width and height — without the
/// copy. The returned values are unchanged; only the route the bytes take is.
class ImageDecoder {
  const ImageDecoder();

  /// Returns the upright pixel dimensions of the image at [path].
  Future<SourceImageDimensions> decodeDimensions(String path) async {
    // The codec path takes ownership of the buffer and disposes it once the
    // codec exists (see `instantiateImageCodecWithSize`, which disposes it in a
    // `finally`), so it is deliberately NOT disposed here — that would be a
    // double dispose.
    final buffer = await ui.ImmutableBuffer.fromFilePath(path);
    final codec = await ui.instantiateImageCodecFromBuffer(buffer);
    try {
      final frame = await codec.getNextFrame();
      final image = frame.image;
      try {
        return SourceImageDimensions(image.width, image.height);
      } finally {
        image.dispose();
      }
    } finally {
      codec.dispose();
    }
  }
}

/// Plain value object for image dimensions.
class SourceImageDimensions {
  const SourceImageDimensions(this.width, this.height);
  final int width;
  final int height;

  @override
  String toString() => '${width}x$height';
}
