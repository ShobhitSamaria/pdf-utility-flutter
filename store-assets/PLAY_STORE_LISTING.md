# Play Store listing — OCR PDF Studio

Everything an owner needs to fill in the Play Console listing without inventing
copy. Character counts are exact; Play enforces 30 / 80 / 4000.

> **Status:** copy is final for the current build (`1.0.0+1`). It describes only
> features that exist in this repository. It does **not** claim DOCX/Word
> export, cloud sync, handwriting recognition, batch OCR of multi-page PDFs, or
> verified translation output — none of those are implemented or verified.

---

## 1. Identity

| Field | Value |
| --- | --- |
| App name (exact brand) | `OCR PDF Studio` (14 chars) |
| Recommended store title | `OCR PDF Studio: Scan & Convert` (30 chars — Play's maximum) |
| Package ID | `com.shobhit.pdfutility.pdf_utility_flutter` (unchanged) |
| Version | `1.0.0` (`versionCode` 1) |
| Default category | Productivity |
| Secondary category | Tools (optional; pick one, not both) |
| Pricing | Free |
| Contains ads | **No, in this build** (AdMob is not integrated; see `ADMOB_INTEGRATION_PLAN.md`) |
| In-app purchases | No |
| Account required | No |

Use the exact brand title if the 30-character title is rejected or the owner
prefers brand-only. Do not add "PDF Utility" anywhere: the old name is fully
retired in the Android label, in-app header, PDF metadata, and README.

---

## 2. Short description (80 max)

Recommended (71 chars):

```text
OCR scanner: extract text from photos and PDFs, translate, create PDFs.
```

Alternatives:

```text
Scan documents, extract text with OCR, translate and convert to PDF.   (68)
Scan, extract text, translate and create searchable PDFs on device.  (67)
```

---

## 3. Full description (4000 max)

```text
OCR PDF Studio turns paper and PDFs into text you can use — on your device.

Scan a page with the camera, choose photos from your gallery, or open an existing PDF. The app recognises printed text with Google ML Kit, lets you copy it, search inside it, and translate it into another language. You can also build a new PDF from your scans and turn a scanned PDF into a searchable one.

WHAT YOU CAN DO

• Scan with the camera, or pick photos from your gallery
• Open an existing PDF and read a page
• Recognise printed Latin and Devanagari (Hindi) text
• Copy the extracted text, or search inside it
• Translate extracted text on device
• Create a PDF from one or more images, with page review and reordering
• Make a scanned PDF searchable
• Save the result to Downloads or share it with another app

BUILT FOR REAL DOCUMENTS

Pages can be rotated before reading, the recognised text is shown next to the
original photo, and a search highlights where a word appears. Created PDFs can
be reordered, named, and compressed before they are written.

PRIVATE BY DESIGN

Text recognition and translation run on your device. There is no account, no
sign-up, no analytics and no advertising in this version. Photos, PDFs and
recognised text stay in the app's private storage until you choose to copy,
save or share them.

Translation models are downloaded once through Google Play Services the first
time you use a language (about 30 MB per language). After that, translation
works without a connection. The download needs an internet connection and
Google Play Services; availability of individual languages depends on Google's
models.

GOOD TO KNOW

• OCR works offline: the Latin and Devanagari recognition models are bundled
  with the app.
• The camera is optional. Gallery and PDF input work on devices without one.
• No document leaves the device unless you share or save it, or use the
  "Search" action, which opens your browser with the selected text.
```

Notes for the reviewer-facing copy:

- Do not add "free unlimited", "100% accurate", "best OCR", or "supports all
  languages". OCR accuracy depends on image quality and script.
- Do not state that translation has been verified end-to-end. On the test
  device the Hindi model could not be downloaded because the device had no
  network; the UI path was verified, the translated output was not.
- "No advertising in this version" is deliberately scoped. If AdMob is added,
  change this sentence and the Data Safety form in the same release.

---

## 4. Graphics

| Asset | Path | Spec | Status |
| --- | --- | --- | --- |
| App icon | `store-assets/graphics/play_store_icon_512.png` | 512×512 PNG, 32-bit, no alpha | Generated from `assets/LOGO.png` |
| Feature graphic | `store-assets/graphics/feature_graphic_1024x500.png` | 1024×500 PNG, no alpha | Generated, no fake UI |
| Phone screenshots | `store-assets/screenshots/*.png` | 1080×2160 or 1080×2092, ≤ 2:1 | Real device captures, see `screenshots/README.md` |
| Tablet screenshots | — | — | Not captured; optional |
| Promo video | — | — | Not supplied |

The icon is full-bleed navy (`#000730`) with the supplied document/scan mark.
The feature graphic is the mark plus wordmark and tagline on the same navy; it
contains no device frames, ratings, prices or "download now" text.

---

## 5. Screenshot order and captions

Captions are optional in Play but recommended. Each line is under the 80-char
caption limit.

| # | File | Suggested caption |
| --- | --- | --- |
| 1 | `01_home.png` | Scan, extract and convert from one place |
| 2 | `02_ocr_scan.png` | Capture a page with the on-device scanner |
| 3 | `03_extracted_text.png` | Copy or search the recognised text |
| 4 | `04_translation.png` | Translate extracted text on device |
| 5 | `05_create_pdf.png` | Review pages and name your PDF |
| 6 | `06_searchable_pdf.png` | Make a scanned PDF searchable |

Caption 4 must stay neutral ("Translate extracted text on device"). Do not
caption it "translated to Hindi": the screenshot shows the language selector
before translation runs, because the Hindi model could not be downloaded on the
test device.

---

## 6. Categorisation, tags and contact

- **Category:** Productivity.
- **Tags:** OCR, scanner, PDF, text recognition, translate, document.
- **Contact email:** `[OWNER: support email]` — required and public.
- **Website:** `[OWNER: optional]`.
- **Privacy policy URL:** `[OWNER: public HTTPS URL]` — required for every app.
  The draft is in `PRIVACY_POLICY_DRAFT.md`; it must be hosted before submission.
- **Developer name:** `[OWNER: legal/developer name as shown on Play]`.

---

## 7. Content rating questionnaire (guidance)

Answer for the current build:

- Violence, sexuality, language, controlled substances: **No**.
- Gambling: **No**.
- User-generated content or social features: **No** (no accounts, feeds, chat,
  or public sharing inside the app; the system share sheet is not UGC).
- Shares location: **No**.
- Purchases: **No**.
- Ads: **No** (current build).
- Expected rating: 3+ / Everyone. The owner must complete the questionnaire in
  the Play Console; this table is guidance, not a submitted rating.

---

## 8. Target audience and families

- Recommended target age: **18+** or **13+**. This is a general productivity
  tool; it is not designed for children.
- Do **not** opt into the Designed for Families programme.
- If the owner later targets children, AdMob and the Data Safety answers must be
  revisited (families policy prohibits personalised ads to children).

---

## 9. Release notes — 1.0.0 (500 max)

```text
First release of OCR PDF Studio.

• Scan a page with the camera or choose photos from your gallery
• Extract printed Latin and Devanagari text on device
• Copy, search and translate recognised text
• Create PDFs from images with page review, reordering and compression
• Turn a scanned PDF into a searchable PDF
• Save to Downloads or share with another app

Recognition runs on device. No account, analytics or ads.
```

---

## 10. Owner inputs still needed

1. Public developer name and support email.
2. Hosted privacy policy at a stable HTTPS URL.
3. Play Console account, app record, and acceptance of the Developer
   Distribution Agreement.
4. Content rating questionnaire and target-audience declaration.
5. Screenshot review (replace any capture the owner dislikes; do not edit the
   UI inside a screenshot).
6. If ads are wanted: AdMob account, app ID, ad unit IDs, consent setup, and a
   listing/Data Safety update — see `ADMOB_INTEGRATION_PLAN.md`.
