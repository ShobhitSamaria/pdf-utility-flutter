import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdf_utility_flutter/pdf/data/pdf_creation_services.dart';
import 'package:pdf_utility_flutter/pdf/domain/pdf_creation.dart';
import 'package:pdf_utility_flutter/pdf/domain/pdf_output_directory.dart';

import 'support/pdf_test_images.dart';

/// Writes a real document with the app's own writer and leaves it on disk.
///
/// The other PDF tests assert structure in-process. This one exists so the file
/// can be **re-opened by an independent PDF engine** after the fact — on this
/// machine, poppler's `pdfinfo` and `pdftoppm`:
///
/// ```
/// flutter test test/pdf_output_verification_test.dart
/// pdfinfo build/verification/pdf_creation_sample.pdf
/// pdftoppm -png -r 40 build/verification/pdf_creation_sample.pdf /tmp/render
/// ```
///
/// That is the difference between "our reader accepts our writer's output" and
/// "a different implementation of the format accepts it". The test asserts the
/// in-process structure too, so it is a real test and not only an artifact
/// generator.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('emits a three-page document for an external parser to check', () async {
    final root = await Directory.systemTemp.createTemp('pdf_verification');
    final pages = Directory('${root.path}/pages')..createSync(recursive: true);
    final output = Directory('${Directory.current.path}/build/verification')
      ..createSync(recursive: true);

    // One portrait, one landscape and one square page: three different shapes,
    // so a renderer that ignored the page boxes would be obvious.
    final portrait = await writeTestPng(
      directory: pages,
      name: 'portrait.png',
      width: 600,
      height: 800,
      color: const Color(0xFF242A5C),
    );
    final landscape = await writeTestPng(
      directory: pages,
      name: 'landscape.png',
      width: 800,
      height: 600,
      color: const Color(0xFF6B7186),
    );
    final square = await writeTestPng(
      directory: pages,
      name: 'square.png',
      width: 700,
      height: 700,
      color: const Color(0xFFEDEEFA),
    );

    final created =
        await createPdfCreationService(outputDirectory: _Into(output)).create(
          pageImagePaths: <String>[portrait, landscape, square],
          fileName: 'pdf_creation_sample.pdf',
        );

    final structure = readPdfStructure(File(created.path));
    expect(structure.header, startsWith('%PDF-'));
    expect(structure.hasTrailer, isTrue);
    expect(structure.hasCatalog, isTrue);
    expect(structure.pageCount, 3);
    expect(created.pageCount, 3);
    expect(created.byteSize, greaterThan(1000));

    // Keep the document where the verification step can find it.
    final artifact = File('${output.path}/pdf_creation_sample.pdf');
    await File(created.path).copy(artifact.path);

    // ignore: avoid_print
    print('PDF artifact: ${artifact.path} (${created.byteSizeLabel})');
    // ignore: avoid_print
    print('Page sizes (points): ${structure.pageSizes}');

    await root.delete(recursive: true);
  });

  test('names the document from what the user typed, exactly once', () async {
    final root = await Directory.systemTemp.createTemp('pdf_name_verification');
    final page = await writeTestPng(
      directory: root,
      name: 'page.png',
      width: 600,
      height: 800,
    );
    final output = Directory('${Directory.current.path}/build/verification')
      ..createSync(recursive: true);
    final writer = createPdfCreationService(outputDirectory: _Into(output));

    // What the review screen passes for a field containing these strings.
    final noExtension = await writer.create(
      pageImagePaths: <String>[page],
      fileName: 'Holiday 2026',
    );
    final doubled = await writer.create(
      pageImagePaths: <String>[page],
      fileName: 'report.pdf.pdf',
    );

    expect(noExtension.fileName, 'Holiday 2026.pdf');
    expect(doubled.fileName, 'report.pdf');
    expect(File(noExtension.path).existsSync(), isTrue);
    expect(File(doubled.path).existsSync(), isTrue);

    // Keep both where the verification step (`pdfinfo`) can read them.
    for (final created in <CreatedPdf>[noExtension, doubled]) {
      await File(created.path).copy('${output.path}/${created.fileName}');
      // ignore: avoid_print
      print('Named PDF artifact: ${output.path}/${created.fileName}');
    }

    await root.delete(recursive: true);
  });
}

/// An output directory that is a specific place, for this test.
class _Into implements PdfOutputDirectory {
  const _Into(this.directory);

  final Directory directory;

  @override
  Future<String> resolve() async => directory.path;
}
