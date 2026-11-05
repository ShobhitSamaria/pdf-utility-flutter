import 'dart:convert';
import 'dart:io';

import 'package:pdf_utility_flutter/ocr/domain/ocr_block.dart';
import 'package:pdf_utility_flutter/ocr/domain/ocr_line.dart';
import 'package:pdf_utility_flutter/ocr/domain/ocr_rect.dart';
import 'package:pdf_utility_flutter/ocr/domain/ocr_result.dart';

/// Rebuilds a real recognition result from a fixture recorded on a device.
///
/// The fixture is the verbatim output of Google ML Kit for one photograph, so a
/// plain `flutter test` run can exercise the layout and merge rules against
/// geometry and text the engine actually produced — including its block
/// boundaries — instead of against rectangles a test invented.
class RecordedPage {
  RecordedPage({
    required this.imagePath,
    required this.width,
    required this.height,
    required Map<String, OcrResult> passes,
  }) : passes = Map<String, OcrResult>.unmodifiable(passes);

  /// Photograph the recording was made from, relative to the package root.
  final String imagePath;

  final int width;
  final int height;

  /// One [OcrResult] per script pass, keyed by the fixture's pass name
  /// (`devanagari`, `latin`).
  final Map<String, OcrResult> passes;

  OcrResult operator [](String pass) {
    final result = passes[pass];
    if (result == null) {
      throw ArgumentError.value(pass, 'pass', 'no such recorded pass');
    }
    return result;
  }

  static RecordedPage load(String path) {
    final decoded = jsonDecode(File(path).readAsStringSync());
    if (decoded is! Map<String, dynamic>) {
      throw FormatException('recorded fixture is not an object', path);
    }
    final source = decoded['sourceImage'] as Map<String, dynamic>;
    final imagePath =
        (decoded['provenance'] as Map<String, dynamic>)['image'] as String;
    final rawPasses = decoded['passes'] as Map<String, dynamic>;
    final width = source['width'] as int;
    final height = source['height'] as int;

    final passes = <String, OcrResult>{};
    for (final entry in rawPasses.entries) {
      final blocks = <OcrBlock>[];
      for (final rawBlock in entry.value['blocks'] as List<dynamic>) {
        final lines = <OcrLine>[
          for (final rawLine in rawBlock['lines'] as List<dynamic>)
            OcrLine(
              text: rawLine['text'] as String,
              boundingBox: _rect(rawLine['box'] as List<dynamic>),
              elements: const [],
            ),
        ];
        blocks.add(
          OcrBlock(
            text: lines.map((line) => line.text).join('\n'),
            boundingBox: _rect(rawBlock['box'] as List<dynamic>),
            lines: List<OcrLine>.unmodifiable(lines),
          ),
        );
      }
      passes[entry.key] = OcrResult(
        sourceImage: SourceImageInfo(
          path: imagePath,
          width: width,
          height: height,
        ),
        fullText: blocks.map((block) => block.text).join('\n'),
        blocks: blocks,
        engineName: entry.value['engineName'] as String,
      );
    }

    return RecordedPage(
      imagePath: imagePath,
      width: width,
      height: height,
      passes: passes,
    );
  }

  static OcrRect _rect(List<dynamic> box) {
    final left = (box[0] as num).toDouble();
    final top = (box[1] as num).toDouble();
    return OcrRect.fromLTRB(
      left,
      top,
      left + (box[2] as num).toDouble(),
      top + (box[3] as num).toDouble(),
    );
  }
}

/// The fixture recorded from the three-column Hindi newspaper page.
const recordedNewspaperFixture =
    'test/fixtures/ocr/newspaper_hindi_three_columns.json';

/// The fixture recorded from the second newspaper page: a photograph and a
/// story at the top, a spanning headline, one wide body column and a boxed
/// sidebar.
const recordedSecondPageFixture = 'test/fixtures/ocr/second_page.json';
