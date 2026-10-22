import 'package:flutter_test/flutter_test.dart';
import 'package:pdf_utility_flutter/ocr/domain/ocr_block.dart';
import 'package:pdf_utility_flutter/ocr/domain/ocr_element.dart';
import 'package:pdf_utility_flutter/ocr/domain/ocr_line.dart';
import 'package:pdf_utility_flutter/ocr/domain/ocr_rect.dart';
import 'package:pdf_utility_flutter/ocr/domain/ocr_result.dart';
import 'package:pdf_utility_flutter/ocr/domain/ocr_script_detector.dart';

/// Builds a result whose lines are laid out down the page, so vertical coverage
/// is realistic rather than a single line pinned to the top.
OcrResult _result(
  String text, {
  double firstTopPercent = 0.05,
  double lineSpacing = 0.3,
  int imageHeight = 1000,
  bool withLines = true,
}) {
  final rawLines = [
    for (final line in text.split('\n'))
      if (line.trim().isNotEmpty) line,
  ];
  final lines = <OcrLine>[];
  if (withLines) {
    for (var i = 0; i < rawLines.length; i++) {
      final top = firstTopPercent * imageHeight + i * lineSpacing * imageHeight;
      lines.add(
        OcrLine(
          text: rawLines[i],
          boundingBox: OcrRect.fromLTRB(50, top, 950, top + 40),
          elements: const <OcrElement>[],
        ),
      );
    }
  }
  return OcrResult(
    sourceImage: SourceImageInfo(
      path: '/tmp/does-not-exist.jpg',
      width: 1000,
      height: imageHeight,
    ),
    fullText: text,
    blocks: [
      OcrBlock(
        text: text,
        boundingBox: OcrRect.fromLTRB(0, 0, 1000, imageHeight.toDouble()),
        lines: lines,
      ),
    ],
  );
}

/// Three sentences of solid English, spread down the page.
const _english =
    'The quick brown fox jumps over the lazy dog\n'
    'and then it rests for a while in the cool shade\n'
    'of the tall tree beside the quiet river bank';

/// Two lines of Devanagari.
const _hindi =
    'यह एक हिन्दी वाक्य है और इसमें बहुत सारे अक्षर हैं\n'
    'दूसरी पंक्ति में भी पर्याप्त अक्षर मौजूद हैं';

/// What a model that cannot read the page emits: symbols, never words.
const _garbage = '||| ### £££ ... :: %% ~~ ^^';

/// A long English sentence, used where a *substantial* read is needed.
const _longEnglish =
    'The quick brown fox jumps over the lazy dog and keeps '
    'running through the wide green field for a very long time indeed';

void main() {
  const detector = OcrScriptDetector();

  group('assess', () {
    test('no text at all is empty', () {
      expect(detector.assess(_result('')).verdict, ScriptVerdict.empty);
      expect(detector.assess(_result('   \n  ')).verdict, ScriptVerdict.empty);
    });

    test('English prose is a confident Latin read', () {
      final assessment = detector.assess(_result(_english));
      expect(assessment.verdict, ScriptVerdict.latin);
      expect(assessment.letterRatio, greaterThan(0.8));
      expect(assessment.wordsWithLetters, greaterThanOrEqualTo(3));
    });

    test('Hindi text is detected as Devanagari, not as garbage', () {
      final assessment = detector.assess(_result(_hindi));
      expect(assessment.verdict, ScriptVerdict.devanagari);
      expect(assessment.devanagariLetters, greaterThan(10));
      expect(assessment.latinLetters, 0);
    });

    test('a mostly-English line with a little Hindi is still Devanagari', () {
      // The Devanagari model is the only one that can emit these code points, so
      // their presence outweighs the surrounding Latin.
      final assessment = detector.assess(
        _result('Invoice number यह एक हिन्दी है total', lineSpacing: 0),
      );
      expect(assessment.verdict, ScriptVerdict.devanagari);
    });

    test('symbol noise is weak, not Latin', () {
      final assessment = detector.assess(_result(_garbage, lineSpacing: 0));
      expect(assessment.verdict, ScriptVerdict.weak);
      expect(assessment.latinLetters, 0);
    });

    test('letters buried in symbols are weak, not Latin', () {
      final assessment = detector.assess(
        _result('a|b|c|d|e|f|g|h|i|j|k|l|m|n', lineSpacing: 0),
      );
      expect(assessment.letters, greaterThanOrEqualTo(12));
      expect(assessment.letterRatio, lessThan(0.6));
      expect(assessment.verdict, ScriptVerdict.weak);
    });

    test('a very short Latin snippet is weak, so Auto will look further', () {
      // Below the word and letter floors: a street sign should not be treated as
      // proof that the whole page is Latin.
      expect(
        detector.assess(_result('Exit', lineSpacing: 0)).verdict,
        ScriptVerdict.weak,
      );
      expect(
        detector.assess(_result('Hello there', lineSpacing: 0)).verdict,
        ScriptVerdict.weak,
      );
    });

    test('Devanagari punctuation alone is not a Devanagari page', () {
      // Danda and double danda are punctuation; counting them would let a Latin
      // page with a stray mark be routed to the Hindi recognizer.
      final assessment = detector.assess(_result('। ॥', lineSpacing: 0));
      expect(assessment.devanagariLetters, 0);
      expect(assessment.verdict, ScriptVerdict.weak);
    });

    test('Devanagari digits count as digits, not as letters', () {
      final assessment = detector.assess(_result('१२३४५', lineSpacing: 0));
      expect(assessment.digits, 5);
      expect(assessment.letters, 0);
      expect(assessment.verdict, ScriptVerdict.weak);
    });

    test('falls back to lines when fullText is empty', () {
      final result = _result(_english);
      final noFullText = OcrResult(
        sourceImage: result.sourceImage,
        fullText: '',
        blocks: result.blocks,
      );
      expect(detector.assess(noFullText).verdict, ScriptVerdict.latin);
    });
  });

  group('page coverage', () {
    test('a full-page English read spans most of the image', () {
      final assessment = detector.assess(_result(_english));
      expect(assessment.verticalCoverage, greaterThan(0.5));
      expect(assessment.weakLineRatio, 0);
    });

    test('one clean line at the top of the page is not the whole page', () {
      final assessment = detector.assess(
        _result(
          'This page has a single heading line at the very top',
          lineSpacing: 0,
        ),
      );
      // The text itself is perfectly good Latin...
      expect(assessment.verdict, ScriptVerdict.latin);
      // ...but it explains 4 % of the page, which is exactly the shape of a
      // Hindi document with an English heading.
      expect(assessment.verticalCoverage, lessThan(0.3));
    });

    test('a page read everywhere but badly in places is not decisive', () {
      // Two big paragraphs plus three unreadable regions: the ratios still look
      // Latin because the good text dominates, but the page was not fully read.
      final text = '$_longEnglish\n$_longEnglish\n||| ###\n%%% ~~~\n^^^ @@';
      final assessment = detector.assess(_result(text));

      expect(assessment.verdict, ScriptVerdict.latin);
      expect(assessment.weakLineRatio, greaterThan(0.5));
      expect(detector.probeIsDecisive(assessment), isFalse);
    });

    test('a result with no structured lines cannot be judged per line', () {
      final assessment = detector.assess(_result(_english, withLines: false));
      expect(assessment.verticalCoverage, 0);
      expect(assessment.weakLineRatio, 1);
    });
  });

  group('probeIsDecisive', () {
    test('a confident, page-covering Latin read settles the question', () {
      expect(
        detector.probeIsDecisive(detector.assess(_result(_english))),
        isTrue,
      );
    });

    test('nothing weaker than that does', () {
      for (final text in <String>[
        '',
        'Exit',
        _garbage,
        _hindi,
        'This page has a single heading line at the very top',
      ]) {
        expect(
          detector.probeIsDecisive(
            detector.assess(_result(text, lineSpacing: 0)),
          ),
          isFalse,
          reason: 'a probe for "$text" must not be decisive on its own',
        );
      }
    });
  });

  group('resolve', () {
    test('Devanagari plus real Latin means a genuinely mixed page', () {
      final decision = detector.resolve(
        probe: detector.assess(_result(_english)),
        secondary: detector.assess(_result(_hindi)),
      );
      expect(decision.outcome, AutoScriptOutcome.merge);
    });

    test('Devanagari over an empty probe needs no merge', () {
      final decision = detector.resolve(
        probe: detector.assess(_result('')),
        secondary: detector.assess(_result(_hindi)),
      );
      expect(decision.outcome, AutoScriptOutcome.useSecondary);
    });

    test('a letterless probe is discarded rather than merged in', () {
      // Symbol soup carries nothing worth keeping, and merging it would only
      // add junk lines to a page the Devanagari model read correctly.
      final decision = detector.resolve(
        probe: detector.assess(_result(_garbage, lineSpacing: 0)),
        secondary: detector.assess(_result(_hindi)),
      );
      expect(decision.outcome, AutoScriptOutcome.useSecondary);
    });

    test('a small but real Latin read is merged, not discarded', () {
      // "Quarterly Report" is too short to satisfy the Latin thresholds, yet it
      // is real text the Devanagari model cannot see. Discarding it would lose
      // the heading from an otherwise Hindi page.
      final heading = detector.assess(
        _result('Quarterly Report', lineSpacing: 0),
      );
      expect(heading.verdict, ScriptVerdict.weak);
      expect(heading.hasAnyLetters, isTrue);

      final decision = detector.resolve(
        probe: heading,
        secondary: detector.assess(_result(_hindi)),
      );
      expect(decision.outcome, AutoScriptOutcome.merge);
    });

    test('the richer pass wins when neither is Devanagari', () {
      final moreLatin = detector.resolve(
        probe: detector.assess(_result(_english)),
        secondary: detector.assess(_result('abc def ghi', lineSpacing: 0)),
      );
      expect(moreLatin.outcome, AutoScriptOutcome.useProbe);

      final moreOther = detector.resolve(
        probe: detector.assess(_result('abc def ghi', lineSpacing: 0)),
        secondary: detector.assess(_result(_english)),
      );
      expect(moreOther.outcome, AutoScriptOutcome.useSecondary);
    });

    test('two empty passes fall back to the probe', () {
      final decision = detector.resolve(
        probe: detector.assess(_result('')),
        secondary: detector.assess(_result('')),
      );
      expect(decision.outcome, AutoScriptOutcome.useProbe);
    });

    test('every decision carries a reason', () {
      final decision = detector.resolve(
        probe: detector.assess(_result(_english)),
        secondary: detector.assess(_result(_hindi)),
      );
      expect(decision.reason, isNotEmpty);
    });
  });
}
