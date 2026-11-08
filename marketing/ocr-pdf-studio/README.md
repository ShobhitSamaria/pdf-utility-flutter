# OCR PDF Studio — Launch Videos

Two finished promotional cuts built from the real app screens, with an editable
Remotion project beside them.

| | Vertical | Landscape |
| --- | --- | --- |
| File | `video/out/OCR-PDF-Studio-Launch-9x16.mp4` | `video/out/OCR-PDF-Studio-Launch-16x9.mp4` |
| Use | Instagram Reels, YouTube Shorts | YouTube, website |
| Resolution | 1080 × 1920 | 1920 × 1080 |
| Frame rate | 30 fps | 30 fps |
| Duration | 27.007 s | 27.007 s |
| Video | H.264, yuv420p, BT.709, CRF 16 | same |
| Audio | AAC 48 kHz stereo, 317 kb/s | same |
| Size | 12 MB | 9.4 MB |

Poster frames are included as `video/out/OCR-PDF-Studio-Poster-9x16.png` and
`video/out/OCR-PDF-Studio-Poster-16x9.png`.

## Deliverables

| Item | Location |
| --- | --- |
| Final MP4s | `video/out/` |
| Poster frames | `video/out/` |
| Editable Remotion project | `video/` |
| Storyboard and copy deck | `STORYBOARD.md` |
| Asset provenance | `ASSET_REFERENCES.md` |
| Licenses | `LICENSES.md` |
| Render instructions | this file and `video/README.md` |

## What the film says

1. **Open** — logo, product name, “Scan. Extract. Convert.”
2. **Problem** — “Text shouldn't be stuck on paper.”
3. **Scan** — real home screen pushing to the real camera screen.
4. **Extract** — real OCR result with 69 words, find-in-text and copy.
5. **Translate** — the real English → हिन्दी selector, with no fabricated result.
6. **Create PDF** — the real two-page review and filename screen.
7. **Searchable PDF** — the real success state for a converted one-page PDF.
8. **Close** — logo, name, tagline and “On-device · no account.”

Every app screen in the film is a release-build screenshot from
`store-assets/screenshots/`. Nothing was composited, redrawn or invented. The
paper still-life in the problem scene is a crop of the invoice page from the
real translation screenshot, used as a paper prop rather than as a second app
screen.

## Render

Requirements: Node.js 20+ (tested on 24.18.0), npm, and enough disk for the
Remotion headless browser. First render downloads Chrome Headless Shell.

```bash
cd marketing/ocr-pdf-studio/video
npm install
npm run dev            # Remotion Studio preview
npm run check          # TypeScript, no bundling
npm run render:all     # both MP4s
```

Individual cuts:

```bash
npm run render:vertical
npm run render:landscape
```

Expected output:

```text
out/OCR-PDF-Studio-Launch-9x16.mp4
out/OCR-PDF-Studio-Launch-16x9.mp4
```

A full render of both cuts takes roughly 2–3 minutes on an Apple-silicon Mac.
`npm run render:all` writes H.264 at CRF 16, yuv420p, BT.709, with 320 kb/s AAC.

Poster frames:

```bash
npx remotion still OcrPdfStudio-Vertical  out/poster-9x16.png  --frame=760
npx remotion still OcrPdfStudio-Landscape out/poster-16x9.png  --frame=760
```

## Project layout

```text
marketing/ocr-pdf-studio/
├── README.md                  ← this file
├── STORYBOARD.md
├── ASSET_REFERENCES.md
├── LICENSES.md
└── video/
    ├── public/
    │   ├── logo.png
    │   ├── screenshots/       ← six release captures + invoice-page crop
    │   ├── music/             ← licensed score + license note
    │   ├── fonts/             ← Manrope variable + OFL
    │   └── sfx/               ← original synthesized whoosh/tick/impact
    ├── src/
    │   ├── OcrPdfStudioPreview.tsx  ← scene order, transitions, audio mix
    │   ├── Root.tsx                 ← both compositions, font loading
    │   ├── theme.ts                 ← colors, scene durations, total length
    │   ├── scenes/                  ← S1…S8
    │   └── components/              ← mockup, background, copy, transitions
    ├── tools/
    │   ├── generate-sfx.py
    │   └── crop-invoice-page.py
    └── out/                   ← final videos and posters
```

The video project is deliberately outside `lib/`, `android/`, `ios/` and
`pubspec.yaml`. No Flutter dependency, Android setting or app source file was
changed for this work.

## Verification performed

- `npx tsc --noEmit` passes.
- Representative frames from every scene and both mid-transition states were
  rendered as stills and inspected at full resolution.
- Both final MP4s were decoded from disk with AVFoundation; 15 frames per cut
  were extracted and reviewed, including the full opening, every feature scene,
  every transition and the final frame.
- Container probe: 30.0 fps, 1080 × 1920 and 1920 × 1080, 27.007 s, H.264 +
  AAC 48 kHz stereo.
- Audio probe: peak 0.73, RMS approximately −16 to −18 dBFS, with a fade-out
  tail near silence. No clipping.
- Copy was checked against the release build: 69 words, 2 pages, 1 page · 97 KB,
  1 page · 562 KB, Standard / Compress, Save PDF / Share PDF, English → हिन्दी.
- The translation scene shows the selector and the Translate button only. No
  translated output, quality claim or completion state is shown.

## Honesty notes

- **Translation.** The app uses Google ML Kit on-device translation and
  on-device language identification. A language model may be downloaded on first
  use, but the document text is processed locally. The film says “Your page stays
  on your device” and does not claim that a translation was completed.
- **Searchable PDF.** The success screen is a real conversion: a 97 KB one-page
  PDF became a 562 KB searchable PDF. The numbers are from the release capture.
- **Sample data.** The invoice, clinic, name, phone, email and amounts are
  synthetic. No real personal data appears.
- **Status bar.** The time, battery and notification icons are from the physical
  test device. The green notification icon is a system notification, not app UI.

## Licensing

- Appshot template and primitives: MIT, Copyright © 2026 Kian Nguyen. Full text
  in `video/LICENSE-APPSHOT.txt` and `LICENSES.md`.
- Music: `cinematic-build.mp3` from the Appshot template, licensed for use in
  generated videos (Pixabay Content License / Chosic CC0 as noted in the track
  folder). Not for standalone redistribution.
- Typeface: Manrope, SIL Open Font License 1.1. Full text in
  `video/public/fonts/OFL.txt`.
- Sound effects: synthesized for this project by
  `video/tools/generate-sfx.py`; no third-party samples.
- App screenshots, logo and brand: © the app owner.

## Git

Nothing in `marketing/ocr-pdf-studio/` has been committed or pushed. The final
videos are large; ask the owner before adding them to the Flutter repository.
