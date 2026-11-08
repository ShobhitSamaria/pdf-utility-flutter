# Compatibility audit — OCR PDF Studio 1.0.0

**Build under test:** `versionCode` 1, `versionName` 1.0.0
**Package:** `com.shobhit.pdfutility.pdf_utility_flutter`
**Physical device:** Realme RMX1801, Android 10 (API 29), 1080×2340, 480 dpi,
`arm64-v8a`, adb serial `d84aca05`.

Only Android 10 was available for physical verification. Everything below
distinguishes **verified** from **expected from code/config**.

---

## 1. Build configuration (verified)

| Item | Value |
| --- | --- |
| Flutter | 3.44.6 (stable) |
| Dart | 3.12.2 |
| Android Gradle Plugin | 9.0.1 |
| Gradle | 9.1.0 |
| Kotlin | 2.3.20 |
| Java | 17 |
| `minSdk` | 24 (Android 7.0) |
| `targetSdk` / `compileSdk` | 36 (Android 16) |
| Version | `1.0.0` / code `1` |
| ABIs in APK | `arm64-v8a`, `armeabi-v7a`, `x86_64` |
| 64-bit | Yes (`arm64-v8a` present) |
| 16 KB page size | Yes — `zipalign -c -P 16` passes; all `arm64-v8a` `LOAD` segments are aligned to `0x4000` (16 KB) or `0x10000` (64 KB) |
| Signing | **Debug key** (`signingConfigs.getByName("debug")`) — must be replaced before upload |

**Built artifacts verified from this tree:**

| Artifact | Size | SHA-256 |
| --- | --- | --- |
| `build/app/outputs/bundle/release/app-release.aab` | 118,900,873 bytes | `e676d74109e8c383eabe41a66fcd81d23688251ad0cdbca3801ea05ec88150a1` |
| `build/app/outputs/flutter-apk/app-release.apk` | 142,232,648 bytes | `3b2db6b184a1e50419d27632457414fdc0ce89b5b3419a541f9b10e249841c91` |

The AAB is JAR-signed (`jarsigner -verify` reports "jar verified") with the
Android Debug certificate (`CN=Android Debug`, SHA-256
`0383db0e…a4fd…`). It is structurally a valid bundle but **not a valid
production upload** until the owner replaces the signing config.

`targetSdk 36` satisfies Google Play's requirement for new apps and updates
from **31 August 2026**. Because the app targets 35+, it must also support
16 KB page sizes; the packaged native libraries do, as checked above.

The ABIs include `x86_64` because Flutter builds it by default. It does not
hurt a phone release; an App Bundle will split by ABI anyway.

---

## 2. Verified on the Realme RMX1801 (Android 10)

| Area | Result |
| --- | --- |
| Install / launch | Installs and launches; app label **OCR PDF Studio** |
| Launcher icon | Adaptive icon and round icon render correctly in App info |
| Splash | Native launch window shows the branded lockup on `#FAFAFC` with dark status-bar icons; no black flash |
| Home | Branded header, both actions, Settings sheet, identity block |
| Camera capture | Permission prompt and live preview; still capture works (`enableAudio: false`) |
| Gallery input | Android Photo Picker opens; selected image reaches OCR |
| OCR (Latin) | End-to-end on a generated invoice; 69 words extracted correctly |
| Devanagari OCR | Devanagari recognizer is bundled; not separately re-verified in this pass |
| Extracted text | Text sheet, word count, copy, find-in-text |
| Translation UI | Language pair, model-state UI and error path; **output unverified** (device had no network) |
| Create PDF | Two images → review → reorder → name → create |
| Searchable PDF | Imported PDF → OCR → searchable output → successful save/share screen |
| Save | MediaStore Downloads copy on Android 10 |
| Share | `FileProvider` chooser opens |
| Permissions | Only camera is requested at runtime; no storage prompt on the tested flows |
| Back navigation | System back dismisses sheets/screens correctly |

Device-specific note: `getCacheDir()` resolves to a `code_cache` path on this
device. The app writes created PDFs to `<files>/shared` instead, precisely so
`FileProvider` can serve them. That workaround is already in
`MainActivity.kt` and `file_paths.xml`.

---

## 3. Version-by-version expectations

| Android version | API | Status | Notes |
| --- | --- | --- | --- |
| 7.0–7.1 | 24–25 | Expected | `minSdk` 24. Camera, SAF picker, app-private files. No runtime storage permission needed for SAF. |
| 8.0–8.1 | 26–27 | Expected | Adaptive icon used from 26. FileProvider sharing. |
| 9 | 28 | Expected | Save falls back to `getExternalFilesDir(DIRECTORY_DOWNLOADS)` because MediaStore Downloads requires 29. `WRITE_EXTERNAL_STORAGE` capped at 28 comes from the camera plugin. |
| 10 | 29 | **Verified** | Scoped storage; Save uses MediaStore Downloads with `IS_PENDING`; Photo Picker path not used yet. |
| 11 | 30 | Expected | `<queries>` for browser and Play Services; package visibility handled in manifest. |
| 12 / 12L | 31–32 | Expected, not physically tested | Android 12 splash uses the system icon on the light brand colour (`values-v31/styles.xml`). |
| 13 | 33 | Expected | System Photo Picker; Android 13 themed icon uses the supplied monochrome layer. |
| 14 | 34 | Expected | No version-specific code. |
| 15 | 35 | Expected, **not physically tested** | Edge-to-edge is enforced for target 35+. The UI uses `SafeArea` and scrollable content; verify on a real Android 15 device. |
| 16 | 36 | Expected, **not physically tested** | Target/compile level. Verify install, splash, camera and system bars. |

---

## 4. Feature dependencies

| Feature | Requires | Works offline? |
| --- | --- | --- |
| OCR (Latin) | Bundled ML Kit model in the APK | Yes |
| OCR (Devanagari) | Bundled ML Kit Devanagari model | Yes |
| OCR (auto / mixed) | Both bundled models | Yes |
| Create PDF | Local files only | Yes |
| Import PDF | System document picker | Yes |
| Make PDF searchable | Bundled OCR + local PDF renderer | Yes |
| Save / Share | System MediaStore / FileProvider | Yes |
| Translate | Google Play Services + one-time model download (~30 MB per language) | Yes after the model is present |
| Language auto-detect | Bundled language-ID model | Yes |
| Web search | A browser | Needs network/browser |

Devices without Google Play Services can still use OCR, PDF creation, PDF
import and searchable PDFs. Translation model provisioning will not be
available there. Do not market the app as "works on every Android device with
translation" without that caveat.

---

## 5. Permissions compatibility

- **Camera** is declared optional in `<uses-feature>`, so the app installs on
  devices without a camera; gallery/PDF input remain.
- **`READ_EXTERNAL_STORAGE`** is declared by `file_picker` with
  `maxSdkVersion=32`. The app uses the Storage Access Framework and the Android
  Photo Picker, so it does not request this at runtime on the tested device.
- **`WRITE_EXTERNAL_STORAGE`** is declared by `camera_android_camerax` with
  `maxSdkVersion=28`; on Android 10+ the app writes through MediaStore.
- **`RECORD_AUDIO`** is removed with `tools:node="remove"`; the final APK does
  not contain it.
- **`AD_ID`** is not present in the current build.

---

## 6. Storage behaviour

| Android | Where a saved PDF goes | Permission needed |
| --- | --- | --- |
| 10+ | `Downloads/` via MediaStore | None |
| ≤ 9 | App-specific external `Downloads` directory (`getExternalFilesDir`) | None at runtime with the plugin-declared max-SDK permission |
| Any | Share sheet via `content://…fileprovider/...` | Temporary read grant only |

Imported PDFs and picked images are read from the picker-provided cached copy.
Rendered PDF pages and rotated images are written to the app cache. No broad
storage access is requested by app code.

---

## 7. Known risks / unverified areas

1. **Android 12+ splash** — configured, not physically observed. The theme uses
   `windowSplashScreenBackground` plus the adaptive icon; `postSplashScreenTheme`
   is intentionally not set because the platform attribute was unavailable in
   this compile setup. The activity still hands over to `NormalTheme` through
   the Flutter embedding.
2. **Android 15/16 edge-to-edge** — target 35+ forces edge-to-edge; system bar
   colours may be ignored. Only Android 10 was checked. Test on API 35/36.
3. **Tablets / foldables / landscape** — not tested. Layouts are scroll-based,
   but the PDF viewer and camera framing are optimised for portrait phones.
4. **Translation output** — not verified end-to-end because the test device had
   no active network and the Hindi model could not be downloaded.
5. **Play Services variants** — translation model download depends on Google
   Play Services; no fallback engine exists.
6. **Debug signing** — the release AAB is currently signed with the debug key;
   Play will reject it as a production upload.
7. **16 KB page size on non-arm64** — checked on `arm64-v8a` (the ABI Play
   requires). `armeabi-v7a` and `x86_64` are present but not the primary target.

---

## 8. Test commands used

```bash
flutter analyze
flutter test
flutter build appbundle --release
flutter build apk --release
"$ANDROID_HOME/build-tools/36.0.0/aapt" dump badging build/app/outputs/bundle/release/app-release.aab
"$ANDROID_HOME/build-tools/36.0.0/zipalign" -c -P 16 -v 4 build/app/outputs/flutter-apk/app-release.apk
adb install -r build/app/outputs/flutter-apk/app-release.apk
adb shell dumpsys package com.shobhit.pdfutility.pdf_utility_flutter | grep -E "versionName|versionCode|minSdk|targetSdk"
```

Final results on this tree: `flutter analyze` reported **no issues**, the full
suite passed **848 tests**, and both release builds completed successfully.
The release APK was installed over the debug build (same debug key) and used for
the final device screenshots; the six store screenshots come from that build.
