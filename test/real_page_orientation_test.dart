import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdf_utility_flutter/ocr/data/image_decoder.dart';
import 'package:pdf_utility_flutter/ocr/data/image_rotator.dart';
import 'package:pdf_utility_flutter/ocr/data/orientation_aware_ocr_service.dart';
import 'package:pdf_utility_flutter/ocr/domain/document_orientation.dart';
import 'package:pdf_utility_flutter/ocr/domain/ocr_block.dart';
import 'package:pdf_utility_flutter/ocr/domain/ocr_element.dart';
import 'package:pdf_utility_flutter/ocr/domain/ocr_line.dart';
import 'package:pdf_utility_flutter/ocr/domain/ocr_rect.dart';
import 'package:pdf_utility_flutter/ocr/domain/ocr_result.dart';
import 'package:pdf_utility_flutter/ocr/domain/ocr_script_mode.dart';
import 'package:pdf_utility_flutter/ocr/domain/ocr_service.dart';
import 'package:pdf_utility_flutter/ocr/presentation/ocr_coordinate_mapper.dart';
import 'package:pdf_utility_flutter/ocr/presentation/widgets/ocr_overlay.dart';
import 'package:pdf_utility_flutter/ocr/domain/ocr_selection.dart';

/// The page the user reported: a photograph of a printed Hindi notice, held
/// sideways. It is 899×1599 **portrait** pixels with no EXIF orientation, and
/// its *content* is rotated 90° clockwise inside them — the case that produced
/// tall, narrow OCR boxes and one-letter-per-line translations.
const _fixture = 'test/assets/real/newspaper_hindi_portrait.png';

/// Pixel size stored in the PNG, read from its `IHDR` chunk.
///
/// Deliberately parsed here rather than taken from a constant: the point of the
/// first test is that the dimensions the app decodes are the dimensions the
/// file actually contains, so nothing may be silently rotated on the way in.
({int width, int height}) _pngHeaderSize(String path) {
  final bytes = File(path).readAsBytesSync();
  expect(bytes.sublist(1, 4), <int>[0x50, 0x4e, 0x47], reason: 'not a PNG');
  final header = ByteData.sublistView(bytes, 16, 24);
  return (width: header.getUint32(0), height: header.getUint32(4));
}

/// One measured text line of the page, in the **upright** frame (1599×899).
///
/// These rectangles are not invented: they are the ink bands measured on this
/// page after it is stood up (row/column projection of the scanned pixels),
/// with the line text read off the page. They are recorded here as the fixture
/// the engine's coordinates are checked against — the app never sees them.
const _measuredLines =
    <({String text, double l, double t, double r, double b})>[
      (text: 'राजस्थान सरकार', l: 0, t: 0, r: 1598, b: 87),
      (text: 'जयपुर, दिनांक 21-10-2026 को', l: 739, t: 139, r: 882, b: 151),
      (
        text: 'कार्यालय जिला निर्वाचन अधिकारी (पंचायत एवं जिला परिषद) जयपुर',
        l: 0,
        t: 165,
        r: 1152,
        b: 185,
      ),
      (text: 'अद्यतन सूची 2026 के लिए', l: 487, t: 198, r: 1135, b: 215),
      (
        text: 'स्थानीय निकाय क्षेत्रीय निर्वाचन अधिकारी की अद्यतन सूची',
        l: 0,
        t: 221,
        r: 1054,
        b: 237,
      ),
      (
        text: 'मानव संसाधन / माध्यमिक शिक्षिका / एडमिट कार्ड',
        l: 89,
        t: 247,
        r: 1568,
        b: 265,
      ),
      (
        text: 'कुल पदों का विवरण, आवंटित कार्यालय',
        l: 0,
        t: 270,
        r: 1561,
        b: 288,
      ),
      (text: 'मानव संसाधन माध्यमिक शिक्षिका', l: 2, t: 318, r: 1572, b: 367),
      (text: 'प्रवेश शिक्षण', l: 45, t: 371, r: 1573, b: 379),
      (text: '357', l: 0, t: 400, r: 1576, b: 408),
      (
        text: '08:15AM बजे स्थानीय निकाय क्षेत्रीय',
        l: 42,
        t: 413,
        r: 1578,
        b: 427,
      ),
      (text: 'एडमिट कार्ड जारी किया जाएगा', l: 40, t: 438, r: 1581, b: 500),
      (text: 'किशोरगंज रेनवाल', l: 38, t: 511, r: 1581, b: 524),
    ];

/// The stored (sideways) frame's size.
const _storedSize = (width: 899, height: 1599);

/// The upright page's size.
const _uprightSize = (width: 1599, height: 899);

/// Maps a rectangle from the upright frame to the **stored** pixels.
///
/// Stored pixels are the upright page turned 90° clockwise, so a point `(x, y)`
/// lands at `(uprightHeight - y, x)`. This is the inverse of the correction the
/// app applies, which is why the fixture can be written once, upright, and used
/// to reconstruct exactly what the engine sees before the fix.
OcrRect _toStored(OcrRect box) {
  final xs = <double>[
    _uprightSize.height - box.top,
    _uprightSize.height - box.bottom,
  ];
  final ys = <double>[box.left, box.right];
  return OcrRect.fromLTRB(
    xs.reduce((a, b) => a < b ? a : b),
    ys.reduce((a, b) => a < b ? a : b),
    xs.reduce((a, b) => a > b ? a : b),
    ys.reduce((a, b) => a > b ? a : b),
  );
}

/// Splits a line box into [parts] words laid out left to right, with a small gap
/// between them, so a line has real word geometry to hit-test.
List<OcrElement> _wordsOf(String text, OcrRect box, {int parts = 3}) {
  final gap = box.width * 0.02;
  final step = (box.width - gap * (parts - 1)) / parts;
  final words = text.split(' ').where((word) => word.isNotEmpty).toList();
  return [
    for (var i = 0; i < parts; i++)
      OcrElement(
        text: i < words.length ? words[i] : '${i + 1}',
        boundingBox: OcrRect.fromLTRB(
          box.left + i * (step + gap),
          box.top,
          box.left + i * (step + gap) + step,
          box.bottom,
        ),
      ),
  ];
}

/// The page as the engine reports it **before** any correction: tall strips.
OcrResult _sidewaysRead() {
  final lines = [
    for (final line in _measuredLines)
      () {
        // Words are laid out along the reading direction on the **upright**
        // page and only then moved into the stored frame, which is exactly how
        // they appear to the engine: one below the next.
        final upright = OcrRect.fromLTRB(line.l, line.t, line.r, line.b);
        final elements = [
          for (final word in _wordsOf(line.text, upright))
            OcrElement(
              text: word.text,
              boundingBox: _toStored(word.boundingBox),
            ),
        ];
        return OcrLine(
          text: line.text,
          boundingBox: _toStored(upright),
          elements: elements,
          // Android's value for text lying on its side. The detector must not
          // depend on its sign, so this is only realistic colour.
          angle: 90,
        );
      }(),
  ];
  return OcrResult(
    sourceImage: const SourceImageInfo(
      path: _fixture,
      width: 899,
      height: 1599,
    ),
    fullText: lines.map((line) => line.text).join('\n'),
    blocks: [
      OcrBlock(
        text: lines.map((line) => line.text).join('\n'),
        boundingBox: OcrRect.fromLTRB(
          0,
          0,
          _storedSize.width.toDouble(),
          _storedSize.height.toDouble(),
        ),
        lines: lines,
      ),
    ],
  );
}

/// The same page, upright: what the second (corrected) read reports.
OcrResult _uprightRead({String path = _fixture}) {
  final lines = [
    for (final line in _measuredLines)
      () {
        final box = OcrRect.fromLTRB(line.l, line.t, line.r, line.b);
        return OcrLine(
          text: line.text,
          boundingBox: box,
          elements: _wordsOf(line.text, box),
          angle: 0,
        );
      }(),
  ];
  return OcrResult(
    sourceImage: SourceImageInfo(
      path: path,
      width: _uprightSize.width,
      height: _uprightSize.height,
    ),
    fullText: lines.map((line) => line.text).join('\n'),
    blocks: [
      OcrBlock(
        text: lines.map((line) => line.text).join('\n'),
        boundingBox: OcrRect.fromLTRB(
          0,
          0,
          _uprightSize.width.toDouble(),
          _uprightSize.height.toDouble(),
        ),
        lines: lines,
      ),
    ],
  );
}

/// An [OcrService] that answers from a fixed script, recording what it was
/// asked — so the test can see both passes and the path between them.
class _ScriptedService implements OcrService {
  _ScriptedService(this.answers);

  final List<OcrResult> answers;
  final List<String> paths = <String>[];

  @override
  String get engineName => 'scripted';

  @override
  Future<OcrResult> recognizeImage(
    String imagePath, {
    OcrScriptMode mode = OcrScriptMode.defaultMode,
  }) async {
    paths.add(imagePath);
    final answer = answers[paths.length - 1];
    // A real engine reports the file it was handed, so the fixture is stamped
    // with the path of the pass that produced it.
    return answer.copyWith(
      sourceImage: SourceImageInfo(
        path: imagePath,
        width: answer.sourceImage.width,
        height: answer.sourceImage.height,
      ),
    );
  }

  @override
  Future<void> dispose() async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('the reported photograph, measured', () {
    test('is 899×1599 portrait with no EXIF turn to apply', () async {
      final header = _pngHeaderSize(_fixture);
      expect(header, (width: 899, height: 1599));

      // The app's decoder must agree with the file: a portrait photograph that
      // decodes landscape is how the whole overlay ended up turned.
      final decoded = await const ImageDecoder().decodeDimensions(_fixture);
      expect(decoded.width, header.width);
      expect(decoded.height, header.height);
      expect(
        decoded.height,
        greaterThan(decoded.width),
        reason: 'the photograph is portrait and must stay portrait',
      );
      // A PNG with no orientation tag: the correction can only come from the
      // geometry of the text, never from metadata. (Flutter applies EXIF while
      // decoding, so a tagged file would decode to a *different* size here —
      // the equality above is what proves there was nothing to apply.)
      expect(File(_fixture).lengthSync(), greaterThan(10000));
    });

    test('the sideways read is tall strips, and the detector turns the page', () {
      final sideways = _sidewaysRead();
      final tall = sideways.lines.where(
        (line) => line.boundingBox.height > line.boundingBox.width,
      );
      expect(
        tall.length,
        sideways.lines.length,
        reason:
            'every line box in the stored pixels must be taller than wide — '
            'that is the geometry that squeezed translations into columns',
      );

      // The fix is a quarter turn anticlockwise, measured from the page itself.
      expect(
        const DocumentOrientationDetector().detect(sideways),
        const DocumentOrientation(3),
      );
    });
  });

  group('the correction, end to end', () {
    test('a sideways page is read again upright, and the image is kept', () async {
      late String rotatedPath;
      final service = OrientationAwareOcrService(
        inner: _ScriptedService([
          _sidewaysRead(),
          // The second read happens on the rotated copy; its path is stamped by
          // the scripted service, exactly as the real engine reports the file
          // it read.
          _uprightRead(),
          // The repeated run below is a second recognition of the *same*
          // sideways file, so it takes the same two passes again.
          _sidewaysRead(),
          _uprightRead(),
        ]),
        // The real rotator, on the real photograph: this is the code that runs
        // on the phone.
        rotator: const UiImageRotator(),
      );
      addTearDown(service.dispose);

      final result = await service.recognizeImage(_fixture);

      expect(result.wasRotated, isTrue);
      expect(result.orientation, const DocumentOrientation(3));
      expect(
        (result.sourceImage.width, result.sourceImage.height),
        (_uprightSize.width, _uprightSize.height),
        reason: 'the page is displayed upright, so it is landscape on screen',
      );

      rotatedPath = result.sourceImage.path;
      expect(rotatedPath, isNot(_fixture));
      expect(File(rotatedPath).existsSync(), isTrue);

      // The file the screen will show really is the rotated photograph.
      final dims = await const ImageDecoder().decodeDimensions(rotatedPath);
      expect(
        (dims.width, dims.height),
        (_uprightSize.width, _uprightSize.height),
      );

      // And its boxes are upright, not strips: a line is ~10× wider than tall.
      for (final line in result.lines) {
        expect(
          line.boundingBox.width / line.boundingBox.height,
          greaterThan(3),
          reason: 'line "${line.text}" is still a vertical strip',
        );
      }

      // Re-running the same page reuses one file instead of filling the cache.
      final again = await service.recognizeImage(_fixture);
      expect(again.sourceImage.path, rotatedPath);
    });

    test('an upright page is read once and never rotated', () async {
      final scripted = _ScriptedService([_uprightRead()]);
      final service = OrientationAwareOcrService(
        inner: scripted,
        rotator: const UiImageRotator(),
      );
      addTearDown(service.dispose);

      final result = await service.recognizeImage(_fixture);

      expect(result.wasRotated, isFalse);
      expect(scripted.paths, [_fixture], reason: 'no second pass, no copy');
      expect(result.sourceImage.path, _fixture);
    });
  });

  group('showing the corrected page', () {
    /// The size a phone gives the photo area.
    const viewports = <Size>[Size(360, 640), Size(411, 780), Size(780, 360)];

    for (final viewport in viewports) {
      testWidgets(
        'at ${viewport.width.toInt()}×${viewport.height.toInt()} the page keeps '
        'its aspect and every word is hit where it is drawn',
        (tester) async {
          final result = _uprightRead();
          final tapped = <String?>[];

          await tester.pumpWidget(
            MaterialApp(
              home: Scaffold(
                body: Center(
                  child: SizedBox.fromSize(
                    size: viewport,
                    child: OcrOverlay(
                      result: result,
                      selection: OcrSelection.empty(result),
                      onElementTap: (element) =>
                          tapped.add(element?.text.trim()),
                    ),
                  ),
                ),
              ),
            ),
          );
          await tester.pump();

          final overlayRect = tester.getRect(find.byType(OcrOverlay));
          final mapper = OcrCoordinateMapper(
            imageWidth: result.sourceImage.width,
            imageHeight: result.sourceImage.height,
            viewportSize: overlayRect.size,
          );

          // Landscape page: fitted, not stretched, and the whole page visible.
          expect(
            mapper.displayedSize.width / mapper.displayedSize.height,
            closeTo(_uprightSize.width / _uprightSize.height, 0.001),
          );
          expect(
            mapper.displayedSize.width,
            lessThanOrEqualTo(overlayRect.width + 0.5),
          );
          expect(
            mapper.displayedSize.height,
            lessThanOrEqualTo(overlayRect.height + 0.5),
          );
          // The fit is `BoxFit.contain`: exactly one axis is filled and the
          // page is never enlarged beyond the smaller scale factor.
          final fit = math.min(
            overlayRect.width / _uprightSize.width,
            overlayRect.height / _uprightSize.height,
          );
          expect(
            mapper.displayedSize.width,
            closeTo(_uprightSize.width * fit, 0.5),
          );
          expect(
            mapper.displayedSize.height,
            closeTo(_uprightSize.height * fit, 0.5),
          );

          for (final element in result.elements) {
            final rect = mapper
                .rectToScreen(element.boundingBox)
                .shift(overlayRect.topLeft);
            // Every word is inside the displayed photograph.
            expect(rect.left, greaterThanOrEqualTo(overlayRect.left - 0.5));
            expect(rect.right, lessThanOrEqualTo(overlayRect.right + 0.5));
            expect(rect.top, greaterThanOrEqualTo(overlayRect.top - 0.5));
            expect(rect.bottom, lessThanOrEqualTo(overlayRect.bottom + 0.5));

            await tester.tapAt(rect.center);
            await tester.pump();
            expect(
              tapped.last,
              element.text.trim(),
              reason:
                  'tapping "${element.text}" at ${rect.center} must select it',
            );
          }

          // The photograph itself is drawn on the fitted rectangle.
          expect(
            tester.getRect(find.byType(Image)),
            (mapper.displayedOffset & mapper.displayedSize).shift(
              overlayRect.topLeft,
            ),
          );
        },
      );
    }
  });
}
