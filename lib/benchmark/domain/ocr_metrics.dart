/// Accuracy metrics for OCR output, plus the latency aggregation the report
/// needs. Pure Dart, no dependencies, fully unit-testable.
///
/// Scoring only, never display
/// ---------------------------
/// [normalize] exists so that two runs can be compared fairly; it is applied to
/// the *scored copies* of the reference and the hypothesis. The text the user
/// sees comes straight from the engine and is never rewritten by any of this.
class OcrMetrics {
  const OcrMetrics._();

  /// Folds text into the form that gets scored.
  ///
  /// Applied to **both** sides, so it can never favour a hypothesis:
  ///
  /// * runs of whitespace (including NBSP, line/paragraph separators and the
  ///   ideographic space) collapse to one plain space, and ends are trimmed, so
  ///   line-wrapping differences are not counted as errors;
  /// * characters that carry no visual content are dropped: zero-width space,
  ///   BOM, and the LEFT-TO-RIGHT/RIGHT-TO-LEFT marks, plus soft hyphen.
  ///
  /// Two deliberate non-normalizations, because both would hide real mistakes:
  ///
  /// * **No case folding** — case is part of the content, and an engine that
  ///   changes it made an error worth seeing.
  /// * **No Unicode normalization** (NFC/NFD). Dart's core library ships no
  ///   normalizer and this phase adds no dependency, so a composed Devanagari
  ///   form and its decomposed equivalent do not compare equal. That is a known
  ///   limitation of these numbers, stated in the report rather than papered
  ///   over; the normalizer is isolated here so adding one later is a
  ///   single-file change.
  ///
  /// ZWJ/ZWNJ are **kept** on purpose: in Devanagari they change which conjunct
  /// a cluster represents, so dropping them would treat two different words as
  /// equal.
  static String normalize(String text) {
    final out = StringBuffer();
    var pendingSpace = false;

    for (final rune in text.runes) {
      if (_isInvisibleFormatting(rune)) continue;
      if (_isWhitespace(rune)) {
        if (out.isNotEmpty) pendingSpace = true;
        continue;
      }
      if (pendingSpace) {
        out.write(' ');
        pendingSpace = false;
      }
      out.writeCharCode(rune);
    }

    return out.toString();
  }

  /// Character error rate: edit distance in **code points** over reference
  /// length.
  ///
  /// `0.0` is perfect. Values above `1.0` are possible (a hypothesis can be
  /// longer than the reference) and are intentionally not clamped, because
  /// clamping would understate catastrophic output.
  static double characterErrorRate({
    required String reference,
    required String hypothesis,
  }) {
    final ref = normalize(reference).runes.toList(growable: false);
    final hyp = normalize(hypothesis).runes.toList(growable: false);
    if (ref.isEmpty) return hyp.isEmpty ? 0 : 1;
    return _editDistance(ref, hyp) / ref.length;
  }

  /// Word error rate: edit distance over whitespace-separated words, divided by
  /// the reference word count.
  static double wordErrorRate({
    required String reference,
    required String hypothesis,
  }) {
    final ref = _words(reference);
    final hyp = _words(hypothesis);
    if (ref.isEmpty) return hyp.isEmpty ? 0 : 1;
    return _editDistance(ref, hyp) / ref.length;
  }

  static List<String> _words(String text) => normalize(
    text,
  ).split(' ').where((word) => word.isNotEmpty).toList(growable: false);

  /// Levenshtein distance between two token sequences (insert/delete/substitute
  /// each cost 1). Uses a single rolling row, so memory is O(min(n, m)).
  static int _editDistance<T>(List<T> a, List<T> b) {
    if (a.isEmpty) return b.length;
    if (b.isEmpty) return a.length;

    // Iterate over the longer sequence on the outside so the row is the
    // shorter one.
    final outer = a.length >= b.length ? a : b;
    final inner = a.length >= b.length ? b : a;

    var previous = List<int>.generate(inner.length + 1, (i) => i);
    var current = List<int>.filled(inner.length + 1, 0);

    for (var i = 1; i <= outer.length; i++) {
      current[0] = i;
      for (var j = 1; j <= inner.length; j++) {
        final substitution =
            previous[j - 1] + (outer[i - 1] == inner[j - 1] ? 0 : 1);
        final deletion = previous[j] + 1;
        final insertion = current[j - 1] + 1;
        var best = substitution < deletion ? substitution : deletion;
        if (insertion < best) best = insertion;
        current[j] = best;
      }
      final swap = previous;
      previous = current;
      current = swap;
    }

    return previous[inner.length];
  }

  static bool _isWhitespace(int rune) =>
      rune == 0x20 ||
      rune == 0x09 ||
      rune == 0x0A ||
      rune == 0x0D ||
      rune == 0x0B ||
      rune == 0x0C ||
      rune == 0xA0 ||
      rune == 0x2028 ||
      rune == 0x2029 ||
      rune == 0x3000;

  static bool _isInvisibleFormatting(int rune) =>
      rune == 0x200B || // zero-width space
      rune == 0xFEFF || // BOM / zero-width no-break space
      rune == 0x200E || // left-to-right mark
      rune == 0x200F || // right-to-left mark
      rune == 0x00AD; // soft hyphen
}

/// Distribution summary for a set of measured durations.
class LatencySummary {
  const LatencySummary({
    required this.count,
    required this.min,
    required this.median,
    required this.p95,
    required this.max,
  });

  final int count;
  final Duration min;
  final Duration median;

  /// Nearest-rank 95th percentile (no interpolation), which is the honest
  /// choice for small sample counts: it is an actually observed value rather
  /// than a made-up one.
  final Duration p95;

  final Duration max;

  /// `null` for an empty input, so an unmeasured set is never reported as zero.
  static LatencySummary? fromDurations(List<Duration> values) {
    if (values.isEmpty) return null;

    final sorted = [...values]..sort((a, b) => a.compareTo(b));
    final middle = sorted.length ~/ 2;
    final median = sorted.length.isOdd
        ? sorted[middle]
        : sorted[middle - 1] + (sorted[middle] - sorted[middle - 1]) ~/ 2;

    return LatencySummary(
      count: sorted.length,
      min: sorted.first,
      median: median,
      p95: sorted[_nearestRankIndex(sorted.length, 0.95)],
      max: sorted.last,
    );
  }

  static int _nearestRankIndex(int count, double percentile) {
    final rank = (percentile * count).ceil();
    final index = (rank < 1 ? 1 : rank) - 1;
    return index > count - 1 ? count - 1 : index;
  }

  @override
  String toString() =>
      'n=$count median=${median.inMilliseconds}ms p95=${p95.inMilliseconds}ms '
      'min=${min.inMilliseconds}ms max=${max.inMilliseconds}ms';
}
