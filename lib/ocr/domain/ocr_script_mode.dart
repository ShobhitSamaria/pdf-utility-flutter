import 'ocr_engine.dart';

/// The user's choice of script for a single OCR run.
///
/// This is the **user-facing** vocabulary and lives one level above
/// [OcrScript], which stays a plain, engine-agnostic list of scripts. Keeping
/// them separate is what lets the UI offer one default choice ([auto]) plus
/// explicit overrides without inventing a fake "mixed" script that no engine
/// actually implements: [OcrScript] describes a recognizer, [OcrScriptMode]
/// describes what the app does with recognizers.
///
/// [auto] is the default and the one most users should ever see. ML Kit ships
/// one recognizer per script, so something has to decide which one runs; asking
/// the user to know whether their page is "Latin" or "Devanagari" is asking them
/// to do the app's job. [auto] decides with the cheapest available evidence —
/// see `OcrScriptDetector` — and falls back to running both recognizers and
/// merging when the page is mixed or the evidence is inconclusive.
///
/// The three manual modes are **overrides**, kept because automatic detection is
/// a heuristic that can be wrong and because [mixed] is still an unmeasured
/// experiment rather than a solved feature.
///
/// Defaults to [auto]; [mixed] stays opt-in until the in-app benchmark harness
/// produces CER/WER numbers for it.
enum OcrScriptMode {
  /// Chooses the recognizer from the photo itself. The default.
  ///
  /// Costs one pass on a clearly Latin page and two on a Devanagari or mixed
  /// page — see `OcrScriptDetector` for the exact rule and its trade-offs.
  auto(
    label: 'Auto',
    description: 'Detects the script from the photo and picks the recognizer.',
  ),

  /// Printed English and other Latin-script text. The recognizer bundled with
  /// `com.google.mlkit:text-recognition`.
  latin(
    label: 'Latin / English',
    description: 'Printed English and other Latin-script text.',
  ),

  /// Printed Hindi in Devanagari. Requires the bundled
  /// `com.google.mlkit:text-recognition-devanagari` artifact.
  devanagari(
    label: 'Hindi / Devanagari',
    description: 'Printed Hindi (Devanagari) text.',
  ),

  /// Runs the Latin **and** Devanagari recognizers and merges the two results.
  ///
  /// Costs roughly twice the latency of a single pass and is not yet measured
  /// on a device, so it is labelled experimental in the UI. [auto] reaches the
  /// same two-pass path on its own when a page is genuinely mixed, which is why
  /// this stays an override rather than the default.
  mixed(
    label: 'Mixed (experimental)',
    description: 'Hindi and English on the same page. Reads the page twice.',
  );

  const OcrScriptMode({required this.label, required this.description});

  /// Short label for the selector chip.
  final String label;

  /// One-line explanation shown under the selector.
  final String description;

  /// The script a single recognizer is configured with.
  ///
  /// For [auto] this is the **probe** pass (Latin), not a commitment: the run
  /// may continue with a Devanagari pass. For [mixed] it is the first of the two
  /// fixed passes; the second is always [OcrScript.devanagari], because the
  /// Latin model cannot emit Devanagari code points while the Devanagari model
  /// is the only one that can.
  OcrScript get primaryScript => switch (this) {
    OcrScriptMode.auto => OcrScript.latin,
    OcrScriptMode.latin => OcrScript.latin,
    OcrScriptMode.devanagari => OcrScript.devanagari,
    OcrScriptMode.mixed => OcrScript.latin,
  };

  /// The script of the second pass, or `null` for single-pass modes.
  ///
  /// [auto] may or may not reach it depending on what the probe read.
  OcrScript? get secondaryScript => switch (this) {
    OcrScriptMode.auto => OcrScript.devanagari,
    OcrScriptMode.mixed => OcrScript.devanagari,
    OcrScriptMode.latin => null,
    OcrScriptMode.devanagari => null,
  };

  /// Whether this mode always reads the page twice and merges.
  bool get isMixed => this == OcrScriptMode.mixed;

  /// Whether this mode chooses a recognizer from the photo first.
  bool get isAuto => this == OcrScriptMode.auto;

  /// Whether this mode *may* perform two recognition passes.
  ///
  /// Broader than [isMixed] on purpose: it is the honest answer to "how much
  /// time does this need?", and it is what gives [auto] a two-pass time budget
  /// instead of turning a healthy Hindi page into a timeout.
  bool get mayReadTwice => isMixed || isAuto;

  /// The modes that override the automatic choice.
  static const List<OcrScriptMode> manualModes = <OcrScriptMode>[
    OcrScriptMode.latin,
    OcrScriptMode.devanagari,
    OcrScriptMode.mixed,
  ];

  /// The mode a fresh app starts in.
  static const OcrScriptMode defaultMode = OcrScriptMode.auto;
}
