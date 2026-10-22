# R8 rules for ML Kit under Flutter's release build.
#
# Why this file exists
# -------------------
# `google_mlkit_text_recognition` resolves a script index to a recognizer inside a
# single `initialize()` method and therefore references every script's options
# class, but its own `android/build.gradle` declares the non-Latin models as
# `compileOnly`. Only the scripts this app actually bundles are present when the
# app is built, so R8 reports the others as missing classes. Flutter enables R8
# for release builds (`FlutterPlugin.kt` sets `isMinifyEnabled = true`), which
# turned that latent mismatch into a hard build failure:
#
#   ERROR: R8: Missing class com.google.mlkit.vision.text.chinese.ChineseTextRecognizerOptions
#     (referenced from: ... TextRecognizer.initialize(MethodCall))
#
# The absence is intentional. `OcrScriptMode` offers Latin (bundled by
# `com.google.mlkit:text-recognition`) and Devanagari (bundled explicitly in
# `android/app/build.gradle.kts`). Chinese, Japanese and Korean are not reachable
# in the UI and their models are deliberately not packaged — roughly 4 MB per
# script per ABI for no user-visible benefit.
#
# --- The rule that makes OCR work in a release build ----------------------
#
# ML Kit is assembled at runtime by Firebase Components: `MlKitInitProvider`
# asks `MlKitComponentDiscoveryService` for the registrars listed in the
# AndroidManifest metadata and instantiates each one **reflectively** with
# `getDeclaredConstructor().newInstance()`.
#
# AGP keeps the *name* of a class named in the manifest, so every registrar was
# still present in the release dex — but with its no-arg constructor removed by
# R8, because nothing in the code calls `new CommonComponentRegistrar()`. The
# reflective instantiation therefore threw, the registrar was skipped, and
# `MlKitContext` came up with **none** of ML Kit's components. The first visible
# consequence was inside `InputImage`'s telemetry: `MlKitContext.get(
# SharedPrefManager.class)` returned null, ML Kit's own logging constructor
# dereferenced it (`NullPointerException ... Object.getClass()`), the platform
# channel surfaced `PlatformException(error, null, null)`, and the app could only
# say "Text recognition failed. Please try again." — for every image, from every
# entry point, in the release APK only.
#
# Reproduced on an Android 15 emulator with the release APK (`MethodChannel#
# google_mlkit_text_recognizer: java.lang.NullPointerException ... zzmj.<init>`),
# while the identical code passed on debug and profile builds. The dex was the
# proof: all six registrars (common, vision, text, translate, language-id,
# language-id bundled) were present without an `<init>`.
#
# This is Firebase's own documented requirement for component discovery: keep the
# registrars as a whole, constructors included. It is six tiny classes, and it
# covers OCR, translation and language identification at once — the same crash
# waits in each of them.
-keep class * implements com.google.firebase.components.ComponentRegistrar { *; }
#
# `-dontwarn` only silences the build failure. It does **not** make these classes
# available: calling the corresponding script at runtime would still fail with
# NoClassDefFoundError. If any of them is ever added to `OcrScriptMode`, its
# artifact must be added to `android/app/build.gradle.kts` in the same change,
# and these lines should be reduced to the scripts that genuinely remain absent.
# Devanagari followed exactly that path: it used to be listed here, and left this
# list when the app started supplying its model.

-dontwarn com.google.mlkit.vision.text.chinese.ChineseTextRecognizerOptions
-dontwarn com.google.mlkit.vision.text.chinese.ChineseTextRecognizerOptions$Builder
-dontwarn com.google.mlkit.vision.text.japanese.JapaneseTextRecognizerOptions
-dontwarn com.google.mlkit.vision.text.japanese.JapaneseTextRecognizerOptions$Builder
-dontwarn com.google.mlkit.vision.text.korean.KoreanTextRecognizerOptions
-dontwarn com.google.mlkit.vision.text.korean.KoreanTextRecognizerOptions$Builder

# Keep the options classes for the scripts this app DOES ship.
#
# These two are the seam between the app and ML Kit's model selection: the
# plugin's `initialize()` reads `TextRecognizerOptions.DEFAULT_OPTIONS` for Latin
# and calls `DevanagariTextRecognizerOptions.Builder().build()` for Devanagari.
# R8 is free to inline and merge them — an earlier release build reported
# `DevanagariTextRecognizerOptions$Builder -> R8$$REMOVED$$CLASS$$n` — and R8's
# rewrite of that call site is very likely sound, but "very likely" is not a
# property that can be inspected in a shipped APK.
#
# Keeping them costs a few kilobytes, leaves the script path plainly visible in
# the dex (`DevanagariTextRecognizerOptions` appears in the release APK's class
# table), and removes the possibility that a merged-away options class is the
# reason Hindi OCR fails on someone's phone. This is the cheapest of the two
# R8 rules to keep; the `ComponentRegistrar` rule above is not optional.
-keep class com.google.mlkit.vision.text.latin.TextRecognizerOptions { *; }
-keep class com.google.mlkit.vision.text.devanagari.DevanagariTextRecognizerOptions { *; }

# The inner Builder needs its own rule: `-keep class X { *; }` covers X's
# members but not the separate class X$Builder. Without this, the release build
# drops the Builder the plugin actually calls (R8 prints
# `DevanagariTextRecognizerOptions$Builder -> R8$$REMOVED$$CLASS$$n` and the
# class is absent from the shipped dex). R8 can rewrite such a call site, but
# that rewrite is not checkable here and nothing in the app depends on it, so
# the Builder is kept and the dex is the proof.
-keep class com.google.mlkit.vision.text.devanagari.DevanagariTextRecognizerOptions$Builder { *; }
