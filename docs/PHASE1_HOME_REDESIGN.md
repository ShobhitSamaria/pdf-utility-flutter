# Phase 1 — Home screen + shared action sheets

The first phase of the Figma redesign. Scope: **Home and the three action sheets
only**. OCR result, translation, PDF import, PDF viewer and the creation flows are
untouched and keep their current UI.

> **Superseded in one respect by Phase 2** (`docs/PHASE2_REDESIGN.md`). The rows
> marked `pending` in the table below — three of them, whatever the prose under
> it says: `Create PDF` from the camera, `Create PDF` from the gallery, and
> `View PDF / Create PDF` on an imported document — were implemented in Phase 2.
> `HomeScreen._pendingMessages` is gone and no action passes
> `SheetAction.pending` any more, though the component keeps the badge capability
> and `test/widget_test.dart` still asserts every sheet is free of it. The
> `View PDF / Create PDF` row was later **removed from Home** altogether
> (Phase 2 § 8.3): the viewer screens still exist, but importing a PDF is now a
> single `Extract Text` action. Everything else below still describes the
> shipped Home screen.

Figma frames this phase implements:

| Frame | Node |
| --- | --- |
| `Home` | `2:1119` |
| `Home · Scan document` | `7:1423` |
| `Home · Choose image` | `7:1500` |
| `Home · Import PDF` | `7:1577` |

## What changed

| File | Change |
| --- | --- |
| `lib/app/app_theme.dart` | **New.** Design tokens (colour, radius, spacing) and the Material 3 theme built from them. |
| `lib/screens/widgets/app_bottom_sheet.dart` | **New.** `showAppActionSheet` + `SheetAction` + `SheetActionTile` — one bottom sheet reused by all three entry points. |
| `lib/screens/home_screen.dart` | Rewritten to the design's layout. Every OCR/PDF-import handler is the same call it was before. |
| `lib/main.dart` | Uses `buildAppTheme()`. |
| `test/widget_test.dart` | Home tests updated to the new labels; the app-composition and translation-with-no-build-flag tests are unchanged. |
| `test/home_screen_test.dart` | **New.** Drives the sheets through injected camera/gallery seams. |

### Home layout

Header (mark, `PDF Utility`, settings/sliders icon) → centred hero (pale
periwinkle tile with the drawn scan glyph, headline, subtitle) → full-width navy
`Scan document` → two ghost actions (`Choose image`, `Import PDF`) → a quiet
`Script: Auto` row.

### Sheets

One component, three sets of rows — exactly as designed:

| Sheet | Row | Subtitle | State |
| --- | --- | --- | --- |
| Scan document | `Extract Text (OCR)` | Scan, copy and translate | **works** (camera → OCR) |
| Scan document | `Create PDF` | Capture one or more pages | pending |
| Choose image | `Extract Text` | Read text from an image | **works** (gallery → OCR) |
| Choose image | `Create PDF` | Combine images into a PDF | pending |
| Import PDF | `Extract Text` | Choose a page to recognize | **works** (PDF import → OCR) |
| Import PDF | `View PDF / Create PDF` | Read or select pages for a new PDF | removed from Home (Phase 2 § 8.3) |

## Pending rows, and why they are visible

The design shows four rows the app cannot honour yet: there is no PDF writer, no
capture-for-PDF, no review screen and no page-selection grid (Phase 3). They are
shipped **badged `Coming soon`**, and tapping one says the feature is not
available yet. Nothing fakes progress or reports success for work that did not
happen — see `HomeScreen._pendingMessages`.

## Deliberate deviations from the frame

* **`Coming soon` badges** — the design has plain rows; a row that cannot work
  must say so rather than look identical to a working one.
* **The script selector moved into a sheet.** The design keeps `Script: Auto` as
  one quiet row, so the full selector (Auto plus the manual overrides and their
  explanations) opens from that row — and from the header's sliders icon, which
  is the same sheet.
* **Developer tools are debug-only.** `Show OCR geometry` and `OCR benchmark`
  live under a `Developer` heading inside the settings sheet, behind
  `kDebugMode`; a release build renders none of it.
* **Colours are approximations.** The Figma file is a view-only session, so no
  token could be exported; `app_theme.dart` records where each value came from.

## Preview renders

The four screens were reviewed as renders at the design's own frame size
(412 × 844). They were produced by a throwaway golden harness that has since
been deleted, and they used the Flutter **test font**, so all text and every
icon appeared as a solid box — they were useful for layout, spacing and colour,
not for reading copy; they are not committed. The wording itself is asserted in
`test/widget_test.dart`.
