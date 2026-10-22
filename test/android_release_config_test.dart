import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Guards the Android **release** configuration that OCR depends on.
///
/// This is not a style check. The release APK shipped on 2026-10-20 failed every
/// OCR run with `Text recognition failed. Please try again.`, while the debug and
/// profile builds passed the same on-device suite. The cause was one missing
/// ProGuard rule: R8 kept ML Kit's component registrars (their names appear in
/// the manifest) but deleted their no-arg constructors, so Firebase Components'
/// reflective instantiation silently skipped every one of them, `MlKitContext`
/// had no `SharedPrefManager`, and ML Kit's own telemetry threw a
/// `NullPointerException` inside `process()`.
///
/// A unit test cannot run R8, so it cannot prove the dex is correct. What it can
/// do — cheaply, on every `flutter test` — is fail loudly if the rule that fixed
/// it is deleted or weakened, which is exactly the mistake that shipped the
/// broken build.
void main() {
  final rules = File('android/app/proguard-rules.pro');

  test('the R8 config keeps ML Kit component registrars constructible', () {
    expect(
      rules.existsSync(),
      isTrue,
      reason: 'android/app/proguard-rules.pro is what carries the fix',
    );

    final lines = rules
        .readAsLinesSync()
        .map((line) => line.trim())
        // Ignore comments: several of them quote the rule while explaining it.
        .where((line) => line.isNotEmpty && !line.startsWith('#'))
        .toList();

    final keepsRegistrars = lines.any(
      (line) =>
          line.startsWith('-keep') &&
          line.contains('implements') &&
          line.contains('com.google.firebase.components.ComponentRegistrar'),
    );
    expect(
      keepsRegistrars,
      isTrue,
      reason:
          'Without a `-keep class * implements '
          'com.google.firebase.components.ComponentRegistrar { *; }` rule, R8 '
          'removes the registrars\' constructors and every ML Kit service '
          '(OCR, translation, language ID) fails in a release build.',
    );
  });

  test('the bundled text-recognition models stay declared', () {
    final gradle = File('android/app/build.gradle.kts').readAsStringSync();

    // Latin ships with the plugin; Devanagari is supplied by the app.
    expect(
      gradle,
      contains('com.google.mlkit:text-recognition-devanagari'),
      reason: 'Hindi OCR needs the bundled Devanagari model in the APK',
    );
    // The other scripts have no UI and no model: R8 must merely not fail on
    // them. Their absence is intentional, so `-dontwarn` is the correct guard.
    expect(rules.readAsStringSync(), contains('-dontwarn'));
  });
}
