import 'ocr_line.dart';
import 'ocr_result.dart';

/// How far a photographed page is turned, expressed as the quarter turns that
/// have to be applied **clockwise** to stand it upright.
///
/// Why this exists
/// ---------------
/// EXIF orientation describes how the *camera* recorded an image; it says
/// nothing about how the *page* was held. A photograph of a landscape document
/// taken in portrait, a page scanned sideways, or a PDF page exported in the
/// wrong aspect ratio all arrive with perfectly valid, perfectly upright
/// metadata — the pixels themselves are turned. Flutter's decoder faithfully
/// reproduces those pixels, so the app used to display (and recognise) a page
/// lying on its side:
///
/// * every OCR line box was a tall, narrow strip,
/// * the translation overlay had to fit sentences into those strips, which is
///   what produced one-letter-per-line "vertical" labels, and
/// * the photo itself was unreadable without tilting the phone.
///
/// This value is the *decision* — how much to turn the pixels — and it is
/// deliberately separate from the [DocumentOrientationDetector] that reaches it
/// and from the image code that performs it, so both halves are testable.
class DocumentOrientation {
  /// Creates an orientation of [quarterTurnsClockwise] quarter turns (0–3).
  const DocumentOrientation(this.quarterTurnsClockwise)
    : assert(
        quarterTurnsClockwise >= 0 && quarterTurnsClockwise < 4,
        'quarter turns are 0–3',
      );

  /// The image is already upright: nothing is rotated.
  static const DocumentOrientation upright = DocumentOrientation(0);

  /// Quarter turns **clockwise** needed to stand the page upright.
  ///
  /// 0 = upright, 1 = 90° clockwise, 2 = 180°, 3 = 270° clockwise.
  final int quarterTurnsClockwise;

  bool get isUpright => quarterTurnsClockwise == 0;

  /// Whether applying this orientation swaps width and height.
  bool get swapsAxes => quarterTurnsClockwise.isOdd;

  /// Width of an image of [width]×[height] after this orientation is applied.
  int widthOf(int width, int height) => swapsAxes ? height : width;

  /// Height of an image of [width]×[height] after this orientation is applied.
  int heightOf(int width, int height) => swapsAxes ? width : height;

  /// Short, user- and log-facing description of the turn.
  String get label => switch (quarterTurnsClockwise) {
    0 => 'upright',
    1 => 'rotated 90° clockwise',
    2 => 'upside down',
    _ => 'rotated 90° anticlockwise',
  };

  @override
  bool operator ==(Object other) =>
      other is DocumentOrientation &&
      other.quarterTurnsClockwise == quarterTurnsClockwise;

  @override
  int get hashCode => quarterTurnsClockwise.hashCode;

  @override
  String toString() => 'DocumentOrientation($label)';
}

/// Decides which way a page is turned from the OCR geometry ML Kit already
/// returns.
///
/// Two independent witnesses, both taken from the reading itself
/// --------------------------------------------------------------
/// 1. **Shape.** A line of upright text is wider than it is tall; a line of
///    text lying on its side is a tall, narrow strip. On the real newspaper
///    page in `test/assets/real/` the long lines measure ~24 px wide by ~450 px
///    tall in the stored pixels, and ~450 × 24 once the page is stood up — a
///    19× aspect flip, so shape alone separates the two cases cleanly.
/// 2. **Word order.** ML Kit reports a line's words in *reading* order. In a
///    tall line, reading downwards means the page is lying rotated clockwise
///    (it has to be turned anticlockwise to stand up) and reading upwards means
///    the opposite. This is what picks the direction, and it deliberately does
///    **not** use the sign of `TextLine.angle`: that sign's convention (clockwise
///    or anticlockwise from horizontal, normalised to ±90 or 0–360) is not
///    stated consistently across platforms and plugin versions, while the order
///    of a line's words is unambiguous. A convention the code cannot verify is
///    exactly the kind of assumption that produced a page turned the wrong way.
///
/// The one case word order cannot see is a page that is upside down, and there
/// the ambiguity disappears: 180° clockwise and 180° anticlockwise are the same
/// image, so the **magnitude** of the reported angle is enough and its sign can
/// be ignored.
///
/// The decision is **weighted by real text**, not by line count, so a table
/// with a few sideways headers cannot outvote the body of a page. It also
/// refuses to act on weak evidence: a page must have a clear majority at one
/// quarter turn before any pixels are moved, and pages with almost no text are
/// left alone. Turning an image is destructive to its pixel grid (one re-encode)
/// and costs a second recognition pass, so the detector only spends that when
/// the page is plainly sideways.
class DocumentOrientationDetector {
  const DocumentOrientationDetector({
    this.minimumShare = 0.6,
    this.minimumCharacters = 24,
    this.tallLineRatio = 1.15,
  });

  /// Fraction of the page's text (by character count) that must agree on one
  /// quarter turn before the page is turned.
  ///
  /// 60 % leaves room for a header, a stamp or a rotated table cell without
  /// flipping a page that is genuinely upright, while a sideways page scores
  /// ~100 % — the two cases are nowhere near the threshold.
  final double minimumShare;

  /// Minimum amount of recognised text (characters) before the detector will
  /// turn anything at all. A photo of a label with one word is not evidence of
  /// a page's orientation.
  final int minimumCharacters;

  /// How much taller than wide a line box has to be before it counts as
  /// vertical text.
  ///
  /// Upright words are wider than tall, but `1.15` rather than `1.0` absorbs the
  /// nearly square box of a short word ("12", "क्र.") without ever mistaking a
  /// real line of prose — measured at roughly 1:12 to 1:19 on this page — for a
  /// sideways one.
  final double tallLineRatio;

  /// The turn to apply to [result]'s image so its text reads upright.
  DocumentOrientation detect(OcrResult result) {
    final weightByTurn = List<int>.filled(4, 0);
    var total = 0;

    for (final line in result.lines) {
      final weight = _weightOf(line);
      if (weight == 0) continue;
      final turn = _turnOf(line);
      if (turn == null) continue;
      weightByTurn[turn.quarterTurnsClockwise] += weight;
      total += weight;
    }

    if (total < minimumCharacters) return DocumentOrientation.upright;

    var best = 0;
    for (var turn = 1; turn < 4; turn++) {
      if (weightByTurn[turn] > weightByTurn[best]) best = turn;
    }

    if (best == 0) return DocumentOrientation.upright;
    if (weightByTurn[best] / total < minimumShare) {
      return DocumentOrientation.upright;
    }

    return DocumentOrientation(best);
  }

  /// Text length in characters — the amount of page evidence a line represents.
  static int _weightOf(OcrLine line) => line.text.trim().runes.length;

  /// The turn this line implies, or `null` when it has no opinion.
  ///
  /// The turn is named by what has to be done to the **image**: 3 means the
  /// image must be turned 270° clockwise (90° anticlockwise) to become upright.
  ///
  /// A vertical line whose words are not separated vertically (one word, or a
  /// stack ML Kit reported as a single word) cannot say which way it reads, so
  /// it abstains rather than guessing — guessing is what a page turned the
  /// wrong way is worth.
  DocumentOrientation? _turnOf(OcrLine line) {
    final box = line.boundingBox;
    final elements = line.elements;
    final isVertical = box.height > box.width * tallLineRatio;

    if (!isVertical) {
      // Horizontal: the page is upright unless the baseline is reversed, and
      // an upside-down turn is the same 180° whichever way the angle's sign
      // points, so only its magnitude is used.
      return _isReversed(line.angle)
          ? const DocumentOrientation(2)
          : DocumentOrientation.upright;
    }

    if (elements.length < 2) return null;

    final firstY = elements.first.boundingBox.centerY;
    final lastY = elements.last.boundingBox.centerY;
    if ((lastY - firstY).abs() < 1) return null;

    // Reading downwards means the page lies rotated clockwise: standing it up
    // needs an anticlockwise quarter turn (3 clockwise). Reading upwards means
    // the mirror image of that.
    return lastY > firstY
        ? const DocumentOrientation(3)
        : const DocumentOrientation(1);
  }

  /// Whether [angle] is closer to 180° than to 0°, ignoring its sign.
  ///
  /// `null` means the engine reported no angle (iOS), which is not evidence of
  /// a turned page.
  static bool _isReversed(double? angle) {
    if (angle == null || !angle.isFinite) return false;
    final magnitude = angle.abs() % 360;
    final folded = magnitude > 180 ? 360 - magnitude : magnitude;
    return folded > 135;
  }
}
