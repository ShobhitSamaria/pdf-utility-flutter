import '../../ocr/domain/ocr_rect.dart';
import 'translation_language.dart';
import 'translation_request.dart';
import 'translation_result.dart';

/// What a translated region corresponds to in the OCR result.
///
/// Kept explicit so the overlay can style/anchor whole-page lines differently
/// from a user-selected run of words if it ever needs to.
enum TranslatedRegionKind {
  /// One recognized OCR **line**.
  ///
  /// Still used for small units (a table cell, a caption, a leftover line), but
  /// whole-page translation now works in [paragraph]s: translating one line at
  /// a time is what turned a page into unconnected fragments.
  line,

  /// A recognised paragraph, heading or caption: several neighbouring lines of
  /// one column, translated as a single run of prose.
  paragraph,

  /// A run of words the user selected.
  selection,
}

/// A unit of text to translate, bound to the OCR geometry it came from.
///
/// This is the bridge between the two features: the OCR layer supplies
/// [text] + [bounds] (image-pixel space), the translation layer supplies the
/// translated string. Nothing else about OCR leaks in — no engine, no blocks,
/// no confidence scores.
class TranslationUnit {
  const TranslationUnit({
    required this.id,
    required this.text,
    required this.bounds,
    required this.kind,
  });

  /// Stable identifier, unique within one batch, preserving reading order.
  ///
  /// Results are matched back to units by id, so nothing depends on a
  /// translation engine echoing its input back verbatim.
  final int id;

  /// The source text (an OCR line, or the joined selected words).
  final String text;

  /// Where this text sits in the **source image**, in image pixels.
  final OcrRect bounds;

  final TranslatedRegionKind kind;

  /// Whether the geometry can actually be drawn over the photo.
  bool get hasGeometry => !bounds.isEmpty;

  TranslationUnit copyWith({
    int? id,
    String? text,
    OcrRect? bounds,
    TranslatedRegionKind? kind,
  }) => TranslationUnit(
    id: id ?? this.id,
    text: text ?? this.text,
    bounds: bounds ?? this.bounds,
    kind: kind ?? this.kind,
  );

  @override
  bool operator ==(Object other) =>
      other is TranslationUnit &&
      other.id == id &&
      other.text == text &&
      other.bounds == bounds &&
      other.kind == kind;

  @override
  int get hashCode => Object.hash(id, text, bounds, kind);

  @override
  String toString() =>
      'TranslationUnit($id, ${kind.name}, $bounds, "${text.length} chars")';
}

/// One translated piece of the image: the original text, its translation, and
/// the **original** bounding rectangle in source-image pixels.
///
/// The rectangle is deliberately the *source* geometry, not a screen rectangle:
/// screen placement is recomputed from it on every layout via the same
/// `OcrCoordinateMapper` the OCR overlay uses, so the two can never drift.
class TranslatedRegion {
  const TranslatedRegion({
    required this.id,
    required this.sourceText,
    required this.translatedText,
    required this.bounds,
    required this.kind,
  });

  final int id;
  final String sourceText;
  final String translatedText;
  final OcrRect bounds;
  final TranslatedRegionKind kind;

  /// Whether this region can be painted over the photo: it needs both geometry
  /// and actual translated text (engines can return whitespace for a region).
  bool get isRenderable => !bounds.isEmpty && translatedText.trim().isNotEmpty;

  @override
  String toString() =>
      'TranslatedRegion($id, ${kind.name}, $bounds, '
      '"$sourceText" -> "$translatedText")';
}

/// The complete set of translated regions for one image, in reading order.
///
/// This is what the overlay renders and what the "read the full text" sheet
/// flattens back into a [TranslationResult].
class TranslatedOverlay {
  const TranslatedOverlay({
    required this.regions,
    required this.sourceLanguage,
    required this.targetLanguage,
    this.sourceWasAutoDetected = false,
    this.alreadyInTargetLanguage = false,
    this.elapsed,
  });

  /// Regions in OCR reading order. Regions without geometry are still listed
  /// (their text is not lost), they are simply not drawn.
  final List<TranslatedRegion> regions;

  final TranslationLanguage sourceLanguage;
  final TranslationLanguage targetLanguage;
  final bool sourceWasAutoDetected;

  /// `true` when the source already was the target language, so the text was
  /// echoed back instead of round-tripping through the engine.
  final bool alreadyInTargetLanguage;

  final Duration? elapsed;

  bool get isEmpty => regions.isEmpty;

  /// Regions that can actually be drawn over the photo.
  List<TranslatedRegion> get renderableRegions => [
    for (final region in regions)
      if (region.isRenderable) region,
  ];

  bool get hasRenderableRegions => regions.any((r) => r.isRenderable);

  /// A flat, text-only view of the same translation, used for copy/read
  /// surfaces.
  ///
  /// Paragraph units are separated by a blank line and single-line units by one
  /// newline, so the full text keeps the document's paragraph boundaries instead
  /// of running everything together — or, worse, repeating fragments in engine
  /// order. Regions are already in reading order.
  TranslationResult asResult(TranslationScope scope) => TranslationResult(
    originalText: _flatten((region) => region.sourceText),
    translatedText: _flatten((region) => region.translatedText),
    sourceLanguage: sourceLanguage,
    targetLanguage: targetLanguage,
    scope: scope,
    sourceWasAutoDetected: sourceWasAutoDetected,
    alreadyInTargetLanguage: alreadyInTargetLanguage,
    elapsed: elapsed,
  );

  String _flatten(String Function(TranslatedRegion region) select) {
    final buffer = StringBuffer();
    for (final region in regions) {
      final text = select(region).trim();
      if (text.isEmpty) continue;
      if (buffer.isNotEmpty) {
        buffer.write(
          region.kind == TranslatedRegionKind.paragraph ? '\n\n' : '\n',
        );
      }
      buffer.write(text);
    }
    return buffer.toString();
  }

  @override
  String toString() =>
      'TranslatedOverlay(${regions.length} regions, '
      '${sourceLanguage.code} -> ${targetLanguage.code})';
}
