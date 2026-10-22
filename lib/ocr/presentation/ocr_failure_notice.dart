import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../domain/ocr_exception.dart';
import '../ocr_log.dart';

/// Reports an OCR failure the same way from every entry point.
///
/// Why one function rather than a `catch` block per screen
/// ------------------------------------------------------
/// Camera, gallery and PDF-page OCR all end in the same recognizer, so they must
/// also end in the same report. Before this, each screen had its own pair of
/// `catch` blocks that printed `OcrException.from(error).message` and dropped
/// the original exception — which made a device failure unreproducible from the
/// app: the user saw "Text recognition failed", and the cause was gone.
///
/// This helper:
/// * logs the **original** error and stack trace under `PDF_UTILITY_OCR`
///   (debug builds only), so `adb logcat | grep PDF_UTILITY_OCR` shows the real
///   cause;
/// * shows the user-facing sentence, with nothing technical in it;
/// * in debug builds only, offers a **Details** action that shows the kind, the
///   original exception and the stack trace — readable on the phone, without a
///   cable.
void showOcrFailure(
  BuildContext context,
  Object error, {
  StackTrace? stackTrace,
  String where = 'OCR',
}) {
  final failure = OcrException.from(error, stackTrace: stackTrace);
  // Always logged, release included: the person sees one calm sentence, while
  // logcat keeps the original error, its type and the stack.
  ocrDiagError(
    '$where failed (${failure.kind.name})'
    '${failure.cause == null ? '' : ' — original cause below'}',
    failure.cause ?? error,
    failure.stackTrace ?? stackTrace,
  );

  final messenger = ScaffoldMessenger.of(context);
  messenger.hideCurrentSnackBar();
  messenger.showSnackBar(
    SnackBar(
      content: Text(failure.message),
      // A release build carries no technical detail: the message is the whole
      // of what a user gets.
      action: kDebugMode
          ? SnackBarAction(
              label: 'Details',
              onPressed: () {
                if (!context.mounted) return;
                showOcrFailureDetails(context, failure);
              },
            )
          : null,
    ),
  );
}

/// The debug-only details dialog. Selectable so it can be copied into a bug
/// report from the device itself.
void showOcrFailureDetails(BuildContext context, OcrException failure) {
  showDialog<void>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: const Text('OCR error details'),
      content: SingleChildScrollView(
        child: SelectableText(
          failure.debugDescription,
          style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(),
          child: const Text('Close'),
        ),
      ],
    ),
  );
}
