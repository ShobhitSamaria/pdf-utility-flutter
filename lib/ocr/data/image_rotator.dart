import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import '../domain/document_orientation.dart';

/// Produces a rotated copy of an image file, leaving the original untouched.
///
/// Why a **copy** rather than a transform in the widget tree
/// --------------------------------------------------------
/// Rotating the photo on screen is easy; keeping the OCR boxes, selection
/// targets, translation regions and tap hit-testing in the same rotated frame is
/// not. Every one of those is expressed in the coordinate space of the pixels
/// ML Kit read, and `OcrCoordinateMapper` maps that space with a single uniform
/// scale. Teaching it a rotation term would mean four widgets agreeing on the
/// same transform, and one of them drifting is invisible until a user taps the
/// wrong word.
///
/// Instead the pixels are rotated **before recognition**. ML Kit then reads an
/// upright page, its rectangles are upright, and every existing piece of
/// geometry code — including hit-testing — keeps working unchanged, because the
/// image the user sees *is* the image that was read
/// (`OcrResult.sourceImage.path` points at this copy).
///
/// The rotation is a quarter turn, so no interpolation is involved beyond the
/// optional downscale described in [UiImageRotator.maxLongSide].
abstract class ImageRotator {
  /// Writes an upright copy of [sourcePath] and returns its path.
  ///
  /// Returns [sourcePath] itself when [orientation] is upright, so callers can
  /// treat this as "give me an upright image" without special-casing.
  Future<String> rotate(String sourcePath, DocumentOrientation orientation);
}

/// [ImageRotator] backed by Flutter's own engine (`dart:ui`), which is already
/// the only image decoder this app uses.
///
/// The copy is written as **PNG**: this is an intermediate file that ML Kit
/// reads and the screen displays, and a lossless copy of a rotated page must not
/// add a second generation of JPEG artefacts to the very text being recognised.
class UiImageRotator implements ImageRotator {
  const UiImageRotator({this.maxLongSide = 3200});

  /// Longest side of the rotated copy, in pixels.
  ///
  /// Rotating decodes the full image into memory (`width × height × 4` bytes),
  /// and the result is held twice — once as a picture and once as the encoded
  /// PNG. A 12 MP phone photo is ~48 MB each, which is not a safe thing to do on
  /// a mid-range device just to turn a page. Capping the long side keeps that
  /// bounded (3 200 px ≈ 2 400 × 3 200 ≈ 7.7 MP) while staying far above what
  /// ML Kit needs: it downsamples to roughly 1 024 px on the long side for text,
  /// so a page scaled to 3 200 px still carries ~3× the detail it uses.
  ///
  /// The cap is applied **before** the rotation, and the returned image reports
  /// its own dimensions, so every coordinate downstream is consistent with the
  /// file that was actually read.
  final int maxLongSide;

  @override
  Future<String> rotate(
    String sourcePath,
    DocumentOrientation orientation,
  ) async {
    if (orientation.isUpright) return sourcePath;

    final buffer = await ui.ImmutableBuffer.fromFilePath(sourcePath);
    final descriptor = await ui.ImageDescriptor.encoded(buffer);
    try {
      final source = ui.Size(
        descriptor.width.toDouble(),
        descriptor.height.toDouble(),
      );
      if (source.isEmpty) {
        throw StateError('$sourcePath has no pixels to rotate');
      }

      // Downscale first (still in the stored orientation), so the canvas only
      // ever holds the smaller bitmap.
      final scale = math.min(
        1.0,
        maxLongSide / math.max(source.width, source.height),
      );
      final decodedWidth = math.max(1, (source.width * scale).round());
      final decodedHeight = math.max(1, (source.height * scale).round());

      final codec = await descriptor.instantiateCodec(
        targetWidth: decodedWidth,
        targetHeight: decodedHeight,
      );
      try {
        final frame = await codec.getNextFrame();
        final image = frame.image;
        try {
          final turns = orientation.quarterTurnsClockwise;
          final outWidth = orientation.widthOf(image.width, image.height);
          final outHeight = orientation.heightOf(image.width, image.height);

          final recorder = ui.PictureRecorder();
          final canvas = ui.Canvas(
            recorder,
            ui.Rect.fromLTWH(0, 0, outWidth.toDouble(), outHeight.toDouble()),
          );
          // Rotate about the centre of the output, then draw the source centred
          // on it: the exact pixels, no resampling, just a different mapping.
          canvas.translate(outWidth / 2, outHeight / 2);
          canvas.rotate(turns * math.pi / 2);
          canvas.translate(-image.width / 2, -image.height / 2);
          canvas.drawImage(
            image,
            ui.Offset.zero,
            ui.Paint()..filterQuality = ui.FilterQuality.high,
          );

          final picture = recorder.endRecording();
          try {
            final rotated = await picture.toImage(outWidth, outHeight);
            try {
              final data = await rotated.toByteData(
                format: ui.ImageByteFormat.png,
              );
              if (data == null) {
                throw StateError('Could not encode the rotated page');
              }
              final file = await _targetFile(sourcePath, orientation);
              await file.writeAsBytes(data.buffer.asUint8List(), flush: true);
              return file.path;
            } finally {
              rotated.dispose();
            }
          } finally {
            picture.dispose();
          }
        } finally {
          image.dispose();
        }
      } finally {
        codec.dispose();
      }
    } finally {
      descriptor.dispose();
    }
  }

  /// Stable name per (source, turn) in the app's cache directory.
  ///
  /// Deterministic so that re-recognising the same page (switching script,
  /// retrying) reuses one file instead of filling the cache with copies.
  Future<File> _targetFile(
    String sourcePath,
    DocumentOrientation orientation,
  ) async {
    final name = sourcePath.split(RegExp(r'[\\/]')).last;
    final stem = name.replaceAll(RegExp(r'\.[^.]*$'), '');
    final directory = Directory.systemTemp;
    return File(
      '${directory.path}/ocr-upright-$stem-${orientation.quarterTurnsClockwise}.png',
    );
  }
}
