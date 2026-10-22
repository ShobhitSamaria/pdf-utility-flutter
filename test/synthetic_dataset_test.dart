import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pdf_utility_flutter/benchmark/data/synthetic_dataset.dart';
import 'package:pdf_utility_flutter/benchmark/domain/benchmark_sample.dart';

void main() {
  // Rendering goes through dart:ui, which needs a binding in a test.
  TestWidgetsFlutterBinding.ensureInitialized();

  final samples = const SyntheticBenchmarkDataset().samples();

  group('dataset definition', () {
    test('covers every category the project asked to measure', () {
      final covered = samples.map((sample) => sample.category).toSet();

      expect(covered, equals(BenchmarkCategory.values.toSet()));
    });

    test('has unique ids and non-empty ground truth', () {
      final ids = samples.map((sample) => sample.id).toList();

      expect(ids.toSet(), hasLength(ids.length));
      for (final sample in samples) {
        expect(sample.groundTruth.trim(), isNotEmpty, reason: sample.id);
      }
    });

    test('is every one synthetic, so no score can be mistaken for a photo', () {
      for (final sample in samples) {
        expect(sample.tier, BenchmarkTier.synthetic);
      }
    });

    test('splits into Hindi and Latin buckets', () {
      final hindi = samples.where((sample) => sample.isDevanagari).toList();
      final latin = samples.where((sample) => !sample.isDevanagari).toList();

      expect(hindi, isNotEmpty);
      expect(latin, isNotEmpty);
      for (final sample in hindi) {
        expect(sample.scriptLabel, contains('Hindi'));
      }
    });
  });

  group('rendering', () {
    test('writes a real PNG to a temporary file', () async {
      final sample = samples.firstWhere((s) => s.id == 'en_clean');
      final path = await sample.imageProvider();
      final file = File(path);

      expect(file.existsSync(), isTrue);
      expect(file.lengthSync(), greaterThan(1000));

      // PNG magic number, so this is an encoded image rather than raw bytes.
      expect(file.readAsBytesSync().take(8).toList(), <int>[
        0x89,
        0x50,
        0x4E,
        0x47,
        0x0D,
        0x0A,
        0x1A,
        0x0A,
      ]);
    });

    test('renders every sample, including the transformed ones', () async {
      for (final sample in samples) {
        final path = await sample.imageProvider();
        expect(
          File(path).lengthSync(),
          greaterThan(500),
          reason: '${sample.id} produced an implausibly small file',
        );
      }
    });
  });
}
