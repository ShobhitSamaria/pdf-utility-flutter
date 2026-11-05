import 'package:flutter_test/flutter_test.dart';
import 'package:pdf_utility_flutter/ocr/data/mlkit_ocr_engine.dart';
import 'package:pdf_utility_flutter/ocr/domain/ocr_capabilities.dart';
import 'package:pdf_utility_flutter/ocr/domain/ocr_engine.dart';
import 'package:pdf_utility_flutter/ocr/domain/ocr_exception.dart';
import 'package:pdf_utility_flutter/ocr/domain/ocr_script_mode.dart';
import 'package:pdf_utility_flutter/translation/domain/ocr_language_support.dart';
import 'package:pdf_utility_flutter/translation/domain/translation_language.dart';

/// What the app can honestly claim about languages.
///
/// Translation and recognition are different capabilities: the on-device
/// translation models cover every language in the registry, while the bundled
/// recognizers cover two scripts. The failure this guards against is a silent
/// one — a Tamil page photographed with Tamil selected came back as "no text
/// found", which blames the photograph for a missing model.
void main() {
  group('recognizers', () {
    test('are the two whose models this build packages', () {
      expect(OcrCapabilities.bundledScripts, <OcrScript>[
        OcrScript.latin,
        OcrScript.devanagari,
      ]);
      expect(OcrCapabilities.isBundled(OcrScript.latin), isTrue);
      expect(OcrCapabilities.isBundled(OcrScript.devanagari), isTrue);
      // The enum has values for these, but no artifact is packaged for them, so
      // they are not available — asking for one must not pretend otherwise.
      expect(OcrCapabilities.isBundled(OcrScript.chinese), isFalse);
      expect(OcrCapabilities.isBundled(OcrScript.japanese), isFalse);
      expect(OcrCapabilities.isBundled(OcrScript.korean), isFalse);
    });

    test('name themselves in a message a person can act on', () {
      final message = OcrCapabilities.unavailableMessage(OcrScript.chinese);
      expect(message, contains('Chinese'));
      expect(message, contains('not included in this build'));
      expect(message, contains('Latin'));
      expect(message, contains('Devanagari'));
    });

    test('every mode the UI offers can actually run', () {
      for (final mode in OcrScriptMode.values) {
        expect(
          OcrCapabilities.isBundled(mode.primaryScript),
          isTrue,
          reason: '${mode.label} would ask for a recognizer this build lacks',
        );
        final secondary = mode.secondaryScript;
        if (secondary != null) {
          expect(OcrCapabilities.isBundled(secondary), isTrue);
        }
      }
    });

    test('refuses an unbundled script instead of failing obscurely', () async {
      final engine = MlKitOcrEngine();
      await expectLater(
        engine.recognize(
          imagePath: 'does-not-matter.png',
          options: const OcrOptions(script: OcrScript.japanese),
        ),
        throwsA(
          isA<OcrException>()
              .having(
                (error) => error.kind,
                'kind',
                OcrErrorKind.engineUnavailable,
              )
              .having(
                (error) => error.message,
                'message',
                contains('Japanese'),
              ),
        ),
      );
      await engine.dispose();
    });
  });

  group('languages', () {
    test('a photo can supply Latin and Devanagari languages only', () {
      final readable = OcrLanguageSupport.readableSources();
      expect(readable, contains(TranslationLanguages.english));
      expect(readable, contains(TranslationLanguages.hindi));
      expect(readable, contains(TranslationLanguages.marathi));
      // These are translatable, but no recognizer in this build reads them.
      expect(readable, isNot(contains(TranslationLanguages.tamil)));
      expect(readable, isNot(contains(TranslationLanguages.telugu)));
      expect(readable, isNot(contains(TranslationLanguages.bengali)));
      expect(readable, isNot(contains(TranslationLanguages.urdu)));
      expect(readable, isNot(contains(TranslationLanguages.thai)));
      expect(readable, isNot(contains(TranslationLanguages.chinese)));

      expect(OcrLanguageSupport.canRead(TranslationLanguages.english), isTrue);
      expect(OcrLanguageSupport.canRead(TranslationLanguages.tamil), isFalse);
      expect(OcrLanguageSupport.canRead(TranslationLanguages.auto), isFalse);
    });

    test('says why a language cannot be read, and names what can', () {
      final limitation = OcrLanguageSupport.limitationFor(
        TranslationLanguages.tamil,
      );
      expect(limitation, isNotNull);
      expect(limitation, contains('Tamil'));
      expect(limitation, contains('Devanagari'));
      expect(
        OcrLanguageSupport.limitationFor(TranslationLanguages.hindi),
        isNull,
      );
    });

    test('Tamil stays translatable — recognition is the limitation', () {
      // The translation model for Tamil is packaged (see MlKitTranslationEngine),
      // so the language must remain in the registry; only a *photo* of it cannot
      // be read. Nothing here may remove it from the source list.
      expect(
        TranslationLanguages.sources,
        contains(TranslationLanguages.tamil),
      );
      expect(
        OcrLanguageSupport.readableSources().length,
        lessThan(TranslationLanguages.all.length),
        reason:
            'the readable list is a subset; a change that makes every language '
            'readable from a photo would be a false claim',
      );
    });
  });
}
