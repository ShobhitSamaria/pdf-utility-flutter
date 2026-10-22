import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app/app_scope.dart';
import '../diagnostics/ocr_translation_self_test.dart';
import '../diagnostics/translation_self_test.dart';
import '../ocr/data/image_source_service.dart';
import '../translation/data/mlkit_translation_engine.dart';
import '../translation/domain/translation_exception.dart';
import '../translation/translation_log.dart';

/// **Opt-in** screen that isolates Google ML Kit on-device translation.
///
/// Two independent tests, deliberately run **one at a time**:
///
/// * **Test A — standalone ML Kit.** One fixed English sentence straight through
///   the translator: no OCR, no detection, no selection, no overlay, no camera,
///   no image. Answers "does ML Kit translation work on this device at all, and
///   if not, at which step?" It runs automatically when the screen opens.
/// * **Test B — real OCR → Hindi.** Picks a photo, reads it with the app's own
///   OCR service, then translates the extracted text with the app's own
///   translation service. Answers "does the actual pipeline work?" and names
///   which half broke when it does not.
///
/// Neither can get stuck on "Running…": progress is rendered after every step,
/// each native call has its own timeout owned by the runners, and this screen
/// additionally arms a watchdog per run and completes its state in a `finally`.
///
/// Every run is also written to logcat under `PDF_UTILITY_TRANSLATION`:
///
/// ```sh
/// adb logcat | grep PDF_UTILITY_TRANSLATION
/// ```
class TranslationDiagnosticsScreen extends StatefulWidget {
  const TranslationDiagnosticsScreen({
    super.key,
    this.selfTest,
    this.ocrSelfTest,
  });

  /// Injectable for tests.
  final TranslationSelfTest? selfTest;

  /// Injectable for tests. When omitted, Test B is built from [AppScope] and the
  /// real photo picker, so it exercises the app's actual OCR + translation path.
  final OcrTranslationSelfTest? ocrSelfTest;

  @override
  State<TranslationDiagnosticsScreen> createState() =>
      _TranslationDiagnosticsScreenState();
}

class _TranslationDiagnosticsScreenState
    extends State<TranslationDiagnosticsScreen> {
  // --- Test A -----------------------------------------------------------------

  late final TranslationSelfTest _selfTest =
      widget.selfTest ?? TranslationSelfTest(engine: MlKitTranslationEngine());

  List<SelfTestStep> _steps = const <SelfTestStep>[];
  SelfTestProgress? _progress;
  TranslationSelfTestReport? _report;
  String? _fatalError;
  bool _running = false;
  Timer? _watchdog;

  // --- Test B -----------------------------------------------------------------

  OcrTranslationSelfTest? _ocrSelfTest;

  List<SelfTestStep> _ocrSteps = const <SelfTestStep>[];
  SelfTestProgress? _ocrProgress;
  OcrTranslationSelfTestReport? _ocrReport;
  String? _ocrFatalError;
  bool _ocrRunning = false;
  Timer? _ocrWatchdog;

  /// Whether either test is in flight — the two are never run together.
  bool get _anyRunning => _running || _ocrRunning;

  @override
  void initState() {
    super.initState();
    _run();
  }

  @override
  void dispose() {
    _watchdog?.cancel();
    _ocrWatchdog?.cancel();
    super.dispose();
  }

  // --- Test A -----------------------------------------------------------------

  Future<void> _run() async {
    if (_anyRunning) return;

    setState(() {
      _running = true;
      _report = null;
      _steps = const <SelfTestStep>[];
      _progress = null;
      _fatalError = null;
    });

    // Belt and braces: the self-test bounds every step, so its total run time is
    // bounded by construction. If some future change breaks that invariant, the
    // UI still leaves "Running…" instead of spinning forever.
    final budget = _selfTest.worstCaseDuration + const Duration(seconds: 30);
    _watchdog?.cancel();
    _watchdog = Timer(budget, () {
      if (!mounted || !_running) return;
      final detail =
          'The diagnostic did not finish within '
          '${budget.inSeconds} seconds, so it was abandoned as stuck.\n'
          'Last operation: ${_progress?.currentStep ?? '(none)'}';
      translationLog('[SELFTEST] watchdog fired: $detail');
      setState(() {
        _fatalError = detail;
        _running = false;
      });
    });

    try {
      final report = await _selfTest.run(
        onProgress: (progress) {
          if (!mounted) return;
          setState(() {
            _progress = progress;
            _steps = progress.steps;
          });
        },
      );
      if (!mounted) return;
      translationLog('report:\n${report.toPlainText()}');
      setState(() {
        _report = report;
        _steps = report.steps;
        _progress = null;
      });
    } catch (error, stack) {
      // An unexpected failure must still end the run and be shown as-is.
      final detail = TranslationException.describe(error, stack);
      translationLog('[SELFTEST] threw outside any step:\n$detail');
      if (mounted) {
        setState(() {
          _fatalError = detail;
          _progress = null;
        });
      }
    } finally {
      _watchdog?.cancel();
      _watchdog = null;
      if (mounted) {
        setState(() {
          _running = false;
          _progress = null;
        });
      }
    }
  }

  // --- Test B -----------------------------------------------------------------

  /// Builds Test B from the app's own services, or returns the injected one.
  ///
  /// Built lazily on first use rather than in [initState] because it needs
  /// [AppScope], which is only reachable from `didChangeDependencies` onwards.
  OcrTranslationSelfTest _ocrRunner() {
    final injected = widget.ocrSelfTest;
    if (injected != null) return injected;
    return _ocrSelfTest ??= OcrTranslationSelfTest(
      ocrService: AppScope.of(context).ocrService,
      translationService: AppScope.of(context).translationService,
      pickImage: ImageSourceService().pickFromGallery,
    );
  }

  Future<void> _runOcrTest({String? imagePath}) async {
    if (_anyRunning) return;

    final runner = _ocrRunner();

    setState(() {
      _ocrRunning = true;
      _ocrReport = null;
      _ocrSteps = const <SelfTestStep>[];
      _ocrProgress = null;
      _ocrFatalError = null;
    });

    final budget = runner.worstCaseDuration + const Duration(seconds: 30);
    _ocrWatchdog?.cancel();
    _ocrWatchdog = Timer(budget, () {
      if (!mounted || !_ocrRunning) return;
      final detail =
          'Test B did not finish within ${budget.inSeconds} seconds, '
          'so it was abandoned as stuck.\n'
          'Last operation: ${_ocrProgress?.currentStep ?? '(none)'}';
      translationLog('[OCR-SELFTEST] watchdog fired: $detail');
      setState(() {
        _ocrFatalError = detail;
        _ocrRunning = false;
      });
    });

    try {
      final report = await runner.run(
        imagePath: imagePath,
        onProgress: (progress) {
          if (!mounted) return;
          setState(() {
            _ocrProgress = progress;
            _ocrSteps = progress.steps;
          });
        },
      );
      if (!mounted) return;
      translationLog('OCR report:\n${report.toPlainText()}');
      setState(() {
        _ocrReport = report;
        _ocrSteps = report.steps;
        _ocrProgress = null;
      });
    } catch (error, stack) {
      final detail = TranslationException.describe(error, stack);
      translationLog('[OCR-SELFTEST] threw outside any step:\n$detail');
      if (mounted) {
        setState(() {
          _ocrFatalError = detail;
          _ocrProgress = null;
        });
      }
    } finally {
      _ocrWatchdog?.cancel();
      _ocrWatchdog = null;
      if (mounted) {
        setState(() {
          _ocrRunning = false;
          _ocrProgress = null;
        });
      }
    }
  }

  // --- shared -----------------------------------------------------------------

  Future<void> _copy() async {
    final parts = <String>[
      if (_report != null) _report!.toPlainText(),
      if (_ocrReport != null) _ocrReport!.toPlainText(),
    ];
    if (parts.isEmpty) return;
    await Clipboard.setData(ClipboardData(text: parts.join('\n\n')));
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('Report copied')));
  }

  @override
  Widget build(BuildContext context) {
    final report = _report;
    final progress = _progress;
    final ocrReport = _ocrReport;
    final ocrProgress = _ocrProgress;
    final canCopy = report != null || ocrReport != null;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Translation diagnostics'),
        actions: [
          IconButton(
            tooltip: 'Copy report',
            onPressed: canCopy ? _copy : null,
            icon: const Icon(Icons.copy_all_outlined),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(
            'Test A — standalone ML Kit',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 4),
          Text(
            'Fixed input: "${TranslationSelfTest.sampleText}"  •  '
            'English → Hindi',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: _anyRunning ? null : _run,
            icon: const Icon(Icons.play_arrow),
            label: Text(_running ? 'Running…' : 'Run again'),
          ),
          const SizedBox(height: 16),

          // The live "what is it doing right now" card — the thing that turns an
          // anonymous spinner into a diagnosis.
          if (_running && progress?.currentStep != null) ...[
            _CurrentStep(progress: progress!),
            const SizedBox(height: 16),
          ],

          if (report != null) ...[
            _Verdict(report: report),
            const SizedBox(height: 16),
          ],

          if (_fatalError != null) ...[
            _FatalErrorCard(detail: _fatalError!),
            const SizedBox(height: 16),
          ],

          if (_steps.isNotEmpty) _StepList(steps: _steps),

          const Divider(height: 40),

          // --- Test B ---------------------------------------------------------
          Text(
            'Test B — real OCR → Hindi',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 4),
          Text(
            'Picks a photo, reads it on device with the app\'s OCR, then '
            'translates the extracted text. Run it on its own — the two tests '
            'never run at the same time.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: _anyRunning ? null : () => _runOcrTest(),
            icon: const Icon(Icons.photo_library_outlined),
            label: Text(_ocrRunning ? 'Testing…' : 'Pick a photo & translate'),
          ),
          if (_ocrReport?.imagePath != null) ...[
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: _anyRunning
                  ? null
                  : () => _runOcrTest(imagePath: _ocrReport!.imagePath),
              icon: const Icon(Icons.refresh),
              label: const Text('Test the same photo again'),
            ),
          ],
          const SizedBox(height: 16),

          if (_ocrRunning && ocrProgress?.currentStep != null) ...[
            _CurrentStep(progress: ocrProgress!),
            const SizedBox(height: 16),
          ],

          if (ocrReport != null) ...[
            _OcrVerdict(report: ocrReport),
            const SizedBox(height: 16),
          ],

          if (_ocrFatalError != null) ...[
            _FatalErrorCard(
              title: 'Test B could not run',
              detail: _ocrFatalError!,
            ),
            const SizedBox(height: 16),
          ],

          if (_ocrSteps.isNotEmpty) _StepList(steps: _ocrSteps),
        ],
      ),
    );
  }
}

/// The operation in flight, with a live elapsed clock.
class _CurrentStep extends StatelessWidget {
  const _CurrentStep({required this.progress});

  final SelfTestProgress progress;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      color: theme.colorScheme.surfaceContainerHighest,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            const SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    progress.currentStep!,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      fontFamily: 'monospace',
                    ),
                  ),
                  if (progress.activity != null)
                    Text(
                      '${progress.activity}  •  '
                      '${(progress.elapsed.inMilliseconds / 1000).toStringAsFixed(1)} s',
                      style: theme.textTheme.bodySmall,
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Verdict extends StatelessWidget {
  const _Verdict({required this.report});

  final TranslationSelfTestReport report;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final ok = report.passed;

    return Card(
      color: ok
          ? theme.colorScheme.primaryContainer
          : theme.colorScheme.errorContainer,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              ok
                  ? 'ML Kit standalone translation: PASS'
                  : 'ML Kit standalone translation: FAIL',
              style: theme.textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            Text(
              'explicit model management: '
              '${report.explicitPathPassed ? 'PASS' : 'FAIL'}',
              style: theme.textTheme.bodyMedium,
            ),
            Text(
              'direct (plugin-provisioned) translate: '
              '${report.directPathChecked ? (report.directPathPassed ? 'PASS' : 'FAIL') : 'not run'}',
              style: theme.textTheme.bodyMedium,
            ),
            const SizedBox(height: 8),
            // On failure this names the step and its exact reason — never a
            // generic sentence.
            SelectableText(
              ok ? 'Hindi: ${report.translatedText}' : report.failureHeadline,
              style: ok
                  ? theme.textTheme.bodyMedium
                  : theme.textTheme.bodyMedium?.copyWith(
                      fontFamily: 'monospace',
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Test B's verdict, which must distinguish "no translation happened" from
/// "translation failed".
class _OcrVerdict extends StatelessWidget {
  const _OcrVerdict({required this.report});

  final OcrTranslationSelfTestReport report;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final ok = report.passed;
    final inconclusive =
        !ok && !report.cancelled && report.firstFailure == null;

    return Card(
      color: ok
          ? theme.colorScheme.primaryContainer
          : inconclusive
          ? theme.colorScheme.surfaceContainerHighest
          : theme.colorScheme.errorContainer,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              ok
                  ? 'OCR → Hindi translation: PASS'
                  : report.cancelled
                  ? 'OCR → Hindi translation: NOT RUN'
                  : inconclusive
                  ? 'OCR → Hindi translation: NOT PROVEN'
                  : 'OCR → Hindi translation: FAIL',
              style: theme.textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            Text(
              'photo: ${report.imagePath ?? '(none)'}',
              style: theme.textTheme.bodySmall,
            ),
            if (report.ocrEngineName != null)
              Text(
                'read by: ${report.ocrEngineName}',
                style: theme.textTheme.bodySmall,
              ),
            if (report.detectedSource != null)
              Text(
                'detected source: ${report.detectedSource!.englishName} '
                '(${report.detectedSource!.code})',
                style: theme.textTheme.bodySmall,
              ),
            const SizedBox(height: 8),
            if (report.extractedText != null) ...[
              Text('Extracted:', style: theme.textTheme.labelMedium),
              SelectableText(
                report.extractedText!,
                style: theme.textTheme.bodyMedium,
              ),
              const SizedBox(height: 8),
            ],
            SelectableText(
              ok ? 'Hindi: ${report.translatedText}' : report.failureHeadline,
              style: theme.textTheme.bodyMedium?.copyWith(
                fontFamily: ok ? null : 'monospace',
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Shown when a *harness* failed rather than a step: a thrown error or the
/// watchdog.
class _FatalErrorCard extends StatelessWidget {
  const _FatalErrorCard({
    required this.detail,
    this.title = 'The diagnostic itself failed',
  });

  final String detail;
  final String title;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      color: theme.colorScheme.errorContainer,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: theme.textTheme.titleMedium),
            const SizedBox(height: 8),
            SelectableText(
              detail,
              style: theme.textTheme.bodySmall?.copyWith(
                fontFamily: 'monospace',
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _StepList extends StatelessWidget {
  const _StepList({required this.steps});

  final List<SelfTestStep> steps;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Steps', style: theme.textTheme.titleSmall),
        const SizedBox(height: 8),
        for (final step in steps)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  switch (step.status) {
                    SelfTestStatus.passed => Icons.check_circle_outline,
                    SelfTestStatus.failed => Icons.error_outline,
                    SelfTestStatus.timeout => Icons.timer_off_outlined,
                    SelfTestStatus.skipped => Icons.remove_circle_outline,
                  },
                  size: 18,
                  color: switch (step.status) {
                    SelfTestStatus.passed => Colors.green,
                    SelfTestStatus.failed => theme.colorScheme.error,
                    SelfTestStatus.timeout => theme.colorScheme.error,
                    SelfTestStatus.skipped => theme.colorScheme.outline,
                  },
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '${step.name}'
                        '${step.elapsed == null ? '' : ' (${step.elapsed!.inMilliseconds} ms)'}',
                        style: theme.textTheme.bodyMedium?.copyWith(
                          fontFamily: 'monospace',
                        ),
                      ),
                      if (step.detail != null)
                        SelectableText(
                          step.detail!,
                          style: theme.textTheme.bodySmall?.copyWith(
                            fontFamily: 'monospace',
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}
