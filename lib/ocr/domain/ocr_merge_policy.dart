import 'ocr_block.dart';
import 'ocr_document_layout.dart';
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
/// Structural rule
/// ---------------
/// The pass that read more text supplies the **block structure**; the other pass
/// only contributes lines the base did not read, and may replace a base line in
/// place when it wins a collision. Word geometry is carried over verbatim and is
/// what every downstream feature uses (selection, hit-testing, search). The
/// resulting blocks are then ordered by `OcrDocumentLayout`, so the full text is
/// in document reading order rather than engine-block order.
///
/// Rebuilding the output as one block per line — an earlier implementation —
/// destroyed every paragraph and, on a multi-column page, made the reading order
/// row-by-row across columns. Keeping the base pass's blocks is what stops a
/// newspaper from being reported as 79 alternating single-line fragments.
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

    // Keep the pass that read more as the **structural base** and add only what
    // the other pass read that the base did not.
    //
    // The previous implementation rebuilt the result as one block per surviving
    // line, sorted top-then-left. That discarded every paragraph boundary and,
    // on a multi-column page, read the page row by row: left column, middle
    // column, right column, next row — the exact interleaving that looks like
    // text from the middle column is missing. Paragraph structure is now kept
    // from the base pass, and reading order is recovered by the same layout
    // engine the rest of the app uses.
    final secondaryLeads = _letterCount(secondary) > _letterCount(primary);
    final base = secondaryLeads ? secondary : primary;
    final other = secondaryLeads ? primary : secondary;
    final baseIsPrimary = !secondaryLeads;

    final blocks = <_MutableBlock>[
      for (final block in base.blocks)
        _MutableBlock(<OcrLine>[
          for (final line in block.lines)
            if (line.text.trim().isNotEmpty && !line.boundingBox.isEmpty) line,
        ]),
    ]..removeWhere((block) => block.lines.isEmpty);

    for (final line in other.lines) {
      if (line.text.trim().isEmpty || line.boundingBox.isEmpty) continue;

      _MutableBlock? owner;
      var ownerIndex = -1;
      var bestOverlap = 0.0;
      for (final block in blocks) {
        for (var index = 0; index < block.lines.length; index++) {
          final overlap = _intersectionOverUnion(
            block.lines[index].boundingBox,
            line.boundingBox,
          );
          if (overlap >= overlapIouThreshold && overlap > bestOverlap) {
            bestOverlap = overlap;
            owner = block;
            ownerIndex = index;
          }
        }
      }

      if (owner == null) {
        // A region only the other pass read: a genuinely mixed page, e.g. an
        // English heading above Hindi body text. It becomes its own unit; the
        // layout may join it to a neighbour if the geometry says so — but only
        // if it is real text. The Latin model pointed at Devanagari emits short
        // symbol-soup fragments that do not always collide with a Devanagari
        // line; appending those would inject junk into an otherwise clean page.
        if (_isCredible(line)) {
          blocks.add(_MutableBlock(<OcrLine>[line]));
        }
        continue;
      }

      final incumbent = owner.lines[ownerIndex];
      final challenger = _LineCandidate(line, isPrimary: !baseIsPrimary);
      final current = _LineCandidate(incumbent, isPrimary: baseIsPrimary);
      if (_beats(challenger, current)) {
        // Replace the word geometry in place so the surrounding paragraph keeps
        // its lines, bounds and reading position.
        owner.lines[ownerIndex] = line;
      }
    }

    final baseBlocks = <OcrBlock>[
      for (final block in blocks)
        OcrBlock(
          text: OcrDocumentLayout.joinLines(
            block.lines.map((line) => line.text),
          ),
          boundingBox: OcrDocumentLayout.boundsOf(block.lines),
          lines: List<OcrLine>.unmodifiable(block.lines),
        ),
    ];

    // Order the surviving blocks with the document layout, so `fullText` is in
    // reading order rather than engine-block order. Paragraphs are formed by the
    // same rules the UI uses; running it again downstream is idempotent.
    final ordered = OcrDocumentLayout.blocks(
      OcrResult(
        sourceImage: base.sourceImage,
        fullText: '',
        blocks: baseBlocks,
        engineName: engineName,
      ),
    );
    final mergedBlocks = <OcrBlock>[
      for (final block in ordered)
        OcrBlock(
          text: block.text,
          boundingBox: block.bounds,
          lines: block.lines,
        ),
    ];

    return OcrResult(
      sourceImage: base.sourceImage,
      fullText: mergedBlocks.map((block) => block.text).join('\n'),
      blocks: mergedBlocks,
      engineName: engineName,
      elapsed: elapsed ?? base.elapsed,
    );
  }

  /// Whether [line] is real text in its own script rather than the symbol soup
  /// a model produces when pointed at a script it was not trained for.
  ///
  /// Devanagari code points are only emitted by the Devanagari model, so their
  /// presence is sufficient evidence and needs no shape test. Latin text gets
  /// three checks, all taken from what this engine actually emitted over real
  /// Devanagari type (`"far"`, `"Hhcill"`, `"fufat H BH, 2022 fr44 3"`):
  ///
  /// * **Letter dominance** — letters must make up most of the line's
  ///   characters that are not digits. Digits are content on a real page
  ///   (`NOC 2022`, `Rs. 500`), so they are excluded from that ratio; what is
  ///   rejected here is a box that is mostly punctuation and symbols.
  /// * **No scrambled token.** A recognizer reading the wrong script emits
  ///   tokens with a capital *inside* an alphabetic run (`sTqT`), a letter
  ///   repeated with inconsistent case (`Hhcill`) or letters fused with digits
  ///   (`fr44`). Printed words do not do that, while hyphenation, plural forms
  ///   and abbreviations all survive the test, so this separates the junk from
  ///   real text without a word list — and a word list would only ever cover
  ///   one language.
  /// * **Enough letters to be a word.** Four is the floor for ordinary words
  ///   (`Name`, `Total`, `Report`), and a line that is all capitals is accepted
  ///   from two letters because that is how abbreviations and short headings
  ///   are printed (`PDF`, `NOC`, `RTI`).
  ///
  /// The rule is deliberately lenient: the caller only applies it to text the
  /// base pass did not read at all, and losing a real English heading on a
  /// Hindi page is a worse failure than keeping a stray fragment. It rejects
  /// short symbol soup and scrambled tokens, not "anything unusual".
  static bool _isCredible(OcrLine line) {
    if (OcrTextUtils.containsDevanagari(line.text)) return true;

    var latin = 0;
    var symbols = 0;
    var uppercase = 0;

    for (final token in line.text.split(_whitespace)) {
      var tokenLetters = 0;
      var tokenUppercase = 0;
      var tokenHasLowercase = false;
      var tokenHasDigit = false;
      for (final rune in token.runes) {
        if (_isAsciiLetter(rune)) {
          tokenLetters++;
          if (_isAsciiUppercase(rune)) {
            tokenUppercase++;
          } else {
            tokenHasLowercase = true;
          }
        } else if (rune >= 0x30 && rune <= 0x39) {
          tokenHasDigit = true;
        } else {
          symbols++;
        }
      }
      if (tokenLetters == 0) continue;
      // Letter/digit fusion is a hallmark of a mis-aimed recognizer, but a
      // genuine code such as `COVID19` or `12A` is all capitals.
      if (tokenHasDigit && tokenHasLowercase) return false;
      if (tokenHasLowercase && _isScrambled(token)) return false;
      latin += tokenLetters;
      uppercase += tokenUppercase;
    }

    final usable = latin + symbols;
    if (latin == 0 || usable == 0) return false;
    if (latin / usable < 0.6) return false;
    if (uppercase == latin) return latin >= 2;
    return latin >= 4;
  }

  /// Whether a token that contains lower-case letters also contains a shape a
  /// printed word cannot have: a capital after the first letter, or the same
  /// letter twice in a row with inconsistent case.
  ///
  /// Both are what this engine's output looks like when it is reading a script
  /// it was not trained for (`Hhcill`, `sTqT`), and neither can occur in an
  /// ordinary word or in a normal abbreviation. Tokens without any lower-case
  /// letters are left alone, so `PDF`, `NOC` and `COVID19` are unaffected; the
  /// known cost is that a brand name with an internal capital (`iPhone`) would
  /// be rejected, which is rare on the documents this app reads and is the
  /// direction this filter deliberately errs in.
  static bool _isScrambled(String token) {
    var seenLetter = false;
    int? previous;
    var capitalAfterFirstLetter = false;
    var inconsistentRepeat = false;
    for (final rune in token.runes) {
      if (!_isAsciiLetter(rune)) {
        previous = null;
        continue;
      }
      if (seenLetter && _isAsciiUppercase(rune)) capitalAfterFirstLetter = true;
      if (previous != null &&
          _sameLetterIgnoringCase(previous, rune) &&
          (previous >= 0x41 && previous <= 0x5A) !=
              (rune >= 0x41 && rune <= 0x5A)) {
        inconsistentRepeat = true;
      }
      seenLetter = true;
      previous = rune;
    }
    return capitalAfterFirstLetter || inconsistentRepeat;
  }

  static bool _sameLetterIgnoringCase(int a, int b) {
    int lower(int rune) => rune >= 0x41 && rune <= 0x5A ? rune + 0x20 : rune;
    return lower(a) == lower(b);
  }

  static bool _isAsciiLetter(int rune) =>
      (rune >= 0x41 && rune <= 0x5A) || (rune >= 0x61 && rune <= 0x7A);

  static bool _isAsciiUppercase(int rune) => rune >= 0x41 && rune <= 0x5A;

  static final RegExp _whitespace = RegExp(r'\s+');

  /// Letters in [result], used only to pick the structural base. Devanagari
  /// matras count, because they are part of the word.
  static int _letterCount(OcrResult result) {
    var count = 0;
    for (final line in result.lines) {
      for (final rune in line.text.runes) {
        if ((rune >= 0x41 && rune <= 0x5A) ||
            (rune >= 0x61 && rune <= 0x7A) ||
            (rune >= 0x0900 && rune <= 0x0963) ||
            (rune >= 0x0971 && rune <= 0x097F)) {
          count++;
        }
      }
    }
    return count;
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

/// A block being built during a merge, with mutable lines so a winning
/// challenger can replace the incumbent without losing the paragraph.
class _MutableBlock {
  _MutableBlock(this.lines);

  final List<OcrLine> lines;
}

/// A line from one pass, competing for the region its box covers.
class _LineCandidate {
  const _LineCandidate(this.line, {required this.isPrimary});

  final OcrLine line;

  /// `true` when this line came from the primary (Latin) pass.
  final bool isPrimary;
}
