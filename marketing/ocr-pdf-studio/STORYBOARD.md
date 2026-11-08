# Storyboard — OCR PDF Studio launch films

One edit, two aspect ratios. The 9:16 and 16:9 cuts share timing, copy and
audio; only the composition and the line breaks change.

| Property | Value |
| --- | --- |
| Length | 27.000 s |
| Frame rate | 30 fps |
| Total frames | 810 |
| Scenes | 8 |
| Transition | 12-frame fade-through the navy brand field |
| Compositions | `OcrPdfStudio-Vertical` 1080 × 1920, `OcrPdfStudio-Landscape` 1920 × 1080 |

Scene starts below are the first frame of each sequence. Because every
transition overlaps its neighbours by 12 frames, the full-frame hold of a scene
starts 12 frames after its listed start and ends 12 frames before the next
listed start.

## 1. Scene map

| # | Scene | Frames | Time | Copy | Visual | Audio |
| --- | --- | --- | --- | --- | --- | --- |
| 1 | Open | 0–96 | 0.00–3.20 | OCR PDF Studio · Scan. Extract. Convert. · On-device document tools | Navy field. Logo springs in at 0.9 scale with a blue scan line crossing it twice. Wordmark rises; tagline lands word by word. Hairline footer fades in. | Low impact at frame 2. Score fades in over 26 frames. |
| 2 | Problem | 84–196 | 2.80–6.53 | The problem · Text shouldn’t be stuck on paper. · Copying by hand is slow. Searching isn’t an option. · Photos / Scans / PDFs · Flat image · no text layer | A still-life stack of real invoice paper, tilted, with soft shadows, a navy bottom gradient and a small paper-status chip. Paper drifts slowly. No phone, no app UI. | Whoosh at 2.33 s. Score continues. |
| 3 | Scan | 184–304 | 6.13–10.13 | 01 / Scan · Start with a page. Any page. · Use the camera, your gallery, or an existing PDF. · Camera / Gallery / PDF | Android phone. Real home screen holds, then pushes left to the real live camera screen at frame 242 (8.07 s). Native push, no dissolve. | Whoosh at 5.67 s. Tick at 8.07 s on the screen change. |
| 4 | Extract | 292–402 | 9.73–13.40 | 02 / Extract · Text you can copy and search. · The words on the page become selectable text, recognised on device. · 69 words found / Find in text / Copy all | Real extracted-text screenshot inside the phone, slow 1.00 → 1.14 push-in toward the text sheet. A thin blue scan line sweeps the text 12 frames into the hold. | Whoosh at 9.27 s. Tick at 10.20 s on the scan line. |
| 5 | Translate | 390–486 | 13.00–16.20 | 03 / Translate · Translation, on your device. · Pick a language. Your page stays on your device. · English ↔ हिन्दी / On-device | Real English → हिन्दी selector inside the phone, slow 1.00 → 1.07 push-in, periwinkle rim light. The Translate button is visible but never pressed. No translated output. | Whoosh at 12.53 s. No tick; the scene is deliberately quiet. |
| 6 | Create PDF | 474–598 | 15.80–19.93 | 04 / Create PDF · Your pages. A real PDF. · Review, reorder, name and compress. · 2 pages / Standard / Compress / One tap | Real two-page review and filename screenshot, 1.00 → 1.10 push-in. Scan line crosses the review list 18 frames into the hold. | Whoosh at 15.33 s. Tick at 16.47 s. |
| 7 | Searchable PDF | 586–698 | 19.53–23.27 | 05 / Searchable PDF · Make scanned PDFs searchable. · Turn a flat PDF into a searchable one. · Searchable / Save / Share | Real success state for the 97 KB → 562 KB conversion, 1.00 → 1.10 push-in on the result card. | Whoosh at 19.07 s. Tick at 20.87 s. |
| 8 | Close | 686–810 | 22.87–27.00 | OCR PDF Studio · Scan. Extract. Convert. · On-device · no account | Logo lockup returns with the same scan-line gesture. Tagline resolves; closing line fades in last. Held to the final frame. | Whoosh at 22.40 s. Score fades out over the last 42 frames. |

“Hold” means the 12-frame transitions are excluded. Scene 1 has no incoming
transition and scene 8 has no outgoing transition.

## 2. Transition timing

Every cut is a 12-frame fade-through, not a crossfade. The outgoing scene
reaches zero by 54% of the transition; the incoming scene starts at 46%. The
continuous `BrandBackground` never leaves the frame, so the edit reads as one
navy field rather than a dip to black.

| Cut | Frames | Time |
| --- | --- | --- |
| Open → Problem | 84–96 | 2.80–3.20 |
| Problem → Scan | 184–196 | 6.13–6.53 |
| Scan → Extract | 292–304 | 9.73–10.13 |
| Extract → Translate | 390–402 | 13.00–13.40 |
| Translate → Create PDF | 474–486 | 15.80–16.20 |
| Create PDF → Searchable | 586–598 | 19.53–19.93 |
| Searchable → Close | 686–698 | 22.87–23.27 |

## 3. Copy deck

The copy is written as plain, verifiable product language. Headline line breaks
are controlled with `LineBreak` inside each scene; the visible text is identical
in both aspect ratios.

### Opening

| Element | Text |
| --- | --- |
| Wordmark | OCR PDF Studio |
| Tagline | Scan. Extract. Convert. |
| Footer | On-device document tools |

### Problem

| Element | Text |
| --- | --- |
| Kicker | The problem |
| Headline | Text shouldn’t be stuck on paper. |
| Body | Copying by hand is slow.<br>Searching isn’t an option. |
| Pills | Photos · Scans · PDFs |
| Paper chip | Flat image · no text layer |

### Feature scenes

| # | Kicker | Headline | Body | Pills |
| --- | --- | --- | --- | --- |
| 01 | 01 / Scan | Start with a page. Any page. | Use the camera, your gallery, or an existing PDF. | Camera · Gallery · PDF |
| 02 | 02 / Extract | Text you can copy and search. | The words on the page become selectable text, recognised on device. | 69 words found · Find in text · Copy all |
| 03 | 03 / Translate | Translation, on your device. | Pick a language. Your page stays on your device. | English ↔ हिन्दी · On-device |
| 04 | 04 / Create PDF | Your pages. A real PDF. | Review, reorder, name and compress. | 2 pages · Standard / Compress · One tap |
| 05 | 05 / Searchable PDF | Make scanned PDFs searchable. | Turn a flat PDF into a searchable one. | Searchable · Save · Share |

### Close

| Element | Text |
| --- | --- |
| Wordmark | OCR PDF Studio |
| Tagline | Scan. Extract. Convert. |
| Footer | On-device · no account |

### Claims behind the copy

| Claim | Evidence in the build |
| --- | --- |
| 69 words found | Real OCR result in `03_extracted_text.png`. |
| 2 pages | Real two-page review in `05_create_pdf.png`. |
| 97 KB → 562 KB | Real conversion shown in `06_searchable_pdf.png`. |
| Standard / Compress, Save PDF / Share PDF | Visible controls in the release captures. |
| English → हिन्दी | Real selector in `04_translation.png`. No result is shown. |
| On-device | Text recognition and translation use Google ML Kit on device. A model may download on first use; document text stays local. |

## 4. Design system

### Palette

| Token | Value | Use |
| --- | --- | --- |
| Navy | `#000730` | Base field, safe area, backgrounds |
| Navy soft | `#070D2A` | Raised background wash |
| App primary | `#242A5C` | App-adjacent surfaces |
| Blue | `#0170FE` | Primary accent, scan-line core |
| Blue bright | `#4D9BFF` | Headline highlight, glow |
| Periwinkle | `#94A8DE` | Secondary accent, translate glow |
| Off-white | `#F7F8FF` | Headlines |
| Body | `rgba(226,232,255,0.72)` | Body copy |

### Type

- **Manrope** variable, weights 200–800, bundled locally under the SIL Open
  Font License.
- Headline: weight 750, tight tracking (−0.048em), balanced measure.
- Kicker: uppercase, wide tracking (0.19em), small caps rhythm.
- Body: weight 500, 1.55 line height.
- Wordmark: weight 800, −0.055em tracking.

### Layout

- 9:16: copy in the upper third, phone or paper in the lower two thirds.
- 16:9: copy on the left, device on the right, with the phone cropped by the
  bottom edge so it reads as a real object rather than a floating card.
- Safe margins: 70 px portrait, 110 px landscape.
- Device: custom 1:2 Android mockup with a punch-hole camera, side buttons and
  a subtle bezel highlight. Screen content is the real 1080 × 2160 capture,
  scaled to fit without cropping.

## 5. Audio timeline

| Time | Event | Level |
| --- | --- | --- |
| 0.00 s | Score starts at 2.0 s into `cinematic-build.mp3`; fades in over 26 frames | 0 → 0.75 |
| 0.07 s | Opening impact | 0.40 |
| 2.33 s | Whoosh into Problem | 0.30 |
| 5.67 s | Whoosh into Scan | 0.30 |
| 8.07 s | Tick: home → camera push | 0.20 |
| 9.27 s | Whoosh into Extract | 0.30 |
| 10.20 s | Tick: text scan line | 0.20 |
| 12.53 s | Whoosh into Translate | 0.30 |
| 15.33 s | Whoosh into Create PDF | 0.30 |
| 16.47 s | Tick: review scan line | 0.20 |
| 19.07 s | Whoosh into Searchable PDF | 0.30 |
| 20.87 s | Tick: success card | 0.20 |
| 22.40 s | Whoosh into Close | 0.30 |
| 25.60–27.00 s | Score fade-out over 42 frames | 0.70 → 0 |

The score sits at −16 to −18 dBFS RMS, peaks at 0.73, and ends near silence.
Sound effects are original synthesized files generated by
`video/tools/generate-sfx.py`.

## 6. What is deliberately not shown

- No translated Hindi output, no “translated” success state and no translation
  quality claim. The selector is shown, not a result.
- No multi-page PDF OCR, batch conversion, DOCX export, cloud sync, account,
  subscription or handwriting recognition.
- No fabricated app UI. Every phone screen is a release-build capture.
- No fake progress bars or invented file sizes. The 97 KB / 562 KB pair is the
  real conversion from the release build.
- The paper in the problem scene is a crop of the real invoice page, used as a
  physical prop. It is not presented as an app screen.
