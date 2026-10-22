# Phase 2 — OCR result, translation and the PDF workflows

The second phase of the Figma redesign: everything Phase 1 deliberately left
alone. Scope: the **OCR result screen**, the **translation design**, and all
**PDF functionality** — import, viewer, page selection, and creation from the
camera, the gallery or an imported document.

Figma frames this phase implements:

| Frame | Where it is implemented |
| --- | --- |
| `Result` (image, extracted text, translate) | `lib/screens/ocr_result_screen.dart`, `lib/screens/widgets/extracted_text_view.dart`, `lib/translation/presentation/widgets/translation_tab.dart` |
| `Translate overlay` (translated text on the photo) | `lib/translation/presentation/widgets/translation_overlay.dart` |
| `Capture pages` | `lib/pdf/presentation/pdf_capture_screen.dart` |
| `Review pages` | `lib/pdf/presentation/pdf_review_screen.dart` |
| `Created PDF` | `lib/pdf/presentation/widgets/pdf_success_sheet.dart` |
| `Select pages` | `lib/pdf/presentation/pdf_page_selection_screen.dart` |
| `View PDF` | `lib/pdf/presentation/pdf_viewer_screen.dart` |

> The design file (`jOjC1z1GxtaSLi98iBaxYm`) is a view-only session, so **no
> node id for a Phase 2 frame is recorded here** — the Phase 1 document holds the
> four ids that were verified (`2:1119`, `7:1423`, `7:1500`, `7:1577`), and
> inventing the rest would be worse than leaving them out. The frames are
> identified by name.

## 1. What the OCR result screen became

`ResultTabBar` (`lib/screens/widgets/result_tab_bar.dart`) is the designed
segmented control — `Image · Extracted Text · Translate` — and the screen owns
which reading is showing. It is a row of buttons over a pill, not a
`TabBar`/`TabBarView`: the three views are three *readings of one result*, not
three pages, and the screen must keep selection, search and translation state
alive across switches (asserted in `test/ocr_result_screen_test.dart`).

* **Image** — the photo, the OCR boxes, tap-to-select a word, the selection
  action bar, and the find bar. Unchanged in behaviour; the frame's layout.
* **Extracted Text** — `ExtractedTextBody`: the page as readable, selectable
  lines with a provenance summary ("N blocks, M words"), copy-all, in-text
  search with match stepping and highlighting, and **Show on photo**, which
  hands the query back to the Image tab so the match is ringed on the photo.
  The old bottom-sheet presentation (`ExtractedTextView`, 30 lines that cap the
  body's height) is still there and still tested, but the redesign routes
  through the tab, so nothing in the app opens it — see the comment on the
  class.
* **Translate** — the translation design, below.

## 2. What the translation design became

| File | Change |
| --- | --- |
| `lib/translation/presentation/widgets/translation_tab.dart` | **New.** The Translate reading of a result: language pair, swap, translate, `Show on image`, selectable translated text. |
| `lib/translation/presentation/widgets/translation_mode_bar.dart` | **Kept, restyled to the tokens.** The bar under the photo while it is in translation mode: target language, region count, **Full text** (opens the Translate tab) and **Show original** (back to selection). |
| `lib/translation/presentation/widgets/language_selector.dart` | **Kept.** The shared `From`/`To` picker, still driven by the language registry rather than a hard-coded list. |
| `lib/translation/presentation/widgets/translation_panel.dart` | **Deleted.** The superseded translation surface: after this phase nothing referenced it but its own widget test, and two surfaces for one feature is a bug, not a spare part. Recoverable from the backups in §5. |
| `lib/translation/presentation/widgets/translation_overlay.dart` | **Kept, extended.** Draws the translated text **in place of** the source boxes, interactive only over those boxes so word selection still works underneath. |
| `lib/translation/presentation/translated_overlay_deck.dart` | **New.** Placement engine: fits, wraps and de-overlaps translated text so a translation can be read on the image. |
| `lib/translation/presentation/translated_text_layout.dart` | **New.** Measures a translated string into a source box: font size, line cap, resolved style. |
| `lib/translation/presentation/ocr_translation_regions.dart` | **New.** Turns the current OCR result into the regions to translate (page, block, line or selection). |
| `lib/translation/domain/translated_region.dart` | **New.** One region's source text, translated text and source geometry. |
| `lib/translation/domain/translation_result.dart` | Records scope, auto-detection and whether the text was already in the target language. |

**Translation is no longer behind a build flag.** The `ENABLE_TRANSLATION`
dart-define, the `--dart-define=ENABLE_TRANSLATION=false` build variant and the
`TranslationFeature.enabled` gate are gone; `AppScope` always carries a
translation service, and `test/ocr_result_screen_test.dart` asserts both that
translation is reachable in the shipped build and that nothing in the UI depends
on the flag any more.

## 3. What the PDF functionality became

Three of the six rows of the three sheets shipped badged `Coming soon` in Phase 1
(`Create PDF` from the camera, `Create PDF` from the gallery, and
`View PDF / Create PDF` on an imported document). All three were implemented
here, and the Import PDF row was then **removed** in the follow-up fixes below:

| Entry | Action | Flow |
| --- | --- | --- |
| Scan document | `Create PDF` | `PdfCaptureScreen` (multi-page session) → `PdfReviewScreen` → written file → `PdfSuccessSheet` |
| Choose image | `Create PDF` | multi-select picker → `PdfReviewScreen` → written file → `PdfSuccessSheet` |
| Import PDF | ~~`View PDF / Create PDF`~~ | **removed from Home.** The row opened `PdfViewerScreen` → `PdfPageSelectionScreen` → `PdfReviewScreen`; both screens still exist, but importing a PDF is now a single `Extract Text` action |
| Scan document / Choose image / Import PDF | `Extract Text` | unchanged OCR routes (`CameraCaptureScreen`, gallery, `PdfImportScreen`) |

### New domain layer (`lib/pdf/domain/`)

| File | Why it exists |
| --- | --- |
| `pdf_creation.dart` | `CreatedPdf` — the name, page count and **size read back from the file that was written**. A success sheet cannot claim success for a document that does not exist. |
| `pdf_page_draft.dart` | `PdfPageDraft` + `PdfPageOrigin`. A page being assembled is an image path and where it came from, nothing else. |
| `pdf_page_layout.dart` | Page geometry: fit the bitmap to A4 portrait/landscape or to its own aspect, with margins. Pure arithmetic, so testable. |
| `pdf_output_directory.dart` | Where a created file goes, as an interface. Android and `flutter test` answer differently and both must be able to run. |
| `pdf_exception.dart` | Every failure reaches the user as a sentence. |

### New data layer (`lib/pdf/data/`)

| File | Why it exists |
| --- | --- |
| `pdf_creation_services.dart` | The composition root for PDF creation — the counterpart of `main.dart`'s service builders, so screens depend on an interface and tests substitute their own. |
| `pdf_library_creation_service.dart` | The writer itself, built on `package:pdf`. |
| `native_pdf_output_directory.dart` | Android's cache directory via the app's own `pdf_utility/share` channel. `Directory.systemTemp` is not writable by an Android app process, and the cache directory is exactly what the existing FileProvider serves. |
| `pdf_file_exporter.dart` | Share sheet, or a copy in Downloads. |
| `pdfx_page_renderer.dart` | `pdfx` rasterisation of a page to an image, at a width chosen by `PdfPageRaster`. |

### New presentation layer (`lib/pdf/presentation/`)

| File | Why it exists |
| --- | --- |
| `pdf_capture_screen.dart` | A **multi-page** capture session. Separate from `CameraCaptureScreen`, which takes exactly one photo and returns — a mode flag in the OCR camera would make the app's most-used route pay for this one. |
| `pdf_review_screen.dart` | The pages in order: delete, drag to reorder, add from camera or gallery, edit the file name, then write the document. |
| `pdf_page_selection_screen.dart` | Choose pages of an imported PDF. Two raster policies for the same document: small for the grid, full-size for the pages actually chosen. |
| `pdf_viewer_screen.dart` | Page navigation over the imported document, read-only, with the way into Select pages. |
| `widgets/pdf_success_sheet.dart` | What to do with a PDF that exists: share, or save to Downloads. Saving **finishes the flow** (the sheet closes and the app returns Home); failures are reported and leave the sheet open. |

The imported document is **never rewritten**: selecting pages produces a
separate new file, so a page the user did not choose cannot go missing from the
file they imported.

## 4. Dependencies added

| Package | Version | Why |
| --- | --- | --- |
| `pdf` | `^3.13.1` | Writes the documents. Pure Dart, so no platform print service is involved. |
| `pdfx` | `^2.11.0` | Rasterises pages to images for the viewer and for OCR. Native, so a page can be rendered at a chosen resolution rather than read as text. |
| `file_picker` | `^13.1.0` | Imports a PDF through the system picker and returns a real path — which both the renderer and the OCR engine need. |

No other dependency was added. `path_provider` was deliberately **not** added:
the cache directory already comes from the app's own native channel.

## 5. Backups

Outside the project, in
`~/Desktop/shobhit/freelenceing/.backups/PDF Utility Flutter/`:

| Directory | Contents |
| --- | --- |
| `phase1-20261016-130237/` | Pre-Phase-1 snapshot. |
| `full-20261016-132434/` | Every file Phase 2 intended to modify, **before** it was modified. |
| `final-20261016-143816/` | The tree at the end of the implementation (`lib`, `test`, `android/app`, `pubspec.yaml`, `docs`), 171 files — taken **before** the documentation fixes and the panel deletion. |
| `delivered-20261016-145833/` | The delivered tree (170 files), refreshed after the final verification. |

No earlier backup was overwritten. The only file *removed* in this phase is
`lib/translation/presentation/widgets/translation_panel.dart` (with its test),
and it is present in `full-20261016-132434/`. Two files were edited in the final session
without a pre-change copy in `full-*` — `test/local_translation_service_test.dart`
(a brace that failed to parse) and `test/ocr_result_translation_widget_test.dart`
— but both are test files whose change is described in §6 and neither is needed
to build the app.

## 6. Verification

| Check | Result |
| --- | --- |
| `flutter test` | **544 tests, all passed** |
| `flutter analyze` | **No issues found** (twice, and again after the last edit) |
| `flutter build apk --release` | succeeded — see the artifact table |
| `flutter build apk --debug` | succeeded — see the artifact table |
| Independent PDF validation | see below |

| Artifact | Size | SHA-1 |
| --- | --- | --- |
| `build/app/outputs/flutter-apk/app-release.apk` | 138,331,681 B (138.3 MB) | `db02c2577aa13037c1d0e209bb7e7fbcb0f72cde` |
| `build/app/outputs/flutter-apk/app-debug.apk` | 259,931,488 B (259.9 MB) | `473de877b41b61673658a9cd0815da973af364f2` |

Both were rebuilt after the very last source edit, so each one is the tree as
delivered. (`app-debug-translation-enabled.apk` / `-disabled.apk` in the same
directory are leftovers from before the flag was removed; they are not part of
this delivery.)

(The count is 552 − 9 + 1: the superseded translation panel's nine widget tests
left with it, and one test was added — *a selection survives a trip through the
other tabs*, the assertion that the segmented control exists for. Nothing was
skipped or weakened.)

### The APK, checked as an artifact

Both APKs were built **after** the last source change (no file under `lib/`,
`pubspec.yaml` or `android/app/` is newer than either one), and the release
artifact was inspected rather than trusted:

```
$ unzip -t app-release.apk                                  # zip OK
$ apksigner verify -v app-release.apk
Verifies
Verified using v2 scheme (APK Signature Scheme v2): true
Signer #1 certificate DN: C=US, O=Android, CN=Android Debug

$ aapt2 dump badging app-release.apk
package: name='com.shobhit.pdfutility.pdf_utility_flutter' versionCode='1' versionName='1.0.0'
minSdkVersion:'24'  targetSdkVersion:'36'
uses-permission: android.permission.CAMERA, INTERNET, ACCESS_NETWORK_STATE, RECORD_AUDIO, …
```

* Native libraries for `arm64-v8a`, `armeabi-v7a` **and** `x86_64`: `libflutter`,
  `libapp`, `libmlkit_google_ocr_pipeline`, `libtranslate_jni`,
  `liblanguage_id_l2c_jni`, `libimage_processing_util_jni` — i.e. OCR, language
  identification and translation are all packaged, not resolved at runtime.
* The release build is R8-minified, and the Kotlin classes are inspected in
  `build/app/outputs/mapping/release/mapping.txt`: ML Kit's public class names
  (`com.google.mlkit.nl.translate.TranslateRemoteModel`, …) are **kept** while
  members are renamed, and `MainActivity` — which owns the app's
  `pdf_utility/model_manager` and `pdf_utility/share` channels — keeps its name.
  Both channel names, and the `cacheDirectory` method, are present in the dex.

### PDF generation, validated by a different engine

`test/pdf_output_verification_test.dart` writes a three-page document with the
app's own writer (portrait, landscape and square pages, so a renderer that
ignored the page boxes would be obvious) and leaves it at
`build/verification/pdf_creation_sample.pdf`. Poppler — an implementation of the
format that shares no code with `package:pdf` — then reads it:

```
$ pdfinfo build/verification/pdf_creation_sample.pdf
Pages:           3
Page size:       631.417 x 841.89 pts
PDF version:     1.7
Encrypted:       no
Creator:         PDF Utility

$ pdftoppm -png -r 40 build/verification/pdf_creation_sample.pdf /tmp/pdfcheck
page-1.png  351 × 468   (portrait)
page-2.png  468 × 351   (landscape, rotated)
page-3.png  468 × 468   (square)
```

Three pages, the three shapes the test asked for, each the right way up, and no
text layer (the pages are images) — `pdftotext` exits 0 and emits one form feed
per page.

## 7. Limits of this verification

* **Nothing was run on physical hardware.** Every check above is
  `flutter analyze`, `flutter test` (no native PDFium, no ML Kit, no camera) or
  the APK **building**. On-device behaviour — camera capture, the share sheet,
  the Downloads copy, PDFium preview, ML Kit OCR and translation — is wired and
  unit-tested against fakes, but has not been exercised on a device in this
  session.
* **The release APK is R8-minified and has not been run.** It builds, verifies
  and packages everything it should, but R8 shrinking is exactly the kind of
  change that only shows up at runtime. The debug APK (no shrinking) is the one
  to install for on-device testing; the release APK is the smaller one to
  sanity-check afterwards.
* Both APKs sign with the debug key (`android/app/build.gradle.kts` carries the
  template `TODO`), so they are installable and testable but not publishable.
* The Figma file is view-only, so colours, type scale and spacing are
  approximations recorded in `lib/app/app_theme.dart`; no token could be
  exported.

## 8. Follow-up fixes after the first device review

Four issues were reported from a device and fixed afterwards. They change
behaviour, so the sections above are read with these in mind.

### 8.1 The file name is the user's, and it is required

* `PdfDraft.fileName` now starts **empty**. The field shows the label `File name`
  and the hint `Enter file name`, with explicit dark ink on a light fill so it is
  legible on Android; it no longer pre-fills `document.pdf`.
* `PdfDraft.canCreate` requires **a page and a usable name**, so **Create PDF**
  stays disabled until both exist, and the panel says which one is missing.
* `pdfFileNameStem` / `sanitizePdfFileName` append `.pdf` exactly once:
  `Holiday`, `Holiday.pdf`, `Final.PDF` and `report.pdf.pdf` become `Holiday.pdf`,
  `Holiday.pdf`, `Final.pdf` and `report.pdf`. Characters no filesystem accepts
  become spaces, a pasted path keeps only its last segment, and a name that is
  only an extension (`.pdf`) is not a name.
* The resolved name is shown as `Will be saved as …` and is what the writer,
  the share sheet and the Downloads copy all receive.

### 8.2 Creating a PDF is finished by saving it

* The success sheet has **Share** and **Save a copy**. `Done` is gone.
* A successful *Save a copy* closes the sheet and returns **Home** by itself
  (`popUntil(isFirst)`), so the same end is reached from the camera, gallery and
  imported-page flows. Home is only reached after the export reported where the
  copy landed; that location is shown in a snackbar on Home.
* A failed save shows a concise message, leaves the sheet open and allows a
  retry. The action is disabled while a save is in flight (`Saving…`), and the
  sheet cannot be dismissed mid-save, so one tap cannot start two exports.

### 8.3 Import PDF has one action

The `View PDF / Create PDF` row is gone from the Home → Import PDF sheet.
`PdfViewerScreen` and `PdfPageSelectionScreen` remain in the tree (with their
tests) for the flows that need them; only the Home entry point was removed.

### 8.4 OCR failures are diagnosable, and no longer permanent

The user-facing failure path and the engine lifecycle are documented in
`docs/OCR_ARCHITECTURE.md` (§ *When recognition fails*). In short: the generic
message was hiding the real exception, a failed recognizer stayed cached for the
life of the process, and Auto threw away a usable Latin read when its Devanagari
pass failed. All three are fixed, and every entry point now reports through one
`showOcrFailure` helper that logs the original error under `PDF_UTILITY_OCR`.
