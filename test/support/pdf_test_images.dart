import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

/// Real PNG page images for PDF tests.
///
/// The PDF writer takes **file paths** and reads their headers, so a test that
/// wants to prove anything about a created document needs real image files, not
/// strings that look like paths. These are encoded by the Flutter engine itself
/// (`Picture.toImage` → PNG), which means the fixtures are genuine PNGs with no
/// third-party encoder and no binary blobs checked into the repository.
///
/// Each page is a solid colour with a differently-shaped frame drawn on it, so
/// two pages of a document are distinguishable by both their size and their
/// pixels.
Future<String> writeTestPng({
  required Directory directory,
  required String name,
  required int width,
  required int height,
  Color color = const Color(0xFF2B2F5B),
}) async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(
    recorder,
    Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
  );

  canvas.drawRect(
    Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
    Paint()..color = Colors.white,
  );
  canvas.drawRect(
    Rect.fromLTWH(width * 0.08, height * 0.08, width * 0.84, height * 0.3),
    Paint()..color = color,
  );

  final picture = recorder.endRecording();
  final image = await picture.toImage(width, height);
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  picture.dispose();

  if (data == null) {
    throw StateError('The engine could not encode a $width x $height PNG.');
  }

  final file = File('${directory.path}/$name');
  await file.writeAsBytes(data.buffer.asUint8List(), flush: true);
  return file.path;
}

/// What a byte-level look at a PDF can tell us.
///
/// This is deliberately a *structural* parse rather than a render: it proves the
/// file is a well-formed PDF with the expected number of page objects, in the
/// expected order, without pretending to be a PDF engine. Rendering it with an
/// independent engine (PDFium on a device, poppler's `pdfinfo` off it) is what
/// the verification step does, and the two together are the evidence.
class PdfStructure {
  const PdfStructure({
    required this.header,
    required this.hasTrailer,
    required this.hasCatalog,
    required this.pageSizes,
  });

  /// The `%PDF-` version line, as written.
  final String header;

  /// Whether the file ends with the `%%EOF` marker a reader looks for.
  final bool hasTrailer;

  /// Whether a `/Type /Catalog` object is present (the document root).
  final bool hasCatalog;

  /// The MediaBox of each page, in the order the page objects appear.
  ///
  /// `[width, height]` in points.
  final List<List<double>> pageSizes;

  int get pageCount => pageSizes.length;
}

/// Reads [file] and reports what its bytes say about its structure.
PdfStructure readPdfStructure(File file) {
  final bytes = file.readAsBytesSync();
  // latin1: a PDF's dictionaries are byte-oriented, and decoding as UTF-8 would
  // throw on the compressed streams the images live in.
  final text = String.fromCharCodes(bytes);

  // Every page carries exactly one `/MediaBox`, and a writer emits page objects
  // in creation order, so the *n*-th box belongs to the *n*-th page. Collected
  // in file order rather than per object: a window around one object would
  // happily match the previous page's box, which is exactly the kind of mistake
  // this parse is meant to catch.
  final boxPattern = RegExp(
    r'/MediaBox\s*\[\s*([\d.\-]+)\s+([\d.\-]+)\s+([\d.\-]+)\s+([\d.\-]+)',
  );
  final pageSizes = <List<double>>[];
  for (final box in boxPattern.allMatches(text)) {
    final x1 = double.parse(box.group(1)!);
    final y1 = double.parse(box.group(2)!);
    final x2 = double.parse(box.group(3)!);
    final y2 = double.parse(box.group(4)!);
    pageSizes.add(<double>[(x2 - x1).abs(), (y2 - y1).abs()]);
  }

  final headerEnd = text.indexOf('\n');
  return PdfStructure(
    header: headerEnd < 0 ? text : text.substring(0, headerEnd),
    hasTrailer: text.trimRight().endsWith('%%EOF'),
    hasCatalog: RegExp(r'/Type\s*/Catalog').hasMatch(text),
    pageSizes: pageSizes,
  );
}
