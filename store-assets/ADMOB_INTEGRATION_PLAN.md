# AdMob integration plan — OCR PDF Studio

**Current status: AdMob is NOT integrated.**

- No AdMob SDK in `pubspec.yaml`.
- No `com.google.android.gms.ads.APPLICATION_ID` in the manifest.
- No app ID, ad unit ID, publisher ID, or account exists in this repository.
- The listing copy and Data Safety answers currently say **no ads**.
- No placeholder or fake ad units are present, and none should be added. A
  release build with fake IDs can be flagged for invalid traffic or simply show
  nothing.

This document is the implementation plan for when the owner has a real AdMob
account. It is deliberately not wired into the app today.

---

## 1. Decide first: should v1 have ads?

Recommendation for the first release: **ship without ads.** Reasons:

1. The product promise is "on-device, no account, private". A banner is a
   visible contradiction unless the policy copy is updated carefully.
2. OCR/scanning apps are task apps: users open them for a few seconds, so a
   banner earns little and an interstitial interrupts the exact moment the user
   is trying to finish a document.
3. AdMob requires consent infrastructure (EEA/UK/Swiss), Data Safety changes,
   `app-ads.txt`, and ongoing policy maintenance. That is a release blocker if
   done badly.

If monetisation is required, use the **minimum** surface described in §3, not a
full ad mesh.

---

## 2. Policy constraints that shape the design

These are the constraints that matter for this app; check the current AdMob
program policies before implementation.

- **No ads on splash, loading, exit, or camera permission screens.** Do not
  show an interstitial while the app launches or while the camera is starting.
- **No ads that cover content or navigation**, and no ad disguised as a button.
  Keep banners outside tap targets with clear spacing.
- **Interstitials only at natural breaks**, with a visible close control. Do not
  show one after every tap; do not chain them.
- **No incentivised clicks.** Rewarded ads must be explicitly opt-in and clearly
  labelled.
- **Consent before personalised ads** where required (EEA/UK/Switzerland under
  GDPR; US state privacy laws). Use Google's UMP SDK and do not request ads
  before the consent result is known.
- **Children:** if the app is ever listed for children or in Designed for
  Families, use families-compliant ads only, no personalised ads, and update
  the content rating. Current plan: not a children's app.
- **Invalid traffic:** never tap or automate ads during testing. Use Google's
  published test ad units and register test devices.
- **Data Safety:** adding the SDK changes the declaration. See §7.
- **`app-ads.txt`:** required for the developer website associated with the
  AdMob account.

---

## 3. Recommended placement (if ads are approved)

| Screen | Placement | Why |
| --- | --- | --- |
| Home | One anchored adaptive banner at the bottom, below the two action cards, inside the scroll view | The only non-task surface; never overlaps a button |
| Settings | None | Low value; avoid clutter |
| Camera / scan / reading | **None** | Task-critical; policy and UX risk |
| OCR result / translation | **None** | User is reading/working; an ad would cover content |
| PDF review / create / share | **None** | The user is completing a document |
| Success screen | **None in v1** | Tempting interstitial, but it interrupts the hand-off. Revisit only with data and a compliant frequency cap |

Do **not** use a banner in the camera preview area, and do not place an ad
between the shutter button and the page.

If an interstitial is ever tested, the only defensible break is **after** a PDF
has been successfully saved/shared and the user has dismissed the success sheet
— never during OCR, never on launch, never twice in a row. Keep a frequency cap
in app config, not in your head.

---

## 4. Implementation steps (owner-approved, real IDs only)

### 4.1 Account and assets

1. Create/verify an AdMob account.
2. Link the Play app (`com.shobhit.pdfutility.pdf_utility_flutter`).
3. Create one **Android banner** ad unit for Home.
4. Record the **App ID** (`ca-app-pub-…~…`) and **ad unit ID**
   (`ca-app-pub-…/…`). Do not commit them to a public repository if the owner
   treats them as configuration; inject at build time.
5. Publish `app-ads.txt` at the root of the developer website with the
   publisher ID.

### 4.2 Dependency and manifest

1. Add the current stable `google_mobile_ads` package. Pin the version; do not
   use `any`.
2. Add to `android/app/src/main/AndroidManifest.xml` inside `<application>`:

```xml
<meta-data
    android:name="com.google.android.gms.ads.APPLICATION_ID"
    android:value="${ADMOB_APP_ID}" />
```

Use a manifest placeholder fed from `local.properties`/CI, not a literal in the
repository. Add the placeholder to `android/app/build.gradle.kts`.

3. Keep `INTERNET` and `ACCESS_NETWORK_STATE`; they already exist.
4. Confirm the merged manifest still has no `AD_ID` permission unless the SDK
   adds it and the owner has declared advertising.

### 4.3 Initialisation and consent

Order matters:

1. Read the consent status with the UMP SDK.
2. Show the consent form if required.
3. Only after consent is resolved, call `MobileAds.instance.initialize()`.
4. Load the banner.
5. If consent is unavailable/refused, request **non-personalised** ads where
   the policy allows, or show no ad.

Do not initialise the SDK in `main()` before the first frame; keep the Home
screen usable even if ads fail.

### 4.4 Configuration that fails closed

Use compile-time configuration with an empty default:

```dart
const bannerId = String.fromEnvironment('ADMOB_BANNER_ID');
const appId = String.fromEnvironment('ADMOB_APP_ID');
```

If `bannerId` is empty, render **no ad widget at all**. This prevents a release
build with missing config from showing a broken/placeholder ad. Never fall back
to a test ID in release.

Build command for the owner's machine/CI:

```bash
flutter build appbundle --release \
  --dart-define=ADMOB_APP_ID=ca-app-pub-…~… \
  --dart-define=ADMOB_BANNER_ID=ca-app-pub-…/…
```

The manifest placeholder also needs the app ID; pass it through Gradle
properties or CI, not a committed literal.

### 4.5 Test ads only in debug

- Use Google's **published test ad units** for debug builds only.
- Register the physical test device.
- Never install a release build with live IDs and tap ads.
- Do not ship a debug flag that can switch a release build to test IDs; test
  IDs should be selected by build type, not by a user-visible setting.

### 4.6 Failure behaviour

The app must behave exactly as it does today when:

- there is no network;
- the ad request fails;
- the SDK is not initialised;
- consent is refused;
- the ad unit is misconfigured.

No blocking dialogs, no retry loops that prevent scanning, no layout jump that
moves the primary action.

---

## 5. UX and layout acceptance criteria

- Banner height is reserved before the ad loads, so the Home cards do not jump.
- The banner never covers the Settings button, OCR Scanner card, Create PDF
  card, or a system bar.
- The banner is outside the camera/OCR/PDF flows entirely.
- Tapping an ad opens the browser/Play Store, not an in-app hidden action.
- Screen-reader order remains logical; the ad is labelled by the SDK.
- In dark mode the app is light-only, so no ad contrast theming is needed.

---

## 6. Testing checklist

- [ ] Debug build with Google test banner renders and can be dismissed.
- [ ] Release build with real IDs renders a banner (owner device, not tapped).
- [ ] Airplane mode: app still scans, creates PDFs and opens; no crash.
- [ ] Consent form appears for an EEA test account and can be accepted/refused.
- [ ] Refusing personalised ads does not break the app.
- [ ] Rotating/resizing does not overlap the banner.
- [ ] Home scroll reaches both cards with the banner present.
- [ ] No ad appears on camera, result, translation, review, or success screens.
- [ ] `aapt dump permissions` shows only expected permissions.
- [ ] Play Console "Contains ads" is set to Yes before review.

---

## 7. Store, privacy and Data Safety changes

Before submitting an ad-enabled build:

1. Change the listing "Contains ads" to **Yes**.
2. Update the full description: remove "no advertising in this version" and add
   a short ad disclosure.
3. Update the privacy policy:
   - advertising ID / App Set ID;
   - ad partners (Google AdMob);
   - consent and opt-out;
   - data retention by the ad SDK;
   - link to Google's partner sites policy.
4. Update Data Safety:
   - Device or other IDs — collected/shared for advertising;
   - App activity — ads/interactions as applicable;
   - approximate location if derived from IP;
   - diagnostics if SDK telemetry is enabled.
5. Add the UMP consent flow and document it.
6. Publish `app-ads.txt`.
7. Re-run the privacy audit and keep the evidence with the release.
8. Consider adding an in-app "Privacy settings" entry to re-open the consent
   form.

---

## 8. What is explicitly out of scope

- No ad IDs are invented here.
- No placeholder banner, test banner, or hidden ad widget is added to the app.
- No mediation, native ads, rewarded ads, app-open ads, or interstitials in v1.
- No behavioural targeting or audience lists.
- No ads for children.

---

## 9. Owner decisions

| Decision | Needed before |
| --- | --- |
| Ads in v1 at all? | Any SDK work |
| AdMob account and linked app | Ad unit creation |
| App ID + banner unit ID | Manifest/config |
| Consent message and privacy-policy URL | EEA/UK launch |
| `app-ads.txt` domain | AdMob verification |
| Data Safety/listing update approval | Submission |
| Test device registration | Testing |
