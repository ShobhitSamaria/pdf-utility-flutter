import 'pdf_creation.dart';

/// Where one page of a PDF being assembled came from.
///
/// Carried so the review screen can say *how* a page got there ("Captured",
/// "From gallery") and so a test can assert that a page kept its provenance
/// through a delete/reorder.
enum PdfPageOrigin {
  /// Photographed in the capture screen.
  camera,

  /// Chosen from the gallery / photo picker.
  gallery,

  /// A page of an existing PDF, re-rendered to an image.
  importedPage,
}

/// One page of a PDF that is still being assembled.
///
/// A draft page is just an image file plus where it came from — deliberately
/// nothing more. The pixel dimensions, the page size and the encoding are all
/// decided once, when the document is written (see `PdfPageLayout` and
/// `PdfLibraryCreationService`), so nothing in the UI can disagree with the
/// file that is produced.
class PdfPageDraft {
  const PdfPageDraft({
    required this.id,
    required this.imagePath,
    required this.origin,
  });

  /// Stable identity, unique within one draft.
  ///
  /// Order is only a list position, so a `ReorderableListView` needs something
  /// that survives a move — deleting or reordering by index alone would let a
  /// thumbnail animate against the wrong page.
  final int id;

  /// Absolute path of the page image on disk.
  final String imagePath;

  /// How this page was added.
  final PdfPageOrigin origin;

  /// Short label for the review UI.
  String get originLabel => switch (origin) {
    PdfPageOrigin.camera => 'Captured',
    PdfPageOrigin.gallery => 'From gallery',
    PdfPageOrigin.importedPage => 'From PDF',
  };

  @override
  String toString() => 'PdfPageDraft($id, ${origin.name}, $imagePath)';
}

/// The ordered pages of a PDF that has **not been written yet**.
///
/// An immutable value object, so every edit (add, delete, reorder, rename) is a
/// pure function of the previous draft. That is what makes the fiddly parts —
/// "did reordering keep every page exactly once?", "does deleting the page I
/// dragged change what I dragged?" — ordinary unit tests instead of something
/// only a device can answer.
///
/// The list is the document: [pages] order is the order the pages appear in the
/// produced file, and nothing sorts or de-duplicates them.
class PdfDraft {
  const PdfDraft({
    this.pages = const <PdfPageDraft>[],
    this.fileName = '',
    this.nextId = 1,
  });

  /// The pages, in document order.
  final List<PdfPageDraft> pages;

  /// The user's chosen file name, **empty until they type one**.
  ///
  /// Not sanitised here — the writer does that ([sanitizePdfFileName]), so the
  /// field can hold exactly what was typed. Deliberately not pre-filled with
  /// `document.pdf`: a name the app chose is a name the user did not, and it
  /// used to be saved silently.
  final String fileName;

  /// Next unused page id.
  final int nextId;

  bool get isEmpty => pages.isEmpty;

  bool get isNotEmpty => pages.isNotEmpty;

  int get pageCount => pages.length;

  /// Whether the user has entered a name that can be written.
  ///
  /// Spaces, punctuation-only entries and a bare `.pdf` do not count: the
  /// field is empty in every sense that matters.
  bool get hasFileName => isUsablePdfFileName(fileName);

  /// Whether there is enough here to write a document: at least one page **and**
  /// a name the user actually entered.
  bool get canCreate => pages.isNotEmpty && hasFileName;

  /// The file name exactly as it would be written.
  ///
  /// Falls back to [PdfCreationService.defaultFileName] when the field is empty,
  /// because the writer must always produce a file. The UI never gets there
  /// while [hasFileName] is false — the action stays disabled instead, so the
  /// fallback is never a name the user did not choose.
  String get resolvedFileName => sanitizePdfFileName(fileName);

  /// Adds [imagePaths] at the end, in the order given, numbering them from
  /// [nextId] so their identities stay stable across later edits.
  PdfDraft addAll(
    Iterable<String> imagePaths, {
    required PdfPageOrigin origin,
  }) {
    final added = <PdfPageDraft>[];
    var id = nextId;
    for (final path in imagePaths) {
      added.add(PdfPageDraft(id: id, imagePath: path, origin: origin));
      id++;
    }
    return PdfDraft(
      pages: <PdfPageDraft>[...pages, ...added],
      fileName: fileName,
      nextId: id,
    );
  }

  /// Adds a single page. Convenience over [addAll] for the capture flow.
  PdfDraft add(String imagePath, {required PdfPageOrigin origin}) =>
      addAll(<String>[imagePath], origin: origin);

  /// Removes the page at [index]. Out-of-range indexes are ignored, so a
  /// double-tap on a delete button cannot throw.
  PdfDraft removeAt(int index) {
    if (index < 0 || index >= pages.length) return this;
    return PdfDraft(
      pages: <PdfPageDraft>[
        ...pages.sublist(0, index),
        ...pages.sublist(index + 1),
      ],
      fileName: fileName,
      nextId: nextId,
    );
  }

  /// Moves a page, using `ReorderableListView.onReorder`'s convention.
  ///
  /// [newIndex] is the index the dragged item would occupy **before** it is
  /// removed, so moving an item *down* the list needs the usual `-1`
  /// adjustment. Doing it here (once, with a test) rather than at the call site
  /// is the difference between a reorder that works and one that is off by one
  /// in one direction only.
  PdfDraft reorder(int oldIndex, int newIndex) {
    if (oldIndex < 0 || oldIndex >= pages.length) return this;

    var target = newIndex;
    if (target > oldIndex) target -= 1;
    if (target < 0) target = 0;
    if (target >= pages.length) target = pages.length - 1;
    if (target == oldIndex) return this;

    final reordered = <PdfPageDraft>[...pages];
    final moved = reordered.removeAt(oldIndex);
    reordered.insert(target, moved);
    return PdfDraft(pages: reordered, fileName: fileName, nextId: nextId);
  }

  /// Moves the page at [from] so that it ends up at index [to] **after** the
  /// move.
  ///
  /// This is the rule "drop it on top of that page means it goes there", which
  /// is what the review grid's drag-and-drop means by a drop. It is deliberately
  /// separate from [reorder], whose arguments follow Flutter's
  /// `ReorderableListView` convention, because mixing the two up is the classic
  /// off-by-one. Both are pure and both are tested.
  PdfDraft moveTo(int from, int to) {
    if (from < 0 || from >= pages.length) return this;
    var target = to.clamp(0, pages.length - 1);
    if (target == from) return this;

    final reordered = <PdfPageDraft>[...pages];
    final moved = reordered.removeAt(from);
    reordered.insert(target, moved);
    return PdfDraft(pages: reordered, fileName: fileName, nextId: nextId);
  }

  /// Removes every page. Keeps the file name, so "clear and start again" does
  /// not also discard what the user typed.
  PdfDraft cleared() => PdfDraft(fileName: fileName, nextId: nextId);

  /// Sets the output file name (raw — sanitised on read).
  PdfDraft withFileName(String name) =>
      PdfDraft(pages: pages, fileName: name, nextId: nextId);

  /// Absolute paths of the pages, in document order — exactly what the writer
  /// is handed.
  List<String> get pageImagePaths => <String>[
    for (final page in pages) page.imagePath,
  ];

  @override
  String toString() => 'PdfDraft(${pages.length} pages, "$fileName")';
}
