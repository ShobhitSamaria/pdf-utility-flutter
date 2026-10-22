import '../domain/pdf_creation.dart';
import '../domain/pdf_output_directory.dart';
import 'native_pdf_output_directory.dart';
import 'pdf_library_creation_service.dart';

/// The PDF writer the app actually ships with.
///
/// This is the composition root for PDF *creation*, the counterpart of
/// `main.dart`'s service builders: the writer, the engine and the directory it
/// writes into are decided here and nowhere else, so the screens depend on
/// [PdfCreationService] and a test can substitute its own.
///
/// The output directory is the **platform's cache directory**, obtained through
/// the app's own native channel (`NativePdfOutputDirectory`). Not
/// `Directory.systemTemp`, whose Android answer is a path an app process cannot
/// write to — the one detail that would have turned every export into a
/// "could not save" on the platform this app ships to.
PdfCreationService createPdfCreationService({
  PdfOutputDirectory outputDirectory = const NativePdfOutputDirectory(),
}) => PdfLibraryCreationService(outputDirectory: outputDirectory);
