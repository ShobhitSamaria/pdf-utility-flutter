import 'package:flutter_test/flutter_test.dart';
import 'package:pdf_utility_flutter/translation/domain/translation_language.dart';
import 'package:pdf_utility_flutter/translation/domain/translation_request.dart';

void main() {
  group('construction', () {
    test('selection factory defaults to auto source and Hindi target', () {
      final request = TranslationRequest.selection(text: 'Hello');
      expect(request.scope, TranslationScope.selection);
      expect(request.source, TranslationLanguages.auto);
      expect(request.target, TranslationLanguages.hindi);
    });

    test('whole-page factory tags the scope', () {
      final request = TranslationRequest.wholePage(pageText: 'Hello\nWorld');
      expect(request.scope, TranslationScope.wholePage);
      expect(request.text, 'Hello\nWorld');
    });

    test('default scope of the raw constructor is selection', () {
      const request = TranslationRequest(
        text: 'Hello',
        source: TranslationLanguages.english,
        target: TranslationLanguages.hindi,
      );
      expect(request.scope, TranslationScope.selection);
    });

    test('honours explicit languages', () {
      final request = TranslationRequest.selection(
        text: 'Bonjour',
        source: TranslationLanguages.french,
        target: TranslationLanguages.english,
      );
      expect(request.source, TranslationLanguages.french);
      expect(request.target, TranslationLanguages.english);
      expect(request.isAutoSource, isFalse);
    });
  });

  group('derived properties', () {
    test('normalizedText trims and collapses whitespace', () {
      final request = TranslationRequest.selection(
        text: '  Hello   world \n\n\n\n Again  ',
      );
      expect(request.normalizedText, 'Hello world\n\nAgain');
    });

    test('isEmpty tracks whether anything can be translated', () {
      expect(TranslationRequest.selection(text: '   ').isEmpty, isTrue);
      expect(TranslationRequest.selection(text: 'x').isEmpty, isFalse);
    });

    test('isAutoSource reflects the source', () {
      expect(TranslationRequest.selection(text: 'x').isAutoSource, isTrue);
      expect(
        TranslationRequest.selection(
          text: 'x',
          source: TranslationLanguages.english,
        ).isAutoSource,
        isFalse,
      );
    });
  });

  group('copyWith and equality', () {
    test('copyWith replaces only the given fields', () {
      final request = TranslationRequest.selection(text: 'Hello');
      final updated = request.copyWith(target: TranslationLanguages.tamil);
      expect(updated.target, TranslationLanguages.tamil);
      expect(updated.text, 'Hello');
      expect(updated.source, TranslationLanguages.auto);
      expect(updated.scope, TranslationScope.selection);
    });

    test('copyWith can change the scope', () {
      final request = TranslationRequest.selection(text: 'Hello');
      expect(
        request.copyWith(scope: TranslationScope.wholePage).scope,
        TranslationScope.wholePage,
      );
    });

    test('equality covers text, scope, source and target', () {
      final a = TranslationRequest.selection(text: 'Hello');
      final b = TranslationRequest.selection(text: 'Hello');
      expect(a, b);
      expect(a.hashCode, b.hashCode);
      expect(a == a.copyWith(text: 'Other'), isFalse);
      expect(a == a.copyWith(scope: TranslationScope.wholePage), isFalse);
      expect(a == a.copyWith(target: TranslationLanguages.tamil), isFalse);
      expect(a == a.copyWith(source: TranslationLanguages.english), isFalse);
    });
  });
}
