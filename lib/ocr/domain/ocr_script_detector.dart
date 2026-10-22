import 'dart:math' as math;

import 'ocr_line.dart';
import 'ocr_result.dart';

/// What a single recognition pass looks like, script-wise.
///
/// Produced by [OcrScriptDetector.assess] from the **text a recognizer
/// returned**, never from the image pixels. See the class doc for why.
enum ScriptVerdict {
  /// Solid, letter-dominated Latin text. A Latin page, read correctly.
  latin,

  /// Real Devanagari letters or marks are present. Only the Devanagari model
  /// can emit those, so their presence is direct evidence about which model
  /// read the region.
  devanagari,

  /// Something came back, but it is not coherent prose in either script: too few
  /// letters, or too many stray symbols. This is the signature of a model
  /// reading a script it was not trained for.
  weak,

  /// Nothing usable came back at all.
  empty,
}

/// Counts behind a [ScriptVerdict]. Kept as data rather than a bare enum so the
/// decision can be inspected, logged and asserted on in tests.
class ScriptAssessment {
  const ScriptAssessment({
    required this.verdict,
    required this.latinLetters,
    required this.devanagariLetters,
    required this.digits,
    required this.otherSymbols,
    required this.wordsWithLetters,
    required this.verticalCoverage,
    required this.weakLineRatio,
  });

  final ScriptVerdict verdict;

  /// ASCII `[A-Za-z]` count.
  final int latinLetters;

  /// Devanagari letters, matras and the virama. **Deliberately excludes** the
  /// danda/double-danda (`।` `॥`) and the abhasa sign, which are punctuation and
  /// would let a single stray mark masquerade as a Hindi page.
  final int devanagariLetters;

  /// Digits, ASCII or Devanagari.
  final int digits;

  /// Everything else that is not whitespace: punctuation, boxes, control glyphs.
  final int otherSymbols;

  /// Whitespace-separated tokens containing at least one letter.
  final int wordsWithLetters;

  /// Share of the image's height that the recognized lines span, in `[0, 1]`.
  ///
  /// This is the signal that catches a page a model only *partly* read: a Hindi
  /// document with an English heading can leave the Latin recognizer reading one
  /// clean line at the top of an otherwise unread page, where every text-based
  /// ratio looks perfect. Text that explains 70 % of the page's height is a
  /// different claim from text that explains 5 % of it.
  final double verticalCoverage;

  /// Share of recognized lines that, judged alone, are [ScriptVerdict.weak].
  ///
  /// The complement of [verticalCoverage]: this catches a page that was read
  /// *everywhere* but badly in places — a mixed page whose Hindi lines came back
  /// from the Latin model as symbol soup.
  final double weakLineRatio;

  /// Non-whitespace characters considered.
  int get usableCharacters =>
      latinLetters + devanagariLetters + digits + otherSymbols;

  /// Letters of either script. Used to compare two passes for "which read more".
  int get letters => latinLetters + devanagariLetters;

  /// Whether this pass produced **any** letters at all.
  ///
  /// This is the gate for merging, and it is deliberately weaker than a
  /// [ScriptVerdict] check. A `weak` pass is ambiguous: it covers both symbol
  /// soup (no letters, nothing worth keeping) and a short but perfectly real
  /// line — an English heading on an otherwise Hindi page. Merging the first
  /// would inject junk lines into the result; discarding the second would throw
  /// away text the Devanagari model cannot see. Letters are the difference.
  bool get hasAnyLetters => letters > 0;

  /// Share of usable characters that are letters, in `[0, 1]`.
  double get letterRatio =>
      usableCharacters == 0 ? 0 : letters / usableCharacters;

  /// Share of usable characters that are stray symbols, in `[0, 1]`.
  double get symbolRatio =>
      usableCharacters == 0 ? 0 : otherSymbols / usableCharacters;

  @override
  String toString() =>
      'ScriptAssessment($verdict, latin: $latinLetters, '
      'devanagari: $devanagariLetters, digits: $digits, '
      'symbols: $otherSymbols, words: $wordsWithLetters, '
      'coverage: ${verticalCoverage.toStringAsFixed(2)}, '
      'weakLines: ${weakLineRatio.toStringAsFixed(2)})';
}

/// What an Auto run should return once both passes are known.
enum AutoScriptOutcome {
  /// The first (Latin) pass read the page; nothing else is needed.
  useProbe,

  /// The second (Devanagari) pass is the real answer. The Latin probe produced
  /// nothing usable, so there is nothing worth merging.
  useSecondary,

  /// Both passes found real text. The page is genuinely mixed, so the two
  /// readings are merged region-by-region.
  merge,
}

/// The outcome plus a short, human-readable reason.
///
/// The reason is recorded rather than discarded so the routing decision can be
/// asserted on directly in tests, and so a future diagnostics surface can show
/// *why* a recognizer was chosen. The user-facing summary already names the
/// chosen route through `OcrResult.engineName`.
class AutoScriptDecision {
  const AutoScriptDecision(this.outcome, this.reason);

  final AutoScriptOutcome outcome;
  final String reason;

  @override
  String toString() => 'AutoScriptDecision($outcome: $reason)';
}

/// Decides which recognizer a photo needs, from the cheapest available evidence.
///
/// Why this is text-based and not image-based
/// ------------------------------------------
/// ML Kit has **no image-level script detector**. Its Language Identification
/// API classifies a *string* (`LanguageIdentifier.identifyLanguage(text)`), not a
/// bitmap, so it cannot be pointed at a photo — assuming otherwise is the
/// classic mistake here. The only way to learn which script a photo contains is
/// to recognise it, so Auto uses the **Latin recognizer as a probe**: it is the
/// cheaper model, it is already bundled, and on a Latin page it is the answer
/// itself rather than wasted work.
///
/// The signal
/// ----------
/// A recognizer pointed at a script it was not trained for does not fail
/// loudly — it returns *something*, typically short, letter-poor and
/// symbol-heavy. So a probe is trusted only when **all** of these hold:
///
/// * [minLatinLetters] — enough Latin letters to be text rather than noise;
/// * [minLetterRatio] — letters dominate the non-whitespace characters;
/// * [minLatinWords] — enough real words to be prose;
/// * [maxSymbolRatio] — few stray symbols;
/// * [minVerticalCoverage] — the read explains a real part of the page; and
/// * [maxWeakLineRatio] — the read is not mostly made of lines that, judged
///   alone, look like garbage.
///
/// The last two exist because the first four are *ratios over whatever came
/// back* and cannot see text that never came back at all: a Hindi page whose
/// English heading was read cleanly looks perfect on every ratio while 90 % of
/// the page is unread. Coverage and weak-line share are what notice that.
///
/// What this does **not** do
/// -------------------------
/// This is a heuristic, not a classifier, and it can be wrong in both
/// directions. A Hindi page whose Latin probe hallucinates a long,
/// plausible-looking English paragraph across the page can still be accepted as
/// Latin. Conversely a genuinely short English snippet — one sign, one line —
/// fails the coverage floor and pays for a second pass. That is why Auto is
/// never the only option: the manual Latin/Devanagari/Mixed overrides stay
/// available, and the empty-result state re-offers them.
///
/// Cost model
/// ----------
/// * confident Latin page → **1 pass** (identical to the old default).
/// * Devanagari, mixed, partly-read or unreadable page → **2 passes**, the
///   first of which was a wasted probe.
///
/// A false positive only ever costs **time**, never accuracy: when the second
/// pass finds nothing useful, [resolve] falls back to the richer of the two
/// readings, and the probe wins ties.
class OcrScriptDetector {
  const OcrScriptDetector({
    this.minLatinLetters = 12,
    this.minLetterRatio = 0.6,
    this.minLatinWords = 3,
    this.maxSymbolRatio = 0.25,
    this.minDevanagariLetters = 2,
    this.minVerticalCoverage = 0.3,
    this.maxWeakLineRatio = 0.5,
  });

  /// Latin letters required before a probe may be trusted as a Latin page.
  final int minLatinLetters;

  /// Share of usable characters that must be letters for a trusted Latin read.
  final double minLetterRatio;

  /// Real words required, so a handful of letters is not mistaken for prose.
  final int minLatinWords;

  /// Share of stray symbols above which a read is treated as garbage.
  final double maxSymbolRatio;

  /// Devanagari letters/marks required to call a page Devanagari.
  final int minDevanagariLetters;

  /// Share of the image height the read must span to be trusted as the whole
  /// page's script.
  final double minVerticalCoverage;

  /// Share of recognized lines allowed to look like garbage before the page is
  /// treated as partly unread.
  final double maxWeakLineRatio;

  /// Measures the text in [result].
  ScriptAssessment assess(OcrResult result) {
    final counts = _countText(_textOf(result));

    final lines = [
      for (final line in result.lines)
        if (line.text.trim().isNotEmpty) line,
    ];

    var weakLines = 0;
    for (final line in lines) {
      if (_verdictForText(line.text) == ScriptVerdict.weak) weakLines++;
    }

    return ScriptAssessment(
      verdict: _verdictForCounts(counts),
      latinLetters: counts.latinLetters,
      devanagariLetters: counts.devanagariLetters,
      digits: counts.digits,
      otherSymbols: counts.otherSymbols,
      wordsWithLetters: counts.wordsWithLetters,
      // No structured lines means the result cannot be judged *per line*, which
      // is itself a reason not to trust the probe on its own.
      weakLineRatio: lines.isEmpty ? 1 : weakLines / lines.length,
      verticalCoverage: _verticalCoverage(lines, result.sourceImage.height),
    );
  }

  /// Whether the probe alone settles the question.
  ///
  /// Only a confident **and page-covering** Latin read does: it is both the
  /// answer *and* the cheapest possible outcome, so a well-read English page
  /// never pays for a second pass.
  bool probeIsDecisive(ScriptAssessment probe) =>
      probe.verdict == ScriptVerdict.latin &&
      probe.verticalCoverage >= minVerticalCoverage &&
      probe.weakLineRatio <= maxWeakLineRatio;

  /// Chooses between the two passes once both have run.
  ///
  /// Ordering matters and is deliberate:
  ///
  /// 1. Devanagari found **and** the probe produced letters →
  ///    [AutoScriptOutcome.merge]. A page with real text from both models is a
  ///    genuinely mixed page; the merge keeps the Devanagari lines that the
  ///    Latin pass mis-read and the Latin lines the Devanagari pass did not read
  ///    at all. Junk the Latin pass emitted *over* Hindi text is dropped by
  ///    `OcrMergePolicy`, which prefers the Devanagari line for a region.
  /// 2. Devanagari found, probe letterless → [AutoScriptOutcome.useSecondary].
  ///    Symbol soup carries nothing worth merging, and merging it would only add
  ///    junk lines and the "two passes" label to a single-script page.
  /// 3. Otherwise pick whichever pass produced more letters, with the probe
  ///    winning ties so a Latin page can never lose to a worse Devanagari read.
  AutoScriptDecision resolve({
    required ScriptAssessment probe,
    required ScriptAssessment secondary,
  }) {
    final secondaryIsDevanagari = secondary.verdict == ScriptVerdict.devanagari;

    if (secondaryIsDevanagari && probe.hasAnyLetters) {
      return AutoScriptDecision(
        AutoScriptOutcome.merge,
        'both scripts were found on the page '
        '(probe read ${probe.letters} letters over '
        '${(probe.verticalCoverage * 100).round()}% of the page)',
      );
    }

    if (secondaryIsDevanagari) {
      return const AutoScriptDecision(
        AutoScriptOutcome.useSecondary,
        'the Latin pass produced no letters, so there is nothing to merge',
      );
    }

    if (secondary.letters > probe.letters) {
      return AutoScriptDecision(
        AutoScriptOutcome.useSecondary,
        'the Devanagari pass read more text (${secondary.letters} vs '
        '${probe.letters} letters)',
      );
    }

    return AutoScriptDecision(
      AutoScriptOutcome.useProbe,
      probe.verdict == ScriptVerdict.empty
          ? 'nothing readable came back'
          : 'the Latin pass read more text (${probe.letters} vs '
                '${secondary.letters} letters)',
    );
  }

  // --- counting -------------------------------------------------------------

  ScriptVerdict _verdictForText(String text) =>
      _verdictForCounts(_countText(text));

  ScriptVerdict _verdictForCounts(_TextCounts counts) {
    final usable =
        counts.latinLetters +
        counts.devanagariLetters +
        counts.digits +
        counts.otherSymbols;
    if (usable == 0) return ScriptVerdict.empty;

    if (counts.devanagariLetters >= minDevanagariLetters) {
      return ScriptVerdict.devanagari;
    }

    final letters = counts.latinLetters + counts.devanagariLetters;
    final letterRatio = letters / usable;
    final symbolRatio = counts.otherSymbols / usable;

    if (counts.latinLetters >= minLatinLetters &&
        letterRatio >= minLetterRatio &&
        counts.wordsWithLetters >= minLatinWords &&
        symbolRatio <= maxSymbolRatio) {
      return ScriptVerdict.latin;
    }

    return ScriptVerdict.weak;
  }

  static _TextCounts _countText(String text) {
    var latinLetters = 0;
    var devanagariLetters = 0;
    var digits = 0;
    var otherSymbols = 0;

    for (final rune in text.runes) {
      if (_isWhitespace(rune)) continue;
      if (rune >= 0x0966 && rune <= 0x096F) {
        digits++;
      } else if (_isDevanagariLetterOrMark(rune)) {
        devanagariLetters++;
      } else if (_isAsciiLetter(rune)) {
        latinLetters++;
      } else if (rune >= 0x30 && rune <= 0x39) {
        digits++;
      } else {
        otherSymbols++;
      }
    }

    return _TextCounts(
      latinLetters: latinLetters,
      devanagariLetters: devanagariLetters,
      digits: digits,
      otherSymbols: otherSymbols,
      wordsWithLetters: _wordsWithLetters(text),
    );
  }

  /// Share of the image's height spanned by [lines]. `0` when there is nothing
  /// measurable, never `1`.
  static double _verticalCoverage(List<OcrLine> lines, int imageHeight) {
    if (lines.isEmpty || imageHeight <= 0) return 0;
    double? top;
    double? bottom;
    for (final line in lines) {
      final box = line.boundingBox;
      if (box.isEmpty) continue;
      top = top == null ? box.top : math.min(top, box.top);
      bottom = bottom == null ? box.bottom : math.max(bottom, box.bottom);
    }
    if (top == null || bottom == null) return 0;
    return ((bottom - top) / imageHeight).clamp(0.0, 1.0);
  }

  /// The text to measure: the engine's flat output when it has one, otherwise
  /// the lines joined, so a result whose `fullText` is empty is never scored as
  /// empty by accident.
  static String _textOf(OcrResult result) {
    if (result.fullText.trim().isNotEmpty) return result.fullText;
    return [for (final line in result.lines) line.text].join(' ');
  }

  static int _wordsWithLetters(String text) {
    var count = 0;
    var currentHasLetter = false;
    for (final rune in text.runes) {
      if (_isWhitespace(rune)) {
        if (currentHasLetter) count++;
        currentHasLetter = false;
        continue;
      }
      if (_isAsciiLetter(rune) ||
          _isDevanagariLetterOrMark(rune) ||
          (rune >= 0x0966 && rune <= 0x096F)) {
        currentHasLetter = true;
      }
    }
    if (currentHasLetter) count++;
    return count;
  }

  static bool _isWhitespace(int rune) =>
      rune == 0x20 ||
      rune == 0x09 ||
      rune == 0x0A ||
      rune == 0x0D ||
      rune == 0xA0 ||
      rune == 0x2028 ||
      rune == 0x2029;

  static bool _isAsciiLetter(int rune) =>
      (rune >= 0x41 && rune <= 0x5A) || (rune >= 0x61 && rune <= 0x7A);

  /// Devanagari letters, matras and virama, plus Devanagari Extended.
  ///
  /// `U+0964`/`U+0965` (danda, double danda) and `U+0970` (abhasa) are excluded
  /// on purpose — they are punctuation and appear in Latin-adjacent contexts.
  /// `U+0966`–`U+096F` (digits) are excluded here and counted as digits instead.
  static bool _isDevanagariLetterOrMark(int rune) =>
      (rune >= 0x0900 && rune <= 0x0963) ||
      (rune >= 0x0971 && rune <= 0x097F) ||
      (rune >= 0xA8E0 && rune <= 0xA8FF);
}

/// Internal character tally.
class _TextCounts {
  const _TextCounts({
    required this.latinLetters,
    required this.devanagariLetters,
    required this.digits,
    required this.otherSymbols,
    required this.wordsWithLetters,
  });

  final int latinLetters;
  final int devanagariLetters;
  final int digits;
  final int otherSymbols;
  final int wordsWithLetters;
}
