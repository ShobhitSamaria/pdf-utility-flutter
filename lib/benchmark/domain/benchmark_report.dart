import 'dart:convert';

import '../../ocr/domain/ocr_script_mode.dart';
import 'benchmark_sample.dart';
import 'ocr_metrics.dart';

/// One sample measured in one script mode.
class SampleResult {
  const SampleResult({
    required this.sampleId,
    required this.tier,
    required this.category,
    required this.scriptLabel,
    required this.attempts,
    required this.failures,
    required this.emptyResults,
    required this.latencies,
    required this.cer,
    required this.wer,
    required this.hypothesis,
    this.error,
    this.peakRssBytes,
  });

  final String sampleId;
  final BenchmarkTier tier;
  final BenchmarkCategory category;

  /// `'Latin'` or `'Hindi (Devanagari)'`, taken from the *reference* text.
  final String scriptLabel;

  /// Total recognition calls made for this sample (including failures).
  final int attempts;

  /// Calls that threw — a timeout (our own bound) or an engine failure.
  final int failures;

  /// Successful calls that returned **no words at all**.
  final int emptyResults;

  /// Latencies of the successful calls, in order.
  final List<Duration> latencies;

  /// Character error rate, scored from the **first successful** call. Repeats
  /// exist to measure latency spread, not to cherry-pick accuracy, so the score
  /// comes from one deterministic run rather than the best of several.
  final double cer;

  /// Word error rate, from the same call as [cer].
  final double wer;

  /// The text that call produced, so a bad number can be explained.
  final String hypothesis;

  /// First failure message, if any call failed.
  final String? error;

  /// Resident set size observed around this sample. Coarse: it is the whole
  /// process, it includes the Dart heap and is read through `dart:io`, so it
  /// says nothing about native ML Kit allocations.
  final int? peakRssBytes;

  /// Successful calls.
  int get successes => latencies.length;

  /// Fraction of **successful** calls that found no words.
  double? get emptyResultRate =>
      successes == 0 ? null : emptyResults / successes;

  /// Fraction of calls that threw.
  double get failureRate => attempts == 0 ? 0 : failures / attempts;

  /// Whether the first successful call's latency is the cold one. Only the very
  /// first sample of a run is truly process-cold; later "first" calls are warm.
  Duration? get firstRunLatency => latencies.isEmpty ? null : latencies.first;

  /// Latencies of the second and later calls.
  List<Duration> get warmLatencies =>
      latencies.length <= 1 ? const <Duration>[] : latencies.sublist(1);

  Map<String, Object?> toJson() => <String, Object?>{
    'sample': sampleId,
    'tier': tier.name,
    'category': category.name,
    'script': scriptLabel,
    'attempts': attempts,
    'failures': failures,
    'emptyResults': emptyResults,
    'latencyMs': [for (final value in latencies) value.inMilliseconds],
    'cer': cer,
    'wer': wer,
    'hypothesis': hypothesis,
    'peakRssBytes': peakRssBytes,
    'error': ?error,
  };

  @override
  String toString() => 'SampleResult($sampleId, cer=${cer.toStringAsFixed(3)})';
}

/// Every sample measured in one script mode.
class ModeResult {
  const ModeResult({required this.mode, required this.results});

  final OcrScriptMode mode;
  final List<SampleResult> results;

  Map<String, Object?> toJson() => <String, Object?>{
    'mode': mode.name,
    'samples': [for (final result in results) result.toJson()],
  };
}

/// The full outcome of a benchmark run, including what it could **not** measure.
///
/// The report is deliberately explicit about gaps. An unmeasured metric is
/// reported as unmeasured — never as zero, and never as an estimate.
class BenchmarkReport {
  const BenchmarkReport({
    required this.startedAt,
    required this.repeats,
    required this.modeResults,
  });

  final DateTime startedAt;

  /// How many times each sample was read per mode.
  final int repeats;

  final List<ModeResult> modeResults;

  List<SampleResult> get allResults => [
    for (final mode in modeResults) ...mode.results,
  ];

  /// Mean CER over [results], or `null` when there is nothing to average.
  static double? meanCer(List<SampleResult> results) =>
      _mean([for (final result in results) result.cer]);

  /// Mean WER over [results], or `null` when there is nothing to average.
  static double? meanWer(List<SampleResult> results) =>
      _mean([for (final result in results) result.wer]);

  static double? _mean(List<double> values) {
    if (values.isEmpty) return null;
    var total = 0.0;
    for (final value in values) {
      total += value;
    }
    return total / values.length;
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'startedAt': startedAt.toIso8601String(),
    'repeatsPerSample': repeats,
    'modes': [for (final mode in modeResults) mode.toJson()],
    'notMeasured': const <String>[
      'pdfPagesPerMinute — this phase has no PDF ingestion, so there are no '
          'pages to process',
      'peak memory attributable to ML Kit — only whole-process RSS is '
          'available without a native profiler',
      'any real-photograph accuracy — the bundled real-photo tier is empty '
          'until photographs are supplied',
      'Unicode-normalized scoring — Dart core has no normalizer and this '
          'phase adds no dependency, so composed and decomposed forms are '
          'scored as different characters',
    ],
  };

  String toJsonString() => const JsonEncoder.withIndent('  ').convert(toJson());

  /// Human-readable report, written for someone reading it on a phone.
  String toPlainText() {
    final buffer = StringBuffer()
      ..writeln('OCR benchmark — ${startedAt.toIso8601String()}')
      ..writeln('$repeats pass(es) per sample per mode')
      ..writeln();

    for (final mode in modeResults) {
      buffer
        ..writeln('=== ${mode.mode.label} ===')
        ..writeln('samples: ${mode.results.length}');

      final cer = meanCer(mode.results);
      final wer = meanWer(mode.results);
      buffer.writeln('mean CER: ${_pct(cer)}   mean WER: ${_pct(wer)}');

      _writeGroup(
        buffer,
        'Latin',
        mode.results,
        (r) => r.scriptLabel.startsWith('Latin'),
      );
      _writeGroup(
        buffer,
        'Hindi',
        mode.results,
        (r) => r.scriptLabel.startsWith('Hindi'),
      );
      _writeGroup(
        buffer,
        'Synthetic',
        mode.results,
        (r) => r.tier == BenchmarkTier.synthetic,
      );
      _writeGroup(
        buffer,
        'Real photos',
        mode.results,
        (r) => r.tier == BenchmarkTier.realPhoto,
      );

      _writeLatency(buffer, mode.results);
      _writeFailures(buffer, mode.results);

      buffer.writeln();
      buffer.writeln('Per sample:');
      for (final result in mode.results) {
        buffer.writeln(
          '  ${result.sampleId.padRight(28)} '
          'CER ${result.cer.toStringAsFixed(3)}  '
          'WER ${result.wer.toStringAsFixed(3)}  '
          '${result.latencies.map((d) => '${d.inMilliseconds}').join('/')} ms'
          '${result.error == null ? '' : '  ERROR: ${result.error}'}',
        );
      }
      buffer.writeln();
    }

    buffer
      ..writeln('Not measured:')
      ..writeln('  * PDF pages/minute — no PDF ingestion in this phase.')
      ..writeln('  * ML Kit native memory — only whole-process RSS is visible.')
      ..writeln('  * Real-photograph accuracy until photographs are supplied.')
      ..writeln('  * Unicode-normalized scoring — see the report JSON.');

    return buffer.toString();
  }

  void _writeGroup(
    StringBuffer buffer,
    String label,
    List<SampleResult> results,
    bool Function(SampleResult) test,
  ) {
    final subset = results.where(test).toList();
    if (subset.isEmpty) return;
    buffer.writeln(
      '  $label: n=${subset.length} '
      'CER ${_pct(meanCer(subset))} WER ${_pct(meanWer(subset))}',
    );
  }

  void _writeLatency(StringBuffer buffer, List<SampleResult> results) {
    final firstRun = <Duration>[
      for (final result in results)
        if (result.firstRunLatency != null) result.firstRunLatency!,
    ];
    final warm = <Duration>[
      for (final result in results) ...result.warmLatencies,
    ];

    final firstRunSummary = LatencySummary.fromDurations(firstRun);
    final warmSummary = LatencySummary.fromDurations(warm);

    buffer.writeln(
      '  latency — first pass: ${firstRunSummary ?? 'not measured'}',
    );
    buffer.writeln('  latency — warm passes: ${warmSummary ?? 'not measured'}');
    buffer.writeln(
      '  note: only the very first call of a run is process-cold; every other '
      '"first pass" already has the model loaded.',
    );

    final rss = <int>[
      for (final result in results)
        if (result.peakRssBytes != null) result.peakRssBytes!,
    ];
    if (rss.isNotEmpty) {
      final peak = rss.reduce((a, b) => a > b ? a : b);
      buffer.writeln(
        '  peak process RSS: ${(peak / (1024 * 1024)).toStringAsFixed(1)} MiB '
        '(whole process, indicative only)',
      );
    }
  }

  void _writeFailures(StringBuffer buffer, List<SampleResult> results) {
    final attempts = results.fold<int>(0, (sum, r) => sum + r.attempts);
    final failures = results.fold<int>(0, (sum, r) => sum + r.failures);
    final successes = results.fold<int>(0, (sum, r) => sum + r.successes);
    final empties = results.fold<int>(0, (sum, r) => sum + r.emptyResults);

    buffer.writeln('  failures: $failures / $attempts calls');
    buffer.writeln(
      '  empty results: $empties / $successes successful calls'
      '${successes == 0 ? '' : ' (${(100 * empties / successes).toStringAsFixed(1)}%)'}',
    );
  }

  static String _pct(double? value) =>
      value == null ? 'not measured' : value.toStringAsFixed(3);
}
