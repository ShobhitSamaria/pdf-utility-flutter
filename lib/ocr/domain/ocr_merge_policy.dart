import 'ocr_block.dart';
import 'ocr_line.dart';
import 'ocr_rect.dart';
import 'ocr_result.dart';
import 'ocr_text_utils.dart';

/// Combines two single-script recognition passes over the **same image** into
/// one [OcrResult].
///
/// Why this exists
/// ---------------
/// ML Kit ships one recognizer per script and refuses to claim any of them reads
/// two scripts well: the Devanagari model is a *different model* from the Latin
/// one. A page that mixes Hindi and English therefore cannot be read by
/// selecting a single recognizer — whichever one is chosen, half the page is
/// read by a model that was not trained for it.
///
/// The only honest options are:
///
/// 1. **Let the user pick** the dominant script (single pass, full speed). This
///    is the default in `OcrScriptMode.latin` / `OcrScriptMode.devanagari`.
/// 2. **Read the page twice and merge**, which is what this class does. It
///    costs roughly double the latency and its accuracy is a claim that has to
///    be *measured*, not asserted.
///
/// This policy is deliberately conservative. It never fuses characters or words
/// across engines — no "take the letters this model got right and the letters
/// that model got right" stitching, because that would be guessing at text the
/// user is about to copy. Instead it treats each engine's **line** as an
/// all-or-nothing candidate for the region its bounding box covers, and picks
/// one winner per colliding region.
///
/// The decision rule
/// -----------------
/// Two candidates *collide* when their boxes overlap by at least
/// [overlapIouThreshold] (intersection-over-union). For a collision, in order:
///
/// 1. If exactly one candidate contains Devanagari code points, it wins. Only
///    the Devanagari model can emit them, so their presence is strong evidence
///    about which pass actually read the region — and the case this rule exists
///    for is a Hindi line that the Latin pass rendered as plausible-looking
///    Latin garbage.
/// 2. If both (or neither) contain Devanagari code points, the candidate with
///    more non-whitespace characters wins, then the primary (Latin) pass. The
///    Latin model is the better Latin reader, so ties and near-ties resolve
///    toward it deterministically.
///
/// Candidates that do **not** collide are all kept, which is the common shape of
/// a real mixed page: the English paragraph and the Hindi paragraph land in
/// different places, so both surviving passes contribute without interacting.
///
/// Structural caveat
/// -----------------
/// The output is rebuilt as **one block per surviving line**, in reading order
/// (top to bottom, then left to right). Word geometry is carried over verbatim
/// and is what every downstream feature uses (selection, hit-testing, search),
/// but the original paragraph grouping is lost — a merge cannot preserve a
/// block structure that came from two different recognizers. Displayed layout
/// is unaffected because nothing renders block boxes except the debug painter.
class OcrMergePolicy {
  const OcrMergePolicy({
    this.overlapIouThreshold = 0.3,
    this.engineName = 'Google ML Kit (Latin + Devanagari)',
  });

  /// Intersection-over-union at or above which two line boxes are considered to
  /// describe the same region of the page.
  final double overlapIouThreshold;

  /// [OcrResult.engineName] for merged results, so the summary strip makes it
  /// obvious that two passes produced the text.
  final String engineName;

  /// Merges a [primary] (Latin) and [secondary] (Devanagari) pass.
  ///
  /// [elapsed] is the wall-clock time of **both** passes, supplied by the
  /// caller, because neither individual result knows the total.
  OcrResult merge({
    required OcrResult primary,
    required OcrResult secondary,
    Duration? elapsed,
  }) {
    final secondaryHasText = secondary.lines.any(
      (line) => line.text.trim().isNotEmpty,
    );

    // Fast path for the single-script page that dominates real usage: the
    // Devanagari pass found nothing, so nothing can collide and the primary
    // result is returned with its original block structure intact.
    if (!secondaryHasText) {
      return OcrResult(
        sourceImage: primary.sourceImage,
        fullText: primary.fullText,
        blocks: primary.blocks,
        engineName: engineName,
        elapsed: elapsed ?? primary.elapsed,
      );
    }

    final accepted = <_LineCandidate>[];
    for (final line in primary.lines) {
      _offer(accepted, _LineCandidate(line, isPrimary: true));
    }
    for (final line in secondary.lines) {
      _offer(accepted, _LineCandidate(line, isPrimary: false));
    }

    accepted.sort((a, b) {
      final byTop = a.line.boundingBox.top.compareTo(b.line.boundingBox.top);
      if (byTop != 0) return byTop;
      return a.line.boundingBox.left.compareTo(b.line.boundingBox.left);
    });

    final blocks = <OcrBlock>[
      for (final candidate in accepted)
        OcrBlock(
          text: candidate.line.text,
          boundingBox: candidate.line.boundingBox,
          recognizedLanguages: candidate.line.recognizedLanguages,
          lines: <OcrLine>[candidate.line],
        ),
    ];

    return OcrResult(
      sourceImage: primary.sourceImage,
      fullText: blocks.map((block) => block.text).join('\n'),
      blocks: blocks,
      engineName: engineName,
      elapsed: elapsed ?? primary.elapsed,
    );
  }

  /// Adds [candidate] to [accepted], replacing the region's current winner when
  /// it wins the collision. Non-colliding candidates are simply appended.
  void _offer(List<_LineCandidate> accepted, _LineCandidate candidate) {
    if (candidate.line.text.trim().isEmpty) return;
    if (candidate.line.boundingBox.isEmpty) return;

    for (var i = 0; i < accepted.length; i++) {
      final incumbent = accepted[i];
      if (_intersectionOverUnion(
            incumbent.line.boundingBox,
            candidate.line.boundingBox,
          ) <
          overlapIouThreshold) {
        continue;
      }
      // One survivor per region; nothing is ever appended alongside it.
      if (_beats(candidate, incumbent)) accepted[i] = candidate;
      return;
    }
    accepted.add(candidate);
  }

  /// Whether [challenger] should own a region currently held by [incumbent].
  /// See the class doc for the rule and its reasoning.
  bool _beats(_LineCandidate challenger, _LineCandidate incumbent) {
    final challengerDevanagari = OcrTextUtils.containsDevanagari(
      challenger.line.text,
    );
    final incumbentDevanagari = OcrTextUtils.containsDevanagari(
      incumbent.line.text,
    );
    if (challengerDevanagari != incumbentDevanagari) {
      return challengerDevanagari;
    }
    if (incumbent.isPrimary != challenger.isPrimary) {
      // Same script-ness: the Latin pass is the better Latin reader, and for a
      // Devanagari-vs-Devanagari collision there is nothing to choose between
      // them, so bias to the primary pass for a deterministic outcome.
      return challenger.isPrimary && !incumbent.isPrimary;
    }
    // Same pass (cannot happen — boxes within one pass do not collide at this
    // threshold in practice) or genuinely identical: prefer the longer read.
    return challenger.line.text.trim().length >
        incumbent.line.text.trim().length;
  }

  /// Intersection over union of two rectangles, in `[0, 1]`. `0` when they do
  /// not overlap or either is degenerate.
  static double _intersectionOverUnion(OcrRect a, OcrRect b) {
    final left = a.left > b.left ? a.left : b.left;
    final top = a.top > b.top ? a.top : b.top;
    final right = a.right < b.right ? a.right : b.right;
    final bottom = a.bottom < b.bottom ? a.bottom : b.bottom;

    final intersectionWidth = right - left;
    final intersectionHeight = bottom - top;
    if (intersectionWidth <= 0 || intersectionHeight <= 0) return 0;

    final intersection = intersectionWidth * intersectionHeight;
    final union = a.width * a.height + b.width * b.height - intersection;
    if (union <= 0) return 0;
    return intersection / union;
  }
}

/// A line from one pass, competing for the region its box covers.
class _LineCandidate {
  const _LineCandidate(this.line, {required this.isPrimary});

  final OcrLine line;

  /// `true` when this line came from the primary (Latin) pass.
  final bool isPrimary;
}
