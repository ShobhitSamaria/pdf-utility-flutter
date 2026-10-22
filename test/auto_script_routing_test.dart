import 'package:flutter_test/flutter_test.dart';
import 'package:pdf_utility_flutter/ocr/data/bounded_ocr_service.dart';
import 'package:pdf_utility_flutter/ocr/data/local_ocr_service.dart';
import 'package:pdf_utility_flutter/ocr/domain/ocr_block.dart';
import 'package:pdf_utility_flutter/ocr/domain/ocr_element.dart';
import 'package:pdf_utility_flutter/ocr/domain/ocr_engine.dart';
import 'package:pdf_utility_flutter/ocr/domain/ocr_exception.dart';
import 'package:pdf_utility_flutter/ocr/domain/ocr_line.dart';
import 'package:pdf_utility_flutter/ocr/domain/ocr_rect.dart';
import 'package:pdf_utility_flutter/ocr/domain/ocr_result.dart';
import 'package:pdf_utility_flutter/ocr/domain/ocr_script_mode.dart';
import 'package:pdf_utility_flutter/ocr/domain/ocr_service.dart';

/// An engine that answers the Latin pass normally and fails the Devanagari one,
/// which is what a build without the Hindi model (or a device where that
/// recognizer cannot start) looks like from the service's point of view.
class _FailingDevanagariEngine implements OcrEngine {
  _FailingDevanagariEngine({required this.latin});

  final OcrResult latin;
  final List<OcrScript> calls = <OcrScript>[];

  @override
  String get name => 'Scripted';

  @override
  Future<OcrResult> recognize({
    required String imagePath,
    OcrOptions options = const OcrOptions(),
  }) async {
    calls.add(options.script);
    if (options.script == OcrScript.devanagari) {
      throw const OcrException(
        OcrErrorKind.engineUnavailable,
        'Text recognition is not available in this build of the app.',
      );
    }
    return latin;
  }

  @override
  Future<void> dispose() async {}
}

/// An engine whose answer depends only on which script it was asked for, and
/// which records every call so a test can assert how many passes actually ran.
class _ScriptedEngine implements OcrEngine {
  _ScriptedEngine({required this.byScript});

  final Map<OcrScript, OcrResult> byScript;
  final List<OcrScript> calls = <OcrScript>[];

  @override
  String get name => 'Scripted';

  @override
  Future<OcrResult> recognize({
    required String imagePath,
    OcrOptions options = const OcrOptions(),
  }) async {
    calls.add(options.script);
    return byScript[options.script] ?? _result('', path: imagePath);
  }

  @override
  Future<void> dispose() async {}
}

/// Builds a result whose lines are laid out down the page, so vertical coverage
/// is realistic: [firstTopPercent] places the first line, and each subsequent
/// line is [lineSpacing] pixels lower.
OcrResult _result(
  String text, {
  String path = '/tmp/does-not-exist.jpg',
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
    sourceImage: SourceImageInfo(path: path, width: 1000, height: imageHeight),
    fullText: text,
    blocks: [
      OcrBlock(
        text: text,
        boundingBox: OcrRect.fromLTRB(0, 0, 1000, imageHeight.toDouble()),
        lines: lines,
      ),
    ],
    // What a real engine reports about itself; the service only relabels the
    // results Auto routed.
    engineName: 'Scripted',
  );
}

/// Three full-line English sentences, laid out down the page.
const _english =
    'The quick brown fox jumps over the lazy dog\n'
    'and then it rests for a while in the cool shade\n'
    'of the tall tree beside the quiet river bank';

/// Two Hindi sentences in Devanagari.
const _hindi =
    'यह एक हिन्दी वाक्य है और इसमें बहुत सारे अक्षर हैं\n'
    'दूसरी पंक्ति में भी पर्याप्त अक्षर मौजूद हैं';

/// What a model that cannot read the page emits: symbols, not words.
const _garbage = '||| ### £££ ... :: %% ~~ ^^';

LocalOcrService _service(OcrEngine engine) => LocalOcrService(engine: engine);

void main() {
  group('mode vocabulary', () {
    test('Auto is the default and the manual modes remain overrides', () {
      expect(OcrScriptMode.defaultMode, OcrScriptMode.auto);
      expect(OcrScriptMode.auto.isAuto, isTrue);
      expect(OcrScriptMode.manualModes, hasLength(3));
      expect(OcrScriptMode.manualModes, isNot(contains(OcrScriptMode.auto)));
    });

    test('Auto may read twice, so it is not given a single-pass budget', () {
      expect(OcrScriptMode.auto.mayReadTwice, isTrue);
      expect(OcrScriptMode.mixed.mayReadTwice, isTrue);
      expect(OcrScriptMode.latin.mayReadTwice, isFalse);
      expect(OcrScriptMode.devanagari.mayReadTwice, isFalse);
    });

    test('the time budget follows mayReadTwice, not isMixed', () {
      final bounded = BoundedOcrService(
        delegate: _service(_ScriptedEngine(byScript: {})),
        timeout: const Duration(seconds: 10),
      );
      // One budget for two passes would turn a healthy Hindi page into a
      // timeout, because Auto's probe pass is not free.
      expect(bounded.budgetFor(OcrScriptMode.auto).inSeconds, 20);
      expect(bounded.budgetFor(OcrScriptMode.mixed).inSeconds, 20);
      expect(bounded.budgetFor(OcrScriptMode.latin).inSeconds, 10);
      expect(bounded.budgetFor(OcrScriptMode.devanagari).inSeconds, 10);
    });
  });

  group('Auto routing', () {
    test('a full English page is read once, by the Latin recognizer', () async {
      final engine = _ScriptedEngine(
        byScript: {OcrScript.latin: _result(_english)},
      );

      final result = await _service(
        engine,
      ).recognizeImage('/tmp/page.jpg', mode: OcrScriptMode.auto);

      // The whole point of Auto: the common case costs exactly what the old
      // Latin default cost.
      expect(engine.calls, <OcrScript>[OcrScript.latin]);
      expect(result.fullText, _english);
      expect(result.engineName, contains('Auto → Latin'));
    });

    test('a Hindi page is routed to the Devanagari recognizer', () async {
      final engine = _ScriptedEngine(
        byScript: {
          OcrScript.latin: _result(_garbage),
          OcrScript.devanagari: _result(_hindi),
        },
      );

      final result = await _service(
        engine,
      ).recognizeImage('/tmp/page.jpg', mode: OcrScriptMode.auto);

      expect(engine.calls, <OcrScript>[OcrScript.latin, OcrScript.devanagari]);
      expect(result.fullText, _hindi);
      expect(result.engineName, contains('Auto → Devanagari'));
    });

    test('a Hindi page the Latin model could not read at all', () async {
      final engine = _ScriptedEngine(
        byScript: {
          OcrScript.latin: _result(''),
          OcrScript.devanagari: _result(_hindi),
        },
      );

      final result = await _service(
        engine,
      ).recognizeImage('/tmp/page.jpg', mode: OcrScriptMode.auto);

      expect(engine.calls, <OcrScript>[OcrScript.latin, OcrScript.devanagari]);
      expect(result.fullText, _hindi);
      expect(result.engineName, contains('Auto → Devanagari'));
    });

    test(
      'a Hindi page with an English heading is still routed correctly',
      () async {
        // The trap: the Latin probe reads the heading perfectly, so every
        // text-based ratio looks healthy while most of the page is unread.
        final engine = _ScriptedEngine(
          byScript: {
            OcrScript.latin: _result(
              'Quarterly Report',
              // One line near the top: strong text, almost no page coverage.
              firstTopPercent: 0.05,
              lineSpacing: 0,
            ),
            // The Hindi body sits below the heading, where it really would be.
            OcrScript.devanagari: _result(_hindi, firstTopPercent: 0.4),
          },
        );

        final result = await _service(
          engine,
        ).recognizeImage('/tmp/page.jpg', mode: OcrScriptMode.auto);

        expect(engine.calls, <OcrScript>[
          OcrScript.latin,
          OcrScript.devanagari,
        ]);
        // Mixed page: the English heading survives alongside the Hindi body.
        expect(result.engineName, contains('Auto → Latin + Devanagari'));
        expect(result.fullText, contains('Quarterly Report'));
        expect(result.fullText, contains('हिन्दी'));
        // One block per line, and no line duplicated by the second pass.
        expect(result.blocks, hasLength(3));
      },
    );

    test(
      'a Latin line over a Hindi region is replaced, not duplicated',
      () async {
        // The case the merge exists for: the Latin model reads a Hindi line as
        // plausible-looking Latin nonsense, at the same coordinates. The region
        // gets exactly one winner — the reading with Devanagari in it — so no
        // overlapping duplicate is ever produced.
        final engine = _ScriptedEngine(
          byScript: {
            OcrScript.latin: _result(
              'Hindi line read as Latin gibberish here',
              firstTopPercent: 0.05,
              lineSpacing: 0.3,
            ),
            OcrScript.devanagari: _result(_hindi, firstTopPercent: 0.05),
          },
        );

        final result = await _service(
          engine,
        ).recognizeImage('/tmp/page.jpg', mode: OcrScriptMode.auto);

        expect(result.engineName, contains('Auto → Latin + Devanagari'));
        // Only the two Hindi lines survive: no Latin gibberish, no duplicates.
        expect(result.blocks, hasLength(2));
        expect(result.fullText, isNot(contains('gibberish')));
        expect(result.fullText, _hindi);
      },
    );

    test(
      'an uncertain page keeps the richer read and reports total time',
      () async {
        final engine = _ScriptedEngine(
          byScript: {
            // Neither pass is confident: the probe read a little more than the
            // Devanagari pass did, so the probe must win.
            OcrScript.latin: _result('abc def ghi jkl mno', lineSpacing: 0),
            OcrScript.devanagari: _result('abc', lineSpacing: 0),
          },
        );

        final result = await _service(
          engine,
        ).recognizeImage('/tmp/page.jpg', mode: OcrScriptMode.auto);

        expect(engine.calls, <OcrScript>[
          OcrScript.latin,
          OcrScript.devanagari,
        ]);
        expect(result.fullText, 'abc def ghi jkl mno');
        // Both passes are billed to the result, so the latency is visible rather
        // than reported as one pass.
        expect(result.elapsed, isNotNull);
      },
    );

    test(
      'an unreadable photo returns an empty result instead of throwing',
      () async {
        final engine = _ScriptedEngine(
          byScript: {
            OcrScript.latin: _result(''),
            OcrScript.devanagari: _result(''),
          },
        );

        final result = await _service(
          engine,
        ).recognizeImage('/tmp/page.jpg', mode: OcrScriptMode.auto);

        expect(engine.calls, <OcrScript>[
          OcrScript.latin,
          OcrScript.devanagari,
        ]);
        expect(result.fullText, isEmpty);
        expect(result.engineName, contains('Auto → Latin'));
      },
    );

    test(
      'a result with text but no line geometry is not trusted alone',
      () async {
        // Coverage and per-line judgement are both unknowable here, so Auto looks
        // again rather than declaring the page Latin on a ratio alone.
        final engine = _ScriptedEngine(
          byScript: {
            OcrScript.latin: _result(_english, withLines: false),
            OcrScript.devanagari: _result(''),
          },
        );

        final result = await _service(
          engine,
        ).recognizeImage('/tmp/page.jpg', mode: OcrScriptMode.auto);

        expect(engine.calls, <OcrScript>[
          OcrScript.latin,
          OcrScript.devanagari,
        ]);
        // Fallback safety: the extra pass cost time but not accuracy.
        expect(result.fullText, _english);
      },
    );
  });

  group('manual overrides are unchanged', () {
    test('Latin is one pass and never probes', () async {
      final engine = _ScriptedEngine(
        byScript: {OcrScript.latin: _result(_garbage)},
      );

      final result = await _service(
        engine,
      ).recognizeImage('/tmp/page.jpg', mode: OcrScriptMode.latin);

      expect(engine.calls, <OcrScript>[OcrScript.latin]);
      expect(result.engineName, 'Scripted');
    });

    test('Devanagari is one pass and never probes', () async {
      final engine = _ScriptedEngine(
        byScript: {OcrScript.devanagari: _result(_hindi)},
      );

      final result = await _service(
        engine,
      ).recognizeImage('/tmp/page.jpg', mode: OcrScriptMode.devanagari);

      expect(engine.calls, <OcrScript>[OcrScript.devanagari]);
      expect(result.engineName, 'Scripted');
    });
  });

  group('when the second pass cannot run', () {
    // The default mode is Auto, so this is the path every photo, gallery image
    // and imported PDF page takes. A page the Latin probe read but could not
    // settle used to fail entirely if the Devanagari recognizer was missing —
    // and, because Auto retries the same second pass on every such page, the
    // same "Text recognition failed" appeared from every entry point.
    test('a usable Latin probe is kept, and labelled as the Latin read', () async {
      // Three words on one line: enough letters to be real text, far too little
      // page coverage for the probe to be decisive, so the second pass runs.
      final engine = _FailingDevanagariEngine(
        latin: _result('Short line here'),
      );
      final result = await _service(
        engine,
      ).recognizeImage('/tmp/page.jpg', mode: OcrScriptMode.auto);

      expect(engine.calls, <OcrScript>[OcrScript.latin, OcrScript.devanagari]);
      // The text is exactly what the recognizer read — not invented, not empty.
      expect(result.fullText, 'Short line here');
      expect(result.engineName, contains('Auto → Latin'));
    });

    test('with nothing read at all, the failure is still reported', () async {
      final engine = _FailingDevanagariEngine(latin: _result(''));

      await expectLater(
        _service(
          engine,
        ).recognizeImage('/tmp/page.jpg', mode: OcrScriptMode.auto),
        throwsA(
          isA<OcrException>().having(
            (error) => error.kind,
            'kind',
            OcrErrorKind.engineUnavailable,
          ),
        ),
      );
    });
  });

  test('the service is an OcrService, so the UI seam still holds', () {
    expect(_service(_ScriptedEngine(byScript: {})), isA<OcrService>());
  });
}
