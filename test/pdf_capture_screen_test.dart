import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdf_utility_flutter/pdf/presentation/pdf_capture_screen.dart';

void main() {
  /// The states a user actually gets stuck on. The live preview itself cannot be
  /// tested without hardware, which is why the camera is injected here.
  Widget harness(PdfCameraStarter starter) =>
      MaterialApp(home: PdfCaptureScreen(startCamera: starter));

  testWidgets('a device with no camera is told so, not left spinning', (
    tester,
  ) async {
    await tester.pumpWidget(harness(() async => null));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.text('The camera could not be started'), findsOneWidget);
    expect(find.text('No camera was found.'), findsOneWidget);
    expect(find.text('Try again'), findsOneWidget);
    expect(find.text('Go back'), findsOneWidget);

    // Nothing pretends to work: no shutter, no Review action.
    expect(find.text('Review pages'), findsNothing);
    expect(find.bySemanticsLabel('Capture page'), findsNothing);
  });

  testWidgets('a refused permission is explained as a permission', (
    tester,
  ) async {
    await tester.pumpWidget(
      harness(
        () async => throw CameraException(
          'CameraAccessDenied',
          'User denied the camera permission.',
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    // The difference between "allow the camera" and "this phone has no camera"
    // is the difference between a fixable setting and a dead end.
    expect(
      find.text('Camera access is needed to capture pages'),
      findsOneWidget,
    );
    expect(find.textContaining('Allow camera access'), findsOneWidget);
    expect(find.textContaining('gallery instead'), findsOneWidget);
  });

  testWidgets('a camera that fails for another reason says what happened', (
    tester,
  ) async {
    await tester.pumpWidget(
      harness(
        () async => throw CameraException(
          'CameraInitializationError',
          'The camera is already in use.',
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.text('The camera could not be started'), findsOneWidget);
    expect(find.text('The camera is already in use.'), findsOneWidget);
  });

  testWidgets('the header still lets the user out, with no camera at all', (
    tester,
  ) async {
    await tester.pumpWidget(harness(() async => null));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.text('Capture pages'), findsOneWidget);
    expect(find.byTooltip('Close'), findsOneWidget);
    // The torch control is unusable without a camera, so it is disabled rather
    // than offering something that cannot work.
    expect(
      tester
          .widget<IconButton>(
            find.ancestor(
              of: find.byTooltip('Turn on torch'),
              matching: find.byType(IconButton),
            ),
          )
          .onPressed,
      isNull,
    );
  });
}
