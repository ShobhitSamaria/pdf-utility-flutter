# Screenshots — provenance and captions

Six phone screenshots for the Play Store listing. All were captured from the
**release build** (`app-release.apk`, `versionName 1.0.0`, `versionCode 1`) on
the physical test device.

| Property | Value |
| --- | --- |
| Device | Realme RMX1801 |
| Android | 10 (API 29) |
| Resolution | 1080×2340, 480 dpi |
| Capture | `adb exec-out screencap -p` |
| Crop | `[0,0][1080,2160]` — excludes the system navigation bar, keeps the status bar, exactly 2:1 |
| Format | PNG, 8-bit RGB, no alpha |
| Size each | 1080×2160 (long side exactly 2× short side, Play's maximum) |
| Data shown | A synthetic sample invoice with a fictional clinic, name, phone, email and amounts. No real personal data. |

Play limits: PNG/JPEG, 8 MB each, sides 320–3840 px, long side ≤ 2× short side.
These files satisfy all three. They are phone screenshots only; tablet
screenshots are optional and were not captured.

---

## 1. Files and captions

| File | Screen | Suggested caption (≤ 80 chars) | What is actually shown |
| --- | --- | --- | --- |
| `01_home.png` | Home | Scan, extract and convert from one place | Branded header, OCR Scanner card, Create PDF card |
| `02_ocr_scan.png` | Camera | Capture a page with the on-device scanner | Live camera preview, page frame, shutter, privacy line |
| `03_extracted_text.png` | Scan result → Read text | Copy or search the recognised text | Extracted-text sheet, 69 words, find-in-text, Copy all |
| `04_translation.png` | Scan result → Translate | Translate extracted text on device | Source English / target हिन्दी, Translate button |
| `05_create_pdf.png` | Review pages | Review pages and name your PDF | Two-page review, filename, size estimate, Standard/Compress |
| `06_searchable_pdf.png` | Make PDF Searchable | Make a scanned PDF searchable | Success state, output filename and size, Save/Share |

---

## 2. Honesty notes

- **`04_translation.png` does not show a completed translation.** It shows the
  language selector before the user taps Translate. The test device had no
  active network, so the Hindi model could not be downloaded and no translated
  output could be produced. Do not caption it "translated to Hindi" and do not
  claim verified translation quality.
- **`06_searchable_pdf.png` is a real conversion.** The source was a one-page
  synthetic PDF (`Medical-Report.pdf`, 97 KB); the output was
  `Medical-Report (searchable).pdf`, 562 KB. The success state is the screen
  shown after Back from the converted document.
- **`03_extracted_text.png` is a real OCR result**: 69 words from the sample
  invoice, with the Latin recogniser.
- **`05_create_pdf.png` is a real two-page review**, using the sample invoice and
  a second gallery image. The PDF shown was not necessarily written to disk in
  this capture session; the review/create flow itself is implemented and was
  exercised separately.
- The status bar is real: time, battery and notification icons are from the
  device. The green notification icon is a system notification, not part of the
  app.
- Screenshots were not retouched. The only edit is the crop that removes the
  system navigation bar and makes the aspect ratio exactly 2:1.

---

## 3. If the owner wants different screenshots

Retake on a device with a clean status bar and, for translation, a downloaded
language model. Keep the same order and captions. Do not composite UI, add
device frames with fake screens, or show features that are not in the build.
