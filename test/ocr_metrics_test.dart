import 'package:flutter_test/flutter_test.dart';
import 'package:pdf_utility_flutter/benchmark/domain/ocr_metrics.dart';

void main() {
  group('normalize', () {
    test('collapses runs of whitespace and trims the ends', () {
      expect(OcrMetrics.normalize('  a \n\n b\t c '), 'a b c');
    });

    test('treats non-breaking and ideographic spaces as whitespace', () {
      expect(OcrMetrics.normalize('a\u00A0b\u3000c'), 'a b c');
    });

    test('drops characters that carry no visual content', () {
      expect(OcrMetrics.normalize('a\u200Bb\uFEFFc\u200Ed\u00ADe'), 'abcde');
    });

    test('keeps ZWJ, because it changes a Devanagari conjunct', () {
      // Dropping it would make two different clusters compare equal.
      expect(OcrMetrics.normalize('क्\u200Dष'), 'क्\u200Dष');
    });

    test('does not fold case', () {
      expect(OcrMetrics.normalize('Hello World'), 'Hello World');
    });
  });

  group('character error rate', () {
    test('is zero for identical text', () {
      expect(
        OcrMetrics.characterErrorRate(reference: 'hello', hypothesis: 'hello'),
        0,
      );
    });

    test('ignores differences that are only line wrapping or spacing', () {
      // The whole point of normalizing: an engine that wraps a line differently
      // did not misread anything.
      expect(
        OcrMetrics.characterErrorRate(
          reference: 'hello world',
          hypothesis: '  hello\nworld  ',
        ),
        0,
      );
    });

    test('counts a single substitution over the reference length', () {
      expect(
        OcrMetrics.characterErrorRate(reference: 'hello', hypothesis: 'hallo'),
        closeTo(0.2, 1e-9),
      );
    });

    test('counts a deletion over the reference length', () {
      expect(
        OcrMetrics.characterErrorRate(reference: 'hello', hypothesis: 'hell'),
        closeTo(0.2, 1e-9),
      );
    });

    test('is not clamped, so catastrophic output stands out', () {
      expect(
        OcrMetrics.characterErrorRate(
          reference: 'ab',
          hypothesis: 'abcdefghij',
        ),
        greaterThan(1),
      );
    });

    test('scores an empty reference as perfect only against an empty read', () {
      expect(OcrMetrics.characterErrorRate(reference: '', hypothesis: 'x'), 1);
      expect(OcrMetrics.characterErrorRate(reference: '', hypothesis: ''), 0);
    });

    test('counts code points, not UTF-16 code units', () {
      // '😀a' is two code points. Deleting the emoji is one error out of two,
      // which code-unit counting would report as 1/3.
      expect(
        OcrMetrics.characterErrorRate(reference: '😀a', hypothesis: 'a'),
        closeTo(0.5, 1e-9),
      );
    });

    test('scores Devanagari matras as their own code points', () {
      // 'कि' is base + vowel sign; dropping the sign is one error out of two.
      expect(
        OcrMetrics.characterErrorRate(reference: 'कि', hypothesis: 'क'),
        closeTo(0.5, 1e-9),
      );
    });
  });

  group('word error rate', () {
    test('is zero for identical words', () {
      expect(
        OcrMetrics.wordErrorRate(reference: 'one two', hypothesis: 'one two'),
        0,
      );
    });

    test('counts a substitution over the reference word count', () {
      expect(
        OcrMetrics.wordErrorRate(reference: 'one two', hypothesis: 'one too'),
        closeTo(0.5, 1e-9),
      );
    });

    test('counts an inserted word', () {
      expect(
        OcrMetrics.wordErrorRate(
          reference: 'one two',
          hypothesis: 'one two three',
        ),
        closeTo(0.5, 1e-9),
      );
    });

    test('ignores line breaks between the same words', () {
      expect(
        OcrMetrics.wordErrorRate(reference: 'one\ntwo', hypothesis: 'one two'),
        0,
      );
    });
  });

  group('latency summary', () {
    test('reports nothing at all for an empty set', () {
      expect(LatencySummary.fromDurations(const []), isNull);
    });

    test('takes the middle value for an odd count', () {
      final summary = LatencySummary.fromDurations(const [
        Duration(milliseconds: 300),
        Duration(milliseconds: 100),
        Duration(milliseconds: 200),
      ])!;

      expect(summary.count, 3);
      expect(summary.min.inMilliseconds, 100);
      expect(summary.median.inMilliseconds, 200);
      expect(summary.max.inMilliseconds, 300);
    });

    test('averages the middle pair for an even count', () {
      final summary = LatencySummary.fromDurations(const [
        Duration(milliseconds: 100),
        Duration(milliseconds: 200),
      ])!;

      expect(summary.median.inMilliseconds, 150);
    });

    test('p95 is an actually observed value, not an interpolation', () {
      final summary = LatencySummary.fromDurations([
        for (var i = 1; i <= 20; i++) Duration(milliseconds: i * 10),
      ])!;

      // Nearest rank for 20 samples at p95 is the 19th value.
      expect(summary.p95.inMilliseconds, 190);
      expect(summary.max.inMilliseconds, 200);
    });
  });
}
