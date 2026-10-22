import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart' show rootBundle;

import '../../ocr/domain/ocr_text_utils.dart';
import '../domain/benchmark_sample.dart';

/// The **real-photograph** tier: images bundled under `assets/benchmark/real/`
/// together with their transcriptions.
///
/// How samples are supplied
/// ------------------------
/// Drop image files into `assets/benchmark/real/`, describe them in
/// `assets/benchmark/manifest.json`, and list the directory under `assets:` in
/// `pubspec.yaml`. Nothing is downloaded and no permission is needed, and the
/// images travel the same code path as a user's photo because each one is copied
/// out of the bundle into a temporary file before recognition.
///
/// Manifest entry:
/// ```json
/// {
///   "id": "kitchen_table_01",
///   "category": "blurry",
///   "image": "assets/benchmark/real/kitchen_table_01.jpg",
///   "groundTruth": "assets/benchmark/real/kitchen_table_01.txt",
///   "notes": "Nothing Phone (2a), dim kitchen light, hand-held"
/// }
/// ```
///
/// `groundTruth` may be either an asset key ending in `.txt` (loaded as a file,
/// which keeps long transcriptions readable) or the transcription itself written
/// inline. This is the tier that says something about the app in someone's
/// hands, and it reports as **not measured** until entries exist — never as a
/// guess.
class AssetBenchmarkDataset {
  const AssetBenchmarkDataset({this.manifestAsset = defaultManifestAsset});

  static const String defaultManifestAsset = 'assets/benchmark/manifest.json';

  final String manifestAsset;

  /// Loads the bundled samples, returning an empty list when no manifest or no
  /// entries are present (the normal state until photographs are added).
  Future<List<BenchmarkSample>> load() async {
    final raw = await _readManifest();
    if (raw == null) return const <BenchmarkSample>[];

    final Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } on FormatException {
      return const <BenchmarkSample>[];
    }
    if (decoded is! Map) return const <BenchmarkSample>[];

    final entries = decoded['samples'];
    if (entries is! List) return const <BenchmarkSample>[];

    final samples = <BenchmarkSample>[];
    for (final entry in entries) {
      if (entry is! Map) continue;

      final id = entry['id'];
      final image = entry['image'];
      final groundTruth = entry['groundTruth'];
      if (id is! String || image is! String || groundTruth is! String) continue;

      final text = await _resolveGroundTruth(groundTruth);
      if (text.trim().isEmpty) continue;

      samples.add(
        BenchmarkSample(
          id: id,
          tier: BenchmarkTier.realPhoto,
          category: _categoryFor(entry['category'], text),
          groundTruth: text,
          notes: entry['notes'] is String ? entry['notes'] as String : '',
          imageProvider: () => _copyToTemp(id, image),
        ),
      );
    }
    return samples;
  }

  Future<String?> _readManifest() async {
    try {
      return await rootBundle.loadString(manifestAsset);
    } catch (_) {
      // No manifest bundled: a legitimate configuration, not an error.
      return null;
    }
  }

  /// Either an asset key to read, or the transcription itself.
  Future<String> _resolveGroundTruth(String spec) async {
    if (!spec.endsWith('.txt')) return spec;
    try {
      return await rootBundle.loadString(spec);
    } catch (_) {
      return '';
    }
  }

  /// Copies a bundled image to a temporary file and returns its path.
  static Future<String> _copyToTemp(String id, String assetKey) async {
    final data = await rootBundle.load(assetKey);
    final extension = _extensionOf(assetKey);

    final file = File(
      '${Directory.systemTemp.path}${Platform.pathSeparator}'
      'ocr_bench_$id$extension',
    );
    await file.writeAsBytes(
      data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
      flush: true,
    );
    return file.path;
  }

  static String _extensionOf(String assetKey) {
    final dot = assetKey.lastIndexOf('.');
    final slash = assetKey.lastIndexOf('/');
    if (dot <= slash) return '';
    return assetKey.substring(dot);
  }

  /// Maps the manifest's category name, falling back to the script of the
  /// reference text rather than to a Latin default that would mislabel a Hindi
  /// photograph.
  static BenchmarkCategory _categoryFor(Object? name, String groundTruth) {
    if (name is String) {
      for (final category in BenchmarkCategory.values) {
        if (category.name == name) return category;
      }
    }
    return OcrTextUtils.containsDevanagari(groundTruth)
        ? BenchmarkCategory.printedHindi
        : BenchmarkCategory.printedEnglish;
  }
}
