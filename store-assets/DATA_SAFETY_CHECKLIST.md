# Play Console Data Safety — answer sheet

**App:** OCR PDF Studio 1.0.0 (`com.shobhit.pdfutility.pdf_utility_flutter`)
**Build assessed:** current repository build, no ads/analytics/backend.

This is a fill-in sheet, not a submitted declaration. Play Console wording can
change; match each answer to the current form, and have the owner sign off.

---

## 1. Recommended answers (current build)

### Data collection and security

| Console question | Recommended answer | Basis |
| --- | --- | --- |
| Does your app collect or share any of the required user data types? | **No** | All OCR/translation processing is on device; the app has no backend and no analytics/ad SDK. |
| Is all of the user data collected by your app encrypted in transit? | Not applicable / No data collected | No user data is transmitted by the app. Model downloads are performed by Google Play Services, not by app code. |
| Do you provide a way for users to request that their data be deleted? | Not applicable | No account and no server-side data. Users delete local data with Android's Clear storage or by uninstalling. |
| Do you have a privacy policy? | **Yes** (required) | Host `PRIVACY_POLICY_DRAFT.md` at a public HTTPS URL and paste it into the listing. |
| Is your app's data collection independently validated? | No | Not applicable. |

### Data types

Leave every category at **not collected / not shared**:

- Personal info (name, email, address, phone, race/ethnicity, political,
  religious, sexual orientation, other)
- Financial info
- Health and fitness
- Messages
- Photos and videos
- Audio
- Files and docs
- Calendar
- Contacts
- App activity (interactions, in-app search history, installed apps, other)
- Web browsing
- App info and performance (crash logs, diagnostics, other)
- Device or other IDs
- Location

### Other declarations

| Question | Answer |
| --- | --- |
| Does your app contain ads? | **No** (current build) |
| Is the app designed for children? | **No** |
| Is all functionality available without special access? | **Yes** — no login, no invite code, no waitlist |
| Does the app use encryption? | Not applicable to user data; no custom crypto |
| Target audience | 13+ or 18+ (owner choice); not Designed for Families |

---

## 2. Why "No data collected" is defensible

Play's definition of **collection** is data transmitted off the device. The app:

- reads camera/gallery/PDF input **on device**;
- runs ML Kit recognition **on device** with bundled models;
- runs ML Kit translation **on device** after a one-time model download;
- keeps recognised/translated text in memory (clipboard only on user tap);
- writes PDFs to app-private storage and, on explicit Save, to Downloads;
- has no HTTP client, no API key, no account, no analytics, no ad SDK.

The only outbound actions are:

1. **Google Play Services model download.** This is a Google-operated service
   call to fetch a language model. It does not carry document text. Google's
   handling is governed by the Google Play Services terms/privacy policy, not by
   this app's developer.
2. **User-initiated browser search.** The user selects text and taps Search;
   the app opens `google.com/search?q=…` in the default browser. The app does
   not receive or store the result. This is a user action in a third-party app,
   not app collection.

If the owner's legal review takes a more conservative view of Play Services
telemetry, the alternative is to declare **Device or other IDs → collected by
Google Play Services**, but that would be a Google SDK disclosure rather than a
developer data flow. Decide before submitting; do not submit contradictory
answers on the listing and in the policy.

---

## 3. Evidence to keep

- `aapt dump permissions build/app/outputs/flutter-apk/app-release.apk` shows no
  `AD_ID` and no `RECORD_AUDIO`.
- `pubspec.yaml` has no analytics, ads, crash-reporting or HTTP dependency.
- `PRIVACY_AUDIT.md` §4 lists every network path.
- Release manifest `android/app/src/main/AndroidManifest.xml` declares only
  camera, internet, network state, and plugin storage permissions.

---

## 4. If AdMob is added later

Adding AdMob changes the answers. At minimum, a typical banner/interstitial
integration would require declaring:

- **Device or other IDs** (advertising ID / App Set ID) — collected and shared
  for advertising;
- **App activity / other actions** — ads shown, interactions;
- possibly **approximate location** if the ad SDK derives it from IP;
- **diagnostics/performance** if SDK telemetry is enabled.

Also required:

- update "Contains ads" to **Yes**;
- add the AdMob/Google privacy-policy link and disclose ad partners;
- implement Google's UMP consent flow for EEA/UK/Swiss users before requesting
  ads;
- publish `app-ads.txt` on the developer website;
- keep ads out of the camera/OCR flow and away from action buttons;
- do not serve personalised ads to children.

See `ADMOB_INTEGRATION_PLAN.md`. Do not add AdMob and leave this sheet saying
"No" — that is a policy violation.

---

## 5. Owner sign-off

| Item | Owner | Date |
| --- | --- | --- |
| Reviewed privacy policy | | |
| Accepted Data Safety answers | | |
| Confirmed no ads/analytics in the submitted build | | |
| Confirmed release signing key is not the debug key | | |
| Confirmed target API 36 at submission time | | |
