import 'package:flutter_test/flutter_test.dart';
import 'package:pdf_utility_flutter/pdf/domain/pdf_creation.dart';
import 'package:pdf_utility_flutter/pdf/domain/pdf_page_draft.dart';

void main() {
  PdfDraft draftOf(int count) => const PdfDraft().addAll(<String>[
    for (var index = 1; index <= count; index++) '/p$index.jpg',
  ], origin: PdfPageOrigin.camera);

  List<String> paths(PdfDraft draft) => draft.pageImagePaths;

  group('adding pages', () {
    test('appends in the order given, with stable ids', () {
      final draft = draftOf(3);

      expect(paths(draft), <String>['/p1.jpg', '/p2.jpg', '/p3.jpg']);
      expect(draft.pages.map((page) => page.id).toList(), <int>[1, 2, 3]);

      // A second batch keeps counting, so a page added later can never take an
      // id an earlier page already has.
      final more = draft.addAll(<String>[
        '/p4.jpg',
      ], origin: PdfPageOrigin.gallery);
      expect(more.pages.last.id, 4);
      expect(more.pages.last.origin, PdfPageOrigin.gallery);
    });

    test('a single add is the same as adding a one-item list', () {
      final single = draftOf(1).add('/p9.jpg', origin: PdfPageOrigin.gallery);
      expect(paths(single), <String>['/p1.jpg', '/p9.jpg']);
    });

    test('an empty draft has nothing to create from', () {
      const empty = PdfDraft();
      expect(empty.isEmpty, isTrue);
      expect(empty.canCreate, isFalse);
      expect(empty.pageCount, 0);
      expect(empty.pageImagePaths, isEmpty);
    });
  });

  group('deleting pages', () {
    test('removes exactly the page asked for', () {
      final draft = draftOf(3).removeAt(1);
      expect(paths(draft), <String>['/p1.jpg', '/p3.jpg']);
      // The surviving pages keep their identity, which is what a grid animating
      // a deletion depends on.
      expect(draft.pages.map((page) => page.id).toList(), <int>[1, 3]);
    });

    test('the first and last pages can be deleted', () {
      expect(paths(draftOf(3).removeAt(0)), <String>['/p2.jpg', '/p3.jpg']);
      expect(paths(draftOf(3).removeAt(2)), <String>['/p1.jpg', '/p2.jpg']);
    });

    test('an out-of-range index is ignored rather than throwing', () {
      final draft = draftOf(2);
      expect(identical(draft.removeAt(-1), draft), isTrue);
      expect(identical(draft.removeAt(5), draft), isTrue);
    });

    test('deleting every page still keeps the file name', () {
      final named = draftOf(2).withFileName('Holiday');
      final cleared = named.pages.fold(named, (draft, _) => draft.removeAt(0));
      expect(cleared.isEmpty, isTrue);
      expect(cleared.fileName, 'Holiday');
    });
  });

  group('reordering with ReorderableListView semantics', () {
    test('dragging downwards needs no extra adjustment by the caller', () {
      // Flutter reports the target index *before* the item is lifted out, so
      // moving 0 down one place arrives as (0, 2).
      expect(paths(draftOf(3).reorder(0, 2)), <String>[
        '/p2.jpg',
        '/p1.jpg',
        '/p3.jpg',
      ]);
    });

    test('dragging upwards is the plain index', () {
      expect(paths(draftOf(3).reorder(2, 0)), <String>[
        '/p3.jpg',
        '/p1.jpg',
        '/p2.jpg',
      ]);
    });

    test('dragging to the end lands on the end', () {
      expect(paths(draftOf(4).reorder(0, 4)), <String>[
        '/p2.jpg',
        '/p3.jpg',
        '/p4.jpg',
        '/p1.jpg',
      ]);
    });

    test('a no-op move changes nothing', () {
      final draft = draftOf(3);
      expect(paths(draft.reorder(1, 1)), paths(draft));
      // (1, 2) is also a no-op: the item would go back where it was.
      expect(paths(draft.reorder(1, 2)), paths(draft));
      // An out-of-range source is ignored.
      expect(identical(draft.reorder(9, 0), draft), isTrue);
    });
  });

  group('reordering by dropping onto another page', () {
    test('the dragged page takes the drop target position', () {
      expect(paths(draftOf(3).moveTo(0, 2)), <String>[
        '/p2.jpg',
        '/p3.jpg',
        '/p1.jpg',
      ]);
      expect(paths(draftOf(3).moveTo(2, 0)), <String>[
        '/p3.jpg',
        '/p1.jpg',
        '/p2.jpg',
      ]);
    });

    test('an out-of-range target is clamped, and a self-drop is a no-op', () {
      final draft = draftOf(3);
      expect(paths(draft.moveTo(0, 9)), <String>[
        '/p2.jpg',
        '/p3.jpg',
        '/p1.jpg',
      ]);
      expect(identical(draft.moveTo(1, 1), draft), isTrue);
      expect(identical(draft.moveTo(7, 0), draft), isTrue);
    });

    test('every page survives every move exactly once', () {
      final draft = draftOf(5);
      for (var from = 0; from < 5; from++) {
        for (var to = 0; to < 5; to++) {
          final moved = draft.moveTo(from, to);
          expect(moved.pageCount, 5);
          expect(
            moved.pageImagePaths.toSet().length,
            5,
            reason: 'moveTo($from, $to) lost or duplicated a page',
          );
        }
      }
    });
  });

  group('the output file name', () {
    test('is kept raw in the field and sanitised for the writer', () {
      final draft = draftOf(1).withFileName('My/Scan: 1');
      // What the user typed...
      expect(draft.fileName, 'My/Scan: 1');
      // ...and what will actually be written. A pasted path keeps only its last
      // segment (this is a name, not a destination), and the characters no
      // filesystem accepts become spaces rather than failing the export.
      expect(draft.resolvedFileName, 'Scan 1.pdf');
      expect(draft.resolvedFileName, sanitizePdfFileName('My/Scan: 1'));
    });

    test('starts empty, so no default name can be saved by accident', () {
      const empty = PdfDraft();
      expect(empty.fileName, isEmpty);
      expect(empty.hasFileName, isFalse);
      expect(empty.canCreate, isFalse);
      // The *writer* still needs a name, so the fallback exists — but the UI
      // never reaches it while the field is empty.
      expect(empty.resolvedFileName, PdfCreationService.defaultFileName);
    });

    test('a blank field is not a name, even with pages', () {
      for (final blank in <String>['', '   ', '\t\n', '///']) {
        final draft = draftOf(2).withFileName(blank);
        expect(draft.hasFileName, isFalse, reason: '"$blank"');
        expect(draft.canCreate, isFalse, reason: '"$blank"');
      }
    });

    test('a real name with pages is what enables creation', () {
      final draft = draftOf(1).withFileName('Trip');
      expect(draft.hasFileName, isTrue);
      expect(draft.canCreate, isTrue);
      expect(draft.resolvedFileName, 'Trip.pdf');

      // No pages, no document, however good the name is.
      expect(const PdfDraft().withFileName('Trip').canCreate, isFalse);
    });

    test('renaming does not disturb the pages', () {
      final original = draftOf(3);
      final renamed = original.withFileName('Report.pdf');
      expect(paths(renamed), paths(original));
      expect(renamed.pageCount, 3);
    });

    test('the extension is added exactly once', () {
      // Typed without one, with one, in capitals, or with a duplicate from a
      // pasted name — all produce a single `.pdf`.
      expect(
        draftOf(1).withFileName('Holiday').resolvedFileName,
        'Holiday.pdf',
      );
      expect(
        draftOf(1).withFileName('Holiday.pdf').resolvedFileName,
        'Holiday.pdf',
      );
      expect(
        draftOf(1).withFileName('Final.PDF').resolvedFileName,
        'Final.pdf',
      );
      expect(
        draftOf(1).withFileName('report.pdf.pdf').resolvedFileName,
        'report.pdf',
      );
      expect(
        draftOf(1).withFileName('report.pdf.PDF').resolvedFileName,
        'report.pdf',
      );
      expect(
        draftOf(1).withFileName('report.pdf.').resolvedFileName,
        'report.pdf',
      );
    });

    test('a name that is only an extension is not a name', () {
      for (final onlyExtension in <String>['.pdf', '.PDF', '...', '. .pdf']) {
        final draft = draftOf(1).withFileName(onlyExtension);
        expect(draft.hasFileName, isFalse, reason: onlyExtension);
      }
    });
  });

  group('cleared', () {
    test('drops the pages and keeps the name and id counter', () {
      final cleared = draftOf(2).withFileName('Report').cleared();
      expect(cleared.isEmpty, isTrue);
      expect(cleared.fileName, 'Report');
      // Adding again must not reuse an id that a previous page had.
      expect(
        cleared.add('/new.jpg', origin: PdfPageOrigin.camera).pages.single.id,
        3,
      );
    });
  });
}
