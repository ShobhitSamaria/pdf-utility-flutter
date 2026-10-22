import 'package:flutter_test/flutter_test.dart';
import 'package:pdf_utility_flutter/translation/domain/translation_language.dart';

void main() {
  group('defaults', () {
    test('target defaults to Hindi', () {
      expect(TranslationLanguages.defaultTarget, TranslationLanguages.hindi);
      expect(TranslationLanguages.defaultTarget.code, 'hi');
      expect(TranslationLanguages.defaultTarget.englishName, 'Hindi');
      expect(TranslationLanguages.defaultTarget.nativeName, 'हिन्दी');
    });

    test('source defaults to auto-detect', () {
      expect(TranslationLanguages.defaultSource, TranslationLanguages.auto);
      expect(TranslationLanguages.defaultSource.isAuto, isTrue);
    });

    test('the default target is one of the offered languages', () {
      expect(TranslationLanguages.all, contains(TranslationLanguages.hindi));
    });

    test('source options list auto-detect first', () {
      expect(TranslationLanguages.sources.first, TranslationLanguages.auto);
      expect(TranslationLanguages.sources.where((l) => l.isAuto).length, 1);
      // Every concrete language is offered as a source.
      for (final language in TranslationLanguages.all) {
        expect(TranslationLanguages.sources, contains(language));
      }
    });

    test('the concrete language list never contains the auto sentinel', () {
      expect(TranslationLanguages.all.where((l) => l.isAuto), isEmpty);
    });

    test('language codes are unique', () {
      final codes = TranslationLanguages.all.map((l) => l.code).toList();
      expect(codes.toSet().length, codes.length);
    });
  });

  group('byCode', () {
    test('resolves exact codes', () {
      expect(TranslationLanguages.byCode('hi'), TranslationLanguages.hindi);
      expect(TranslationLanguages.byCode('en'), TranslationLanguages.english);
    });

    test('is case- and whitespace-insensitive', () {
      expect(TranslationLanguages.byCode(' HI '), TranslationLanguages.hindi);
    });

    test('resolves the auto sentinel', () {
      expect(TranslationLanguages.byCode('auto'), TranslationLanguages.auto);
    });

    test('drops region suffixes', () {
      expect(
        TranslationLanguages.byCode('en-GB'),
        TranslationLanguages.english,
      );
      expect(
        TranslationLanguages.byCode('pt-BR'),
        TranslationLanguages.portuguese,
      );
    });

    test('normalises script/region variants of Chinese', () {
      expect(
        TranslationLanguages.byCode('zh-Hant'),
        TranslationLanguages.chinese,
      );
      expect(
        TranslationLanguages.byCode('zh-CN'),
        TranslationLanguages.chinese,
      );
    });

    test('normalises legacy tags', () {
      expect(TranslationLanguages.byCode('iw'), TranslationLanguages.hebrew);
      expect(
        TranslationLanguages.byCode('in'),
        TranslationLanguages.indonesian,
      );
    });

    test('returns null for unknown or empty tags', () {
      expect(TranslationLanguages.byCode('xx'), isNull);
      expect(TranslationLanguages.byCode('und'), isNull);
      expect(TranslationLanguages.byCode(''), isNull);
      expect(TranslationLanguages.byCode('   '), isNull);
    });
  });

  group('labels and equality', () {
    test('non-Latin languages show their own name first', () {
      expect(TranslationLanguages.hindi.label, 'हिन्दी (Hindi)');
      expect(TranslationLanguages.tamil.label, 'தமிழ் (Tamil)');
    });

    test('English reads plainly', () {
      expect(TranslationLanguages.english.label, 'English');
    });

    test('auto-detect reads plainly', () {
      expect(TranslationLanguages.auto.label, 'Auto-detect');
      expect(TranslationLanguages.auto.isConcrete, isFalse);
    });

    test('equality is based on the code alone', () {
      const copy = TranslationLanguage(
        code: 'hi',
        englishName: 'Different name',
        nativeName: 'Different name',
      );
      expect(copy, TranslationLanguages.hindi);
      expect(copy.hashCode, TranslationLanguages.hindi.hashCode);
      expect(copy == TranslationLanguages.english, isFalse);
    });
  });
}
