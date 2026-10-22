import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../ocr/data/text_sharer.dart';
import '../../ocr/domain/ocr_script_mode.dart';
import '../../ocr/domain/ocr_service.dart';
import '../data/asset_dataset.dart';
import '../data/benchmark_runner.dart';
import '../data/synthetic_dataset.dart';
import '../domain/benchmark_report.dart';
import '../domain/benchmark_sample.dart';

/// Debug-only harness screen: reads the benchmark dataset with the **real** OCR
/// service and reports accuracy and latency.
///
/// Deliberately separated from normal use: it only runs when the user presses
/// Run, it never starts at launch, and it is reached from a debug build only.
/// A benchmark that fires on startup would slow every launch and, worse, would
/// warm the recognizers before the first real photo — destroying the very
/// cold-start number it is supposed to measure.
class BenchmarkScreen extends StatefulWidget {
  const BenchmarkScreen({
    super.key,
    required this.ocrService,
    this.textSharer = const TextSharer(),
  });

  final OcrService ocrService;

  /// Injectable so tests never touch the platform share sheet.
  final TextSharer textSharer;

  @override
  State<BenchmarkScreen> createState() => _BenchmarkScreenState();
}

class _BenchmarkScreenState extends State<BenchmarkScreen> {
  List<BenchmarkSample> _samples = const <BenchmarkSample>[];
  bool _loading = true;

  /// Modes to evaluate. Latin and Devanagari by default; mixed is opt-in
  /// because it doubles the work for the same dataset.
  final Set<OcrScriptMode> _modes = <OcrScriptMode>{
    OcrScriptMode.latin,
    OcrScriptMode.devanagari,
  };

  int _repeats = 2;

  bool _running = false;
  bool _cancelRequested = false;
  BenchmarkProgress? _progress;
  BenchmarkReport? _report;
  String? _error;

  @override
  void initState() {
    super.initState();
    unawaited(_loadDataset());
  }

  Future<void> _loadDataset() async {
    final synthetic = const SyntheticBenchmarkDataset().samples();
    var real = const <BenchmarkSample>[];
    try {
      real = await const AssetBenchmarkDataset().load();
    } catch (error) {
      _error = 'Could not read the bundled samples: $error';
    }

    if (!mounted) return;
    setState(() {
      _samples = <BenchmarkSample>[...synthetic, ...real];
      _loading = false;
    });
  }

  int get _syntheticCount =>
      _samples.where((s) => s.tier == BenchmarkTier.synthetic).length;
  int get _realCount =>
      _samples.where((s) => s.tier == BenchmarkTier.realPhoto).length;

  Future<void> _run() async {
    if (_running || _modes.isEmpty || _samples.isEmpty) return;

    final modes = OcrScriptMode.values
        .where(_modes.contains)
        .toList(growable: false);

    setState(() {
      _running = true;
      _cancelRequested = false;
      _report = null;
      _error = null;
      _progress = null;
    });

    try {
      final report = await BenchmarkRunner(ocrService: widget.ocrService).run(
        samples: _samples,
        modes: modes,
        repeats: _repeats,
        onProgress: (progress) {
          if (mounted) setState(() => _progress = progress);
        },
        shouldCancel: () => _cancelRequested,
      );
      if (mounted) setState(() => _report = report);
    } catch (error) {
      if (mounted) setState(() => _error = 'Benchmark failed: $error');
    } finally {
      if (mounted) setState(() => _running = false);
    }
  }

  void _cancel() => _cancelRequested = true;

  Future<void> _copyReport() async {
    final report = _report;
    if (report == null) return;
    final text = report.toJsonString();
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('Report JSON copied')));
  }

  Future<void> _shareReport() async {
    final report = _report;
    if (report == null) return;
    final shown = await widget.textSharer.shareText(
      report.toPlainText(),
      subject: 'OCR benchmark report',
    );
    if (!mounted || shown) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('No app available to share with')),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(title: const Text('OCR benchmark (debug)')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                _Section(
                  title: 'Dataset',
                  child: Text(
                    '$_syntheticCount synthetic sample(s) with exact ground '
                    'truth\n$_realCount bundled photograph(s)\n'
                    '${_realCount == 0 ? 'Add photographs to assets/benchmark/real/ to measure real-world accuracy.' : ''}',
                    style: theme.textTheme.bodySmall,
                  ),
                ),
                _Section(
                  title: 'Script modes',
                  child: Wrap(
                    spacing: 8,
                    runSpacing: 4,
                    children: [
                      for (final mode in OcrScriptMode.values)
                        FilterChip(
                          label: Text(mode.label),
                          selected: _modes.contains(mode),
                          onSelected: _running
                              ? null
                              : (selected) => setState(() {
                                  if (selected) {
                                    _modes.add(mode);
                                  } else if (_modes.length > 1) {
                                    _modes.remove(mode);
                                  }
                                }),
                        ),
                    ],
                  ),
                ),
                _Section(
                  title: 'Passes per sample',
                  child: Wrap(
                    spacing: 8,
                    children: [
                      for (final repeats in const <int>[1, 2, 3])
                        ChoiceChip(
                          label: Text('$repeats'),
                          selected: _repeats == repeats,
                          onSelected: _running
                              ? null
                              : (_) => setState(() => _repeats = repeats),
                        ),
                    ],
                  ),
                ),
                Text(
                  'Only the first call of a run is process-cold; extra passes '
                  'measure warm latency spread and never change the accuracy '
                  'score.',
                  style: theme.textTheme.bodySmall,
                ),
                const SizedBox(height: 16),
                SizedBox(
                  width: double.infinity,
                  child: _running
                      ? OutlinedButton.icon(
                          onPressed: _cancel,
                          icon: const Icon(Icons.stop_circle_outlined),
                          label: const Text('Cancel'),
                        )
                      : FilledButton.icon(
                          onPressed: (_samples.isEmpty || _modes.isEmpty)
                              ? null
                              : _run,
                          icon: const Icon(Icons.play_arrow),
                          label: const Text('Run benchmark'),
                        ),
                ),
                if (_running) ...[
                  const SizedBox(height: 16),
                  LinearProgressIndicator(value: _progress?.fraction),
                  const SizedBox(height: 8),
                  Text(
                    _progress == null
                        ? 'Preparing…'
                        : '${(_progress!.fraction * 100).toStringAsFixed(0)}% · '
                              '${_progress!.label}',
                    style: theme.textTheme.bodySmall,
                  ),
                  if (_cancelRequested) ...[
                    const SizedBox(height: 4),
                    Text(
                      'Stopping after the current image…',
                      style: theme.textTheme.bodySmall,
                    ),
                  ],
                ],
                if (_error != null) ...[
                  const SizedBox(height: 16),
                  Text(
                    _error!,
                    style: TextStyle(color: theme.colorScheme.error),
                  ),
                ],
                if (_report != null) ...[
                  const SizedBox(height: 16),
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          'Results',
                          style: theme.textTheme.titleMedium,
                        ),
                      ),
                      IconButton(
                        tooltip: 'Copy report JSON',
                        onPressed: () => unawaited(_copyReport()),
                        icon: const Icon(Icons.copy_all_outlined),
                      ),
                      IconButton(
                        tooltip: 'Share report',
                        onPressed: () => unawaited(_shareReport()),
                        icon: const Icon(Icons.share_outlined),
                      ),
                    ],
                  ),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: theme.colorScheme.surfaceContainerHighest,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: SelectableText(
                      _report!.toPlainText(),
                      style: const TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 11.5,
                      ),
                    ),
                  ),
                ],
              ],
            ),
    );
  }
}

class _Section extends StatelessWidget {
  const _Section({required this.title, required this.child});

  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: theme.textTheme.labelLarge),
          const SizedBox(height: 6),
          child,
        ],
      ),
    );
  }
}
