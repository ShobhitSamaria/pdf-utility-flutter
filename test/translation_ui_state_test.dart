import 'package:flutter_test/flutter_test.dart';
import 'package:pdf_utility_flutter/translation/domain/translation_language.dart';
import 'package:pdf_utility_flutter/translation/domain/translation_model_state.dart';
import 'package:pdf_utility_flutter/translation/domain/translation_request.dart';
import 'package:pdf_utility_flutter/translation/domain/translation_result.dart';
import 'package:pdf_utility_flutter/translation/presentation/translation_ui_state.dart';

void main() {
  group('TranslationInProgress messages', () {
    test('are human and never mention models or downloads', () {
      const starting = TranslationInProgress(phase: TranslationPhase.starting);
      expect(starting.message, 'Starting…');

      const detecting = TranslationInProgress(
        phase: TranslationPhase.detectingLanguage,
      );
      expect(detecting.message, 'Detecting language…');

      const translating = TranslationInProgress(
        phase: TranslationPhase.translating,
      );
      expect(translating.message, 'Translating…');

      for (final state in [starting, detecting, translating]) {
        expect(state.message.toLowerCase(), isNot(contains('model')));
        expect(state.message.toLowerCase(), isNot(contains('download')));
        expect(state.message.toLowerCase(), isNot(contains('ml kit')));
      }
    });

    test('preparing a model names the language when known', () {
      const named = TranslationInProgress(
        phase: TranslationPhase.preparingModel,
        languageLabel: 'Hindi',
      );
      expect(named.message, 'Preparing Hindi…');

      const unnamed = TranslationInProgress(
        phase: TranslationPhase.preparingModel,
      );
      expect(unnamed.message, 'Preparing translation…');
    });

    test('reports progress as a percentage, not as "X of Y"', () {
      const counting = TranslationInProgress(
        phase: TranslationPhase.translating,
        completed: 3,
        total: 12,
      );
      expect(counting.hasCounter, isTrue);
      // ((3 / 12) * 100).round()
      expect(counting.percentage, 25);
      expect(counting.progress, closeTo(0.25, 0.0001));
      expect(counting.message, 'Translating… 25%');
      // The old build-log phrasing is gone, and the percentage is what the
      // progress bar beside it is showing.
      expect(counting.message, isNot(contains(' of ')));

      const finished = TranslationInProgress(
        phase: TranslationPhase.translating,
        completed: 2,
        total: 2,
      );
      expect(finished.percentage, 100);
      expect(finished.progress, 1.0);
      expect(finished.message, 'Translating… 100%');

      // Rounds to the nearest whole percent rather than truncating to 33.
      const third = TranslationInProgress(
        phase: TranslationPhase.translating,
        completed: 2,
        total: 3,
      );
      expect(third.percentage, 67);
    });

    test('has no percentage when there is no progress to report', () {
      const single = TranslationInProgress(
        phase: TranslationPhase.translating,
        completed: 1,
        total: 1,
      );
      expect(single.hasCounter, isFalse);
      expect(single.percentage, isNull);
      expect(single.progress, isNull);
      expect(single.message, 'Translating…');

      // The batch's opening tick announces "translating" before any region is
      // done. There is no honest number yet, so the UI shows an indeterminate
      // bar instead of inventing a "0%".
      const open = TranslationInProgress(
        phase: TranslationPhase.translating,
        total: 12,
      );
      expect(open.hasCounter, isFalse);
      expect(open.percentage, isNull);
      expect(open.progress, isNull);
      expect(open.message, 'Translating…');
    });
  });

  group('state variants', () {
    test('success exposes the result', () {
      const result = TranslationResult(
        originalText: 'Hello',
        translatedText: 'नमस्ते',
        sourceLanguage: TranslationLanguages.english,
        targetLanguage: TranslationLanguages.hindi,
        scope: TranslationScope.selection,
      );
      const state = TranslationSuccess(result);
      expect(state, isA<TranslationUiState>());
      expect(state.result.translatedText, 'नमस्ते');
    });

    test('failure defaults to retryable', () {
      const state = TranslationFailure(message: 'Something went wrong.');
      expect(state.retryable, isTrue);
      expect(
        const TranslationFailure(message: 'Nope', retryable: false).retryable,
        isFalse,
      );
    });

    test('every variant is a TranslationUiState', () {
      const states = <TranslationUiState>[
        TranslationIdle(),
        TranslationInProgress(phase: TranslationPhase.translating),
        TranslationSuccess(
          TranslationResult(
            originalText: 'a',
            translatedText: 'b',
            sourceLanguage: TranslationLanguages.english,
            targetLanguage: TranslationLanguages.hindi,
            scope: TranslationScope.selection,
          ),
        ),
        TranslationFailure(message: 'x'),
      ];
      expect(states.length, 4);
    });
  });
}
