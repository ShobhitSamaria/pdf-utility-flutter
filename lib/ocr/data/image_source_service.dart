import 'package:image_picker/image_picker.dart';
import 'package:image_picker_android/image_picker_android.dart';
import 'package:image_picker_platform_interface/image_picker_platform_interface.dart';

/// Thin wrapper around gallery image selection.
///
/// The live camera path is handled by `CameraCaptureScreen` (which needs the
/// `camera` package's preview controller); this service only covers picking an
/// existing image, which is a single platform call.
class ImageSourceService {
  ImageSourceService({ImagePicker? picker})
    : _picker = picker ?? _createPicker();

  /// Builds the picker used for both single- and multi-image selection.
  ///
  /// On Android this opts into the system **Photo Picker**. Without it the
  /// plugin falls back to `ACTION_GET_CONTENT`, which on this app's minimum
  /// Android versions opens a file browser (DocumentsUI) — a storage UI, not a
  /// gallery. Opting in is a no-op on other platforms.
  static ImagePicker _createPicker() {
    final platform = ImagePickerPlatform.instance;
    if (platform is ImagePickerAndroid) {
      platform.useAndroidPhotoPicker = true;
    }
    return ImagePicker();
  }

  final ImagePicker _picker;

  /// Opens the system gallery/photo picker and returns the selected image's
  /// file path, or `null` if the user cancelled.
  ///
  /// On modern Android this uses the Photo Picker, so no storage permission is
  /// required. `imageQuality` is left untouched to preserve OCR fidelity — the
  /// full-resolution image is important for accurate bounding boxes.
  Future<String?> pickFromGallery() async {
    final file = await _picker.pickImage(source: ImageSource.gallery);
    return file?.path;
  }

  /// Opens the same picker in **multi-select** mode and returns the chosen
  /// images' paths, in the order the platform returned them.
  ///
  /// Used by the PDF creation flow, where several pages are chosen at once.
  /// Kept here rather than in a second service so both features share one
  /// picker, one set of platform quirks and one place to fix them.
  ///
  /// The returned list is empty when the user cancels — the platform reports a
  /// cancelled multi-pick as an empty selection, and "nothing chosen" is a
  /// normal outcome rather than a failure. Order is preserved as given: it is
  /// the order the pages will appear in the document, so it is never sorted.
  ///
  /// `imageQuality` is not touched, for the same reason as the single-pick
  /// path: re-encoding the images would cost a generation of quality on a page
  /// that is about to be embedded at full size.
  Future<List<String>> pickMultipleFromGallery() async {
    final files = await _picker.pickMultiImage();
    return <String>[for (final file in files) file.path];
  }
}
