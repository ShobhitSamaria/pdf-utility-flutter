import 'dart:io';

import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart'
    as mlkit;

import '../domain/ocr_block.dart';
import '../domain/ocr_element.dart';
import '../domain/ocr_engine.dart';
import '../domain/ocr_exception.dart';
import '../domain/ocr_line.dart';
import '../domain/ocr_rect.dart';
import '../domain/ocr_result.dart';
import '../ocr_log.dart';
import 'image_decoder.dart';

/// Concrete [OcrEngine] backed by Google's on-device ML Kit Text Recognition.
///
/// Everything runs locally through a platform channel — no cloud calls, no
/// Tesseract, no Python backend. This class is the ONLY place that imports the
/// ML Kit package, keeping the rest of the app engine-agnostic.
///
/// Three things are handled here rather than left to the caller, because this is
/// the layer that can see them:
///
/// * **Preflight.** The file is checked before anything decodes it: missing,
///   empty or unreadable images become `imageUnreadable`, which is a message the
///   user can act on, instead of an opaque engine error.
/// * **Failure bookkeeping.** A [mlkit.TextRecognizer] is cached per script, so
///   one failed call used to poison that script for the rest of the process:
///   every later photo, from every entry point, failed the same way. A failed
///   recognizer is now closed and dropped, so the next run starts fresh.
/// * **Diagnostics.** The original exception and stack trace are logged under the
///   shared `PDF_UTILITY_OCR` tag (debug builds only) and preserved in the
///   thrown [OcrException].
class MlKitOcrEngine implements OcrEngine {
  MlKitOcrEngine([this._decoder = const ImageDecoder()]);

  final ImageDecoder _decoder;

  /// One recognizer per script, created lazily and reused across calls (native
  /// model loading is expensive, so we avoid re-creating it per image).
  final Map<mlkit.TextRecognitionScript, mlkit.TextRecognizer> _recognizers =
      {};

  @override
  String get name => 'Google ML Kit';

  @override
  Future<OcrResult> recognize({
    required String imagePath,
    OcrOptions options = const OcrOptions(),
  }) async {
    final stopwatch = Stopwatch()..start();

    ocrDiag(
      'engine: run start script=${options.script.name} '
      'file=${_fileLabel(imagePath)}',
    );

    // 1. Preflight: fail with a precise, actionable kind *before* the native
    //    layer, so a stale path is never reported as a recognizer fault.
    await _ensureReadable(imagePath);

    // 2. Upright dimensions — must match the coordinate space ML Kit uses.
    final dims = await _decodeDimensions(imagePath);
    ocrDiag(
      'engine: decoded upright dims=${dims.width}x${dims.height} '
      '(${stopwatch.elapsedMilliseconds} ms)',
    );

    // 3. Hand the file path to the native recognizer.
    final recognizer = _recognizerFor(options.script);
    ocrDiag('engine: recognizer ready script=${options.script.name}');
    try {
      final inputImage = mlkit.InputImage.fromFilePath(imagePath);
      ocrDiag('engine: process start script=${options.script.name}');
      final recognized = await recognizer.processImage(inputImage);

      stopwatch.stop();

      // 4. Translate the ML Kit tree into our engine-agnostic domain models.
      final blocks = <OcrBlock>[
        for (final block in recognized.blocks) _mapBlock(block),
      ];

      // Counts only: the recognised characters are the document, and must never
      // reach a log line.
      ocrDiag(
        'engine: process done in ${stopwatch.elapsedMilliseconds} ms '
        'blocks=${blocks.length} '
        'lines=${blocks.fold<int>(0, (n, b) => n + b.lines.length)} '
        'words=${blocks.fold<int>(0, (n, b) => n + b.lines.fold<int>(0, (m, l) => m + l.elements.length))} '
        'textLength=${recognized.text.length}',
      );
      if (blocks.isEmpty || recognized.text.trim().isEmpty) {
        // A successful read of a page with no text is NOT a failure: the engine
        // answered, so this is reported as an empty result, never as an error.
        ocrDiag('engine: empty result (no text found) — not an error');
      }

      return OcrResult(
        sourceImage: SourceImageInfo(
          path: imagePath,
          width: dims.width,
          height: dims.height,
        ),
        fullText: recognized.text,
        blocks: blocks,
        engineName: name,
        elapsed: stopwatch.elapsed,
      );
    } catch (error, stackTrace) {
      // A recognizer that has thrown is not trustworthy for the next image: the
      // native instance can be left in a failed state. Drop it so the next run
      // (from any screen) constructs a fresh one instead of repeating the same
      // failure forever.
      await _discardRecognizer(options.script);
      // Always logged, release included: this is the line that turns a shipped
      // build's generic failure into a diagnosable one.
      ocrDiagError(
        'engine: process FAILED script=${options.script.name} '
        'after ${stopwatch.elapsedMilliseconds} ms',
        error,
        stackTrace,
      );
      throw OcrException.from(error, stackTrace: stackTrace);
    }
  }

  /// File name and byte size — never the whole path (it can carry a person's
  /// name) and never any bytes of the image.
  static String _fileLabel(String path) {
    final separator = path.lastIndexOf(RegExp(r'[\\/]'));
    final name = separator < 0 ? path : path.substring(separator + 1);
    try {
      final length = File(path).lengthSync();
      return '$name ($length bytes)';
    } catch (_) {
      return '$name (size unknown)';
    }
  }

  /// Verifies that [imagePath] is something the recognizer can plausibly open.
  ///
  /// Deliberately does not try to fully decode here: the decoder below does that
  /// and reports its own failure. This catches the cases where there is no file
  /// at all — a photo removed from the cache, or a PDF page that was never
  /// written — with a message that names the real problem.
  Future<void> _ensureReadable(String imagePath) async {
    if (imagePath.trim().isEmpty) {
      throw const OcrException(
        OcrErrorKind.imageUnreadable,
        'There was no image to read. Please capture or choose one again.',
      );
    }

    final file = File(imagePath);
    try {
      if (!await file.exists()) {
        ocrDiag('engine: input file missing (${_fileLabel(imagePath)})');
        throw OcrException(
          OcrErrorKind.imageUnreadable,
          'That image is no longer available. Please capture or choose it again.',
          cause: FileSystemException('No such file', imagePath),
        );
      }
      if (await file.length() == 0) {
        ocrDiag('engine: input file is empty (${_fileLabel(imagePath)})');
        throw OcrException(
          OcrErrorKind.imageUnreadable,
          'That image is empty, so there is no text to read. Please capture or '
          'choose it again.',
          cause: FileSystemException('Empty file', imagePath),
        );
      }
    } on OcrException {
      rethrow;
    } catch (error, stackTrace) {
      ocrLogError('Could not open "$imagePath"', error, stackTrace);
      throw OcrException(
        OcrErrorKind.imageUnreadable,
        'That image could not be opened. Please capture or choose it again.',
        cause: error,
        stackTrace: stackTrace,
      );
    }
  }

  /// Decodes the image header to learn the upright pixel size, reporting a
  /// decode failure as an unreadable image rather than an engine failure.
  Future<SourceImageDimensions> _decodeDimensions(String imagePath) async {
    try {
      return await _decoder.decodeDimensions(imagePath);
    } catch (error, stackTrace) {
      ocrDiagError(
        'engine: decode failed (${_fileLabel(imagePath)})',
        error,
        stackTrace,
      );
      throw OcrException(
        OcrErrorKind.imageUnreadable,
        'That image could not be read. Please capture or choose it again.',
        cause: error,
        stackTrace: stackTrace,
      );
    }
  }

  mlkit.TextRecognizer _recognizerFor(OcrScript script) {
    final mlScript = _mlScriptFor(script);
    final existing = _recognizers[mlScript];
    if (existing != null) {
      ocrDiag('engine: reusing ${script.name} recognizer');
      return existing;
    }
    ocrDiag('engine: creating ${script.name} recognizer');
    final created = mlkit.TextRecognizer(script: mlScript);
    _recognizers[mlScript] = created;
    return created;
  }

  /// Closes and forgets the recognizer for [script]. Never throws: the original
  /// failure is the one worth reporting.
  Future<void> _discardRecognizer(OcrScript script) async {
    final recognizer = _recognizers.remove(_mlScriptFor(script));
    if (recognizer == null) return;
    try {
      await recognizer.close();
    } catch (error) {
      ocrLogError('Could not close the failed recognizer', error);
    }
  }

  static mlkit.TextRecognitionScript _mlScriptFor(OcrScript script) =>
      switch (script) {
        OcrScript.latin => mlkit.TextRecognitionScript.latin,
        OcrScript.devanagari => mlkit.TextRecognitionScript.devanagiri,
        OcrScript.chinese => mlkit.TextRecognitionScript.chinese,
        OcrScript.japanese => mlkit.TextRecognitionScript.japanese,
        OcrScript.korean => mlkit.TextRecognitionScript.korean,
      };

  OcrBlock _mapBlock(mlkit.TextBlock block) => OcrBlock(
    text: block.text,
    boundingBox: OcrRect.fromRect(block.boundingBox),
    recognizedLanguages: block.recognizedLanguages,
    lines: [for (final line in block.lines) _mapLine(line)],
  );

  OcrLine _mapLine(mlkit.TextLine line) => OcrLine(
    text: line.text,
    boundingBox: OcrRect.fromRect(line.boundingBox),
    confidence: line.confidence,
    angle: line.angle,
    recognizedLanguages: line.recognizedLanguages,
    elements: [for (final element in line.elements) _mapElement(element)],
  );

  OcrElement _mapElement(mlkit.TextElement element) => OcrElement(
    text: element.text,
    boundingBox: OcrRect.fromRect(element.boundingBox),
    confidence: element.confidence,
    recognizedLanguages: element.recognizedLanguages,
  );

  @override
  Future<void> dispose() async {
    for (final recognizer in _recognizers.values) {
      await recognizer.close();
    }
    _recognizers.clear();
  }
}
