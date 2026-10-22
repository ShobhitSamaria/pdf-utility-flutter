import 'translation_language.dart';

/// What the writing system of a piece of text says about its language.
///
/// Newspaper OCR is the hard case for statistical language identification: a
/// page holds a Hindi headline, an English byline, a date, a name and a
/// Sanskritised quote, so no single language clears a 0.5 confidence bar and
/// ML Kit answers `und`. The script itself, however, is unambiguous for most
/// Indian languages — Devanagari text is not English no matter what the
/// statistics say.
///
/// This is deliberately a **heuristic**, not a classifier. It only answers when
/// one script clearly dominates, and [coverage] is reported so a caller can see
/// how strong the evidence was. Ambiguous cases are resolved by the statistical
/// detector first:
///
/// * Devanagari → Hindi by default; Marathi is preferred when ML Kit proposes it.
/// * Arabic script → Urdu by default; Arabic and Persian are preferred when ML
///   Kit proposes them.
/// * Han + kana → Japanese; Han alone → Chinese.
class ScriptEvidence {
  const ScriptEvidence({
    required this.language,
    required this.coverage,
    required this.letters,
  });

  /// The language this writing system most likely represents.
  final TranslationLanguage language;

  /// Share of the counted letters that are in this script (0–1).
  final double coverage;

  /// Number of letters in this script.
  final int letters;

  @override
  String toString() =>
      'ScriptEvidence(${language.code}, ${(coverage * 100).round()}%, '
      '$letters letters)';
}

/// Whether Devanagari text is Hindi or Marathi, decided from its function
/// words.
///
/// Why this is needed
/// ------------------
/// ML Kit's language identifier confuses Hindi and Marathi on real documents.
/// The two languages share a script, a large vocabulary and the same OCR
/// mistakes, so a Hindi government form was identified as **Marathi** with a
/// confidence high enough to satisfy the statistical detector. The translation
/// then ran through the Marathi model: the output is not gibberish, which is
/// why this went unnoticed, but verbs, postpositions and case endings come out
/// wrong.
///
/// Script evidence cannot separate them, so this looks at the words that do:
/// Marathi uses आहे / आहेत / च्या / साठी / मध्ये / आणि, Hindi uses
/// है / हैं / गया / किया / और / नहीं. Only words that are (near-)exclusive to one
/// language are counted, so a shared word can never vote.
///
/// It answers `null` when both sides are equally represented (or neither is),
/// and the caller keeps its default. Being honest about uncertainty matters
/// more than guessing here: a wrong source language silently degrades every
/// sentence on the page.
abstract final class DevanagariLanguage {
  static final RegExp _word = RegExp(r'[\u0900-\u097F]+');

  /// Words that are effectively Hindi-only. Shared words deliberate excluded.
  static const Set<String> hindiMarkers = <String>{
    'है',
    'हैं',
    'होता',
    'था',
    'थे',
    'थी',
    'गया',
    'गई',
    'गए',
    'किया',
    'करना',
    'करने',
    'रहा',
    'रही',
    'हुआ',
    'हुई',
    'नहीं',
    'और',
    'यह',
    'वह',
    'उन्होंने',
    'इन्होंने',
    'द्वारा',
    'लिए',
    'बाद',
    'पहले',
    'सकता',
    'सकती',
    'सकते',
  };

  /// Words that are effectively Marathi-only.
  static const Set<String> marathiMarkers = <String>{
    'आहे',
    'आहेत',
    'च्या',
    'ची',
    'चे',
    'साठी',
    'मध्ये',
    'नाही',
    'म्हणून',
    'करण्यात',
    'झाले',
    'झाला',
    'झाली',
    'यांनी',
    'त्यांनी',
    'जिल्हा',
    'तालुका',
    'आणि',
    'तसेच',
  };

  /// The language [text] reads as, or `null` when the evidence is inconclusive.
  ///
  /// [TranslationLanguages.hindi] wins ties on purpose: it is the script's
  /// default and the overwhelmingly common Devanagari document in this app.
  /// Only a clear Marathi majority switches the answer.
  static TranslationLanguage? resolve(String text) {
    var hindi = 0;
    var marathi = 0;
    for (final match in _word.allMatches(text)) {
      final word = match.group(0)!;
      if (hindiMarkers.contains(word)) hindi++;
      if (marathiMarkers.contains(word)) marathi++;
    }
    if (hindi == 0 && marathi == 0) return null;
    if (marathi > hindi) return TranslationLanguages.marathi;
    return TranslationLanguages.hindi;
  }
}

/// Which script a string is written in, and the language that implies.
abstract final class LanguageScript {
  /// A script needs at least this share of the letters to count as dominant.
  ///
  /// Deliberately low: a Hindi newspaper page with an English masthead is still
  /// a Hindi page, and 20 % Devanagari is already far more evidence than the
  /// `und` the statistical detector returns for the same text.
  static const double minCoverage = 0.2;

  /// Below this many letters, a two-word fragment is not evidence of a script.
  static const int minLetters = 4;

  /// The dominant script of [text], or `null` when it has no letters or no
  /// script reaches [minCoverage].
  static ScriptEvidence? dominant(String text) {
    var total = 0;
    final counts = <String, int>{};
    for (final rune in text.runes) {
      final group = _groupOfRune(rune);
      if (group == null) continue;
      total += 1;
      counts[group] = (counts[group] ?? 0) + 1;
    }
    if (total == 0) return null;

    var bestGroup = '';
    var bestCount = 0;
    counts.forEach((group, count) {
      if (count > bestCount) {
        bestGroup = group;
        bestCount = count;
      }
    });

    // Kana is decisive for Japanese even when the page is mostly kanji: Chinese
    // prose does not contain hiragana or katakana at all.
    if (bestGroup == 'han' && (counts['kana'] ?? 0) >= 2) {
      bestGroup = 'kana';
      bestCount = counts['kana']!;
    }

    final language = _languageOfGroup[bestGroup];
    if (language == null) return null;
    final coverage = bestCount / total;
    if (bestCount < minLetters || coverage < minCoverage) return null;
    return ScriptEvidence(
      language: language,
      coverage: coverage,
      letters: bestCount,
    );
  }

  /// The language implied by the dominant script of [text], if any.
  static TranslationLanguage? languageHint(String text) =>
      dominant(text)?.language;

  /// The script family of a concrete language, used to compare a statistical
  /// candidate against the script evidence.
  static String? groupOf(TranslationLanguage language) =>
      _groupByCode[language.code];

  /// Script families that identify the same language set, so Han and kana
  /// candidates can be compared with a Han-dominant page.
  static bool sameFamily(String a, String b) =>
      a == b || (_cjk.contains(a) && _cjk.contains(b));

  static const Set<String> _cjk = <String>{'han', 'kana', 'cjk'};

  static const Map<String, TranslationLanguage> _languageOfGroup =
      <String, TranslationLanguage>{
        'latin': TranslationLanguages.english,
        'devanagari': TranslationLanguages.hindi,
        'bengali': TranslationLanguages.bengali,
        'gujarati': TranslationLanguages.gujarati,
        'tamil': TranslationLanguages.tamil,
        'telugu': TranslationLanguages.telugu,
        'kannada': TranslationLanguages.kannada,
        'arabic': TranslationLanguages.urdu,
        'hebrew': TranslationLanguages.hebrew,
        'cyrillic': TranslationLanguages.russian,
        'thai': TranslationLanguages.thai,
        'kana': TranslationLanguages.japanese,
        'han': TranslationLanguages.chinese,
        'hangul': TranslationLanguages.korean,
      };

  static const Map<String, String> _groupByCode = <String, String>{
    'en': 'latin',
    'de': 'latin',
    'fr': 'latin',
    'it': 'latin',
    'pt': 'latin',
    'pl': 'latin',
    'es': 'latin',
    'nl': 'latin',
    'id': 'latin',
    'ms': 'latin',
    'sw': 'latin',
    'tr': 'latin',
    'vi': 'latin',
    'hi': 'devanagari',
    'mr': 'devanagari',
    'bn': 'bengali',
    'gu': 'gujarati',
    'ta': 'tamil',
    'te': 'telugu',
    'kn': 'kannada',
    'ur': 'arabic',
    'ar': 'arabic',
    'fa': 'arabic',
    'he': 'hebrew',
    'ru': 'cyrillic',
    'uk': 'cyrillic',
    'zh': 'han',
    'ja': 'kana',
    'ko': 'hangul',
    'th': 'thai',
  };

  /// The script family a code point belongs to, or `null` when it is not a
  /// letter of a script this app can translate.
  static String? _groupOfRune(int rune) {
    // Digits and dates are not language evidence; neither are punctuation and
    // currency marks, which survive OCR in every script.
    if (rune >= 0x30 && rune <= 0x39) return null;
    if (rune >= 0x2000 && rune <= 0x206F) return null;
    if (_isScriptDigit(rune)) return null;
    if (_isCommonPunctuation(rune)) return null;

    if ((rune >= 0x41 && rune <= 0x5A) ||
        (rune >= 0x61 && rune <= 0x7A) ||
        (rune >= 0xC0 && rune <= 0x24F)) {
      return 'latin';
    }
    if (rune >= 0x0900 && rune <= 0x097F) return 'devanagari';
    if (rune >= 0x0980 && rune <= 0x09FF) return 'bengali';
    if (rune >= 0x0A80 && rune <= 0x0AFF) return 'gujarati';
    if (rune >= 0x0B80 && rune <= 0x0BFF) return 'tamil';
    if (rune >= 0x0C00 && rune <= 0x0C7F) return 'telugu';
    if (rune >= 0x0C80 && rune <= 0x0CFF) return 'kannada';
    if (rune >= 0x0590 && rune <= 0x05FF) return 'hebrew';
    if ((rune >= 0x0600 && rune <= 0x06FF) ||
        (rune >= 0x0750 && rune <= 0x077F) ||
        (rune >= 0x08A0 && rune <= 0x08FF)) {
      return 'arabic';
    }
    if (rune >= 0x0400 && rune <= 0x04FF) return 'cyrillic';
    if (rune >= 0x0E00 && rune <= 0x0E7F) return 'thai';
    if (rune >= 0x3040 && rune <= 0x30FF) return 'kana';
    if ((rune >= 0x4E00 && rune <= 0x9FFF) ||
        (rune >= 0x3400 && rune <= 0x4DBF)) {
      return 'han';
    }
    if ((rune >= 0xAC00 && rune <= 0xD7AF) ||
        (rune >= 0x1100 && rune <= 0x11FF) ||
        (rune >= 0x3130 && rune <= 0x318F)) {
      return 'hangul';
    }
    return null;
  }

  /// Digit blocks that live inside a script's letter range.
  static bool _isScriptDigit(int rune) {
    if (rune >= 0x0966 && rune <= 0x096F) return true; // Devanagari
    if (rune >= 0x09E6 && rune <= 0x09EF) return true; // Bengali
    if (rune >= 0x0AE6 && rune <= 0x0AEF) return true; // Gujarati
    if (rune >= 0x0BE6 && rune <= 0x0BEF) return true; // Tamil
    if (rune >= 0x0C66 && rune <= 0x0C6F) return true; // Telugu
    if (rune >= 0x0CE6 && rune <= 0x0CEF) return true; // Kannada
    if (rune >= 0x0E50 && rune <= 0x0E59) return true; // Thai
    if (rune >= 0x0660 && rune <= 0x0669) return true; // Arabic-Indic
    if (rune >= 0x06F0 && rune <= 0x06F9) return true; // Extended Arabic-Indic
    return false;
  }

  /// Punctuation that appears inside script ranges but carries no language.
  static bool _isCommonPunctuation(int rune) {
    if (rune >= 0x0964 && rune <= 0x0965) return true; // danda
    if (rune == 0x060C || rune == 0x061B || rune == 0x061F) return true;
    if (rune >= 0x066A && rune <= 0x066D) return true;
    return false;
  }
}
