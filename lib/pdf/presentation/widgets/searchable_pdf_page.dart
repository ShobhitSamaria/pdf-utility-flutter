import 'package:flutter/material.dart';

import '../../domain/pdf_text_layer.dart';

/// One PDF page and, when a search hit is on it, the box over the matched line.
///
/// Why this is a widget of its own
/// -------------------------------
/// A highlight is only in the right place if it is drawn in the **page's**
/// coordinate system. Putting it in the viewport's — measuring the screen,
/// guessing where `pdfx` put the page, then scaling — is wrong as soon as the
/// page is scrolled, zoomed, panned, padded, or has a different aspect ratio
/// from its neighbours.
///
/// This widget is the page. The caller gives it the page's own [pageSize] and
/// the PDF's normalised [highlight]; the image and the box are children of one
/// `Stack` with exactly those dimensions. Everything above this widget (the
/// `PhotoView` inside `pdfx`) then transforms the page and the box together, so
/// the marker cannot drift away from the word it marks.
class SearchablePdfPage extends StatelessWidget {
  const SearchablePdfPage({
    super.key,
    required this.image,
    required this.pageSize,
    this.highlight,
  });

  /// The rendered page, as a decoded image provider.
  final ImageProvider image;

  /// The page's own size in PostScript points.
  ///
  /// Its aspect ratio is what the image is laid out at, so a landscape page
  /// stays landscape and its highlight is computed in landscape coordinates.
  final Size pageSize;

  /// The normalised line box to mark, or `null` when this page has no active
  /// match. The box is in the same 0..1 space as the text layer.
  final PdfTextBounds? highlight;

  @override
  Widget build(BuildContext context) {
    if (pageSize.width <= 0 || pageSize.height <= 0) {
      return const SizedBox.shrink();
    }

    final bounds = highlight;

    return Stack(
      fit: StackFit.expand,
      children: [
        Image(
          image: image,
          // The Stack is already exactly [pageSize], whose aspect is the
          // page's. Filling it therefore cannot stretch the scan; using
          // `contain` here would letterbox a page that already fits.
          fit: BoxFit.fill,
          gaplessPlayback: true,
          // A page is a white sheet. Showing white while the PNG decodes is
          // closer to the document than showing the viewer's dark backdrop.
          frameBuilder: (context, child, frame, wasSynchronouslyLoaded) {
            if (wasSynchronouslyLoaded || frame != null) return child;
            return const ColoredBox(color: Colors.white);
          },
        ),
        if (bounds != null)
          Positioned.fromRect(
            key: const ValueKey('searchable-pdf-highlight'),
            rect: bounds.rectOn(pageSize, inflate: 2),
            child: const IgnorePointer(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: Color(0x55FFC400),
                  border: Border.fromBorderSide(
                    BorderSide(color: Color(0xFFFFA000), width: 1.6),
                  ),
                  borderRadius: BorderRadius.all(Radius.circular(3)),
                ),
              ),
            ),
          ),
      ],
    );
  }
}
