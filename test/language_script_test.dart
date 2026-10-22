import 'package:flutter_test/flutter_test.dart';
import 'package:pdf_utility_flutter/translation/data/mlkit_language_detector.dart';
import 'package:pdf_utility_flutter/translation/domain/language_script.dart';
import 'package:pdf_utility_flutter/translation/domain/translation_language.dart';

void main() {
  group('Devanagari wording', () {
    test('reads a Hindi notice as Hindi', () {
      expect(
        DevanagariLanguage.resolve(
          'राजस्थान सरकार ने अधिसूचना जारी की है। आवेदन पत्र '
          'कार्यालय में जमा किया जाएगा और अंतिम तिथि 31-10-2026 है।',
        ),
        TranslationLanguages.hindi,
      );
    });

    test('reads a Marathi notice as Marathi', () {
      expect(
        DevanagariLanguage.resolve(
          'राज्य सरकारने अधिसूचना जारी केली आहे. अर्ज कार्यालयात '
          'द्यायचा आहे आणि शेवटची तारीख 31-10-2026 आहे.',
        ),
        TranslationLanguages.marathi,
      );
    });

    test('is inconclusive when no marker word appears', () {
      // Shared vocabulary only: statistics (or the caller's default) must decide.
      expect(DevanagariLanguage.resolve('जयपुर दैनिक भास्कर'), isNull);
      expect(DevanagariLanguage.resolve(''), isNull);
    });

    test('Hindi wins a tie, because it is the script default', () {
      expect(
        DevanagariLanguage.resolve('यह है आहे'),
        TranslationLanguages.hindi,
      );
    });
  });

  group('source language resolution', () {
    TranslationLanguage? resolve({
      required String text,
      TranslationLanguage? candidate = TranslationLanguages.marathi,
      double confidence = 0.9,
      TranslationLanguage fallback = TranslationLanguages.hindi,
    }) => MlKitSourceLanguageDetector.resolveSameScript(
      text: text,
      candidate: candidate,
      candidateConfidence: confidence,
      scriptDefault: fallback,
      family: 'devanagari',
    );

    test('rejects a confident Marathi label on clearly Hindi text', () {
      // The real failure: a Rajasthan government form was identified as Marathi
      // with high confidence, so every sentence was translated with the wrong
      // Devanagari model.
      expect(
        resolve(
          text:
              'जिला निर्वाचन अधिकारी कार्यालय. मतदान दल क्रमांक 1. '
              'प्रशिक्षण विवरण. द्वितीय प्रशिक्षण और प्रस्थान दिया जाएगा है।',
        ),
        TranslationLanguages.hindi,
      );
    });

    test('accepts Marathi when the text actually reads as Marathi', () {
      expect(
        resolve(text: 'अर्ज कार्यालयात द्यायचा आहे आणि तारीख आहे.'),
        TranslationLanguages.marathi,
      );
    });

    test('falls back to the script default without wording evidence', () {
      expect(
        resolve(text: 'जयपुर दैनिक भास्कर 2025'),
        TranslationLanguages.hindi,
        reason:
            'Hindi and Marathi share these words; a statistical label '
            'alone must not switch the model.',
      );
    });

    test('ignores a weak candidate', () {
      expect(resolve(text: 'काहीही आहे', confidence: 0.2), isNull);
    });
  });
  group('dominant script', () {
    test('Devanagari text is Hindi', () {
      final evidence = LanguageScript.dominant(
        'दिल्ली में आज मौसम साफ रहेगा और तापमान बढ़ेगा',
      );
      expect(evidence, isNotNull);
      expect(evidence!.language, TranslationLanguages.hindi);
      expect(evidence.coverage, greaterThan(0.9));
    });

    test('a Hindi page with an English masthead is still Hindi', () {
      // The case that made ML Kit answer `und`: 30 % Devanagari, 70 % Latin.
      final evidence = LanguageScript.dominant(
        'THE DAILY NEWS\nशहर में बारिश के कारण सड़कें जलमग्न हो गईं और '
        'यातायात बुरी तरह प्रभावित हुआ',
      );
      expect(evidence?.language, TranslationLanguages.hindi);
    });

    test('a stray Hindi name in an English page is not evidence', () {
      final evidence = LanguageScript.dominant(
        'The minister met officials in New Delhi on Monday to review the '
        'annual budget and the new highway project. राहुल',
      );
      expect(evidence?.language, TranslationLanguages.english);
    });

    test('pure Latin text is English', () {
      expect(
        LanguageScript.languageHint('Council approves the new budget'),
        TranslationLanguages.english,
      );
    });

    test('dates and numbers are not evidence', () {
      expect(LanguageScript.dominant('12/08/2026 — ₹45,00,000'), isNull);
      expect(LanguageScript.languageHint('   '), isNull);
    });

    test('a two-letter fragment is not enough evidence', () {
      expect(LanguageScript.dominant('कल'), isNull);
    });

    test('other scripts map to the language this app can translate', () {
      expect(
        LanguageScript.languageHint('বাংলায় লেখা একটি সংবাদ প্রতিবেদন'),
        TranslationLanguages.bengali,
      );
      expect(
        LanguageScript.languageHint('தமிழில் எழுதப்பட்ட செய்தி'),
        TranslationLanguages.tamil,
      );
      expect(
        LanguageScript.languageHint('یہ اردو میں لکھی گئی خبر ہے'),
        TranslationLanguages.urdu,
      );
      expect(
        LanguageScript.languageHint('これは日本語のニュースです'),
        TranslationLanguages.japanese,
      );
    });

    test('kanji-only text defaults to Chinese; kana makes it Japanese', () {
      expect(
        LanguageScript.languageHint('每日新闻城市交通改善计划'),
        TranslationLanguages.chinese,
      );
      expect(
        LanguageScript.languageHint('毎日のニュースです'),
        TranslationLanguages.japanese,
      );
    });
  });

  group('script families', () {
    test('codes map to the right family', () {
      expect(LanguageScript.groupOf(TranslationLanguages.hindi), 'devanagari');
      expect(
        LanguageScript.groupOf(TranslationLanguages.marathi),
        'devanagari',
      );
      expect(LanguageScript.groupOf(TranslationLanguages.english), 'latin');
      expect(LanguageScript.groupOf(TranslationLanguages.urdu), 'arabic');
    });

    test('Han and kana candidates compare with each other', () {
      expect(LanguageScript.sameFamily('han', 'kana'), isTrue);
      expect(LanguageScript.sameFamily('han', 'latin'), isFalse);
    });
  });
}
