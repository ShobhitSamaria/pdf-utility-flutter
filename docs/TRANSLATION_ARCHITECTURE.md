# Translation Architecture (on-device, OCR text → Hindi)

This document explains the **local translation foundation** and the
**Google-Lens-style translated overlay**: how recognized OCR text becomes Hindi
(or another language) *in place on the photo*, without anything leaving the
device.

It builds on the OCR layer documented in
[`OCR_ARCHITECTURE.md`](OCR_ARCHITECTURE.md) but stays decoupled from it. There
is no cloud API, no Chrome/web translation, no Python backend, no Tesseract and
no ONNX/Transformers.

## Flow

### 1. Text translation (the simple path)

```
OcrSelection.text  /  OcrResult.fullText
                 │
                 ▼
        TranslationRequest
                 │
                 ▼
   TranslationService.translate(request)
                 │
     ┌───────────┼────────────┐
     ▼           ▼            ▼
 resolve      provision    translate
 source       models        text
 (auto-       (if           (on-
  detect)      missing)      device)
     │           │            │
     ▼           ▼            ▼
SourceLanguage  Translation  Translation
Detector        Engine       Engine
     │           │            │
     ▼           ▼            ▼
ML Kit Lang.   ML Kit       ML Kit
Identific.     model mgr    translator
                 │
                 ▼
         TranslationResult
```

### 2. Region translation (what the overlay uses)

```
OcrResult ─┬─ OcrDocumentLayout.blocks()          → paragraphs in reading order
           │     (columns → bands → top-to-bottom, tables row by row)
           └─ OcrTranslationRegions.fromPage()      → one unit per paragraph
              OcrTranslationRegions.fromSelection()  → one unit per touched line
                 │
                 ▼
        List<TranslationUnit>   {id, text, OcrRect}      ← source-image pixels
                 │
                 ▼
   TranslationService.translateRegions(units, target)
                 │   detect once · provision once · one engine call per region
                 ▼
        TranslatedOverlay { List<TranslatedRegion> }
                 │   {id, sourceText, translatedText, OcrRect}  ← same rectangles
                 ▼
        TranslationOverlay widget
                 │   OcrCoordinateMapper (the OCR layer's mapper)
                 ▼
      text drawn over the photo, inside each paragraph's box
      (full text joins the same regions in reading order, paragraphs
       separated by a blank line)
```

## Layers

| Layer | Path | Responsibility |
| --- | --- | --- |
| Domain | `lib/translation/domain/` | Value objects (`TranslationLanguage`, `TranslationRequest`, `TranslationResult`, `TranslationModelState`, `TranslationProgress`, `TranslationUnit`, `TranslatedRegion`, `TranslatedOverlay`), text helpers, and the `TranslationEngine` / `SourceLanguageDetector` / `TranslationService` interfaces. Framework-free. |
| Data | `lib/translation/data/` | Concrete ML Kit engine + language detector, and `LocalMlKitTranslationService` (orchestration). **Only these two files import ML Kit.** |
| Presentation | `lib/translation/presentation/` | `TranslationController` (ChangeNotifier state machine), sealed `TranslationUiState`, the OCR→region bridge (`ocr_translation_regions.dart`), the layout maths (`translated_text_layout.dart`), and the widgets. |

The OCR layer never imports anything from `lib/translation/`. The only place the
two meet is the presentation layer, which is the layer that is *supposed* to
bridge app models to view models:

* `ocr_translation_regions.dart` — the **only** translation file that knows about
  `OcrResult` / `OcrSelection`. It reads OCR *result models*, never the OCR
  engine, and introduces no new coordinate space.
* `translation_overlay.dart` — imports `OcrCoordinateMapper`, deliberately, so
  there is exactly one image→screen transform in the app.
* `lib/screens/ocr_result_screen.dart` — owns the two modes and starts
  translations; it is the app layer, which already knows about OCR.

### Why the extra `TranslationEngine` / `SourceLanguageDetector` split?

Same reasoning as `OcrEngine` / `OcrService`:

* `TranslationEngine` is the pluggable *algorithm* seam (swap ML Kit for another
  on-device translator).
* `SourceLanguageDetector` is separate because identification and translation
  are different ML Kit models that need to be faked independently in tests.
* `TranslationService` is the app-facing API. Screens depend on it alone, so the
  UI never imports an ML Kit package, and the composition root
  (`lib/main.dart` → `createTranslationService()`) is the single place that
  picks concrete implementations.

## Language configuration

`TranslationLanguages` (`lib/translation/domain/translation_language.dart`) is
the curated registry:

* **Source: `TranslationLanguages.auto`** — the default. `sources` always puts
  auto-detect first.
* **Target: `TranslationLanguages.hindi`** — the default, exposed as
  `TranslationService.defaultTargetLanguage`.
* 30 concrete languages are offered, each mapping to a language ML Kit ships an
  on-device model for. A test asserts every offered code has a native mapping, so
  a language can never be "offered but broken".

`TranslationLanguage` is a value object (not an enum) keyed on its BCP-47 code,
which is what keeps it extensible: adding a language is one registry entry, and a
language reported by the detector can be represented without touching call
sites. `TranslationLanguages.byCode` normalises real-world tags (`en-GB` → `en`,
`zh-Hant` → `zh`, legacy `iw` → `he`) and returns `null` for anything unknown.

## Region mapping (how a translation lands back on the page)

`OcrTranslationRegions` produces [`TranslationUnit`]s — **paragraph-level, not
word-level, and not line-level either**, because a translator can only produce
coherent prose from a coherent run of text:

* **Whole page** → one unit per **paragraph** from `OcrDocumentLayout`, in the
  document's reading order, each carrying the union of its lines' boxes. That
  fixes the two defects the line-per-unit version had on real pages:
  * translating each line separately produced disconnected phrases
    ("Same that their appointment / Advertising not by direct selection"),
    because no sentence was ever sent as a sentence;
  * the engine's block order interleaved columns, so the fragments came back in
    an order no one could read.

  A paragraph longer than 900 characters is split at its own line boundaries so
  one call never carries an unbounded input; no word is cut in half. Text with no
  usable geometry is kept as a final unit rather than dropped, so nothing the OCR
  read is missing from the full translation.
* **Selection** → one unit per line the selected words touch, in reading order
  (not tap order), whose text is only the *selected* words of that line and whose
  box is the **union** of just those words' boxes. Unselected words on the same
  line are neither translated nor covered, and a multi-line selection becomes a
  handful of regions rather than one.

`translatedRegions` returns `TranslatedRegion`s that keep the **same id, order
and `OcrRect`** as their units, so the mapping is 1:1 and nothing depends on an
engine echoing its input back verbatim. The full text (`TranslatedOverlay
.asResult`) joins those regions in the same order, with a blank line between
paragraphs and a single newline after a line/cell unit — complete, in order, and
without repeating anything.

## Model provisioning behaviour

On-device translation models are not bundled with the APK; ML Kit fetches them on
demand and caches them on the device.

`LocalMlKitTranslationService`:

* `translate()` — validates the pair, resolves auto-detect, short-circuits when
  the text already *is* the target language, provisions, then translates.
* `translateRegions()` — the same, plus: **detect once for the whole batch**
  (one page's lines are one language, and one detection is both faster and more
  reliable than N), **provision each model once**, then **one engine call per
  region**. Per-region calls are the whole point: a single joined call would have
  to be split again by guesswork to place each line's text back on its own line.

The UI sees only coarse phases through `TranslationProgress`:

| Phase | Copy shown |
| --- | --- |
| `starting` | `Starting…` (set by the controller before the service reports) |
| `detectingLanguage` | `Detecting language…` |
| `preparingModel` | `Preparing <Language>…` |
| `translating` | `Translating…`, then `Translating 3 of 12…` for batches |

There is deliberately **no** "downloading 30 MB" dialog, no model names, no
byte-level progress bar, and no ML Kit vocabulary. Provisioning is just another
loading line. Every native failure is wrapped in a `TranslationException`
carrying a user-safe sentence, so the UI never renders a platform error and never
fails silently.

> **Where models are fetched.** ML Kit requires **both** the source and target
> language models before translating. The service therefore checks and, when
> missing, downloads each of them (through the `TranslationModelManager` seam →
> `isModelDownloaded` / `downloadModel`) before calling
> `OnDeviceTranslator.translateText`. `translateText` also runs
> `Translator.downloadModelIfNeeded()` natively, so it remains a second chance
> if the explicit step failed.
>
> Three things bit us on real devices and must not regress:
> 1. The plugin's `ModelManager.downloadModel` defaults to `isWifiRequired:
>    true`, which builds `DownloadConditions.requireWifi()`. On a
>    cellular-only phone that queues the download forever — the classic
>    "Preparing Hindi…" hang. `NativeModelManager` therefore always sends
>    `wifi: false` (its plugin fallback passes `isWifiRequired: false`),
>    pinned by `native_model_manager_test.dart`.
> 2. The plugin's native download handler attaches only success/failure
>    listeners to the Play Services `Task` with **no timeout**. On some
>    devices (observed: Nothing phone, Android 16, GMS 26.36.33) the `Task`
>    never calls back at all — `downloadModel(hi)` hung past 120 s. Provisioning
>    therefore no longer goes through the plugin's channel: `MlKitTranslationEngine`
>    delegates to `NativeModelManager`, which uses our own
>    `pdf_utility/model_manager` channel (`MainActivity.kt`). That channel
>    attaches a **per-attempt watchdog** (30 s native deadline, +5 s Dart bound)
>    so it always answers `success`/`failed`/`timeout`, **retries with a fresh
>    `Task`** (3 attempts, 1 s apart, re-checking `isModelDownloaded` first so
>    a background completion short-circuits), and throws
>    `ModelDownloadException` carrying every attempt's raw outcome. Worst case
>    ≈107 s — inside the self-test's 120 s download budget and the engine's
>    150 s backstop, so a FAIL shows per-attempt evidence instead of one
>    umbrella timeout. If our channel is missing it falls back to the plugin's
>    manager, still bounded and still not Wi-Fi-gated.
> 3. `translateText` itself bridges a Play Services `Task` the same way, so
>    every stage (create → translate → close) stays bounded by
>    `MlKitTranslationEngine.operationTimeout` (150 s), turning a stuck call
>    into a retryable `engineFailure` naming the stage instead of an eternal
>    spinner. Timeouts are a backstop, not the fix.
>
> **Diagnostics.** ML Kit failures are never hidden:
> `TranslationException.details` carries the raw cause (exception type, the
> `PlatformException` `code`/`message`/`details`, per-attempt download
> outcomes, timing, stack), which the controller logs and the failure chip
> exposes behind a debug-only **Details** button. The friendly sentence stays
> the headline; the root cause is always recoverable (`adb logcat`, filter
> `PDF_UTILITY_TRANSLATION` — native and Dart lines share the tag, including
> the `downloadModel(...): attempt N/M BEFORE/AFTER` sequence).
>
> Android permissions: the download needs `android.permission.INTERNET` (declared
> in the main manifest, since debug/profile only add it for tooling) and
> `android.permission.ACCESS_NETWORK_STATE` for ML Kit's connectivity checks.
> Translation itself always runs offline once a model is present.

## Standalone translation diagnostics (debug only)

When translation fails on a real device, isolate the engine before touching OCR:

* **Screen** — Home → **Translation diagnostics (debug)** (only rendered in
  `kDebugMode`) runs `TranslationSelfTest` and shows the verdict, every step,
  and the exact failure. It uses **no** OCR, detection, selection, overlay,
  camera or images: one fixed sentence, `"Hello, how are you?"`, English →
  Hindi.
* **One native operation per step, each individually bounded** —
  `isModelDownloaded(en)` → `downloadModel(en)` (skipped when already present) →
  `isModelDownloaded(hi)` → `downloadModel(hi)` → create translator →
  `translateText()` → `close()`. Nothing is one opaque future, so the screen
  always names the operation it is waiting on, with a live elapsed clock.
  Budgets: 20 s per model check, 120 s per download (~30 MB each, so a slow but
  working download is not misreported), 30 s for the translation, 10 s for
  device info.
* **A timeout per operation, and the run stops at the first failure** — a step
  that never returns is reported as `TIMEOUT` naming that step
  (`Timeout after 30 seconds`), and the remaining steps are listed as `SKIP`,
  so the **first** blocking native call is unambiguous. The screen also arms an
  independent watchdog at the sum of the budgets, so no future change can leave
  it on "Running…".
* **Explicit flow by default** — the explicit flow is what the app uses, so it
  runs alone. A *direct* `translateText` (letting the plugin's own
  `downloadModelIfNeeded` provision) is available via
  `includeDirectPath: true` for comparison: if explicit fails but direct works,
  our model management is the problem; if both fail, it is ML Kit/the device.
* **BEFORE/AFTER logging** — every operation logs immediately before and after
  with elapsed milliseconds (`[SELFTEST] downloadModel(hi): BEFORE (timeout
  120000 ms)` … `: AFTER OK — downloaded (3120 ms)`), and per-stage
  `create …/translateText()/close()` logging comes from
  `MlKitTranslationEngine.translateTraced`, which returns a
  `TranslatorCallTrace` instead of collapsing the failure into one sentence.
* **Environment** — device manufacturer/model, Android release + SDK, ABIs,
  application id and the installed **Google Play Services version**
  (`DeviceDiagnostics`, via the `pdf_utility/diagnostics` channel). No new Dart
  package and no new Gradle dependency: the GMS version is read from the
  installed `com.google.android.gms` package (`<queries>` entry added for
  Android 11+).
* **Log tag** — every translation log line, everywhere, is prefixed
  `PDF_UTILITY_TRANSLATION` (`lib/translation/translation_log.dart`):

  ```
  adb logcat | grep PDF_UTILITY_TRANSLATION
  ```

  or tap **Copy report** on the diagnostics screen.

## The translated overlay (Lens-like in-place text)

The photo is the primary UI. Translation never replaces it and never opens a
full-screen panel over it.

### Geometry — one transform, no second coordinate system

`TranslationOverlay` is stacked *over* the OCR overlay with identical
constraints, then builds its **own** `OcrCoordinateMapper` from the same
`imageWidth`/`imageHeight`/`viewportSize` inputs the OCR overlay uses:

```
scale = min(viewportW / imageW, viewportH / imageH)      // BoxFit.contain
screenRect = mapper.rectToScreen(region.bounds)          // region.bounds is the
                                                         // original OcrRect
```

Both layers compute the same mapper independently but from the same inputs, so
translated text and selection highlights can never disagree about where a word
is. Region rectangles stay in **source-image pixels** (they are the OCR
rectangles, unmodified) and are re-projected on every layout — nothing is cached
in screen space, so rotation, resize and text-scale changes all re-fit.

### Leading — measured from the font, never assumed

`TranslatedTextLayout.lineHeightFor` derives the line height from the metrics of
the font that will actually shape the string (including the Devanagari fallback)
and clamps it to `[1.15, 1.9]`. This is not cosmetic. A fixed `height: 1.15`
is correct for Latin but wrong for Devanagari, whose natural line is about
1.29 × the font size: forcing 1.15 makes matras paint **outside** the measured
line box — measured at 5.3 px for 48 px text. Glyphs that leave their box are the
one overlap a rectangle-based collision check cannot see, so they looked like a
bug in the de-overlap algorithm when they were a typography bug.

The widget paints with exactly the resolved `TextStyle` the fitter measured, so
it inherits the same leading. `test/translated_overlay_font_metrics_test.dart`
loads a real Noto Sans Devanagari and asserts with glyph ink extents that both
the paragraph and every fitted line stay inside their boxes.

### Blocks, not independent cards — `TranslatedOverlayDeck`

The overlay is a **page-level** layout problem. `TranslatedOverlayDeck.layout`
groups vertically adjacent lines that share a column into blocks and flows each
block like a paragraph:

* grouping uses the original OCR geometry — a caption that only clips a column's
  edge, or a line a whole line-height away, starts a new block;
* inside a block, line `N` starts `height(N-1) + lineSpacing` below line `N-1`,
  so a longer translation pushes **its own paragraph** down instead of growing
  over the next line;
* collisions are resolved against the **rendered** spans (`spanFor`, widened to a
  minimum usable width), not the original OCR boxes — the old deck compared the
  boxes it was given and drew the boxes it had widened;
* a block only takes room down to the next block it can actually touch, and is
  never allowed outside the displayed photo;
* when a block does not fit, its whole text shrinks uniformly first, then gets
  equal slices that can still hold one measured line, and only then is the tail
  left off the image. A slice shorter than a line is never painted: that was the
  second defect the old fix left behind — non-overlapping rectangles whose glyphs
  still bled into the line below;
* the result is deterministic: the same input produces identical rectangles on
  every rebuild.

`TranslatedTextLayout.fit` remains the single place a single line's box, font
size, line cap and padding are decided, and `TranslatedOverlayDeck` passes it the
resolved span and a height budget. The rendered `Text` uses exactly that style,
line cap and ellipsis, so what was measured is what is painted.

### When it cannot fit

Long Hindi can be physically larger than the space between two printed lines.
The overlay does not pretend otherwise: regions that cannot be drawn legibly are
listed in `TranslatedDeckLayout.hiddenRegionIds`, and the overlay shows a small
**"N translations did not fit on the image · Full text"** notice. The notice opens
the Translate tab, where every region is present in reading order. Nothing is
silently dropped from the model or from the UI.

### Backing style

Each **block** gets one rounded, paper-coloured backing at 95 % opacity
(`surface`) with `onSurface` text, and the lines inside it share that single veil
so a paragraph reads as one unit rather than a stack of cards.

Its rectangle is `TranslatedBlockPlacement.coverage`: the union of the fitted
text boxes and the **source OCR rectangles of the lines actually drawn**, clipped
to the photo. That is the Lens behaviour of *replacing* a paragraph. A translated
paragraph is almost always shorter than its Hindi original, so a veil sized only
to the translation left the rest of the paragraph's Hindi visible beside the
English — the reader saw both languages of the same paragraph at once. Covering
the source lines hides exactly the text that was translated; a line that had no
room on the image is not covered, because there is no English to replace it.

The veil is deliberately near-opaque: at 90 % the original words stayed visible
as a grey ghost through the translation, which looks like overlapping text even
when the rectangles do not overlap. **Nothing else is drawn** — no scrim over the
photo, no full-image panel, no permanent rectangles around un-translated words,
and no debug boxes (the existing opt-in OCR debug geometry toggle still draws the
*source* boxes, which is exactly what you want when checking alignment). The
letterbox around the photograph is a deep neutral navy rather than a light grey,
so the sheet is the brightest object on screen and its edges are unambiguous.

### Interaction

Each line's slot is its own tap target, positioned at the line's *rendered* box,
so a translation that was pushed down by its paragraph still opens its own full
text. Everything that is not a translated line falls through to the OCR layer, so
word selection keeps working in both modes and gets the whole surface back when
translation is switched off (`Show original`).

## UI flow

Two modes, one image, one tap apart:

* **OCR mode** (default) — tap a word to select it, long-press to add more.
  Copy / Search / Translate act on the selection.
* **Translation mode** — translated text is painted onto the photo, and a compact
  bar offers the target language (Hindi by default), a region count, **Full text**
  and **Show original**.

Starting a translation:

* **Selected text** → `SelectionActionBar` → **Translate** → only the selected
  words are translated, and the result is drawn at those words. The selection is
  then cleared so its highlight does not sit under the result.
* **Whole page** → app-bar action → every recognized line is translated and drawn
  at its own line.

While a translation runs, a small **chip floats over the photo** with the friendly
phase text; on failure the same chip stays put with the message and a *Try again*
action. There is no modal, no blocking dialog, and no silent failure. Retrying
from the chip switches into translation mode as soon as a result arrives.

The panel carries the From/To selectors, the translated text and Copy. Changing a
language drops the stale overlay and clears the result state, so the panel can
never present an old pair's answer as the current one — and while a re-run is in
flight the panel shows its own progress instead of the photo flashing back to the
original text.

## One surface, translation inline

The result screen has no tabs. The photo is the only view of the recognition, and
**Translate** opens `InlineTranslationPanel` directly beneath it: `From` / `To`
selectors, a swap control, one **Translate** button and the result (or the
loading/error state) in the same card. Tapping Translate never navigates, so the
source words and their translation stay on screen together.

There is exactly one `TranslationController` per screen, so the panel and the
in-place overlay cannot disagree about the answer, and the overlay stays optional
behind its **On photo** switch. `TranslationPanel` and the `ResultTabBar` /
`TranslationTab` pair are gone; the readable text is now a sheet reached from the
strip's **Read text** action (see `OCR_ARCHITECTURE.md`), not a competing view.

## Error handling

| Situation | Result |
| --- | --- |
| Nothing to translate | `TranslationException(emptyInput)` — not retryable |
| Detector unsure / crashed | `TranslationException(detectionFailed)` — retryable |
| Language not offered | `TranslationException(unsupportedLanguage)` — not retryable |
| Auto target, or unoffered pair | `TranslationException(unsupportedPair)` — not retryable |
| Model could not be provisioned | `TranslationException(modelUnavailable)` — retryable |
| Native translator threw | `TranslationException(engineFailure)` — retryable |
| Anything unexpected | Controller catches it and shows a generic retryable message |

## Tests

`test/support/translation_fakes.dart` provides in-memory fakes for all three
interfaces, so the entire flow is exercised with **no platform channels**:

* `translation_language_test.dart` — registry, defaults (Hindi target, auto
  source), code normalisation, value equality.
* `translation_text_test.dart` — normalisation and whole-page aggregation.
* `translation_request_test.dart` — request construction and derived fields.
* `translation_model_state_test.dart` — availability states and progress.
* `translation_ui_state_test.dart` — progress copy is human, internals-free, and
  counts regions only when there is more than one.
* `local_translation_service_test.dart` — auto-detect, provisioning, model
  reuse, whole page, region batches (mapping, order, one detect/provision per
  batch, counters, blank-region skipping) and every graceful-failure path.
* `mlkit_translation_engine_test.dart` — every offered language has a native
  ML Kit mapping.
* `translation_controller_test.dart` — state machine, progress phases, retry,
  language changes, overlay retention, re-run, disposal safety.
* `translation_tab` coverage lives in `ocr_result_translation_widget_test.dart`
  and `ocr_result_screen_test.dart` (the Translate reading, the tab bar, and the
  in-place overlay), so there is one surface under test rather than two.
* `ocr_document_layout_test.dart` — reading order and paragraph grouping on
  synthetic pages: a scrambled three-column newspaper (plus a single-block
  page), portrait vs landscape, paragraph gaps, a heading kept out of the body,
  a caption in another column, tables and receipts read row by row, mixed
  Hindi-English text with dates/numbers/punctuation, determinism, and degenerate
  input.
* `ocr_translation_regions_test.dart` — OCR → region mapping: paragraph
  granularity in reading order, union boxes, hyphenated line joins, text with no
  geometry kept, plus the selection path (unions, unselected words excluded,
  blank/degenerate elements skipped).
* `translated_overlay_paragraph_test.dart` — paragraph full text (blank-line
  boundaries, no duplicates, empty translations skipped) and paragraph overlay
  geometry: a paragraph is drawn inside its column with more than five lines of
  room, two columns never collide, a sliver never paints outside the photo, and
  a dense page keeps every paragraph in the full text.
* `translated_text_layout_test.dart` — font sizing for short/long/overwhelming
  text, growth caps, letterbox clamping, and dense/anchor rules.
* `translated_overlay_font_metrics_test.dart` — real Devanagari font: the forced
  1.15 leading reproduces glyph bleed, the derived leading removes it, every
  drawn line's ink stays inside its box, the rendered widget contains its text,
  hidden translations are counted and openable, and the backing masks the photo.
* `translated_overlay_collision_test.dart` — the two surviving defects (widened
  spans, sub-line slices), a 40-page geometry sweep, narrow-page accounting,
  column/paragraph grouping, widget-level box geometry, hit testing after
  repositioning, and overlay-off selection.
* `translation_overlay_widget_test.dart` — each region is drawn at exactly the
  box the shared mapper and fitter predict, through square *and* letterboxed
  viewports; degenerate/empty translations draw nothing; backings stay small.
* `ocr_result_translation_widget_test.dart` — the end-to-end screen flow:
  select → Translate → in-place overlay, whole-page overlay, mode switching,
  full-text sheet, selection still working over the translation, and the
  failure/retry path.

## Still requires a physical device

* Real ML Kit model download (first-run provisioning) and actual translation
  quality — no emulator or device is available in this environment.
* Whether a real device takes a cellular connection for the model fetch.
* Overlay legibility on real photographs: how the 93 % backing reads over
  busy/low-contrast text, how often real translations shrink to the minimum font
  or ellipsize, and whether the 2× vertical growth cap overlaps neighbouring
  lines too aggressively at real densities.
* Touch feel of selecting words *through* the translated layer.
