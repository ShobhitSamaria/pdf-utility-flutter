# OCR PDF Studio promo — Remotion project

Editable source for the two launch films. The finished files are in `out/`; the
storyboard and provenance live one level up.

## Quick start

```bash
cd marketing/ocr-pdf-studio/video
npm install
npm run dev
```

Remotion Studio opens both compositions:

| Composition | Size | Use |
| --- | --- | --- |
| `OcrPdfStudio-Vertical` | 1080 × 1920 | Reels, Shorts, TikTok |
| `OcrPdfStudio-Landscape` | 1920 × 1080 | YouTube, website |

Both are 810 frames at 30 fps (27.000 s).

## Commands

| Command | What it does |
| --- | --- |
| `npm run dev` | Remotion Studio preview with hot reload |
| `npm run check` | `tsc --noEmit`; no bundling |
| `npm run still:vertical` | PNG of frame 0 at 1080 × 1920 |
| `npm run still:landscape` | PNG of frame 0 at 1920 × 1080 |
| `npm run render:vertical` | Final 9:16 MP4 |
| `npm run render:landscape` | Final 16:9 MP4 |
| `npm run render:all` | Both finals, sequentially |

Renders are H.264 at CRF 16, `yuv420p`, BT.709, with 320 kb/s AAC 48 kHz
stereo. Output:

```text
out/OCR-PDF-Studio-Launch-9x16.mp4
out/OCR-PDF-Studio-Launch-16x9.mp4
```

The first render downloads Chrome Headless Shell (about 90 MB). Subsequent
renders reuse it. Both finals take roughly 2–3 minutes on an Apple-silicon Mac.

## Project map

```text
video/
├── public/
│   ├── logo.png                     app mark, 256 × 256 RGBA
│   ├── screenshots/                 six release captures + invoice-page crop
│   ├── music/
│   │   ├── cinematic-build.mp3      licensed score
│   │   └── LICENSE                  track terms
│   ├── fonts/
│   │   ├── Manrope-Variable.ttf     variable weight 200–800
│   │   └── OFL.txt                  SIL Open Font License 1.1
│   └── sfx/                         original whoosh, tick, impact
├── src/
│   ├── index.ts                     Remotion entry point
│   ├── Root.tsx                     compositions + font loading
│   ├── OcrPdfStudioPreview.tsx      scene order, transitions, audio mix
│   ├── theme.ts                     colors, durations, total frames
│   ├── app-config.ts                app metadata and video defaults
│   ├── styles.css                   global reset, Manrope stack
│   ├── scenes/
│   │   ├── S1_Open.tsx
│   │   ├── S2_Problem.tsx
│   │   ├── S3_Scan.tsx
│   │   ├── S4_Extract.tsx
│   │   ├── S5_Translate.tsx
│   │   ├── S6_CreatePdf.tsx
│   │   ├── S7_Searchable.tsx
│   │   └── S8_Close.tsx
│   └── components/
│       ├── BrandBackground.tsx      animated navy field
│       ├── DeviceMockup.tsx         1:2 Android phone
│       ├── ScreenshotScreen.tsx     real screen + push + scan line
│       ├── FadeThrough.tsx          clean scene transition
│       ├── SceneFrame.tsx           shared copy + device layout
│       ├── SceneCopy.tsx            kicker, headline, body, pills
│       ├── PaperStack.tsx           invoice paper still-life
│       ├── LogoLockup.tsx           opening and closing lockup
│       └── layout.ts               responsive sizes
├── tools/
│   ├── generate-sfx.py              regenerate the three WAVs
│   └── crop-invoice-page.py         regenerate the paper crop
├── out/                             finals and posters
├── LICENSE-APPSHOT.txt              MIT text for Appshot
├── package.json
├── package-lock.json
└── remotion.config.ts               Tailwind webpack hook
```

## How the edit is built

`OcrPdfStudioPreview.tsx` owns the timeline:

- `TransitionSeries` holds the eight scenes with 12-frame `fadeThrough()`
  transitions. The outgoing scene is gone before the incoming scene appears, so
  headlines and app screens never double-expose.
- `BrandBackground` sits outside the transition series, so the navy field and
  its slow breathing motion are continuous across every cut.
- One `Audio` element plays the score from 2.0 s into the track, fading in over
  26 frames and out over the final 42.
- Seven whooshes lead each cut by 14 frames. Four ticks land on screen changes.
  The opening impact is at frame 2.

Scene timing lives in `src/theme.ts`:

```ts
export const SCENE_DURATIONS = [96, 112, 120, 110, 96, 124, 112, 124];
export const TRANSITION_FRAMES = 12;
```

With eight scenes and seven 12-frame overlaps, the total is
`894 − 84 = 810` frames.

## Editing copy

Copy is inside each scene file. Headlines use `LineBreak` to control wraps per
aspect ratio; body copy accepts a React node, so `<br />` and emphasis are
allowed.

```tsx
<FeatureScene
  kicker="01 / Scan"
  headline={
    <>
      Start with a page.<LineBreak only="landscape" />{" "}
      <span style={{ color: COLORS.blueBright }}>Any page.</span>
    </>
  }
  body="Use the camera, your gallery, or an existing PDF."
  pills={["Camera", "Gallery", "PDF"]}
>
```

After any copy change, run `npm run check`, then render stills of the affected
scene in both formats. Long headlines are the usual source of awkward wraps.

## Changing the phone screen

The mockup uses a custom 1:2 screen so the 1080 × 2160 captures fit without
cropping. Each scene passes a file from `public/screenshots/`:

```tsx
<DeviceMockup screenWidth={phoneScreenWidth} enterDelay={2}>
  <ScreenshotScreen
    src="screenshots/03_extracted_text.png"
    durationInFrames={110}
    startScale={1}
    endScale={1.14}
    focusX={50}
    focusY={42}
    scan
    scanDelay={12}
  />
</DeviceMockup>
```

`ScreenSwap` pushes from one screen to another with a native-style horizontal
move. It is used once, from the home screen to the live camera screen.

## Changing audio

The mix is in `OcrPdfStudioPreview.tsx`. Levels were set by measurement, not by
ear: the master peaks at 0.73 and sits around −16 to −18 dBFS RMS.

- `startFrom={60}` skips the score’s quiet lead-in (frame 60 = 2.0 s).
- The volume curve `[0, 26, TOTAL_DURATION - 42, TOTAL_DURATION]` maps to
  `[0, 0.75, 0.7, 0]`.
- Whoosh lead is `WHOOSH_LEAD = 14` frames.
- Tick frames are offsets from scene starts, not absolute frames.

If you replace the score, re-measure the mix. A track that reads fine in Studio
can still clip after AAC encoding.

## Regenerating derived assets

```bash
python3 tools/generate-sfx.py       # deterministic, seed 7
python3 tools/crop-invoice-page.py  # crop 04_translation.png
```

Both scripts are idempotent. Their output hashes are recorded in
`../ASSET_REFERENCES.md`.

## Verification routine

```bash
npm run check
npx remotion still OcrPdfStudio-Vertical  out/check-v.png  --frame=430
npx remotion still OcrPdfStudio-Landscape out/check-l.png  --frame=430
```

For a final pass, extract frames from the encoded MP4s rather than trusting the
compositions alone. On macOS:

```bash
# metadata
mdls -name kMDItemPixelWidth -name kMDItemPixelHeight \
     -name kMDItemDurationSeconds -name kMDItemCodecs out/*.mp4

# audio container
afinfo out/OCR-PDF-Studio-Launch-9x16.mp4
```

The shipped files were checked at 30.0 fps, 1080 × 1920 and 1920 × 1080,
27.007 s, H.264 + AAC 48 kHz stereo, peak 0.73.

## Notes

- The project is self-contained. It does not import from `lib/`, does not touch
  `pubspec.yaml`, and changes no Android or iOS configuration.
- `npm audit` reports inherited vulnerabilities from the Appshot template
  dependency tree. They were not auto-fixed because that would move pinned
  Remotion versions.
- Do not commit `node_modules/` or the large MP4s without the owner’s approval.
  See `.gitignore`.
