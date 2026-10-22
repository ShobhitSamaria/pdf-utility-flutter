import 'package:flutter_test/flutter_test.dart';
import 'package:pdf_utility_flutter/translation/domain/translation_language.dart';
import 'package:pdf_utility_flutter/translation/domain/translation_model_state.dart';

void main() {
  const hindi = TranslationLanguages.hindi;

  group('TranslationModelState', () {
    test('available is translatable right now', () {
      const state = TranslationModelState.available(hindi);
      expect(state.isAvailable, isTrue);
      expect(state.needsProvisioning, isFalse);
      expect(state.isUnsupported, isFalse);
      expect(state.isFailed, isFalse);
    });

    test('notAvailable has to be provisioned first', () {
      const state = TranslationModelState(
        language: hindi,
        status: TranslationModelStatus.notAvailable,
      );
      expect(state.isAvailable, isFalse);
      expect(state.needsProvisioning, isTrue);
    });

    test('unknown also counts as needing provisioning (give it a try)', () {
      const state = TranslationModelState.unknown(hindi);
      expect(state.status, TranslationModelStatus.unknown);
      expect(state.needsProvisioning, isTrue);
      expect(state.isAvailable, isFalse);
    });

    test('unsupported and failed are distinguishable', () {
      const unsupported = TranslationModelState(
        language: hindi,
        status: TranslationModelStatus.unsupported,
      );
      const failed = TranslationModelState(
        language: hindi,
        status: TranslationModelStatus.failed,
        message: 'boom',
      );
      expect(unsupported.isUnsupported, isTrue);
      expect(unsupported.needsProvisioning, isFalse);
      expect(failed.isFailed, isTrue);
      expect(failed.message, 'boom');
    });

    test('downloading is neither available nor a failure', () {
      const state = TranslationModelState(
        language: hindi,
        status: TranslationModelStatus.downloading,
      );
      expect(state.isAvailable, isFalse);
      expect(state.isFailed, isFalse);
      expect(state.isUnsupported, isFalse);
    });

    test('copyWith and equality', () {
      const a = TranslationModelState.unknown(hindi);
      final b = a.copyWith(status: TranslationModelStatus.available);
      expect(b.status, TranslationModelStatus.available);
      expect(b.language, hindi);
      expect(a == b, isFalse);
      expect(a == a.copyWith(), isTrue);
      expect(a.hashCode, a.copyWith().hashCode);
    });
  });

  group('TranslationProgress', () {
    test('carries the phase and optional language', () {
      const progress = TranslationProgress(
        TranslationPhase.preparingModel,
        language: hindi,
      );
      expect(progress.phase, TranslationPhase.preparingModel);
      expect(progress.language, hindi);
      expect(progress.toString(), contains('preparingModel'));
    });

    test('language is optional', () {
      const progress = TranslationProgress(TranslationPhase.detectingLanguage);
      expect(progress.language, isNull);
      expect(progress.toString(), contains('detectingLanguage'));
    });
  });
}
