# Store release assets — OCR PDF Studio 1.0.0

This folder contains everything prepared for the Play Store submission **except**
the things only the owner can create (Play Console account, upload key, hosted
privacy-policy URL, AdMob account). Nothing here changes the app at runtime.

---

## 1. What is in here

| File | Purpose | State |
| --- | --- | --- |
| `PLAY_STORE_LISTING.md` | Title, short/full description, categories, screenshot order, content-rating guidance, release notes | Ready to paste |
| `PRIVACY_AUDIT.md` | Evidence-based audit of data flows, permissions, storage and network use | Complete for build 1 |
| `DATA_SAFETY_CHECKLIST.md` | Recommended Play Console Data Safety answers and caveats | Ready for owner sign-off |
| `COMPATIBILITY_AUDIT.md` | SDK/ABI/16 KB/permission/version compatibility, device results, unverified areas | Complete for build 1 |
| `ADMOB_INTEGRATION_PLAN.md` | Policy-safe plan; explicitly **not integrated** | Planning only |
| `PRIVACY_POLICY_DRAFT.md` | Full policy draft with owner placeholders | Needs owner/legal review and hosting |
| `graphics/play_store_icon_512.png` | 512×512 Play icon | Generated from `assets/LOGO.png` |
| `graphics/feature_graphic_1024x500.png` | 1024×500 feature graphic | Generated |
| `screenshots/` | Six 1080×2160 phone screenshots | Captured on the release build, Realme RMX1801 |
| `screenshots/README.md` | Screenshot provenance and captions | Complete |

Not included: tablet screenshots, promo video, AdMob IDs, upload keystore,
Play Console listing. Those require owner decisions/accounts.

---

## 2. Release artifacts (verified)

| Artifact | Path | Size | SHA-256 |
| --- | --- | --- | --- |
| App Bundle (upload format) | `build/app/outputs/bundle/release/app-release.aab` | 118,900,873 bytes (118.9 MB) | `e676d74109e8c383eabe41a66fcd81d23688251ad0cdbca3801ea05ec88150a1` |
| Release APK (device testing) | `build/app/outputs/flutter-apk/app-release.apk` | 142,232,648 bytes (142.2 MB) | `3b2db6b184a1e50419d27632457414fdc0ce89b5b3419a541f9b10e249841c91` |
| Preserved previous APK | `PDF-Utility-Latest.apk` | 141,405,138 bytes | `c70258fcdc159ad9b7cd92ead50f06c2373a7c897dc08c92b012e6435c60944a` |

Verified on the AAB/APK pair built from the same tree:

- package `com.shobhit.pdfutility.pdf_utility_flutter` (unchanged);
- version `1.0.0` / code `1`;
- `minSdk 24`, `targetSdk 36`, `compileSdk 36`;
- ABIs `arm64-v8a`, `armeabi-v7a`, `x86_64`;
- 16 KB page-size compatible (`zipalign -c -P 16` passes; arm64 `LOAD` alignment
  ≥ `0x4000`);
- permissions: `CAMERA`, `INTERNET`, `ACCESS_NETWORK_STATE`,
  `READ_EXTERNAL_STORAGE`, `WRITE_EXTERNAL_STORAGE` (max SDK 28), plus the
  app-scoped dynamic-receiver permission; **no** `RECORD_AUDIO`, **no** `AD_ID`;
- AAB is JAR-signed (verified) but with the **Android Debug** certificate.

### Blocking owner action

The AAB is **debug-signed**. Play Console will reject it as a production upload.
Create an upload keystore, configure `android/app/build.gradle.kts` to use it,
rebuild, and keep the key safe. Do not reuse the debug key.

---

## 3. Verification summary

| Check | Result |
| --- | --- |
| `flutter analyze` | Clean (0 issues) |
| `flutter test` | 848 tests passed |
| `flutter build appbundle --release` | Success |
| `flutter build apk --release` | Success |
| Installed on Realme RMX1801 (Android 10) | Success |
| Label / icon / splash / Home | Verified visually |
| OCR end-to-end | Verified (69 words from a synthetic invoice) |
| Create PDF end-to-end | Verified (2-page review → name → create) |
| Searchable PDF end-to-end | Verified (1-page PDF → 562 KB searchable output) |
| Save/Share | Save path verified; share chooser opens |
| Translation output | **Not verified** — test device had no network, Hindi model could not download |
| Android 12/13/15/16 visual checks | **Not physically verified** |
| Play Console upload | **Not possible locally** |

---

## 4. Owner actions before submission

1. **Upload key** — replace debug signing; rebuild the AAB.
2. **Privacy policy URL** — fill the draft, host it over HTTPS, add it to Play.
3. **Play Console** — create the app record, complete content rating, target
   audience, Data Safety, and the store listing.
4. **Developer identity** — public developer name, support email, website.
5. **Screenshots** — review the six captures; optionally add tablet captures.
6. **Translation claim** — run English→Hindi on a connected device before making
   any quality claim.
7. **AdMob** — only if ads are wanted; otherwise leave the build ad-free.
8. **Android 15/16 check** — install on an API 35/36 device and verify
   edge-to-edge layout, splash, camera and system bars.

---

## 5. What must not be done

- Do not change `applicationId` or the package ID.
- Do not add a live/fake AdMob ID or a placeholder ad.
- Do not claim DOCX/Word export, cloud sync, handwriting OCR, or verified
  translation quality.
- Do not overwrite `assets/LOGO.png` with a different mark.
- Do not commit or push on the owner's behalf.
- Do not edit screenshots to add features or UI that is not in the build.
