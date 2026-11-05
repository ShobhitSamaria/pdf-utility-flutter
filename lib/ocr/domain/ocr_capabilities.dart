import 'ocr_engine.dart';

/// What text recognition can actually read in **this build**.
///
/// Why this exists
/// ---------------
/// ML Kit ships one recognizer per script, as separate Gradle artifacts. This app
/// bundles exactly two — Latin (`com.google.mlkit:text-recognition`) and
/// Devanagari (`…:text-recognition-devanagari`) — because the others would add
/// tens of megabytes to every install for scripts most users never photograph.
/// [OcrScript] nevertheless lists Chinese, Japanese and Korean, because it is the
/// engine-agnostic vocabulary and an engine that bundles them can honour them.
///
/// The gap between "the enum has a value" and "this APK can run it" is exactly
/// where a product lies to its user: choosing such a script used to construct a
/// recognizer with no model behind it, and the failure surfaced as a generic
/// engine error after a delay. [isBundled] is the single honest answer, and both
/// the engine (which refuses to pretend) and the UI (which can name what it can
/// read) are built on it.
abstract final class OcrCapabilities {
  /// Scripts whose ML Kit models are packaged in this app.
  ///
  /// Keep this in step with `android/app/build.gradle.kts`: one entry per
  /// `com.google.mlkit:text-recognition-*` dependency.
  static const List<OcrScript> bundledScripts = <OcrScript>[
    OcrScript.latin,
    OcrScript.devanagari,
  ];

  /// Whether this build can run a recognizer for [script].
  static bool isBundled(OcrScript script) => bundledScripts.contains(script);

  /// Script family of each recognizer, in the same vocabulary as
  /// `LanguageScript.groupOf` (`'latin'`, `'devanagari'`, …) so a language can be
  /// matched to a recognizer without either layer knowing the other's types.
  static const Map<OcrScript, String> _familyOf = <OcrScript, String>{
    OcrScript.latin: 'latin',
    OcrScript.devanagari: 'devanagari',
    OcrScript.chinese: 'han',
    OcrScript.japanese: 'kana',
    OcrScript.korean: 'hangul',
  };

  /// The script family [script] recognises, or `null` when it is not mapped.
  static String? familyOf(OcrScript script) => _familyOf[script];

  /// Whether a page written in [family] (see `LanguageScript.groupOf`) can be
  /// read from a photograph by this build.
  ///
  /// `'han'` counts for Chinese only: a Japanese page needs kana, which the same
  /// model reads, but that model is not bundled — so both answer `false` here
  /// until their artifacts are added.
  static bool canReadFamily(String family) {
    for (final script in bundledScripts) {
      final bundled = _familyOf[script];
      if (bundled == family) return true;
    }
    return false;
  }

  /// Human-readable name of [script], for messages and the empty-result state.
  static String labelOf(OcrScript script) => switch (script) {
    OcrScript.latin => 'Latin',
    OcrScript.devanagari => 'Devanagari (Hindi, Marathi)',
    OcrScript.chinese => 'Chinese',
    OcrScript.japanese => 'Japanese',
    OcrScript.korean => 'Korean',
  };

  /// The bundled scripts as a sentence fragment: `"Latin and Devanagari"`.
  static String get bundledLabel {
    final labels = <String>[
      for (final script in bundledScripts) labelOf(script),
    ];
    if (labels.length <= 1) return labels.join();
    return '${labels.sublist(0, labels.length - 1).join(', ')} and ${labels.last}';
  }

  /// The message shown when a recognizer outside [bundledScripts] is requested.
  static String unavailableMessage(OcrScript script) =>
      '${labelOf(script)} text recognition is not included in this build. '
      'It can read $bundledLabel text from a photo.';
}
