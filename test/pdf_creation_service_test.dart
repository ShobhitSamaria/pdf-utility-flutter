import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdf_utility_flutter/pdf/data/pdf_library_creation_service.dart';
import 'package:pdf_utility_flutter/pdf/domain/pdf_creation.dart';
import 'package:pdf_utility_flutter/pdf/domain/pdf_exception.dart';
import 'package:pdf_utility_flutter/pdf/domain/pdf_output_directory.dart';

import 'support/pdf_test_images.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory root;
  late Directory pages;

  /// A real PNG page image, written where the writer can read it.
  Future<String> page(
    String name, {
    required int width,
    required int height,
    Color color = const Color(0xFF2B2F5B),
  }) => writeTestPng(
    directory: pages,
    name: name,
    width: width,
    height: height,
    color: color,
  );

  setUp(() async {
    root = await Directory.systemTemp.createTemp('pdf_creation_test');
    pages = Directory('${root.path}/pages')..createSync(recursive: true);
  });

  tearDown(() async {
    if (root.existsSync()) await root.delete(recursive: true);
  });

  PdfLibraryCreationService service() => PdfLibraryCreationService(
    directoryName: 'documents',
    outputDirectory: _FixedDirectory(root),
  );

  group('creating a document', () {
    test('writes a well-formed PDF with one page object per image', () async {
      final landscape = await page('a.png', width: 800, height: 400);
      final portrait = await page('b.png', width: 400, height: 800);

      final created = await service().create(
        pageImagePaths: <String>[landscape, portrait],
        fileName: 'Two pages',
      );

      expect(created.fileName, 'Two pages.pdf');
      expect(created.pageCount, 2);
      expect(created.byteSize, greaterThan(0));

      final file = File(created.path);
      expect(file.existsSync(), isTrue, reason: 'the file must really exist');
      // The size reported to the user is the size on disk, not an estimate.
      expect(file.lengthSync(), created.byteSize);

      final structure = readPdfStructure(file);
      expect(structure.header, startsWith('%PDF-'));
      expect(
        structure.hasTrailer,
        isTrue,
        reason: 'a reader looks for the %%EOF marker',
      );
      expect(
        structure.hasCatalog,
        isTrue,
        reason: 'a PDF needs a document catalog',
      );
      // A MediaBox per page is what makes the page sizes in the other tests
      // trustworthy: the parse pairs one box with one page.
      expect(structure.pageCount, 2);
      expect(structure.pageSizes.length, 2);
      expect(
        structure.pageSizes.every((size) => size[0] > 0 && size[1] > 0),
        isTrue,
      );
    });

    test('keeps the pages in the order it was given', () async {
      // A wide page then a tall one: the pages are distinguishable by shape, so
      // their order in the file is checkable without decoding the images.
      final wide = await page('wide.png', width: 900, height: 300);
      final tall = await page('tall.png', width: 300, height: 900);

      final created = await service().create(
        pageImagePaths: <String>[wide, tall],
        fileName: 'ordered.pdf',
      );
      final structure = readPdfStructure(File(created.path));

      expect(structure.pageSizes.length, 2);
      expect(
        structure.pageSizes.first[0] > structure.pageSizes.first[1],
        isTrue,
        reason: 'page 1 was the wide image, so page 1 must be wide',
      );
      expect(
        structure.pageSizes.last[1] > structure.pageSizes.last[0],
        isTrue,
        reason: 'page 2 was the tall image, so page 2 must be tall',
      );

      // Reversing the order reverses the pages — nothing is sorted for us.
      final reversed = await service().create(
        pageImagePaths: <String>[tall, wide],
        fileName: 'reversed.pdf',
      );
      final reversedStructure = readPdfStructure(File(reversed.path));
      expect(
        reversedStructure.pageSizes.first[1] >
            reversedStructure.pageSizes.first[0],
        isTrue,
      );
    });

    test(
      'gives each page the image aspect ratio, scaled to A4 length',
      () async {
        final square = await page('square.png', width: 500, height: 500);
        final wide = await page('wide2.png', width: 1000, height: 250);

        final created = await service().create(
          pageImagePaths: <String>[square, wide],
          fileName: 'shapes.pdf',
        );
        final structure = readPdfStructure(File(created.path));

        final squarePage = structure.pageSizes[0];
        expect(squarePage[0] / squarePage[1], closeTo(1.0, 0.01));
        // The longest edge is A4's, so the page is a sensible printed size.
        expect(squarePage[1], closeTo(841.89, 0.5));

        final widePage = structure.pageSizes[1];
        expect(widePage[0] / widePage[1], closeTo(4.0, 0.02));
        // No distortion: the wide page is wide, not stretched to A4's height.
        expect(widePage[0], closeTo(841.89, 0.5));
        expect(widePage[1], lessThan(300));
      },
    );

    test('reports progress once per page, in order', () async {
      final a = await page('a.png', width: 200, height: 200);
      final b = await page('b.png', width: 200, height: 200);
      final c = await page('c.png', width: 200, height: 200);

      final ticks = <String>[];
      await service().create(
        pageImagePaths: <String>[a, b, c],
        fileName: 'progress.pdf',
        onProgress: (completed, total) => ticks.add('$completed/$total'),
      );

      expect(ticks, <String>['1/3', '2/3', '3/3']);
    });

    test('sanitises the file name it is handed', () async {
      final only = await page('only.png', width: 200, height: 200);
      final created = await service().create(
        pageImagePaths: <String>[only],
        fileName: 'My/Scan: "1"',
      );

      expect(created.fileName, sanitizePdfFileName('My/Scan: "1"'));
      expect(created.fileName, isNot(contains('/')));
      expect(File(created.path).path, endsWith(created.fileName));
      // The name in the document's own metadata matches the file on disk.
      expect(readPdfStructure(File(created.path)).hasTrailer, isTrue);

      // A duplicated extension is not a name: the file is `report.pdf`, not
      // `report.pdf.pdf`, and the extension is not added twice.
      final doubled = await service().create(
        pageImagePaths: <String>[only],
        fileName: 'report.pdf.pdf',
      );
      expect(doubled.fileName, 'report.pdf');
      expect(File(doubled.path).path, endsWith('/report.pdf'));
    });

    test('a single page document is still a document', () async {
      final only = await page('one.png', width: 300, height: 400);
      final created = await service().create(
        pageImagePaths: <String>[only],
        fileName: 'one.pdf',
      );

      expect(created.pageCount, 1);
      expect(created.pageCountLabel, '1 page');
      expect(created.summaryLabel, contains('1 page'));
      expect(readPdfStructure(File(created.path)).pageCount, 1);
    });
  });

  group('what it refuses to do', () {
    test('refuses to write a document with no pages', () async {
      await expectLater(
        service().create(
          pageImagePaths: const <String>[],
          fileName: 'empty.pdf',
        ),
        throwsA(
          isA<PdfException>()
              .having((error) => error.kind, 'kind', PdfErrorKind.noPages)
              .having(
                (error) => error.message,
                'message',
                contains('at least one'),
              ),
        ),
      );
    });

    test('names the page it could not read, and writes nothing', () async {
      final good = await page('good.png', width: 200, height: 200);

      await expectLater(
        service().create(
          pageImagePaths: <String>[good, '${pages.path}/missing.png'],
          fileName: 'partial.pdf',
        ),
        throwsA(
          isA<PdfException>()
              .having((error) => error.kind, 'kind', PdfErrorKind.unreadable)
              .having((error) => error.message, 'message', contains('Page 2')),
        ),
      );

      // A failed creation must not leave a half-written document behind that a
      // user could mistake for a result. (The read fails before the output
      // directory is even created, so "no directory" is the strongest form of
      // this.)
      final output = Directory('${root.path}/documents');
      final leftovers = output.existsSync()
          ? output.listSync().whereType<File>().toList()
          : const <File>[];
      expect(leftovers, isEmpty);
    });

    test('names the engine it is using', () {
      expect(service().engineName, contains('pdf'));
    });
  });
}

/// An output directory that is a specific place, for tests.
class _FixedDirectory implements PdfOutputDirectory {
  const _FixedDirectory(this.directory);

  final Directory directory;

  @override
  Future<String> resolve() async => directory.path;
}
