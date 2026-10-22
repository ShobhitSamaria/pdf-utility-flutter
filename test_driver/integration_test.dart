import 'package:integration_test/integration_test_driver.dart';

/// Driver for `flutter drive`, used to run the OCR integration suite against a
/// **release** build:
///
/// ```
/// flutter drive --driver=test_driver/integration_test.dart \
///   --target=integration_test/ocr_device_test.dart --release -d emulator-5554
/// ```
///
/// A release run is the only way to reproduce a failure that depends on R8, the
/// app's shipped configuration, or AOT compilation.
Future<void> main() => integrationDriver();
