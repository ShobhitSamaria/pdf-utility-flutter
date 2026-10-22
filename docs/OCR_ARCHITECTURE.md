# OCR POC Architecture

This document explains the OCR foundation in this Flutter app: the layers, the
coordinate system, and how the flow is wired. It covers **only** the OCR +
geometry layer; PDF import/creation is documented separately in the code under
`lib/pdf/` and in [`PHASE2_REDESIGN.md`](PHASE2_REDESIGN.md).

On-device translation (the `Translate` action, including the Lens-like overlay
that paints translated text back onto the photo) is implemented as a **separate,
sibling module** that never imports this one. It *reuses* this layer's geometry —
the same `OcrCoordinateMapper` and the original OCR rectangles — so there is only
ever one image→screen transform; see
[`TRANSLATION_ARCHITECTURE.md`](TRANSLATION_ARCHITECTURE.md).

Translation is a permanent feature with no build flag; everything described
below under *Scripts* and *Extracted text* is what the OCR layer itself
provides, and the translation modules build on top of it.

## Flow

```
Camera / Gallery
      │  (file path)
      ▼
ImageSourceService / CameraCaptureScreen
      │
      ▼
OcrService.recognizeImage(path)          ← UI depends on this abstraction only
      │
      ▼
LocalOcrService  →  OcrEngine (interface)
      │
      ▼
MlKitOcrEngine                            ← the ONLY file importing ML Kit
      │  InputImage.fromFilePath(path)
      ▼
Google ML Kit Text Recognition (on-device)
      │
      ▼
OcrResult { SourceImageInfo, blocks → lines → elements (words) + OcrRect }
      │
      ▼
OcrResultScreen → OcrOverlay → OcrCoordinateMapper (image px → screen px)
```

Everything runs locally on the device. There is no cloud call, no Tesseract,
and no Python backend.

## Layers

| Layer | Path | Responsibility |
| --- | --- | --- |
| Domain models | `lib/ocr/domain/` | Engine-agnostic result types and the `OcrEngine` / `OcrService` interfaces. Framework-free where possible. |
| Data | `lib/ocr/data/` | Concrete ML Kit engine, image decoder, gallery source, `LocalOcrService`. |
| Presentation | `lib/ocr/presentation/` | Coordinate mapper, hit tester, overlay widgets. |
| Screens | `lib/screens/` | Home, camera capture, OCR result, selection action bar. This is the only layer that knows about both OCR and translation. |
| DI | `lib/app/app_scope.dart` | Tiny `InheritedWidget` providing the `OcrService`, the `TranslationService`, and the debug toggle. |

### Why an `OcrEngine` / `OcrService` split?

* `OcrEngine` is the pluggable algorithm seam (swap ML Kit for another
  on-device engine).
* `OcrService` is the app-facing API the UI uses. It hides engine choice and
  configuration so screens never import ML Kit.
* The composition root (`lib/main.dart` → `createOcrService()`) is the single
  place that picks the concrete engine.

## Coordinate system (critical)

**Every rectangle in an `OcrResult` is in _source-image pixel coordinates_.**

* Origin `(0, 0)` is the top-left of the **upright** image (EXIF rotation
  already applied). This matches ML Kit's default coordinate space.
* `SourceImageInfo.width` / `height` are the upright pixel dimensions.
* `OcrRect` uses `left/top/right/bottom`, right/bottom exclusive, mirroring
  Flutter's `Rect`.

### Image → screen mapping

The image is displayed with `BoxFit.contain`, which scales uniformly and
letterboxes. `OcrCoordinateMapper` reproduces exactly that transform:

```
scale      = min(viewportW / imageW, viewportH / imageH)
displayedW = imageW * scale
displayedH = imageH * scale
dx         = (viewportW - displayedW) / 2     // horizontal letterbox
dy         = (viewportH - displayedH) / 2     // vertical letterbox

screenX = imageX * scale + dx
screenY = imageY * scale + dy
```

Assumptions (documented in code too):

1. Uniform scaling on both axes (`BoxFit.contain` guarantees this).
2. No on-screen rotation/flip of the image. If that is ever added, the mapper
   must gain a rotation term.
3. Coordinates are **logical** pixels — device pixel ratio is not applied here
   because Flutter layout sizes are already logical.
4. The decoder (`ImageDecoder`) applies EXIF orientation, so image and OCR
   coordinates share the same upright space.

`screenToImage` is the inverse, returning `null` for taps in the letterbox
region. It is the basis for future word-selection hit-testing.

### A page photographed sideways

EXIF describes how the *camera* was held, not how the *document* was. A
landscape page photographed in portrait arrives with perfectly upright metadata
and turned pixels, so the boxes above are correct yet describe tall strips, and
the page is unreadable on screen. Measured on the reported photograph
(`test/assets/real/newspaper_hindi_portrait.png`, 899×1599, no EXIF turn): a
first read returns 38 lines at 89.8–89.9° whose boxes are 20–30 px wide and up
to 1 563 px tall.

`OrientationAwareOcrService` wraps the service and fixes this **before** the UI
sees anything:

1. Read once.
2. `DocumentOrientationDetector` decides whether the page is turned, from the
   **shape** of the line boxes (tall = sideways) and the **order of the words**
   inside them (reading downwards or upwards picks the direction). It does not
   use the sign of `TextLine.angle`, whose convention is not stated
   consistently; the magnitude alone is used for the 180° case, where both
   signs mean the same image.
3. If the page is turned, `UiImageRotator` writes an upright PNG copy (quarter
turn, no resampling beyond an optional downscale cap) and the service reads
   again.
4. The returned result is the **second** read, whose `sourceImage.path` is the
upright copy — so the photo on screen *is* the image the boxes were measured
against, and every coordinate consumer (overlay, hit-testing, translation
regions, search) is unchanged.

`OcrResult.orientation` reports the turn that was applied (`wasRotated`), which
is history for diagnostics and tests, not a transform waiting to be re-applied.
The cost is one extra recognition pass on sideways pages only; upright pages
are read once. If the corrective pass fails, the first read is returned and the
reason is logged rather than turning a usable result into an error.

## Overlay rules

* The **original image is the base layer**; it is never replaced or filtered.
* No scrim, no crop/review/filter flow.
* Recognized text is **invisible by default** and only becomes visible when a
  word is selected (future copy/search/translate) or in debug mode. This
  prevents any permanent colored layer over the photo.
* `debugGeometry` (default **OFF**) is the only thing that draws bounding boxes
  and word labels. It is toggled from the home screen and the result app bar.

## Text selection (Google Lens-like)

Interaction model on the result screen:

* **Tap** a word → select just that word (replaces any selection).
* **Long-press then drag** → select a **range**: the pressed word is the anchor
  and every word between it and the finger is selected, in reading order. The
  range grows and shrinks both ways as the finger moves, so a multi-word
  selection reads naturally no matter which direction the drag goes. A
  long-press that never moves just selects its own word.
* **Tap empty image area / letterbox** → clear the selection.

Architecture:

* `OcrSelection` (`lib/ocr/domain/ocr_selection.dart`) is the multi-word model:
  an **ordered, de-duplicated list of `OcrElement`s**, always sorted into OCR
  reading order. It is intentionally *not* a text range, so it stays aligned
  with per-word geometry. `add`/`remove`/`toggle`/`only`/`clear`/`addAll` and
  `range(anchor, extent)` are pure and immutable; `text` concatenates the
  selected words with single spaces using each word's original OCR text.
  `range` is what a drag uses: it returns every selectable word between the two
  endpoints (inclusive), sorted into reading order, so argument order does not
  matter. `isContiguous` describes such a run.
* `OcrTextUtils` (`lib/ocr/domain/ocr_text_utils.dart`) defines what is
  selectable: non-empty text + non-degenerate box, with **exact duplicates**
  (same text *and* same box) collapsed, order preserved. Repeated words at
  different positions are all kept.
* `OcrHitTester` (`lib/ocr/presentation/ocr_hit_tester.dart`) maps a **screen**
  tap to a word by reusing `OcrCoordinateMapper.screenToImage` — the exact
  inverse of the render transform — then does a point-in-rect search
  (smallest box wins on overlap). It exposes the same `selectableElements` the
  overlay renders, so *what you see is what you can hit*. A companion
  `nearestElementAtScreen` snaps to the closest word instead of returning
  `null`, which is what keeps a drag growing as the finger crosses the gaps
  between words or lines (taps still use the exact hit test).
* `OcrOverlay` owns a **single gesture path**: one `GestureDetector` over the
  whole viewport resolves taps, long-presses, and long-press drags via the hit
  tester. Taps that miss every word report `null`, which the screen interprets
  as "clear selection". A long-press reports its anchor word (`onSelectionStart`),
  each drag update reports the word under the finger (`onSelectionUpdate`), and
  release reports the end (`onSelectionEnd`). Debug geometry is wrapped in
  `IgnorePointer`, so it can never affect hit-testing.

Actions (shown in `SelectionActionBar` only while a selection exists):

* **Copy** — writes `OcrSelection.text` to the clipboard.
* **Search** — opens the device browser (via `url_launcher`) with a web search
  for the selected text.
* **Share** — hands the selected text to the Android share sheet through the
  `pdf_utility/share` channel (`TextSharer`). Native, because text sharing is one
  `ACTION_SEND` intent and this phase adds no Dart dependency for it.
* **Translate** — opens the inline on-device translation section for
  `OcrSelection.text` (auto-detect → English by default on a scanned page). See
  [`TRANSLATION_ARCHITECTURE.md`](TRANSLATION_ARCHITECTURE.md). The app bar
  offers the same for the whole page.

  Translation is a **normal, always-available** feature: there is no build flag,
  `dart-define` or debug switch that turns it on or off. It used to be gated
  behind `ENABLE_TRANSLATION`, which meant a shipped release build had no way to
  reach it at all, so the switch was removed rather than defaulted differently.

## Reading order and document layout

`OcrResult.fullText` and the engine's block order are **not** a reading order.
On a newspaper page ML Kit can return the right-hand column before the left one,
and it can return one block for the whole page. Building the readable text or the
page translation directly from that order is what made Hindi→English output jump
between columns and read as disconnected fragments.

`OcrDocumentLayout` (`lib/ocr/domain/ocr_document_layout.dart`) recovers the
structure from geometry alone, so it works for any document type:

* **Columns first** — the page is split at vertical free channels (gutters) that
  run the full height of the region, and the resulting columns are read left to
  right. Looking for gutters *before* horizontal splits is what stops two
  columns whose paragraph gaps line up from being read row by row.
* **Then bands** — a full-width headline blocks every gutter, so it is separated
  by the largest horizontal free band and read before the body beneath it.
* **Then top-to-bottom** — a single column with no clear gaps is read down.
* **Tables** — when the gutter-separated bands behave like a grid (short,
  single-line cells aligned across columns) they are read row by row, so a table
  or receipt does not become one column after another. A run of prose in a
  column is recognised by its tall multi-line blocks and is never mistaken for a
  grid.
* **Paragraphs** — neighbouring lines of one column are grouped when they are
  vertically tight (within 0.8 of a line height) and typographically alike
  (line-height ratio ≥ 0.7), so a heading or a caption is not glued onto the body
  under it. A group carries a stable id, its lines and the union rectangle.
  Paragraphs are formed over the **whole ordered page**, not block by block: ML
  Kit regularly cuts one printed paragraph at a block boundary, and paragraphing
  each block in isolation split one sentence into two translation units. An
  across-block join additionally requires a leading-sized gap (≤ 0.45 of a line)
  and at least one multi-line block on either side, so two tightly stacked table
  cells or list rows are never merged into one row-spanning paragraph. Lines
  inside a block are ordered with the same whitespace cut as the page, because a
  single block can itself span two columns.

The result is `List<OcrLayoutBlock>` in reading order. Both the readable-text
sheet and the page translation are built from it; nothing else re-guesses the
order. Thresholds are expressed as fractions of the page's own median line
height, never as absolute pixels, so a phone photo and a PDF page render at any
scale without retuning.

## Reading the text instead of the photo

**Read text** in the strip under the photo opens `ExtractedTextView`: the whole
page as selectable text, one line per recognized line, **in document reading
order** (see above), with **Copy all** and its own find field. Copy all keeps
paragraph breaks, so the copied page reads like the page, not like engine
output. It is deliberately
*not* behind the translation flag — reading the text of a page is a core OCR
feature, and it is the fallback when the overlay is not enough (text drawn tiny,
a page photographed at an angle, a read that produced text but no usable word
geometry).

Its search works on the text as text (`OcrTextFinder`), which is a different
surface from the find-on-photo search below: that one maps a hit back to a
bounding box, this one highlights characters in the readable view. Where both
are available, **Show on photo** hands the current query to the screen and closes
the sheet, so the same matches light up on the image through the existing
selection highlight.

`OcrTextFinder` performs no Unicode normalization, for the same reason as
document search — see below.

## Finding text in a result

The app bar's search action opens an in-document find bar
(`OcrDocumentSearch`): match count plus previous/next, case-insensitive, on the
recognized words joined by single spaces — the same text `OcrSelection.text`
produces. A hit is a **range of words**, so it is shown with the existing
selection highlight rather than a second highlighting mechanism.

Two boundaries are handled explicitly so a match never lands somewhere
meaningless: a match may not begin on a low surrogate (which would split an
astral code point), and a match is extended across trailing combining marks and
Devanagari vowel signs/virama/nukta so `क` does not match the base of `कि`.

**No Unicode normalization is applied.** Dart's core library ships no
normalizer and this phase adds no dependency, so a composed form and its
decomposed equivalent do not match each other. The matcher is confined to
`lib/ocr/domain/ocr_document_search.dart` so adding normalization later is a
one-file change.

## Extension points (not implemented yet)

* **Chinese / Japanese / Korean** — same mechanism as Devanagari (see
  "Scripts" below); no request reaches them yet.
* **QR / barcode** — add a sibling overlay layer; ML Kit barcode scanning would
  follow the same engine/service pattern.
* **PDF ingestion** — not started. See the PDF priority list in
  [`OCR_BENCHMARK.md`](OCR_BENCHMARK.md) for what comes first when it is.

## Scripts

The mode is carried in `OcrScriptMode` and handed to
`OcrService.recognizeImage(path, mode:)`:

| Mode | What runs | Notes |
| --- | --- | --- |
| `auto` | Latin probe, then Devanagari **only if needed** | **Default.** Chooses the recognizer from the photo. |
| `latin` | Latin recognizer | Override. Printed English and other Latin-script text. |
| `devanagari` | Devanagari recognizer | Override. Printed Hindi. |
| `mixed` | Latin **and** Devanagari, then a merge | Override. Experimental. Roughly twice the latency; accuracy unmeasured. |

ML Kit ships one recognizer **per script** and none of them reads two scripts
well — the Devanagari model is a separate model from the Latin one. So a mixed
Hindi/English page cannot be solved by choosing a single recognizer, and the two
honest options are: let the user pick (fast), or read the page twice and merge
(slow, and only as good as the merge rule).

### Automatic script detection (`auto`)

Asking the user whether their document is "Latin" or "Devanagari" is asking them
to do the app's job, and getting it wrong produces nothing usable rather than
something merely worse. So `auto` is the default and the three fixed modes are
disclosed as overrides.

ML Kit has **no image-level script detector**, and this is easy to get wrong: the
Language Identification API classifies a *string*
(`LanguageIdentifier.identifyLanguage(text)`), not a bitmap, so it cannot be
pointed at a photo. The only way to learn a photo's script is to recognize it, so
`auto` uses the **Latin recognizer as a probe** — it is the cheaper model, it is
already bundled, and on a Latin page it is the answer itself rather than wasted
work. `OcrScriptDetector` judges the returned text on six counts: enough Latin
letters, letters dominating the non-whitespace characters, enough real words, few
stray symbols, **vertical page coverage**, and **share of lines that look like
garbage on their own**.

The last two are the ones that matter, because the first four are ratios over
*whatever came back* and cannot see text that never came back at all. A Hindi
page whose English heading was read cleanly looks perfect on every ratio while
90 % of the page is unread; coverage is what notices.

The result, and its cost:

| Page | Passes | Result |
| --- | --- | --- |
| Clearly Latin, covering the page | **1** | The probe, relabelled `… (Auto → Latin)`. Costs exactly what the old default cost. |
| Devanagari, or a partly-read page | **2** | Devanagari pass, or a merge when the probe found real text too. |
| Unreadable | **2**, then the empty state | The richer of the two readings, or empty. |

A false positive only ever costs **time, never accuracy**: when the second pass
finds nothing useful, the richer reading wins and the probe wins ties. Auto is a
heuristic and is documented as one — a Hindi page whose Latin probe hallucinates
a page-spanning, plausible-looking English paragraph can still be accepted as
Latin. That is why the overrides exist, and why the empty-result state re-offers
them.

`BoundedOcrService` keys its time budget on `OcrScriptMode.mayReadTwice`, not on
`isMixed`, so `auto` gets a two-pass budget — one budget for two passes would
turn every healthy Hindi page into a timeout.

`MixedScriptOcrEngine` decorates the single-script engine, running both passes
sequentially and handing the pair to `OcrMergePolicy`, which keeps each
non-colliding line and resolves collisions in favour of the reading that
contains Devanagari code points (only the Devanagari model emits them), then the
Latin pass. It never fuses characters or words across engines — that would be
guessing at text the user is about to copy. Merged results are rebuilt as one
block per surviving line, so block grouping is lost while word geometry is
carried over verbatim.

Mixed mode is **off by default and makes no accuracy claim**: the in-app
benchmark harness exists to measure whether it beats a single pass, and until
there are numbers it is labelled experimental in the UI.

When a read comes back empty, the result screen says so and offers the other
scripts inline, re-reading the same image rather than sending the user back to
the camera.

### Adding another script (e.g. Chinese)

The plugin declares the non-Latin script models as `compileOnly`, so the app
must supply them itself:

```kotlin
dependencies {
    implementation("com.google.mlkit:text-recognition-devanagari:16.0.1")
    // Chinese / Japanese / Korean use the same coordinates.
}
```

Then make the new script reachable: add it to `OcrScriptMode`, map it in
`OcrScriptMode.primaryScript`, and it flows through the existing `OcrScript`
switch in `MlKitOcrEngine`. No UI work is needed beyond the selector, which
iterates `OcrScriptMode.values`.

## Android specifics

* `minSdk` is Flutter's default (24) — satisfies ML Kit text recognition (23)
  and camera (24); no version changes were needed.
* `android/app/build.gradle.kts` supplies the **bundled** OCR models:
  `com.google.mlkit:text-recognition` (via the plugin) and
  `com.google.mlkit:text-recognition-devanagari`, both at `16.0.1`. Bundled
  rather than `play-services-mlkit-*` on purpose: the model ships inside the APK
  and works offline on first run, with no download step that can stall the way
  the translation models did. Cost is roughly **4 MB per script per ABI**.
* `AndroidManifest.xml` declares the `CAMERA` permission (optional hardware).
  Its `com.google.mlkit.vision.DEPENDENCIES` entry is **inert here**: that
  meta-data only pre-downloads models for the *unbundled* library family. It is
  kept because it changes nothing and becomes meaningful again if OCR is ever
  moved to the unbundled variant.
* Gallery picking uses the Android Photo Picker — no storage permission.

### Release builds and R8

Flutter enables R8 shrinking for Android release builds. It has now broken this
app twice, in two different ways, and `android/app/proguard-rules.pro` is the
whole fix for both. Flutter's Gradle plugin adds that file automatically
whenever shrinking is enabled, so **no `android/app/build.gradle.kts` change is
needed** in either case.

**1. The release build did not compile.** It failed with `Missing class
com.google.mlkit.vision.text.chinese.ChineseTextRecognizerOptions` (plus the
Japanese and Korean equivalents, and — before an earlier phase — Devanagari),
because the plugin resolves every script's options class from one `initialize()`
method while declaring those models `compileOnly`. The absence is intentional,
so `-dontwarn` covers those three and `-keep` protects the options classes the
app does ship (Latin, Devanagari, including
`DevanagariTextRecognizerOptions$Builder`, which needs its own rule because
`-keep class X { *; }` does not cover the separate class `X$Builder`).

**2. The release build compiled, installed, and could not read a single
image.** Every OCR run — camera, gallery, imported PDF page — failed with
`Text recognition failed. Please try again.` while the identical code passed on
debug and profile builds and in the whole fake-engine unit suite.

AGP keeps the *name* of any class named in the manifest, so all six ML Kit
component registrars stayed in the release dex — but R8 deleted their no-arg
constructors, because nothing in the app's code calls
`new CommonComponentRegistrar()`. Firebase Components instantiates those
registrars **reflectively** (`getDeclaredConstructor().newInstance()`), so each
one threw and was skipped: `MlKitContext` came up with none of ML Kit's
components. The first visible consequence was ML Kit's own telemetry inside
`InputImage`, where `MlKitContext.get(SharedPrefManager.class)` returned null and
its logging constructor dereferenced it. That reached Dart as
`PlatformException(error, null, null)` — no message, nothing to classify, hence
the generic sentence for every image.

```
-keep class * implements com.google.firebase.components.ComponentRegistrar { *; }
```

That one rule is Firebase's documented requirement for component discovery. It
covers OCR, translation **and** language identification, which all resolve their
services from the same context — the same null pointer was waiting in each.

How this was pinned down, in order:

1. reproduce with the release APK on an Android 15 emulator and read the native
   stack out of logcat (`... google_mlkit_text_recognizer:
   java.lang.NullPointerException ... zzmj.<init>` — ML Kit's telemetry, not
   recognition);
2. `dexdump` the release APK and confirm all six registrars were present with
   **no `<init>`**, which is the whole mechanism;
3. add the rule, rebuild, and re-read the dex: the constructors are back;
4. install that APK and exercise the three entry points by hand — gallery image,
   camera capture, imported PDF page — plus the translation panel on the same
   build, since it shared the cause.

The last step is the one that matters, and it was repeated on the final APK with
an image that actually contains words (a four-line PNG, pushed to the emulator's
Photos): Auto mode read all four lines and reported 14 words, and English →
Hindi then translated them on the same build. An empty
photograph proves less than it looks: recognition returning "no text found" is
consistent with a recognizer that never started, which is exactly the failure
being fixed, so the check needs words in it.

`test/android_release_config_test.dart` guards the rule (and the bundled
Devanagari artifact) on every `flutter test`, because nothing in the Dart suite
can run R8: the only cheap protection against deleting the rule is a test that
notices. It cannot prove a future dex is correct — step 4 is still the proof —
but it fails loudly on the exact mistake that shipped a broken build.

Because `flutter test`, `flutter run` and the whole `integration_test` suite all
run a **debug** runtime, none of them can see a missing R8 rule. A release build
therefore needs its own smoke test:

```
flutter build apk --release
adb install -r build/app/outputs/flutter-apk/app-release.apk
```

…then read a photo that has words in it — from the gallery, the camera and an
imported PDF page — and translate once. Three inputs, because a single path that
works can still be the one that never touches the missing component.

Sizes, measured on this machine. They are package measurements, not accuracy or
latency claims (those are in the on-device suite below):

* release APK, `--target-platform android-arm64`: **99,451,685 bytes (99.5 MB)**
* debug APK after adding the Devanagari artifact: **249,923,103 bytes**, i.e.
  **+100,933 bytes** over the 249,822,170-byte APK built before the change
* the release APK contains the Devanagari model assets (`Deva_ctc`, the
  `taser_tflite_gocrdevanagari_and_latin_*` binaries,
  `text-recognition-devanagari.properties`) and both options classes, and
  Devanagari no longer appears in R8's removed-code report

The +99 KB debug delta is *not* the cost of the script model: Google documents
"about 4 MB per script per architecture" for a bundled model, and most of this
app's OCR payload (the taser detector, script detector, language id and layout
models) was already present from the Latin artifact. A clean attribution would
need the pre-change APK rebuilt and compared byte for byte, which was not done —
so treat the delta as directionally small, not as a specification.

## Long operations always answer

Neither the OCR plugin nor native ML Kit gives up on a recognition call: the
native task is bridged with success/failure listeners only. A call that never
returns would spin forever, which is exactly what happened to the translation
model download.

`BoundedOcrService` therefore wraps the service and bounds every call itself
(60 s per pass, doubled for a mixed run, both overridable), turning a stall into
a real `OcrException` the UI can explain. A timed-out call is *abandoned* rather
than cancelled — ML Kit's `process` exposes no cancellation — which is safe
because the recognizer instance is only reused once its own call has returned,
but it is a real limitation rather than a hidden one.

## When recognition fails: taxonomy, reset and diagnostics

Every failure a user saw used to read `Text recognition failed. Please try
again.` That sentence came from the fallback in `OcrException.from`, which kept
the original error nowhere and matched exactly three strings. Reading the plugin
and `google_mlkit_commons` sources shows real failures it did not match:

| Native shape | Where it comes from | What it means |
| --- | --- | --- |
| `PlatformException(error, "MlKitContext has not been initialized")` | ML Kit client creation throwing inside Flutter's method-call handler | the recognizer cannot start at all |
| `PlatformException(error, null)` | the same wrapper around a `NoClassDefFoundError` / `NoSuchMethodError`, whose `getMessage()` may be null | a model or class is missing from this build |
| `InputImageConverterError` (+ `java.io.FileNotFoundException`, `IOException`) | `InputImageConverter.handleFileImage` | the file could not be opened as an image |
| `TextRecognizerError` | `TextRecognizer.handleDetection`'s failure listener | the recognizer ran and failed |
| `MissingPluginException` | the channel was never registered | the plugin is not in this build |

So `OcrException` now has four kinds — `timeout`, `imageUnreadable`,
`engineUnavailable`, `engineFailure` — and `from` classifies all of the shapes
above, always keeping the original object in `cause` and the stack in
`stackTrace`. The user still gets one sentence; the developer gets the truth.

Three defects made a single failure permanent, and are fixed:

1. **A failed recognizer was cached.** `MlKitOcrEngine` keeps one
   `TextRecognizer` per script. After a failed `processImage` the native
   instance could be left wedged, and every later run — camera, gallery, PDF
   page — reused it, which is exactly the "same error from every source"
   symptom. A failure now closes and drops that recognizer, so the next run
   constructs a fresh one (`test/mlkit_ocr_pipeline_test.dart`).
2. **Auto discarded a good read.** Auto probes with Latin and then runs
   Devanagari when the probe is inconclusive. If that second pass failed — a
   build without the Hindi model, for instance — the usable Latin text was
   thrown away and the whole run reported failure. The probe result is now kept
   (labelled `Auto → Latin`) whenever it contains letters, and the failure is
   only reported when neither pass read anything
   (`test/auto_script_routing_test.dart`).
3. **Nothing was logged.** `showOcrFailure` is the one reporter every entry
   point uses: it writes the original error and stack under
   `PDF_UTILITY_OCR` in debug builds, and offers a debug-only **Details**
   dialog with the kind, cause and stack, readable on the phone itself.

```
adb logcat | grep PDF_UTILITY_OCR
```

Before the engine runs, `MlKitOcrEngine` also checks that the file exists and is
not empty, and turns a decoder failure into `imageUnreadable`. That does not fix
a missing model or a wedged native library — nothing in Dart can — but it stops
a stale path from being reported as a recognizer fault, and it makes the real
cause visible.
