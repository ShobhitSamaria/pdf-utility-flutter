# Privacy Policy — OCR PDF Studio (DRAFT)

> **Draft, not legal advice.** Fill every `[BRACKETED]` field, have the owner or
> counsel review it, host it at a public HTTPS URL, and link that URL in the Play
> Console. This draft describes the current build (`1.0.0+1`) with no ads, no
> analytics and no developer server. If AdMob, analytics, a backend or accounts
> are added, this policy must be updated before that build is published.

**Effective date:** `[EFFECTIVE DATE]`
**Last updated:** `[LAST UPDATED]`

`[DEVELOPER LEGAL NAME]` ("we", "us", "our") provides **OCR PDF Studio**
("the app"). This policy explains what the app does with information when you
install and use it.

**Contact:** `[SUPPORT EMAIL]`
**Postal address (if required):** `[ADDRESS]`

---

## 1. The short version

- OCR and translation run **on your device**.
- The app has **no account, no sign-up, no analytics, no advertising and no
  crash-reporting SDK** in this version.
- We do **not** operate a server that receives your photos, PDFs, recognised
  text or translations.
- Your documents stay in the app's private storage until you choose to copy,
  save or share them.
- The first time you translate a language, Google Play Services downloads a
  language model (about 30 MB) over the internet. The text you translate is
  processed on the device, not sent to us.
- If you tap **Search**, the app opens your browser with the selected text as a
  Google search. That is a request to Google, made by you, in your browser.

---

## 2. Information the app processes

### 2.1 Camera and photos

With your permission, the app uses the camera to capture a page, or lets you
choose photos through Android's system photo picker. These images are used to
recognise text. They are processed on the device and stored in the app's
private cache/temporary storage. We do not receive them.

You can use the app without the camera by choosing photos or importing a PDF.

### 2.2 PDFs you import

You can pick a PDF through Android's system document picker. The app reads and
renders the page on the device so it can recognise text or make the PDF
searchable. The file is not uploaded to us.

### 2.3 Recognised and translated text

Text produced by OCR and translation is held in the app's memory for the
current session. The app does not save it to a database or send it to us.

- **Copy** places the text on the Android clipboard. Other apps may read the
  clipboard according to Android's rules and their own privacy practices.
- **Search** opens your default browser with the selected text as a Google
  search query. Google and your browser handle that request under their own
  policies. The app does not receive the search results.
- **Share** opens Android's share sheet and sends the file or text to the app
  you choose. That app's privacy policy then applies.

### 2.4 PDFs you create or convert

Created PDFs and searchable PDFs are written to the app's private storage. If
you tap **Save**, a copy is written to your device's Downloads folder (or the
app's external files directory on Android 9 and older). If you tap **Share**,
the file is handed to the app you select.

We do not receive these files. Files in Downloads remain until you delete them.
App-private files remain until you clear the app's storage or uninstall it.

### 2.5 Settings

Your OCR script choice and debug display option are kept in memory for the
session. They are not sent anywhere. The current build does not persist them
across a restart.

### 2.6 Device and diagnostic information

The app can display model/device diagnostics in debug builds. Those screens do
not upload anything. Release builds do not include the debug-only developer
tools.

We do not collect device identifiers, advertising IDs, location, contacts,
calendar data, messages, health data, or app-usage analytics.

---

## 3. Permissions and why they are used

| Permission | Purpose |
| --- | --- |
| Camera | Scan a page. Optional; gallery and PDF input work without it. |
| Internet | Download translation models through Google Play Services; open a web search only when you tap Search. |
| Network state | Let ML Kit check connectivity before a model download. |
| Read/write external storage (legacy Android only, capped by OS version) | Declared by the camera/document-picker libraries on older Android versions. The app uses Android's system pickers and MediaStore and does not request broad storage access at runtime. |
| Microphone | **Not used and removed from the app.** The camera library normally declares it; this app removes it because it only captures still images. |

You can revoke camera permission in Android Settings. The app will then offer
gallery/PDF input instead.

---

## 4. On-device processing and Google ML Kit

Text recognition and translation use **Google ML Kit** running on the device.
The recognition models for Latin and Devanagari are bundled with the app and do
not need a download. Translation models are provisioned through **Google Play
Services** the first time you use a language; this requires an internet
connection and availability of the model from Google.

Google's handling of Play Services and ML Kit is governed by Google's terms and
privacy policy:

- Google Privacy Policy: https://policies.google.com/privacy
- ML Kit terms: https://developers.google.com/ml-kit/terms

We do not control Google's processing. If Google Play Services is unavailable
on a device, OCR and PDF features still work, but translation models cannot be
downloaded.

---

## 5. Sharing and disclosure

We do not sell your information. We do not share your photos, PDFs, recognised
text or translations with third parties, because we do not receive them.

The app can disclose information only when **you** initiate it:

- the system share sheet (to the app you pick);
- Save to Downloads (a file on your device);
- Search (a query to Google in your browser);
- the Android clipboard (when you tap Copy).

We may disclose information if required by law, but we hold no server-side
user data to disclose.

---

## 6. Retention and deletion

- **App-private files** (created PDFs, cache, rendered pages): kept until you
  clear the app's storage or uninstall the app. Android may evict cache files
  earlier.
- **Downloads copies**: kept until you delete them with Files or another file
  manager.
- **Clipboard**: controlled by Android and other apps; clear it from the
  keyboard/clipboard UI if you need to.
- **No account**: there is no account or server-side profile to delete.

To remove local data: Android Settings → Apps → OCR PDF Studio → Storage →
Clear storage, or uninstall the app. This does not delete copies you saved to
Downloads or shared with another app; delete those separately.

**Android backup:** if you have Android backup enabled, the operating system
may include app-private files in your Google Drive backup. This is controlled
by your Android/Google account settings, not by us. Disable backup for this app
in Android Settings if you do not want that.

---

## 7. Security

We design the app to keep documents local:

- files are stored in the app's private sandbox;
- sharing uses a scoped `content://` URI with a temporary read grant, not a
  public file path;
- the app does not transmit document content to a developer server;
- model downloads are performed by Google Play Services over its own connection.

No method of storage or transmission is completely secure. You are responsible
for the device lock, OS updates, and the apps you choose to share files with.

---

## 8. Children

The app is a general productivity tool and is not directed to children under
13 (or the applicable age in your country). We do not knowingly collect
personal information from children. Because the app has no account and no
developer server, there is no child profile to delete. If you believe a child
has provided information to us, contact us and we will address it.

---

## 9. International users

The app itself does not transfer your documents internationally. Google Play
Services model downloads and Google Search are operated by Google and may
involve processing in other countries under Google's policies. If you are in
the EEA, UK or Switzerland, you have rights under applicable data-protection
law; because we do not hold your personal data, most requests will be handled
by clearing local data or by contacting Google for Google-controlled
processing.

---

## 10. Your choices

- Use gallery/PDF input instead of the camera.
- Revoke camera permission in Android Settings.
- Copy text only when you choose; avoid Copy if you do not want it on the
  clipboard.
- Avoid Search if you do not want the selected text sent to Google.
- Clear app storage or uninstall to remove app-private files.
- Disable Android backup for the app.
- Delete saved copies from Downloads.

---

## 11. Changes to this policy

We may update this policy when the app changes (for example, if ads, analytics,
accounts or a backend are added). The "Last updated" date will change, and the
new policy will be posted at the same URL. Material changes will be reflected
in the Play listing and, where required, in-app.

---

## 12. Contact

Questions about this policy or the app's privacy practices:

`[DEVELOPER LEGAL NAME]`
`[SUPPORT EMAIL]`
`[ADDRESS, if required]`

---

### Appendix A — statements that must stay true

If any of these become false, update this policy **before** shipping the change:

- no account or sign-in;
- no developer-operated server receiving user documents;
- no analytics, crash-reporting or advertising SDK;
- OCR and translation run on device;
- no sale of user data;
- no collection of location, contacts, calendar, messages or health data.

### Appendix B — pre-publication checklist

- [ ] Replace every bracketed placeholder.
- [ ] Confirm the legal entity and contact email.
- [ ] Host at a stable HTTPS URL (no redirects to a PDF, no login).
- [ ] Link the URL in Play Console and, ideally, in Settings.
- [ ] Re-read §4 if Google ML Kit or Play Services terms change.
- [ ] Re-read §2.4 if Save/Share behaviour changes.
- [ ] Re-read §6 if backup or cleanup behaviour changes.
- [ ] Have counsel review if the app is offered in regulated markets.
