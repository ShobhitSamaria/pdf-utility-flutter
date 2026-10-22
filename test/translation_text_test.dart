import 'package:flutter_test/flutter_test.dart';
import 'package:pdf_utility_flutter/translation/domain/translation_text.dart';

void main() {
  group('isTranslatable', () {
    test('rejects null and blank text', () {
      expect(TranslationText.isTranslatable(null), isFalse);
      expect(TranslationText.isTranslatable(''), isFalse);
      expect(TranslationText.isTranslatable('   '), isFalse);
      expect(TranslationText.isTranslatable('\n\t\n'), isFalse);
    });

    test('accepts text with content', () {
      expect(TranslationText.isTranslatable('Hello'), isTrue);
      expect(TranslationText.isTranslatable('  Hello  '), isTrue);
    });
  });

  group('normalize', () {
    test('trims the ends', () {
      expect(TranslationText.normalize('   Hello world   '), 'Hello world');
    });

    test('collapses runs of spaces and tabs inside a line', () {
      expect(
        TranslationText.normalize('Hello     world\tagain'),
        'Hello world again',
      );
    });

    test('trims each line but keeps line breaks', () {
      expect(
        TranslationText.normalize('  first line  \n   second line  '),
        'first line\nsecond line',
      );
    });

    test('collapses excess blank lines', () {
      expect(TranslationText.normalize('a\n\n\n\n\nb'), 'a\n\nb');
    });

    test('keeps a single blank line', () {
      expect(TranslationText.normalize('a\n\nb'), 'a\n\nb');
    });

    test('returns an empty string for blank input', () {
      expect(TranslationText.normalize('   \n  '), '');
    });
  });

  group('aggregate (whole-page text)', () {
    test('joins lines with newlines by default', () {
      expect(
        TranslationText.aggregate(const ['Line one', 'Line two']),
        'Line one\nLine two',
      );
    });

    test('drops empty and whitespace-only segments and trims the rest', () {
      expect(
        TranslationText.aggregate(const ['  A  ', '', '   ', 'B']),
        'A\nB',
      );
    });

    test('preserves order', () {
      expect(
        TranslationText.aggregate(const ['third', 'first', 'second']),
        'third\nfirst\nsecond',
      );
    });

    test('supports a custom separator', () {
      expect(
        TranslationText.aggregate(const ['Hello', 'World'], separator: ' '),
        'Hello World',
      );
    });

    test('returns an empty string when nothing is translatable', () {
      expect(TranslationText.aggregate(const ['', '  ']), '');
      expect(TranslationText.aggregate(const <String>[]), '');
    });

    test('rebuilds a whole page from per-line OCR text', () {
      const lines = <String>[
        '  Terms and conditions  ',
        '',
        '1. The agreement starts today.',
        '2. Please read carefully.',
      ];
      expect(
        TranslationText.aggregate(lines),
        'Terms and conditions\n'
        '1. The agreement starts today.\n'
        '2. Please read carefully.',
      );
    });
  });
}
