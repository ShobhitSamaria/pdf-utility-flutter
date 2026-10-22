# OCR benchmark

A repeatable way to put a number on OCR accuracy and speed **before** claiming
either. It runs the app's real `OcrService` — the same object the camera and
gallery paths use — over a fixed dataset on a physical device, and reports what
it measured alongside what it could not.

Open it from a **debug** build: Home → **OCR benchmark (debug)**. It never runs
at startup and never runs by itself. That is deliberate: running it
automatically would slow every launch, and warming the recognizers before the
first real photo would destroy the cold-start number it exists to measure.

> Nothing in this repository is a benchmark result. The harness has been built
> and the scoring is unit-tested, but no run has been made on a device, so every
> accuracy and latency figure is **unmeasured** until the report is produced on a
> phone.

## Two tiers, never averaged together

| Tier | Where it comes from | Ground truth | What it can tell you |
| --- | --- | --- | --- |
| **Synthetic** | Rendered on the device by `SyntheticBenchmarkDataset` | **Exact by construction** — it is the string that was drawn | Whether the pipeline works, and how conditions (blur, tilt, resolution) move the numbers |
| **Real photographs** | Photos you supply under `assets/benchmark/real/` | Typed by you | How the app behaves on a page photographed by a hand |

Synthetic pages have no sensor noise, no perspective, no paper texture and no
realistic lighting, so they flatter any recognizer. Their numbers are reported
under their own heading and must never be quoted as real-world accuracy. The
real-photograph tier is the one that says something, and it reports as **not
measured** until samples exist — never as a guess or an estimate.

The synthetic tier also depends on the device having a Devanagari font. If the
phone lacks one the Hindi samples render as tofu boxes and score badly for a
reason that has nothing to do with OCR; that will be obvious in the per-sample
list and should be recorded as a finding, not hidden.

## Coverage

The 13 synthetic samples cover every category the project asked for. Several
categories appear in more than one sample because a real page is usually blurry
*and* small-font *and* badly lit; a sample carries its *primary* category and
notes the rest.

| Sample | Category | Condition |
| --- | --- | --- |
| `en_clean` | Printed English | clean |
| `en_small_font` | Small font | 15 px text |
| `en_low_resolution` | Low resolution | downscaled ×0.28 |
| `en_blurry` | Blurry | Gaussian σ = 1.8 |
| `en_tilted` | Tilted | canvas rotated ~2° |
| `en_shadowed` | Uneven lighting | diagonal gradient |
| `en_dense` | Dense text | repeated short lines |
| `en_table` | Table | ruled table, bold header |
| `en_form` | Form | label/rule rows |
| `hi_clean` | Printed Hindi | clean |
| `hi_small_font` | Small font (Hindi) | 16 px text |
| `hi_blurry` | Blurry (Hindi) | Gaussian σ = 1.6 |
| `mixed_invoice` | Mixed Hindi + English | both scripts, form layout |

## Adding real photographs

1. Put the photo in `assets/benchmark/real/` — e.g. `kitchen_01.jpg`.
2. Put its **exact** transcription in `kitchen_01.txt` next to it. Include every
   character you can see, including punctuation; a transcription typo is scored
   as an OCR error.
3. Add an entry to `assets/benchmark/manifest.json`:

```json
{
  "id": "kitchen_01",
  "category": "blurry",
  "image": "assets/benchmark/real/kitchen_01.jpg",
  "groundTruth": "assets/benchmark/real/kitchen_01.txt",
  "notes": "Nothing Phone (2a), dim kitchen light, hand-held"
}
```

4. Rebuild. Assets are compiled into the app, so hot reload is not enough.

`groundTruth` may also be the transcription written inline instead of a `.txt`
path, which is fine for a couple of words and unreadable for a paragraph.
`category` accepts any of `printedEnglish`, `printedHindi`, `mixedScript`,
`blurry`, `tilted`, `shadowed`, `lowResolution`, `smallFont`, `denseText`,
`table`, `form`; an unknown or missing one falls back to the script of the
reference text rather than to a Latin default that would mislabel Hindi.

For a useful set: photograph stable, non-confidential pages, hold the phone
roughly 20–30 cm above the page, keep the page flat, and record the device and
lighting in `notes`. Twenty to thirty samples spread across the categories is
enough for a first signal. A handful of samples is not a trend.

## Metrics, defined exactly

* **CER** — Levenshtein distance over **Unicode code points**, divided by the
  reference code-point count. `0.0` is perfect. Not clamped: a hypothesis can
  score above `1.0`, and clamping would understate catastrophic output.
* **WER** — the same distance over whitespace-separated words, divided by the
  reference word count.
* **Normalization** — applied to the scored copies of both sides only, never to
  text the app displays. Runs of whitespace (including NBSP, line/paragraph
  separators and the ideographic space) collapse to one space and the ends are
  trimmed, so line wrapping is not an error; zero-width space, BOM, the
  LTR/RTL marks and soft hyphen are dropped. **No case folding** (case is
  content) and **no Unicode normalization** (Dart core has no normalizer and
  this phase adds no dependency) — so composed and decomposed forms are scored
  as different characters. ZWJ/ZWNJ are kept, because in Devanagari they change
  which conjunct a cluster represents.
* **First-pass vs warm latency** — reported separately, with median and a
  nearest-rank p95 (an actually observed value, not an interpolation). Only the
  very first call of a run is process-cold; every later "first pass" already has
  the model loaded, and the report says so rather than implying otherwise.
* **Failure rate** — calls that threw, including the app's own timeout.
* **Empty-result rate** — successful calls that returned no words, over
  successful calls. A separate signal from CER: an engine that returns nothing
  is not the same as an engine that returns the wrong thing.
* **Peak RSS** — `ProcessInfo.currentRss`, i.e. the whole process. It is
  indicative only: it includes the Dart heap and says nothing about native ML Kit
  allocations.
* **Accuracy scoring uses the first successful pass** of each sample. Repeats
  exist to measure latency spread, not to cherry-pick the best read.

## Deliberately not measured yet

* **PDF pages per minute** — this phase has no PDF ingestion, so there are no
  pages to process. Reporting a rate would mean inventing one.
* **Native ML Kit memory** — needs a native profiler; only process RSS is
  visible from Dart.
* **Real-world accuracy** — until photographs are added, the tier is empty.
* **Unicode-normalized scoring** — see above.

## How a run works

1. The screen loads the synthetic tier (generated, no files) and the bundled
   photographs (usually none).
2. Pick script modes — `latin` and `devanagari` by default, `mixed` opt-in
   because it doubles the work — and 1–3 passes per sample.
3. Run. Progress shows the mode and sample being read, and **Cancel** stops
   after the current image rather than mid-call.
4. The report appears on screen with **Copy** (JSON, for pasting back into a
   session) and **Share**. Each recognition is also logged natively under the
   `PDF_UTILITY_OCR` logcat tag.

Every image — generated or bundled — is written to a temporary file and
recognized through `InputImage.fromFilePath`, exactly as a user's photo is. No
sample takes a shortcut that the real pipeline does not.

## Requirements this phase preserves

Working: camera and gallery OCR; word-level selection with Copy and Share;
Unicode-aware case-insensitive search with match count and previous/next;
responsive progress and a bounded (never indefinite) wait; no translation in a
shipped build; no mandatory cloud OCR; no automatic uploads.

Not started, in the order they should be attacked: PDF ingestion (below), TXT
and DOCX export with Hindi/English Unicode, and local document saving with
recoverable OCR results. DOCX export should preserve readable text and basic
structure first — perfect layout reconstruction is not a promise worth making.

## PDF priority order (when it starts)

1. Inspect each page for usable **embedded text**.
2. Extract embedded text directly when it is reliable.
3. Render and OCR **only** image-only pages.
4. Process pages sequentially, or with strictly bounded concurrency.
5. Show page progress and support cancellation.
6. Persist completed page results, so a failure does not repeat the whole
   document.
7. Handle encrypted, corrupt, oversized and unsupported files with clear errors.

Never hold an entire large PDF in memory as high-resolution images. Treat 20
pages as the initial reliability target, 21–100 as a stress range, and anything
larger as unvalidated — and do not advertise a maximum before it has been
measured. Before adding a PDF library, inspect the existing dependencies and
check compatibility, maintenance and licensing; there is no PDF package in this
project today.
