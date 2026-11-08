# Asset references — provenance and checksums

Every asset in the promo is traceable. The app screenshots are release-build
captures; the logo is the app’s own mark; the music and typeface are licensed;
the sound effects were generated for this project.

## 1. Screenshots

The six source files live in `store-assets/screenshots/`. The copies in
`video/public/screenshots/` are **byte-identical** (verified with `cmp`); the
video project does not crop, retouch or recolour them.

| Video asset | Store source | Screen | SHA-256 |
| --- | --- | --- | --- |
| `01_home.png` | `store-assets/screenshots/01_home.png` | Home | `636e20f4f812edfe2d798a6b5b4adcaf0585ee9e048f1f0b5dfd4326f37b2a4c` |
| `02_ocr_scan.png` | `store-assets/screenshots/02_ocr_scan.png` | Live camera | `6c71a9ef2ac00c8671e24dd417c2d74c1847af622019ec469e28ba8f07584e2f` |
| `03_extracted_text.png` | `store-assets/screenshots/03_extracted_text.png` | Extracted text | `6b32447897fe4b31d0ea3bc89c3f750d24a75ff727c188d7c5c47a27b515fd84` |
| `04_translation.png` | `store-assets/screenshots/04_translation.png` | Translation selector | `37daf7a9fc3521ba8dd1d84e9a91ad6f7799d33434a73e1532f89840a3bb6829` |
| `05_create_pdf.png` | `store-assets/screenshots/05_create_pdf.png` | Review pages | `d880540c5dbd393580163cd39f73acbf89cef8400cbea3522e7fe18257c16bc9` |
| `06_searchable_pdf.png` | `store-assets/screenshots/06_searchable_pdf.png` | Searchable PDF success | `53cb5987875a112a5a4a03194e07e0e95fdae70aa90ba0d52a566bc6d96c98c9` |

### Capture provenance

From `store-assets/screenshots/README.md`:

| Property | Value |
| --- | --- |
| Build | `app-release.apk`, `versionName 1.0.0`, `versionCode 1` |
| Device | Realme RMX1801 |
| Android | 10 (API 29) |
| Native resolution | 1080 × 2340, 480 dpi |
| Capture | `adb exec-out screencap -p` |
| Crop | `[0,0][1080,2160]` — removes the system navigation bar, keeps the status bar |
| Format | PNG, 8-bit RGB, no alpha, 1080 × 2160 |
| Data | Synthetic invoice with a fictional clinic, name, phone, email and amounts |

The only edit applied to the screenshots was that crop, made when the Play Store
set was produced. The green notification icon in the status bar is a system
notification, not app UI.

### Honesty limits carried into the film

- `04_translation.png` shows the English → हिन्दी selector **before** Translate
  is pressed. The test device had no active network, so the Hindi model could
  not be downloaded. The film never shows a translated result.
- `06_searchable_pdf.png` is a real conversion: a one-page 97 KB synthetic PDF
  became a 562 KB searchable PDF.
- `03_extracted_text.png` is a real OCR result: 69 words from the sample invoice.
- `05_create_pdf.png` is a real two-page review; the create flow is implemented,
  but the screenshot is the review step, not a written file.

## 2. Logo

| Item | Value |
| --- | --- |
| Master | `assets/LOGO.png` — 1254 × 1254, RGB |
| Master SHA-256 | `268ef01ba9d6c330781c36e4efb101acf19b283f6adbc63a8123ced6ec83cd8b` |
| Video copy | `video/public/logo.png` — 256 × 256, RGBA |
| Video SHA-256 | `de2f13f5597c359f7f95ad57ef2703c9ec913db0381dbcfcea49499698bb1556` |

The video copy is a downscale of the master with an alpha channel so it can sit
on the navy field without a visible square. The mark is not redrawn, recoloured
or re-lettered. The wordmark “OCR PDF Studio” is set in Manrope.

## 3. Paper still-life

The problem scene uses a paper prop, not a second app screen.

| Item | Value |
| --- | --- |
| Source | `video/public/screenshots/04_translation.png` |
| Crop | `(0, 310) → (1080, 1790)` — excludes the app bar and the language selector |
| Output | `video/public/screenshots/invoice-page.png`, 1080 × 1480 |
| SHA-256 | `9cc4dcaa82b1ee4a3c83eb132f37012d38bd12941fc18531d6cc026f4bb31ab3` |
| Script | `video/tools/crop-invoice-page.py` |

The crop is displayed at a slight tilt with soft shadows, a navy bottom
gradient and a small “Flat image · no text layer” chip. It is the real invoice
page from the real capture; no text is added to the page itself.

## 4. Music

| Item | Value |
| --- | --- |
| File | `video/public/music/cinematic-build.mp3` |
| Source | Appshot video template, `template/public/music/cinematic-build.mp3` |
| SHA-256 | `5c20118ee9f5e7ed17ae34c321fd11b0803b9beec15a4dba0599cb3cdc396197` |
| License note | `video/public/music/LICENSE` |

The track is 48.07 s. The film starts playback at 2.0 s (`startFrom={60}`) to
skip the near-silent lead-in, so only the build section is used. The file itself
is not trimmed or re-encoded. License terms are reproduced in `LICENSES.md`.

## 5. Typeface

| Item | Value |
| --- | --- |
| File | `video/public/fonts/Manrope-Variable.ttf` |
| Family | Manrope, variable weight 200–800 |
| SHA-256 | `3ae11c49db0455a3cc33e37d380f20fdb8c7f8b41dc07625c177e3d87a9d6ae6` |
| License | SIL Open Font License 1.1 — `video/public/fonts/OFL.txt` |
| Upstream | The Manrope Project Authors, <https://github.com/googlefonts/manrope> |

Loaded with `@remotion/fonts` `loadFont()` in `src/Root.tsx` before the
compositions render, so headless renders and Studio use the same file.

## 6. Sound effects

All three effects are original synthesis, generated deterministically by
`video/tools/generate-sfx.py` (Python 3, standard library only; seed 7,
44.1 kHz, 16-bit mono). No third-party samples.

| File | Length | SHA-256 |
| --- | --- | --- |
| `video/public/sfx/whoosh.wav` | 1.250 s | `a5c2c0481914c0962c99159e1445d7f5bd5ea549712534fe0f38fe8671e59d0b` |
| `video/public/sfx/tick.wav` | 0.090 s | `43959248a6f7ec7972ccb5881cecbd6f4d03dccaf62e756a5a3ecb7f9f060aab` |
| `video/public/sfx/impact.wav` | 1.000 s | `881595cc8c2bbb36b1cef9b37180fc6a2dd758daf11472a7cb2a82b7762c223d` |

Re-running the script reproduces the same bytes, so the checksums above are a
regression check as well as provenance.

## 7. Rendered outputs

| File | Dimensions | SHA-256 |
| --- | --- | --- |
| `video/out/OCR-PDF-Studio-Launch-9x16.mp4` | 1080 × 1920 | `0824c2b351633326d686c84e9b2f6e3dbe3f1d95c043095fb1c29701b6fd709e` |
| `video/out/OCR-PDF-Studio-Launch-16x9.mp4` | 1920 × 1080 | `8a18d7d05aa5b96ef707fd23e3156f174aa92f4b1186cf2c1bebb108423a19ad` |
| `video/out/OCR-PDF-Studio-Poster-9x16.png` | 1080 × 1920 | `8c5ce62e8c6635c769c6411b56edb5e7c0047c770587c71278827da4bc58ebe6` |
| `video/out/OCR-PDF-Studio-Poster-16x9.png` | 1920 × 1080 | `1c8c2f3ec75ac322af9531967260dda82cfd18157930239d2f4099960db46650` |

Checksums were taken from the files in `video/out/` after the final render.
Poster frames are stills at frame 760, the settled closing lockup.

## 8. Checksum verification

From the repository root:

```bash
cd marketing/ocr-pdf-studio/video
shasum -a 256 public/logo.png public/screenshots/*.png \
  public/music/cinematic-build.mp3 public/fonts/Manrope-Variable.ttf \
  public/sfx/*.wav out/*
```

The output should match the tables above. The source screenshots can be checked
against the store set with:

```bash
for f in 01_home 02_ocr_scan 03_extracted_text 04_translation 05_create_pdf 06_searchable_pdf; do
  cmp "store-assets/screenshots/$f.png" "marketing/ocr-pdf-studio/video/public/screenshots/$f.png" \
    && echo "$f identical"
done
```
