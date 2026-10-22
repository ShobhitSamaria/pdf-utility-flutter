import '../../ocr/domain/ocr_text_utils.dart';

/// Where a sample came from, which decides how much its numbers can be trusted.
enum BenchmarkTier {
  /// Rendered on the device from text the harness itself supplies.
  ///
  /// Ground truth is **exact by construction** — nothing was transcribed by
  /// hand — but the image is a digital rendering, not a camera capture, so it
  /// has none of a real photo's noise, sensor blur, perspective or lighting.
  /// Synthetic scores are therefore optimistic and must never be quoted as
  /// real-world accuracy.
  synthetic('Synthetic (exact ground truth)'),

  /// A real photograph supplied by the user, with its transcription typed out.
  ///
  /// This is the tier that says something about the app in someone's hands.
  realPhoto('Real photographs (supplied)');

  const BenchmarkTier(this.label);

  final String label;
}

/// What a sample is testing. Categories overlap on purpose: a real-world page is
/// usually blurry *and* small-font *and* badly lit.
enum BenchmarkCategory {
  printedEnglish('Printed English'),
  printedHindi('Printed Hindi'),
  mixedScript('Mixed Hindi + English'),
  blurry('Blurry'),
  tilted('Tilted / rotated'),
  shadowed('Uneven lighting'),
  lowResolution('Low resolution'),
  smallFont('Small font'),
  denseText('Dense text'),
  table('Table'),
  form('Form');

  const BenchmarkCategory(this.label);

  final String label;
}

/// One benchmark input: ground-truth text plus a way to obtain the image file.
class BenchmarkSample {
  const BenchmarkSample({
    required this.id,
    required this.tier,
    required this.category,
    required this.groundTruth,
    required this.imageProvider,
    this.notes = '',
  });

  /// Stable identifier, used as the row key in the report.
  final String id;

  final BenchmarkTier tier;
  final BenchmarkCategory category;

  /// What the image actually says. Typed by hand for a photograph, or the exact
  /// string the generator drew for a synthetic sample.
  final String groundTruth;

  /// Produces an absolute path to the image on disk.
  ///
  /// Synthetic samples render one; bundled photographs are copied out of the
  /// asset bundle into a temporary file, so the recognised input travels the
  /// **same** path as a real user image (`InputImage.fromFilePath`).
  final Future<String> Function() imageProvider;

  /// Free-form context shown in the report (e.g. which device took the photo).
  final String notes;

  /// Whether the reference text is Devanagari, which is how accuracy is split
  /// into Hindi and English buckets.
  bool get isDevanagari => OcrTextUtils.containsDevanagari(groundTruth);

  /// Bucket label used when grouping results.
  String get scriptLabel => isDevanagari ? 'Hindi (Devanagari)' : 'Latin';

  @override
  String toString() => 'BenchmarkSample($id, ${tier.name}, ${category.name})';
}
