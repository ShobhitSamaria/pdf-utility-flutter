import 'dart:io';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:pdf_utility_flutter/pdf/data/pdf_library_creation_service.dart';
import 'package:pdf_utility_flutter/pdf/domain/pdf_creation.dart';
import 'package:pdf_utility_flutter/pdf/domain/pdf_output_directory.dart';

/// Points the writer at the test's own directory.
class _TempOutput implements PdfOutputDirectory {
  const _TempOutput(this.path);
  final String path;

  @override
  Future<String> resolve() async => path;
}

void main() {
  test('Compress really makes the file smaller than Standard', () async {
    final work = Directory.systemTemp.createTempSync('pdf_compression_test');
    addTearDown(() {
      if (work.existsSync()) work.deleteSync(recursive: true);
    });

    // A noisy "phone photo": high-frequency blocks resist JPEG compression, so
    // the comparison reflects what re-encoding actually does to a document
    // image rather than to a blank page.
    final source = img.Image(width: 1600, height: 2000);
    final random = Random(7);
    for (var y = 0; y < source.height; y += 16) {
      for (var x = 0; x < source.width; x += 16) {
        img.fillRect(
          source,
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
    final photo = File('${work.path}/photo.jpg')
      ..writeAsBytesSync(img.encodeJpg(source, quality: 92));
    final originalLength = photo.lengthSync();

    final service = PdfLibraryCreationService(
      outputDirectory: _TempOutput(work.path),
    );
    final standard = await service.create(
      pageImagePaths: [photo.path],
      fileName: 'standard.pdf',
    );
    final compressed = await service.create(
      pageImagePaths: [photo.path],
      fileName: 'compress.pdf',
      compression: PdfCompression.compress,
    );

    // The source is only read, never rewritten.
    expect(photo.lengthSync(), originalLength);
    expect(standard.pageCount, 1);
    expect(compressed.pageCount, 1);
    expect(compressed.byteSize, lessThan(standard.byteSize));
    // A saved PDF, not an error document.
    expect(File(standard.path).readAsBytesSync().take(4).toList(), [
      0x25,
      0x50,
      0x44,
      0x46,
    ]);
    expect(File(compressed.path).readAsBytesSync().take(4).toList(), [
      0x25,
      0x50,
      0x44,
      0x46,
    ]);

    // The user-facing vocabulary: Standard and Compress, with the short
    // explanation the review screen shows.
    expect(PdfCompression.standard.label, 'Standard');
    expect(PdfCompression.compress.label, 'Compress');
    expect(
      PdfCompression.compress.explanation,
      'Reduce PDF size with slightly lower image quality.',
    );
  });
}
