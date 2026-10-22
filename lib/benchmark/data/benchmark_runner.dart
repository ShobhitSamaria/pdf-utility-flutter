import 'dart:io';

import '../../ocr/domain/ocr_exception.dart';
import '../../ocr/domain/ocr_result_index.dart';
import '../../ocr/domain/ocr_script_mode.dart';
import '../../ocr/domain/ocr_service.dart';
import '../domain/benchmark_report.dart';
import '../domain/benchmark_sample.dart';
import '../domain/ocr_metrics.dart';

/// Progress of a running benchmark, for a progress bar and a status line.
class BenchmarkProgress {
  const BenchmarkProgress({
    required this.completed,
    required this.total,
    required this.label,
  });

  final int completed;
  final int total;

  /// What is being measured right now (mode and sample).
  final String label;

  double get fraction => total == 0 ? 0 : completed / total;
}

/// Drives the **real** [OcrService] over a dataset and scores the output.
///
/// It runs the actual service the app runs — no mocks, no shortcut — so a
/// number from here reflects the shipping pipeline as measured on this device.
/// It never invents a value: if a call fails it is counted as a failure, and if
/// a metric has no data behind it the report says "not measured".
class BenchmarkRunner {
  BenchmarkRunner({required this.ocrService});

  final OcrService ocrService;

  /// Reads every sample once per mode, [repeats] times each.
  ///
  /// [shouldCancel] is polled between calls, so cancelling stops promptly
  /// without leaving a recognition mid-flight.
  Future<BenchmarkReport> run({
    required List<BenchmarkSample> samples,
    required List<OcrScriptMode> modes,
    int repeats = 2,
    void Function(BenchmarkProgress progress)? onProgress,
    bool Function()? shouldCancel,
  }) async {
    final total = samples.length * modes.length * repeats;
    var completed = 0;
    final modeResults = <ModeResult>[];

    for (final mode in modes) {
      final results = <SampleResult>[];
      for (final sample in samples) {
        if (shouldCancel?.call() ?? false) break;

        results.add(
          await _measureSample(
            sample: sample,
            mode: mode,
            repeats: repeats,
            onCall: () {
              completed++;
              onProgress?.call(
                BenchmarkProgress(
                  completed: completed,
                  total: total,
                  label: '${mode.label} · ${sample.id}',
                ),
              );
            },
          ),
        );
      }

      modeResults.add(ModeResult(mode: mode, results: results));
      if (shouldCancel?.call() ?? false) break;
    }

    return BenchmarkReport(
      startedAt: DateTime.now(),
      repeats: repeats,
      modeResults: modeResults,
    );
  }

  Future<SampleResult> _measureSample({
    required BenchmarkSample sample,
    required OcrScriptMode mode,
    required int repeats,
    required void Function() onCall,
  }) async {
    final latencies = <Duration>[];
    var failures = 0;
    var emptyResults = 0;
    var attempts = 0;
    String? firstError;
    var hypothesis = '';
    var cer = 0.0;
    var wer = 0.0;
    var scored = false;
    int? peakRssBytes;

    String imagePath;
    try {
      imagePath = await sample.imageProvider();
    } catch (error) {
      return SampleResult(
        sampleId: sample.id,
        tier: sample.tier,
        category: sample.category,
        scriptLabel: sample.scriptLabel,
        attempts: repeats,
        failures: repeats,
        emptyResults: 0,
        latencies: latencies,
        cer: 1,
        wer: 1,
        hypothesis: '',
        error: 'could not prepare the image: $error',
      );
    }

    for (var repeat = 0; repeat < repeats; repeat++) {
      attempts++;
      final stopwatch = Stopwatch()..start();
      try {
        final result = await ocrService.recognizeImage(imagePath, mode: mode);
        stopwatch.stop();
        latencies.add(stopwatch.elapsed);

        if (OcrResultIndex.of(result).selectableElements.isEmpty) {
          emptyResults++;
        }

        if (!scored) {
          // Accuracy is scored from the FIRST successful pass, so repeats
          // measure latency spread rather than letting a lucky run be picked.
          scored = true;
          hypothesis = result.fullText;
          cer = OcrMetrics.characterErrorRate(
            reference: sample.groundTruth,
            hypothesis: hypothesis,
          );
          wer = OcrMetrics.wordErrorRate(
            reference: sample.groundTruth,
            hypothesis: hypothesis,
          );
        }
      } on OcrException catch (error) {
        stopwatch.stop();
        failures++;
        firstError ??= error.message;
      } catch (error) {
        stopwatch.stop();
        failures++;
        firstError ??= error.toString();
      }

      final rss = ProcessInfo.currentRss;
      if (peakRssBytes == null || rss > peakRssBytes) peakRssBytes = rss;
      onCall();
    }

    return SampleResult(
      sampleId: sample.id,
      tier: sample.tier,
      category: sample.category,
      scriptLabel: sample.scriptLabel,
      attempts: attempts,
      failures: failures,
      emptyResults: emptyResults,
      latencies: latencies,
      cer: cer,
      wer: wer,
      hypothesis: hypothesis,
      error: firstError,
      peakRssBytes: peakRssBytes,
    );
  }
}
