import 'package:flutter_test/flutter_test.dart';
import 'package:pdf_utility_flutter/pdf/domain/pdf_text_layer.dart';
import 'package:pdf_utility_flutter/pdf/domain/pdf_text_search.dart';

PdfTextPage _page({
  int pageNumber = 1,
  double width = 600,
  double height = 800,
  required List<PdfTextRun> runs,
}) => PdfTextPage(
  pageNumber: pageNumber,
  width: width,
  height: height,
  runs: runs,
);

PdfTextRun _run(String text, double left, double right) => PdfTextRun(
  text: text,
  left: left,
  top: 0.2,
  right: right,
  bottom: 0.3,
);

void main() {
  test('English search is case-insensitive', () {
    final layer = PdfTextLayer(
      pages: [
        _page(runs: [_run('Recovery 80', 0.05, 0.6)]),
      ],
    );

    final matches = const PdfTextSearch().find(layer, 'rEcOvErY 80');

    expect(matches, hasLength(1));
    expect(matches.single.text, 'Recovery 80');
    expect(matches.single.pageNumber, 1);
  });

  test('Devanagari with matras and nukta matches exactly', () {
    final layer = PdfTextLayer(
      pages: [
        _page(runs: [_run('ज़रूरत', 0.1, 0.35)]),
      ],
    );

    final matches = const PdfTextSearch().find(layer, 'ज़रूरत');

    expect(matches, hasLength(1));
    expect(matches.single.text, 'ज़रूरत');
    expect(matches.single.bounds.left, 0.1);
    expect(matches.single.bounds.right, 0.35);
  });

  test('a Devanagari prefix matches without consuming the whole run', () {
    final layer = PdfTextLayer(
      pages: [
        _page(runs: [_run('ज़रूरत बहुत', 0.1, 0.6)]),
      ],
    );

    final matches = const PdfTextSearch().find(layer, 'ज़रू');

    expect(matches, hasLength(1));
    expect(matches.single.text, 'ज़रू');
  });

  test('a mixed Hindi + English query spans adjacent runs', () {
    final layer = PdfTextLayer(
      pages: [
        _page(
          runs: [
            _run('Invoice', 0.05, 0.25),
            _run('पवन सामरिया', 0.3, 0.8),
          ],
        ),
      ],
    );

    final matches = const PdfTextSearch().find(layer, 'invoice पवन');

    expect(matches, hasLength(1));
    // One box covering both runs, not two partial boxes.
    expect(matches.single.bounds.left, 0.05);
    expect(matches.single.bounds.right, 0.8);
  });

  test('a query across a script change matches the whole phrase', () {
    final layer = PdfTextLayer(
      pages: [
        _page(
          runs: [
            _run('Total', 0.05, 0.2),
            _run('120', 0.25, 0.35),
            _run('Revenue', 0.4, 0.7),
          ],
        ),
      ],
    );

    final matches = const PdfTextSearch().find(layer, 'Total 120 Revenue');

    expect(matches, hasLength(1));
    expect(matches.single.bounds.left, 0.05);
    expect(matches.single.bounds.right, 0.7);
  });

  test('matches are reported on the page they belong to', () {
    final layer = PdfTextLayer(
      pages: [
        _page(
          pageNumber: 1,
          runs: [_run('Recovery 80', 0.05, 0.6)],
        ),
        _page(
          pageNumber: 2,
          width: 800,
          height: 600,
          runs: [_run('Recovery 80', 0.1, 0.5)],
        ),
      ],
    );

    final matches = const PdfTextSearch().find(layer, 'Recovery');

    expect(matches, hasLength(2));
    expect(matches[0].pageNumber, 1);
    expect(matches[1].pageNumber, 2);
  });

  test('empty and whitespace queries find nothing', () {
    final layer = PdfTextLayer(
      pages: [
        _page(runs: [_run('Recovery 80', 0.05, 0.6)]),
      ],
    );

    expect(const PdfTextSearch().find(layer, ''), isEmpty);
    expect(const PdfTextSearch().find(layer, '   '), isEmpty);
  });

  test('pages without text are skipped', () {
    final layer = PdfTextLayer(
      pages: [
        _page(runs: const []),
        _page(pageNumber: 2, runs: [_run('Recovery 80', 0.05, 0.6)]),
      ],
    );

    final matches = const PdfTextSearch().find(layer, 'Recovery');

    expect(matches, hasLength(1));
    expect(matches.single.pageNumber, 2);
  });

  test('the match cap bounds a one-letter query', () {
    final layer = PdfTextLayer(
      pages: [
        _page(
          runs: [
            _run('a a a a a a', 0.05, 0.6),
          ],
        ),
      ],
    );

    final matches = const PdfTextSearch(maxMatches: 3).find(layer, 'a');

    expect(matches, hasLength(3));
  });
}
