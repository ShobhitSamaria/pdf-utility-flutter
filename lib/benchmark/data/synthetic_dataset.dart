import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../domain/benchmark_sample.dart';

/// The **synthetic** tier: images rendered on the device from text this file
/// supplies, so the ground truth is exact by construction rather than typed out
/// by a human.
///
/// What this tier is for
/// --------------------
/// It gives a *repeatable* baseline the moment the harness runs, with no dataset
/// to prepare and nothing to download — and because the reference string is the
/// string that was drawn, a bad score can only come from the recognizer (or from
/// a missing font), never from a transcription typo.
///
/// What it is **not**
/// ------------------
/// A synthetic page has no sensor noise, no perspective, no paper texture and no
/// realistic lighting, so it flatters every recognizer. It also depends on the
/// device having a Devanagari font, which is why the Hindi samples can produce
/// tofu boxes on a stripped-down build. Its numbers are therefore reported under
/// their own tier and must never be quoted as real-world accuracy; the
/// real-photograph tier exists for that, and it stays empty until photographs
/// are supplied.
class SyntheticBenchmarkDataset {
  const SyntheticBenchmarkDataset();

  /// Samples in a fixed order, so two runs are directly comparable.
  List<BenchmarkSample> samples() => <BenchmarkSample>[
    for (final spec in _specs)
      BenchmarkSample(
        id: spec.id,
        tier: BenchmarkTier.synthetic,
        category: spec.category,
        groundTruth: spec.text,
        notes: spec.notes,
        imageProvider: () => _render(spec),
      ),
  ];

  // --- rendering ------------------------------------------------------------

  static Future<String> _render(_Spec spec) async {
    var image = await _paint(spec);

    if (spec.blurSigma > 0) {
      final blurred = await _filters(image, spec.blurSigma, 0);
      image.dispose();
      image = blurred;
    } else if (spec.shadowStrength > 0) {
      final shaded = await _filters(image, 0, spec.shadowStrength);
      image.dispose();
      image = shaded;
    }

    if (spec.downscale < 1) {
      final small = await _rescale(image, spec.downscale);
      image.dispose();
      image = small;
    }

    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    if (bytes == null) {
      throw StateError('Could not encode synthetic sample ${spec.id}');
    }

    // Temp storage needs no permission on Android, unlike external storage, and
    // the recognised input then travels exactly the path a user's photo does.
    final file = File(
      '${Directory.systemTemp.path}${Platform.pathSeparator}ocr_bench_${spec.id}.png',
    );
    await file.writeAsBytes(bytes.buffer.asUint8List(), flush: true);
    return file.path;
  }

  /// Draws the page: white paper, optional tilt, then the content.
  static Future<ui.Image> _paint(_Spec spec) async {
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    final width = spec.width.toDouble();
    final height = spec.height.toDouble();

    canvas.drawRect(
      Rect.fromLTWH(0, 0, width, height),
      Paint()..color = const Color(0xFFFFFFFF),
    );

    if (spec.rotationTurns != 0) {
      canvas.save();
      canvas.translate(width / 2, height / 2);
      canvas.rotate(spec.rotationTurns);
      canvas.translate(-width / 2, -height / 2);
    }

    switch (spec.kind) {
      case _Kind.paragraph:
        _paintParagraph(canvas, spec);
      case _Kind.table:
        _paintTable(canvas, spec);
      case _Kind.form:
        _paintForm(canvas, spec);
    }

    if (spec.rotationTurns != 0) canvas.restore();

    final picture = recorder.endRecording();
    final image = await picture.toImage(spec.width, spec.height);
    picture.dispose();
    return image;
  }

  static void _paintParagraph(Canvas canvas, _Spec spec) {
    const margin = 48.0;
    final painter = TextPainter(
      text: TextSpan(
        text: spec.text,
        style: TextStyle(
          color: const Color(0xFF000000),
          fontSize: spec.fontSize,
          height: 1.4,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: spec.width - margin * 2);
    painter.paint(canvas, const Offset(margin, margin));
  }

  /// A simple ruled table: one header row and a body row per `|`-separated line.
  static void _paintTable(Canvas canvas, _Spec spec) {
    const margin = 40.0;
    final rows = spec.text.split('\n');
    final columns = rows.first.split('|').length;
    final columnWidth = (spec.width - margin * 2) / columns;
    final rowHeight = spec.fontSize * 2.2;
    final rule = Paint()
      ..color = const Color(0xFF000000)
      ..strokeWidth = 1.5;

    for (var row = 0; row < rows.length; row++) {
      final y = margin + row * rowHeight;
      canvas.drawLine(Offset(margin, y), Offset(spec.width - margin, y), rule);

      final cells = rows[row].split('|');
      for (var column = 0; column < cells.length; column++) {
        final painter = TextPainter(
          text: TextSpan(
            text: cells[column].trim(),
            style: TextStyle(
              color: const Color(0xFF000000),
              fontSize: spec.fontSize,
              fontWeight: row == 0 ? FontWeight.bold : FontWeight.normal,
            ),
          ),
          textDirection: TextDirection.ltr,
        )..layout(maxWidth: columnWidth - 12);
        painter.paint(
          canvas,
          Offset(margin + column * columnWidth + 6, y + rowHeight * 0.28),
        );
      }
    }

    final bottom = margin + rows.length * rowHeight;
    canvas.drawLine(
      Offset(margin, bottom),
      Offset(spec.width - margin, bottom),
      rule,
    );

    // Column separators.
    for (var column = 0; column <= columns; column++) {
      final x = margin + column * columnWidth;
      canvas.drawLine(Offset(x, margin), Offset(x, bottom), rule);
    }
  }

  /// A form-like page: `Label: value` lines with a rule under each value.
  static void _paintForm(Canvas canvas, _Spec spec) {
    const margin = 48.0;
    final lines = spec.text.split('\n');
    final pitch = spec.fontSize * 2.6;
    final rule = Paint()
      ..color = const Color(0xFF333333)
      ..strokeWidth = 1.0;

    for (var index = 0; index < lines.length; index++) {
      final y = margin + index * pitch;
      final painter = TextPainter(
        text: TextSpan(
          text: lines[index],
          style: TextStyle(
            color: const Color(0xFF000000),
            fontSize: spec.fontSize,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout(maxWidth: spec.width - margin * 2);
      painter.paint(canvas, Offset(margin, y));
      canvas.drawLine(
        Offset(margin, y + pitch * 0.62),
        Offset(spec.width - margin, y + pitch * 0.62),
        rule,
      );
    }
  }

  /// Re-draws [source] through a blur and/or a diagonal lighting gradient.
  static Future<ui.Image> _filters(
    ui.Image source,
    double blurSigma,
    double shadowStrength,
  ) async {
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    final width = source.width.toDouble();
    final height = source.height.toDouble();
    final rect = Rect.fromLTWH(0, 0, width, height);

    final paint = Paint();
    if (blurSigma > 0) {
      paint.imageFilter = ui.ImageFilter.blur(
        sigmaX: blurSigma,
        sigmaY: blurSigma,
      );
    }
    canvas.drawImage(source, Offset.zero, paint);

    if (shadowStrength > 0) {
      canvas.drawRect(
        rect,
        Paint()
          ..shader = ui.Gradient.linear(
            Offset.zero,
            Offset(width, height),
            <Color>[
              const Color(0x00000000),
              Color.fromRGBO(0, 0, 0, shadowStrength),
            ],
            <double>[0.35, 1.0],
          ),
      );
    }

    final picture = recorder.endRecording();
    final result = await picture.toImage(source.width, source.height);
    picture.dispose();
    return result;
  }

  /// True resolution loss: the image is re-rendered at a fraction of its size.
  static Future<ui.Image> _rescale(ui.Image source, double factor) async {
    final width = (source.width * factor).round().clamp(1, 1 << 16);
    final height = (source.height * factor).round().clamp(1, 1 << 16);

    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    canvas.drawImageRect(
      source,
      Rect.fromLTWH(0, 0, source.width.toDouble(), source.height.toDouble()),
      Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
      Paint()..filterQuality = FilterQuality.medium,
    );
    final picture = recorder.endRecording();
    final result = await picture.toImage(width, height);
    picture.dispose();
    return result;
  }
}

/// How the page is laid out. Independent of what the sample tests.
enum _Kind { paragraph, table, form }

/// The full definition of one synthetic sample.
class _Spec {
  const _Spec({
    required this.id,
    required this.category,
    required this.text,
    this.kind = _Kind.paragraph,
    this.fontSize = 34,
    this.width = 1000,
    this.height = 1400,
    this.rotationTurns = 0,
    this.blurSigma = 0,
    this.shadowStrength = 0,
    this.downscale = 1,
  });

  final String id;
  final BenchmarkCategory category;

  /// The exact text drawn, and therefore the exact ground truth.
  final String text;

  final _Kind kind;
  final double fontSize;
  final int width;
  final int height;

  /// Canvas rotation in radians (a tilt, as if the phone were not square to the
  /// page).
  final double rotationTurns;

  final double blurSigma;

  /// Strength of the diagonal lighting gradient. `0` disables it.
  final double shadowStrength;

  /// Scale factor applied at the end; below `1` produces a genuinely
  /// lower-resolution image.
  final double downscale;

  String get notes {
    final parts = <String>['synthetic'];
    if (rotationTurns != 0) parts.add('tilted');
    if (blurSigma > 0) parts.add('blur σ=$blurSigma');
    if (shadowStrength > 0) parts.add('shadow gradient');
    if (downscale < 1) parts.add('downscaled ×$downscale');
    parts.add('font ${fontSize.toStringAsFixed(0)}px');
    return parts.join(', ');
  }
}

const _englishParagraph =
    'The quick brown fox jumps over the lazy dog. Pack my box with five dozen '
    'liquor jugs. Sixty zippers were quickly picked from the woven jute bag.';

const _hindiParagraph =
    'यह एक साधारण हिन्दी वाक्य है। भारत एक विशाल देश है और यहाँ अनेक भाषाएँ '
    'बोली जाती हैं। हर राज्य की अपनी भाषा और अपनी संस्कृति है।';

const _denseText =
    'Invoice summary. Invoice summary. Invoice summary. Invoice summary. '
    'Invoice summary. Invoice summary. Invoice summary. Invoice summary. '
    'Invoice summary. Invoice summary. Invoice summary. Invoice summary.';

const _tableText =
    'Item|Qty|Price\n'
    'Notebook|2|120.00\n'
    'Ballpoint pen|10|50.00\n'
    'Printer paper|1|349.00\n'
    'File folder|4|88.00';

const _formText =
    'Name: Shobhit Samaria\n'
    'Order no: 48213\n'
    'Date: 11/10/2026\n'
    'Amount: 12480.75\n'
    'City: Jaipur';

const _mixedText =
    'Total amount: Rs. 1250\n'
    'कुल राशि: रुपये 1250\n'
    'Date: 11/10/2026\n'
    'दिनांक: 11/10/2026\n'
    'Thank you / धन्यवाद';

const List<_Spec> _specs = <_Spec>[
  _Spec(
    id: 'en_clean',
    category: BenchmarkCategory.printedEnglish,
    text: _englishParagraph,
  ),
  _Spec(
    id: 'en_small_font',
    category: BenchmarkCategory.smallFont,
    text: _englishParagraph,
    fontSize: 15,
    width: 760,
    height: 620,
  ),
  _Spec(
    id: 'en_low_resolution',
    category: BenchmarkCategory.lowResolution,
    text: _englishParagraph,
    downscale: 0.28,
  ),
  _Spec(
    id: 'en_blurry',
    category: BenchmarkCategory.blurry,
    text: _englishParagraph,
    blurSigma: 1.8,
  ),
  _Spec(
    id: 'en_tilted',
    category: BenchmarkCategory.tilted,
    text: _englishParagraph,
    rotationTurns: 0.035,
  ),
  _Spec(
    id: 'en_shadowed',
    category: BenchmarkCategory.shadowed,
    text: _englishParagraph,
    shadowStrength: 0.45,
  ),
  _Spec(
    id: 'en_dense',
    category: BenchmarkCategory.denseText,
    text: _denseText,
    fontSize: 22,
    width: 900,
    height: 900,
  ),
  _Spec(
    id: 'en_table',
    category: BenchmarkCategory.table,
    text: _tableText,
    kind: _Kind.table,
    fontSize: 28,
    width: 900,
    height: 420,
  ),
  _Spec(
    id: 'en_form',
    category: BenchmarkCategory.form,
    text: _formText,
    kind: _Kind.form,
    fontSize: 30,
    width: 900,
    height: 560,
  ),
  _Spec(
    id: 'hi_clean',
    category: BenchmarkCategory.printedHindi,
    text: _hindiParagraph,
  ),
  _Spec(
    id: 'hi_small_font',
    category: BenchmarkCategory.smallFont,
    text: _hindiParagraph,
    fontSize: 16,
    width: 760,
    height: 640,
  ),
  _Spec(
    id: 'hi_blurry',
    category: BenchmarkCategory.blurry,
    text: _hindiParagraph,
    blurSigma: 1.6,
  ),
  _Spec(
    id: 'mixed_invoice',
    category: BenchmarkCategory.mixedScript,
    text: _mixedText,
    kind: _Kind.form,
    fontSize: 30,
    width: 900,
    height: 620,
  ),
];
