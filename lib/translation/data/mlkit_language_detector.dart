import 'package:google_mlkit_language_id/google_mlkit_language_id.dart'
    as mlkit;

import '../domain/language_script.dart';
import '../domain/source_language_detector.dart';
import '../domain/translation_language.dart';
import '../domain/translation_text.dart';
import '../translation_log.dart';

/// Concrete [SourceLanguageDetector] backed by Google's **on-device** ML Kit
/// Language Identification, with a writing-system fallback.
///
/// Why this is not just `identifyLanguage(text)`
/// ---------------------------------------------
/// The single-result API answers with one language only when it clears a
/// confidence bar, and returns `und` otherwise. A newspaper page defeats that
/// bar routinely: a Hindi headline, an English byline, a date, a name and a
/// Sanskritised quote leave no single language confident. The service then
/// reported "We couldn't tell which language this is" for perfectly readable
/// Hindi text.
///
/// So detection now uses three layers, in order:
///
/// 1. **All candidates** from [mlkit.LanguageIdentifier.identifyPossibleLanguages]
///    with a low native threshold, mapped to languages this app can translate.
/// 2. **Script evidence** from [LanguageScript]: Devanagari text is Hindi (or
///    Marathi, when ML Kit is strongly sure), never English — no matter what the
///    statistics answer for a mixed page.
/// 3. The single-language API, then `null` only when the text has no usable
///    letters at all (dates, numbers, punctuation).
///
/// Returning `null` therefore means "there is genuinely nothing to go on", not
/// "the page was too mixed for ML Kit". The UI can then offer a manual choice,
/// and a manual choice never reaches this class at all.
///
/// This is the ONLY place that imports the ML Kit language-id package. The
/// identifier is created lazily and reused, because native model loading is
/// expensive.
class MlKitSourceLanguageDetector implements SourceLanguageDetector {
  MlKitSourceLanguageDetector({
    this.confidenceThreshold = 0.5,
    this.nativeCandidateThreshold = 0.1,
    this.minCandidateConfidence = 0.15,
    this.strongCandidateConfidence = 0.5,
  }) : assert(
         confidenceThreshold >= 0 && confidenceThreshold <= 1,
         'confidenceThreshold must be within [0, 1]',
       ),
       assert(
         nativeCandidateThreshold >= 0 && nativeCandidateThreshold <= 1,
         'nativeCandidateThreshold must be within [0, 1]',
       );

  /// Tag ML Kit returns when it cannot decide.
  static const String undeterminedCode = 'und';

  /// Minimum confidence for the single-language fallback to be accepted.
  final double confidenceThreshold;

  /// Confidence passed to the **native** identifier when asking for all
  /// candidates.
  ///
  /// Deliberately far below [confidenceThreshold]: the whole point is to see
  /// the 0.2–0.4 signals a mixed page produces, then judge them here against the
  /// dominant script. Passing 0.5 would make the native side drop exactly the
  /// candidates this class exists to use.
  final double nativeCandidateThreshold;

  /// Lowest candidate confidence worth considering at all.
  final double minCandidateConfidence;

  /// Confidence a candidate needs before it overrides the script's default
  /// language (e.g. Marathi over Hindi for Devanagari).
  final double strongCandidateConfidence;

  mlkit.LanguageIdentifier? _identifier;

  @override
  Future<TranslationLanguage?> detect(String text) async {
    if (!TranslationText.isTranslatable(text)) return null;

    final evidence = LanguageScript.dominant(text);
    final identifier = _identifier ??= mlkit.LanguageIdentifier(
      confidenceThreshold: nativeCandidateThreshold,
    );

    final candidates = await _possibleLanguages(identifier, text);
    final best = _bestCandidate(candidates);
    final evidenceLanguage = evidence?.language;

    if (evidenceLanguage != null) {
      final family = LanguageScript.groupOf(evidenceLanguage);
      if (family != null) {
        // A candidate in the same writing system is the most trustworthy
        // statistical answer available: it can distinguish Marathi from Hindi,
        // Arabic from Urdu, Japanese from Chinese.
        TranslationLanguage? sameScript;
        var sameScriptConfidence = 0.0;
        for (final candidate in candidates) {
          if (candidate.confidence < minCandidateConfidence) continue;
          final group = LanguageScript.groupOf(candidate.language);
          if (group == null || !LanguageScript.sameFamily(group, family)) {
            continue;
          }
          if (candidate.confidence > sameScriptConfidence) {
            sameScript = candidate.language;
            sameScriptConfidence = candidate.confidence;
          }
        }
        final resolved = resolveSameScript(
          text: text,
          candidate: sameScript,
          candidateConfidence: sameScriptConfidence,
          scriptDefault: evidenceLanguage,
          family: family,
          minimumConfidence: strongCandidateConfidence,
        );
        if (resolved != null) {
          _log(
            'possible languages → ${resolved.code} '
            '(${sameScriptConfidence.toStringAsFixed(2)}) '
            'overrides script default ${evidenceLanguage.code}',
          );
          return resolved;
        }
      }

      if (evidenceLanguage != TranslationLanguages.english) {
        // A dominant non-Latin script is decisive for the purpose of picking a
        // model: translating Devanagari text with the English model is always
        // wrong, even if the English words on the page outnumber the Hindi ones.
        _log(
          'script evidence → ${evidenceLanguage.code} '
          '(${((evidence?.coverage ?? 0) * 100).round()}% '
          '${evidence?.letters} letters); best candidate '
          '${best?.language.code ?? '(none)'}',
        );
        return evidenceLanguage;
      }
    }

    if (best != null) {
      _log(
        'possible languages → ${best.language.code} '
        '(${best.confidence.toStringAsFixed(2)})',
      );
      return best.language;
    }

    // Last chance: the single-language API. Kept because some devices return an
    // empty candidate list for text that the one-shot API still classifies.
    try {
      final tag = await identifier.identifyLanguage(text);
      if (tag.isNotEmpty && tag != undeterminedCode) {
        final resolved = TranslationLanguages.byCode(tag);
        if (resolved != null) {
          _log('identifyLanguage → "$tag" → ${resolved.code}');
          return resolved;
        }
        _log('identifyLanguage → "$tag" (unsupported)');
      } else {
        _log(
          'identifyLanguage → "$tag" (undetermined) for '
          '${text.length} chars',
        );
      }
    } catch (error, stack) {
      _log(
        'identifyLanguage FAILED for ${text.length} chars\n'
        '${error.runtimeType}: $error\n$stack',
      );
    }

    // Text with letters in a script we cannot translate, or no letters at all:
    // the caller shows a manual choice instead of guessing.
    return evidenceLanguage;
  }

  /// The language to use when a statistical candidate shares the page's writing
  /// system, or `null` when the script default should stand.
  ///
  /// Extracted as a pure function because this is the decision that matters:
  /// ML Kit confidently labels Hindi pages "Marathi", and translating with the
  /// wrong Devanagari model silently degrades every sentence. The rules are:
  ///
  /// * a candidate in another writing system is irrelevant (the caller filters
  ///   those out already);
  /// * no candidate, or a weak one, leaves the script default in place;
  /// * for Devanagari, [DevanagariLanguage] decides from function words, so
  ///   statistics can only override the Hindi default with textual evidence of
  ///   Marathi — and conversely, a Marathi label on clearly Hindi text is
  ///   rejected;
  /// * any other shared script (Arabic/Urdu, Han/Japanese) still trusts the
  ///   statistical candidate when it is strong.
  static TranslationLanguage? resolveSameScript({
    required String text,
    required TranslationLanguage? candidate,
    required double candidateConfidence,
    required TranslationLanguage scriptDefault,
    required String family,
    double minimumConfidence = 0.5,
  }) {
    if (candidate == null || candidateConfidence < minimumConfidence) {
      return null;
    }
    if (family == 'devanagari') {
      final wording = DevanagariLanguage.resolve(text);
      if (wording != null) return wording;
      // No usable wording evidence: keep the script's default rather than a
      // label that may be a statistically strong mistake.
      return scriptDefault;
    }
    return candidate;
  }

  /// All supported languages ML Kit proposes for [text], best first.
  Future<List<({TranslationLanguage language, double confidence})>>
  _possibleLanguages(mlkit.LanguageIdentifier identifier, String text) async {
    try {
      final raw = await identifier.identifyPossibleLanguages(text);
      final mapped = <({TranslationLanguage language, double confidence})>[];
      for (final identified in raw) {
        final language = TranslationLanguages.byCode(identified.languageTag);
        if (language == null) continue;
        mapped.add((language: language, confidence: identified.confidence));
      }
      mapped.sort((a, b) => b.confidence.compareTo(a.confidence));
      return mapped;
    } catch (error, stack) {
      // Detection is best-effort; the script evidence below still works.
      _log(
        'identifyPossibleLanguages FAILED for ${text.length} chars\n'
        '${error.runtimeType}: $error\n$stack',
      );
      return const <({TranslationLanguage language, double confidence})>[];
    }
  }

  ({TranslationLanguage language, double confidence})? _bestCandidate(
    List<({TranslationLanguage language, double confidence})> candidates,
  ) {
    for (final candidate in candidates) {
      if (candidate.confidence >= minCandidateConfidence) return candidate;
    }
    return null;
  }

  @override
  Future<void> dispose() async {
    final identifier = _identifier;
    _identifier = null;
    await identifier?.close();
  }

  static void _log(String message) => translationLog('detector: $message');
}
