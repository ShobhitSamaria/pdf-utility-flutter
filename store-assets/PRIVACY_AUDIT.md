# Privacy audit — OCR PDF Studio 1.0.0

**Method:** static review of `lib/**`, `android/app/src/main/**`,
`android/app/src/main/kotlin/**`, `pubspec.yaml`/`pubspec.lock`, the merged
release manifest, and the installed release APK (`aapt dump permissions`), plus
on-device behaviour on a Realme RMX1801 running Android 10.

**Scope:** the build in this repository (`versionCode` 1). It describes what the
code does today, not what a future AdMob or analytics integration might do.

---

## 1. Summary

| Question | Finding |
| --- | --- |
| Account or sign-in? | No. |
| Analytics / crash reporting? | No SDK and no code. |
| Advertising SDK? | No. No `AD_ID` permission. |
| Developer-operated backend? | No. There is no API endpoint, no upload code and no server URL. |
| OCR location | On device (bundled ML Kit text-recognition models). |
| Translation location | On device (ML Kit translation models provisioned through Google Play Services). |
| Draft text / recognised text uploaded? | No code path sends it anywhere. |
| Network use | Two paths only: ML Kit translation-model download (via Google Play Services), and the user-initiated "Search" action, which opens `google.com` in the device browser. |
| Data sold? | No. |
| Data shared with third parties? | No user content. Google Play Services handles model downloads; the system browser handles a user-requested web search. |
| Deletion | Clear app storage or uninstall. There is no account or server-side copy to delete. |

The app is therefore a **local document tool**, not a data-collecting service.

---

## 2. Data inventory

| Data | Where it comes from | Where it is processed | Where it is stored | Leaves the device? | Retention / control |
| --- | --- | --- | --- | --- | --- |
| Camera preview and still | `camera` plugin, still capture with `enableAudio: false` | Native camera + ML Kit OCR | Captured still is written to app cache/temporary storage | No | Cache-managed; removed on uninstall or app-data clear |
| Gallery photos | Android Photo Picker via `image_picker` | ML Kit OCR | Picker-provided cached copy | No | Cache-managed |
| Imported PDF | Storage Access Framework via `file_picker` | `pdfx` renders a page; ML Kit OCR reads it | Picker-provided cached copy + rendered page image in cache | No | Cache-managed; rendered page is temporary |
| Recognised text | ML Kit result | App memory; optional clipboard | **Not persisted by the app** | No, unless the user taps Copy (clipboard) or Search (browser) | Session only |
| Translated text | ML Kit translation | App memory; optional clipboard | Not persisted | No | Session only |
| Created PDF | `pdf` package | On device | App-private `<files>/shared`; a copy goes to `Downloads` only when the user taps Save | Only on explicit Save/Share | Persists until the user deletes it, clears app data, or uninstalls |
| Searchable PDF | `pdf`/`pdfx` | On device | App-private output directory; Save/Share copies it | Only on explicit Save/Share | Same as above |
| OCR script preference | User's Settings choice | In memory (`ValueNotifier`) | Not persisted across process death | No | Session only |
| Debug geometry flag | Debug builds only | In memory | None | No | Not present in release UI |
| Diagnostics / benchmark | Debug builds only | Local screen; logcat tags | No file upload | No | Debug builds only |

### Clipboard

`Clipboard.setData` is called only in response to a user tap (Copy all, Copy
translation). The clipboard is an OS service shared with other apps by design;
the app does not read it.

### Web search

`lib/ocr/data/search_launcher.dart` builds
`https://www.google.com/search?q=<selected text>` and opens it with
`LaunchMode.externalApplication`. Only text the user explicitly selected is
included. The app does not receive the response. Once the browser opens, the
browser's own privacy policy applies.

### Android Auto Backup

The manifest does not set `android:allowBackup`, so the platform default
(`true`) applies. On devices with Android backup enabled, app-private files —
including PDFs in `<files>/shared` — may be included in the user's Google Drive
backup. This is OS behaviour, not an app upload, but the privacy policy should
disclose it. If the owner wants a strict "documents never leave the device"
guarantee, set `android:allowBackup="false"` in the `<application>` tag. That
is an owner decision because it also disables restore of any app data.

---

## 3. Permissions

From the installed APK (`aapt dump permissions`):

| Permission | Declared by | Why it is present | Runtime prompt? |
| --- | --- | --- | --- |
| `CAMERA` | App + `camera_android_camerax` | Live preview and still capture for scanning | Yes, when the user opens the camera |
| `INTERNET` | App | ML Kit translation-model download through Google Play Services; user-initiated web search | No |
| `ACCESS_NETWORK_STATE` | App | ML Kit checks connectivity before/when downloading models | No |
| `READ_EXTERNAL_STORAGE` (`maxSdkVersion=32`) | `file_picker` | Legacy document picking on Android ≤ 12; the app uses SAF and the Photo Picker, so it does not request this at runtime | No |
| `WRITE_EXTERNAL_STORAGE` (`maxSdkVersion=28`) | `camera_android_camerax` | Legacy camera-plugin storage path on Android ≤ 9 | No |
| `com.shobhit…DYNAMIC_RECEIVER_NOT_EXPORTED_PERMISSION` | AndroidX/Flutter | App-scoped signature permission for non-exported dynamic receivers | No |
| `RECORD_AUDIO` | Declared by `camera_android_camerax`, then **removed** with `tools:node="remove"` | Not used: both capture screens pass `enableAudio: false` | Absent from the merged manifest and the APK |
| `AD_ID` | — | Not present | — |

`aapt dump permissions` on the current release APK confirms `RECORD_AUDIO` and
`AD_ID` are not in the final permission set.

The app declares the camera as optional
(`android.hardware.camera` / `autofocus`, `required="false"`), so it installs on
devices without a camera.

---

## 4. Network and third-party processing

### 4.1 ML Kit OCR — offline

`google_mlkit_text_recognition` is used through its **bundled** artifacts:
`com.google.mlkit:text-recognition` (Latin) and
`:text-recognition-devanagari`. The models are packaged into the APK at build
time. OCR needs no network and does not call Google.

### 4.2 ML Kit translation — on-device, model download via Play Services

`google_mlkit_translation` and `google_mlkit_language_id` run on device. The
first use of a language pair provisions the model through Google Play Services
(`RemoteModelManager`), which needs a network connection. The text being
translated is processed locally; the app does not post it to a translation API.

The download is bounded by a watchdog in `MainActivity.kt` (30 s per attempt)
and uses `DownloadConditions` without `requireWifi()`, so a cellular-only device
is not stuck waiting for Wi-Fi.

**Verified limitation:** on the test device the network was disconnected
(`Active default network: none`), so the Hindi model could not be downloaded
and translation output was not produced. The language-pair UI, model-state
handling and error path were exercised; the translated result was not. Do not
claim verified translation quality until it runs on a connected device.

### 4.3 Browser search

Only the user-initiated action described in §2. No SDK, no WebView, no
in-app network request.

### 4.4 No other endpoints

A repository-wide search found no `HttpClient`, `http`, `dio`, Firebase,
analytics, crash-reporting or ad SDK usage. `url_launcher` is the only package
that can open an external destination.

---

## 5. Storage locations

| Path | Contents | Access |
| --- | --- | --- |
| `<app>/files/shared` | Created PDFs awaiting Share/Save | App-private; shared only through `FileProvider` with a one-URI read grant |
| `<app>/cache` (or platform temp) | Picker copies, rotated page images, rendered PDF pages, intermediate files | App-private; OS may evict |
| `Downloads` (Android 10+) / app external files dir (≤ 9) | Copy written by the user's Save action | Public Downloads on 10+; app-specific external dir on ≤ 9 |
| `files/shared` and cache on app uninstall | Removed by the OS | — |

`FileProvider` is `exported="false"`; its roots are `cache`, `files` and
`external-files`. It cannot serve arbitrary files outside the app sandbox.

**Finding:** generated PDFs in `<files>/shared` are not automatically pruned.
They persist until the user clears app data/uninstalls or manually manages
storage. This is low risk (app-private) but can accumulate. A future cleanup on
startup or a "Delete all documents" control would improve hygiene.

---

## 6. Logging

- Release builds: no OCR text or user content is logged. Debug-only OCR logging
  is gated by `kDebugMode`/debug build type.
- The diagnostics channel logs model names, timings and device info to logcat;
  it does not upload anything and is not reachable from release UI.
- The OCR benchmark and translation diagnostics screens are debug-only or not
  linked from release UI.

---

## 7. Security observations

- Files are app-private by default; sharing uses a scoped `content://` URI.
- No custom crypto is implemented, because no user data is transmitted by the
  app.
- Model downloads are handled by Google Play Services over its own TLS channel.
- The release build is currently **debug-signed** (`signingConfig =
  signingConfigs.getByName("debug")`). That is a release-engineering issue, not
  a privacy one, but it must be fixed before upload.
- No certificate pinning is needed: the app has no developer API.

---

## 8. Findings and recommendations

| # | Finding | Severity | Recommendation |
| --- | --- | --- | --- |
| 1 | Translation output unverified on the test device (no network) | Medium (claim risk) | Verify English→Hindi on a connected device before claiming translation quality; keep listing copy neutral |
| 2 | Release uses the debug signing key | High (cannot upload as-is) | Owner creates an upload keystore and configures release signing |
| 3 | `android:allowBackup` defaults to true, so app-private PDFs may enter Android backup | Low–Medium | Owner decides: disclose in policy, or set `allowBackup="false"` |
| 4 | `<files>/shared` PDFs are never pruned | Low | Add startup cleanup or a delete-all control in a future release |
| 5 | `READ_EXTERNAL_STORAGE`/`WRITE_EXTERNAL_STORAGE` appear via plugins | Low | Kept because plugins declare them; they are capped by `maxSdkVersion` and are not requested at runtime. Revisit if Play asks for a storage-permission declaration |
| 6 | No in-app privacy policy link | Medium (Play requirement is a hosted URL, but in-app link is good practice) | Add a Settings link when the URL exists |
| 7 | No account/data-deletion flow | Not applicable today | If accounts or a backend are added, add deletion |

---

## 9. What this audit does not cover

- Legal sufficiency of the privacy policy; that needs owner/legal review.
- Google's own processing under the Play Services terms.
- Third-party apps that receive a file through the share sheet.
- Android 12+ splash and Android 15/16 edge-to-edge behaviour on physical
  devices (only Android 10 was available).
- Future AdMob/analytics code; adding either invalidates §1 and the Data Safety
  answers.
