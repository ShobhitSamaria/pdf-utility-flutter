import 'dart:io';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:pdf_utility_flutter/pdf/data/pdf_library_creation_service.dart';
import 'package:pdf_utility_flutter/pdf/domain/pdf_creation.dart';
import 'package:pdf_utility_flutter/pdf/domain/pdf_output_directory.dart';
import 'package:pdf_utility_flutter/pdf/domain/pdf_size_estimate.dart';

/// Points the writer at the test's own directory.
class _TempOutput implements PdfOutputDirectory {
  const _TempOutput(this.path);
  final String path;

  @override
  Future<String> resolve() async => path;
}

/// A noisy "phone photo": high-frequency blocks resist JPEG compression, so the
/// comparison reflects a real document image rather than a blank page.
File _writePhoto(Directory work) {
  final image = img.Image(width: 1600, height: 2000);
  final random = Random(7);
  for (var y = 0; y < image.height; y += 16) {
    for (var x = 0; x < image.width; x += 16) {
      img.fillRect(
        image,
        x1: x,
        y1: y,
        x2: x + 15,
        y2: y + 15,
        color: img.ColorRgb8(
          random.nextInt(256),
          random.nextInt(256),
          random.nextInt(256),
        ),
      );
    }
  }
  return File('${work.path}/photo.jpg')
    ..writeAsBytesSync(img.encodeJpg(image, quality: 92));
}

/// A paper-like scan exported as PNG: mostly white, with black rules.
File _writeScan(Directory work) {
  final image = img.Image(width: 1000, height: 1400);
  img.fill(image, color: img.ColorRgb8(255, 255, 255));
  for (var y = 120; y < 1300; y += 46) {
    img.fillRect(
      image,
      x1: 90,
      y1: y,
      x2: 910,
      y2: y + 7,
      color: img.ColorRgb8(20, 24, 40),
    );
  }
  for (var y = 120; y < 1300; y += 92) {
    img.fillRect(
      image,
      x1: 90,
      y1: y,
      x2: 520,
      y2: y + 5,
      color: img.ColorRgb8(70, 74, 90),
    );
  }
  return File('${work.path}/scan.png')
    ..writeAsBytesSync(img.encodePng(image));
}

void main() {
  late Directory work;

  setUp(() {
    work = Directory.systemTemp.createTempSync('pdf_size_estimate_test');
    PdfSizeEstimate.clearCache();
  });

  tearDown(() {
    if (work.existsSync()) work.deleteSync(recursive: true);
  });

  test('the estimate matches the file the writer actually produces', () async {
    final photo = _writePhoto(work);
    final scan = _writeScan(work);
    final paths = [photo.path, scan.path];

    final service = PdfLibraryCreationService(outputDirectory: _TempOutput(work.path));

    for (final compression in PdfCompression.values) {
      final estimate = await PdfSizeEstimate.bytes(
        pageImagePaths: paths,
        compression: compression,
      );
      final created = await service.create(
        pageImagePaths: paths,
        fileName: '${compression.name}.pdf',
        compression: compression,
      );

      final difference = estimate - created.byteSize;
      final percent = difference.abs() / created.byteSize * 100;
      // ignore: avoid_print
      print(
        'SIZEPROBE ${compression.name}: estimate=$estimate '
        'actual=${created.byteSize} diff=$difference '
        'percent=${percent.toStringAsFixed(2)}%',
      );

      // The estimate must be consistently close, not a hardcoded percentage.
      // 3% of a real document is well inside what a user perceives as "about
      // the same size" and leaves room for xref/metadata variance.
      expect(
        percent,
        lessThan(3),
        reason:
            '${compression.name} estimate $estimate vs actual '
            '${created.byteSize} (${percent.toStringAsFixed(2)}%)',
      );
    }
  });

  test('compress is estimated smaller than standard for the same pages', () async {
    final photo = _writePhoto(work);
    final scan = _writeScan(work);
    final paths = [photo.path, scan.path];

    final standard = await PdfSizeEstimate.bytes(pageImagePaths: paths);
    final compress = await PdfSizeEstimate.bytes(
      pageImagePaths: paths,
      compression: PdfCompression.compress,
    );

    expect(compress, lessThan(standard));
  });

  test('a missing page adds no invented image bytes', () async {
    final estimate = await PdfSizeEstimate.bytes(
      pageImagePaths: ['${work.path}/gone.jpg'],
    );
    expect(
      estimate,
      PdfSizeEstimate.documentOverheadBytes + PdfSizeEstimate.pageOverheadBytes,
    );
  });

  test('size labels stay short and in sensible units', () {
    expect(PdfSizeEstimate.format(512), '512 bytes');
    expect(PdfSizeEstimate.format(900 * 1024), '900 KB');
    expect(PdfSizeEstimate.format(9 * 1024 * 1024), '9.0 MB');
  });
}
