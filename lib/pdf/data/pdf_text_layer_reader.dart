import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import '../domain/pdf_exception.dart';
import '../domain/pdf_text_layer.dart';

/// Reads the **text layer** out of a PDF file.
///
/// Why this exists
/// ---------------
/// The app writes the invisible text layer itself, but until now nothing could
/// read it back: `pdfx` renders pages and has no text API, and Android's
/// `PdfRenderer` cannot extract text either. So searching a freshly generated
/// searchable PDF would have meant searching the OCR result object it was made
/// from — which is *not* the same thing, and would tell the user nothing about
/// whether the file they are about to share is actually searchable.
///
/// This reader parses the file instead: objects, page tree, content streams,
/// fonts and their `/ToUnicode` maps, and the text-showing operators. What it
/// returns is what any other PDF viewer would find in the document.
///
/// Scope, stated plainly
/// ---------------------
/// * It reads **our output** first and foremost, and ordinary uncompressed
///   (`FlateDecode`) PDFs in general.
/// * Text inside form XObjects, `/ObjStm` object streams and encrypted files is
///   not traversed; those pages report no text instead of guessing.
/// * Encoding support is `/ToUnicode` (preferred, and what makes Devanagari
///   readable) with a WinAnsi fallback for simple Latin fonts.
class PdfTextLayerReader {
  const PdfTextLayerReader();

  Future<PdfTextLayer> readFile(String path) async {
    final bytes = await File(path).readAsBytes();
    return readBytes(bytes);
  }

  /// Parses [bytes]. Throws [PdfException] when the file is not a PDF.
  PdfTextLayer readBytes(Uint8List bytes) {
    try {
      final file = _PdfFile.parse(bytes);
      final pages = file.pages();
      if (pages.isEmpty) {
        throw const PdfException(
          PdfErrorKind.unreadable,
          'That PDF has no readable pages.',
        );
      }

      final result = <PdfTextPage>[];
      for (var index = 0; index < pages.length; index++) {
        final info = pages[index];
        result.add(
          PdfTextPage(
            pageNumber: index + 1,
            width: info.width,
            height: info.height,
            runs: file.textRuns(info),
          ),
        );
      }
      return PdfTextLayer(pages: result);
    } on PdfException {
      rethrow;
    } catch (error) {
      throw PdfException(
        PdfErrorKind.unreadable,
        'The PDF text layer could not be read.',
        cause: error,
      );
    }
  }
}

// --- object model ----------------------------------------------------------

class _PdfName {
  const _PdfName(this.value);
  final String value;
}

class _PdfRef {
  const _PdfRef(this.number);
  final int number;
}

class _PdfString {
  const _PdfString(this.bytes);
  final List<int> bytes;
}

class _PdfKeyword {
  const _PdfKeyword(this.word);
  final String word;
}

class _PdfDict {
  _PdfDict(this.values);
  final Map<String, Object?> values;
}

class _PdfArray {
  const _PdfArray(this.items);
  final List<Object?> items;
}

class _PdfStream {
  _PdfStream(this.dict, this.bytes);
  final _PdfDict dict;
  final Uint8List bytes;
}

// --- a tiny PDF tokenizer --------------------------------------------------

class _Lexer {
  _Lexer(this.data);

  final Uint8List data;
  int pos = 0;

  bool get atEnd => pos >= data.length;

  static bool _isWhitespace(int c) =>
      c == 0x00 ||
      c == 0x09 ||
      c == 0x0A ||
      c == 0x0C ||
      c == 0x0D ||
      c == 0x20;

  static bool _isDelimiter(int c) =>
      c == 0x28 || // (
      c == 0x29 || // )
      c == 0x3C || // <
      c == 0x3E || // >
      c == 0x5B || // [
      c == 0x5D || // ]
      c == 0x7B || // {
      c == 0x7D || // }
      c == 0x2F || // /
      c == 0x25; // %

  void skipSpace() {
    while (!atEnd) {
      final c = data[pos];
      if (_isWhitespace(c)) {
        pos++;
        continue;
      }
      if (c == 0x25) {
        while (!atEnd && data[pos] != 0x0A && data[pos] != 0x0D) {
          pos++;
        }
        continue;
      }
      break;
    }
  }

  /// A bare word: an operator, a number, `R`, `obj`, `true`, …
  String readWord() {
    skipSpace();
    final start = pos;
    while (!atEnd && !_isWhitespace(data[pos]) && !_isDelimiter(data[pos])) {
      pos++;
    }
    return latin1.decode(data.sublist(start, pos));
  }

  String readName() {
    final start = pos;
    while (!atEnd && !_isWhitespace(data[pos]) && !_isDelimiter(data[pos])) {
      pos++;
    }
    return latin1.decode(data.sublist(start, pos));
  }

  List<int> readLiteralString() {
    // The opening ( has already been consumed.
    final out = <int>[];
    var depth = 1;
    while (!atEnd) {
      final c = data[pos++];
      if (c == 0x5C) {
        // Backslash escapes.
        if (atEnd) break;
        final e = data[pos++];
        switch (e) {
          case 0x6E:
            out.add(0x0A);
          case 0x72:
            out.add(0x0D);
          case 0x74:
            out.add(0x09);
          case 0x62:
            out.add(0x08);
          case 0x66:
            out.add(0x0C);
          case 0x0D:
            if (!atEnd && data[pos] == 0x0A) pos++;
          case 0x0A:
            break;
          case 0x28:
          case 0x29:
          case 0x5C:
            out.add(e);
          default:
            if (e >= 0x30 && e <= 0x37) {
              var value = e - 0x30;
              for (var i = 0; i < 2 && !atEnd; i++) {
                final d = data[pos];
                if (d < 0x30 || d > 0x37) break;
                value = value * 8 + (d - 0x30);
                pos++;
              }
              out.add(value & 0xFF);
            } else {
              out.add(e);
            }
        }
        continue;
      }
      if (c == 0x28) {
        depth++;
        out.add(c);
        continue;
      }
      if (c == 0x29) {
        depth--;
        if (depth == 0) break;
        out.add(c);
        continue;
      }
      out.add(c);
    }
    return out;
  }

  List<int> readHexString() {
    // The opening < has already been consumed.
    final out = <int>[];
    var high = -1;
    while (!atEnd) {
      final c = data[pos++];
      if (c == 0x3E) break;
      if (_isWhitespace(c)) continue;
      final digit = _hexValue(c);
      if (digit < 0) continue;
      if (high < 0) {
        high = digit;
      } else {
        out.add((high << 4) | digit);
        high = -1;
      }
    }
    if (high >= 0) out.add(high << 4);
    return out;
  }

  static int _hexValue(int c) {
    if (c >= 0x30 && c <= 0x39) return c - 0x30;
    if (c >= 0x41 && c <= 0x46) return c - 0x41 + 10;
    if (c >= 0x61 && c <= 0x66) return c - 0x61 + 10;
    return -1;
  }
}

Object? _parseValue(_Lexer lexer) {
  lexer.skipSpace();
  if (lexer.atEnd) return null;

  final c = lexer.data[lexer.pos];
  switch (c) {
    case 0x2F: // /Name
      lexer.pos++;
      return _PdfName(lexer.readName());

    case 0x28: // (literal string)
      lexer.pos++;
      return _PdfString(lexer.readLiteralString());

    case 0x3C: // <hex> or <<dict>>
      if (lexer.pos + 1 < lexer.data.length &&
          lexer.data[lexer.pos + 1] == 0x3C) {
        lexer.pos += 2;
        final values = <String, Object?>{};
        while (true) {
          lexer.skipSpace();
          if (lexer.atEnd) break;
          if (lexer.data[lexer.pos] == 0x3E &&
              lexer.pos + 1 < lexer.data.length &&
              lexer.data[lexer.pos + 1] == 0x3E) {
            lexer.pos += 2;
            break;
          }
          final key = _parseValue(lexer);
          if (key is! _PdfName) {
            if (key == null) lexer.pos++;
            continue;
          }
          values[key.value] = _parseValue(lexer);
        }
        return _PdfDict(values);
      }
      lexer.pos++;
      return _PdfString(lexer.readHexString());

    case 0x5B: // [array]
      lexer.pos++;
      final items = <Object?>[];
      while (true) {
        lexer.skipSpace();
        if (lexer.atEnd) break;
        if (lexer.data[lexer.pos] == 0x5D) {
          lexer.pos++;
          break;
        }
        final value = _parseValue(lexer);
        if (value == null) {
          // A stray `]` handled above; anything else that parses to null is
          // `null` in the document, which arrays may contain.
          items.add(null);
          continue;
        }
        items.add(value);
      }
      return _PdfArray(items);

    case 0x5D:
    case 0x3E:
    case 0x7B:
    case 0x7D:
      lexer.pos++;
      return null;
  }

  final word = lexer.readWord();
  if (word.isEmpty) {
    lexer.pos++;
    return null;
  }

  final number = num.tryParse(word);
  if (number != null) {
    if (number is int) {
      // `12 0 R` — an indirect reference.
      final saved = lexer.pos;
      final generation = lexer.readWord();
      if (generation.isNotEmpty && int.tryParse(generation) != null) {
        if (lexer.readWord() == 'R') return _PdfRef(number);
      }
      lexer.pos = saved;
    }
    return number;
  }

  if (word == 'true') return true;
  if (word == 'false') return false;
  if (word == 'null') return null;
  return _PdfKeyword(word);
}

// --- the document ----------------------------------------------------------

/// A rectangle in default PDF user space: origin bottom-left, units in points.
class _PdfBox {
  const _PdfBox({
    required this.left,
    required this.bottom,
    required this.right,
    required this.top,
  });

  final double left;
  final double bottom;
  final double right;
  final double top;

  double get width => right - left;
  double get height => top - bottom;

  bool get isValid => width > 0 && height > 0;

  /// The overlapping part of two boxes, or `null` when they do not overlap.
  _PdfBox? intersect(_PdfBox other) {
    final left = math.max(this.left, other.left);
    final bottom = math.max(this.bottom, other.bottom);
    final right = math.min(this.right, other.right);
    final top = math.min(this.top, other.top);
    if (right <= left || top <= bottom) return null;
    return _PdfBox(left: left, bottom: bottom, right: right, top: top);
  }
}

class _PageInfo {
  _PageInfo({
    required this.dict,
    required this.resources,
    required this.box,
    required this.rotation,
    required this.width,
    required this.height,
  });

  final _PdfDict dict;
  final Object? resources;

  /// The visible area, after the CropBox/MediaBox intersection.
  final _PdfBox box;

  /// Normalised `/Rotate` in degrees clockwise: 0, 90, 180 or 270.
  final int rotation;

  /// Displayed page size: the crop box, swapped for a quarter turn.
  final double width;
  final double height;
}

class _PdfFile {
  _PdfFile(this.objects);

  final Map<int, Object?> objects;

  static _PdfFile parse(Uint8List data) {
    final objects = <int, Object?>{};
    final lexer = _Lexer(data);

    while (true) {
      lexer.skipSpace();
      if (lexer.atEnd) break;

      // A top-level object starts with `num gen obj`. Anything else is a
      // keyword (`trailer`, `xref`, `startxref`) and is skipped.
      final first = lexer.data[lexer.pos];
      if (first < 0x30 || first > 0x39) {
        lexer.pos++;
        continue;
      }

      final objectNumber = int.tryParse(lexer.readWord());
      if (objectNumber == null) continue;
      final generation = int.tryParse(lexer.readWord());
      if (generation == null) continue;
      if (lexer.readWord() != 'obj') continue;

      final value = _parseValue(lexer);
      lexer.skipSpace();

      if (value is _PdfDict && _startsWith(lexer, 'stream')) {
        lexer.pos += 6;
        if (!lexer.atEnd && lexer.data[lexer.pos] == 0x0D) lexer.pos++;
        if (!lexer.atEnd && lexer.data[lexer.pos] == 0x0A) lexer.pos++;

        final declared = value.values['Length'];
        int? length = declared is num ? declared.toInt() : null;
        final start = lexer.pos;
        if (length == null || length < 0 || start + length > data.length) {
          final end = _indexOf(data, 'endstream', start);
          length = (end < 0 ? data.length : end) - start;
        }

        final bytes = Uint8List.sublistView(
          data,
          start,
          math.min(start + length, data.length),
        );
        objects[objectNumber] = _PdfStream(value, bytes);
        lexer.pos = math.min(start + length, data.length);
      } else {
        objects[objectNumber] = value;
      }

      final end = _indexOf(data, 'endobj', lexer.pos);
      lexer.pos = end < 0 ? data.length : end + 6;
    }

    return _PdfFile(objects);
  }

  static bool _startsWith(_Lexer lexer, String word) {
    if (lexer.pos + word.length > lexer.data.length) return false;
    for (var i = 0; i < word.length; i++) {
      if (lexer.data[lexer.pos + i] != word.codeUnitAt(i)) return false;
    }
    return true;
  }

  static int _indexOf(Uint8List data, String needle, int from) {
    final pattern = ascii.encode(needle);
    outer:
    for (var i = from; i <= data.length - pattern.length; i++) {
      for (var j = 0; j < pattern.length; j++) {
        if (data[i + j] != pattern[j]) continue outer;
      }
      return i;
    }
    return -1;
  }

  Object? resolve(Object? value) {
    var current = value;
    var guard = 0;
    while (current is _PdfRef && guard++ < 32) {
      current = objects[current.number];
    }
    return current;
  }

  String nameOf(Object? value) {
    final resolved = resolve(value);
    return resolved is _PdfName ? resolved.value : '';
  }

  double _numberOf(Object? value, double fallback) {
    final resolved = resolve(value);
    return resolved is num ? resolved.toDouble() : fallback;
  }

  /// Reads a `/MediaBox`-shaped array, ignoring anything malformed.
  _PdfBox? _boxOf(Object? value) {
    final resolved = resolve(value);
    if (resolved is! _PdfArray || resolved.items.length < 4) return null;

    final x0 = _numberOf(resolved.items[0], 0);
    final y0 = _numberOf(resolved.items[1], 0);
    final x1 = _numberOf(resolved.items[2], 0);
    final y1 = _numberOf(resolved.items[3], 0);

    final box = _PdfBox(
      left: math.min(x0, x1),
      bottom: math.min(y0, y1),
      right: math.max(x0, x1),
      top: math.max(y0, y1),
    );
    return box.isValid ? box : null;
  }

  /// `/Rotate` normalised to a supported clockwise quarter turn.
  ///
  /// A non-multiple of 90 is not something the app can display, so it is
  /// treated as no rotation instead of approximating a transform.
  int _rotationOf(Object? value) {
    final resolved = resolve(value);
    if (resolved is! num) return 0;
    final normalised = (resolved.toInt() % 360 + 360) % 360;
    return switch (normalised) {
      90 => 90,
      180 => 180,
      270 => 270,
      _ => 0,
    };
  }

  List<_PageInfo> pages() {
    _PdfDict? catalog;
    for (final value in objects.values) {
      if (value is _PdfDict && nameOf(value.values['Type']) == 'Catalog') {
        catalog = value;
        break;
      }
    }

    final pages = <_PageInfo>[];

    _PageInfo infoFor(
      _PdfDict dict,
      Object? resources,
      Object? mediaBox,
      Object? cropBox,
      Object? rotate,
    ) {
      final media =
          _boxOf(mediaBox) ??
          const _PdfBox(left: 0, bottom: 0, right: 612, top: 792);

      // The CropBox is intersected with the MediaBox: a CropBox that extends
      // past the media is not a bigger page, and one that does not overlap at
      // all is unusable, so it falls back to the media box.
      final crop = _boxOf(cropBox)?.intersect(media) ?? media;
      final rotation = _rotationOf(rotate);
      final swaps = rotation == 90 || rotation == 270;

      return _PageInfo(
        dict: dict,
        resources: resources,
        box: crop,
        rotation: rotation,
        width: swaps ? crop.height : crop.width,
        height: swaps ? crop.width : crop.height,
      );
    }

    void walk(
      Object? node,
      Object? inheritedResources,
      Object? inheritedMediaBox,
      Object? inheritedCropBox,
      Object? inheritedRotate,
    ) {
      final dict = resolve(node);
      if (dict is! _PdfDict) return;

      // MediaBox, CropBox and Rotate are inheritable page attributes: a writer
      // may put them once on the Pages node. Reading only the page dictionary
      // missed a rotated scan whose /Rotate lived on its parent.
      final resources = dict.values.containsKey('Resources')
          ? dict.values['Resources']
          : inheritedResources;
      final mediaBox = dict.values.containsKey('MediaBox')
          ? dict.values['MediaBox']
          : inheritedMediaBox;
      final cropBox = dict.values.containsKey('CropBox')
          ? dict.values['CropBox']
          : inheritedCropBox;
      final rotate = dict.values.containsKey('Rotate')
          ? dict.values['Rotate']
          : inheritedRotate;

      if (nameOf(dict.values['Type']) == 'Page') {
        pages.add(infoFor(dict, resources, mediaBox, cropBox, rotate));
        return;
      }

      final kids = resolve(dict.values['Kids']);
      if (kids is _PdfArray) {
        for (final kid in kids.items) {
          walk(kid, resources, mediaBox, cropBox, rotate);
        }
      }
    }

    if (catalog != null) walk(catalog.values['Pages'], null, null, null, null);

    if (pages.isEmpty) {
      // No usable page tree: fall back to object order, which is still the
      // right order for a lot of writers.
      for (final value in objects.values) {
        if (value is _PdfDict && nameOf(value.values['Type']) == 'Page') {
          pages.add(
            infoFor(
              value,
              value.values['Resources'],
              value.values['MediaBox'],
              value.values['CropBox'],
              value.values['Rotate'],
            ),
          );
        }
      }
    }

    return pages;
  }

  /// All text runs on [page], in content-stream order.
  List<PdfTextRun> textRuns(_PageInfo page) {
    final content = _contentBytes(page);
    if (content.isEmpty) return const <PdfTextRun>[];

    final resources = resolve(page.resources);
    final fonts = <String, _FontDecoder>{};
    if (resources is _PdfDict) {
      final fontDict = resolve(resources.values['Font']);
      if (fontDict is _PdfDict) {
        for (final entry in fontDict.values.entries) {
          final font = resolve(entry.value);
          if (font is _PdfDict) {
            fonts[entry.key] = _FontDecoder.fromDict(font, this);
          }
        }
      }
    }

    final extractor = _TextExtractor(fonts: fonts, page: page);
    extractor.run(content);
    return extractor.runs;
  }

  Uint8List _contentBytes(_PageInfo page) {
    final contents = resolve(page.dict.values['Contents']);
    final streams = <_PdfStream>[];

    if (contents is _PdfStream) {
      streams.add(contents);
    } else if (contents is _PdfArray) {
      for (final item in contents.items) {
        final stream = resolve(item);
        if (stream is _PdfStream) streams.add(stream);
      }
    }

    if (streams.isEmpty) return Uint8List(0);
    if (streams.length == 1) return decodeStream(streams.first);

    final builder = BytesBuilder(copy: false);
    for (final stream in streams) {
      builder.add(decodeStream(stream));
      builder.addByte(0x0A);
    }
    return builder.takeBytes();
  }

  /// Applies the filters this reader understands. An unsupported filter yields
  /// no bytes rather than mojibake.
  Uint8List decodeStream(_PdfStream stream) {
    final filter = resolve(stream.dict.values['Filter']);
    if (filter == null) return stream.bytes;

    final names = <String>[
      if (filter is _PdfArray)
        for (final item in filter.items) nameOf(item)
      else
        nameOf(filter),
    ];

    var bytes = stream.bytes;
    for (final name in names) {
      try {
        switch (name) {
          case 'FlateDecode':
          case 'Fl':
            bytes = Uint8List.fromList(ZLibDecoder().convert(bytes));
          case 'ASCIIHexDecode':
          case 'AHx':
            bytes = _asciiHexDecode(bytes);
          default:
            return Uint8List(0);
        }
      } catch (_) {
        return Uint8List(0);
      }
    }
    return bytes;
  }

  static Uint8List _asciiHexDecode(Uint8List input) {
    final out = <int>[];
    var high = -1;
    for (final c in input) {
      if (c == 0x3E) break;
      final digit = _Lexer._hexValue(c);
      if (digit < 0) continue;
      if (high < 0) {
        high = digit;
      } else {
        out.add((high << 4) | digit);
        high = -1;
      }
    }
    return Uint8List.fromList(out);
  }
}

// --- fonts -----------------------------------------------------------------

/// Maps the byte codes in a content stream back to characters.
class _FontDecoder {
  _FontDecoder({
    required this.twoByte,
    required this.toUnicode,
    required this.widths,
    required this.defaultWidth,
  });

  final bool twoByte;
  final Map<int, String> toUnicode;
  final Map<int, double> widths;
  final double defaultWidth;

  factory _FontDecoder.fromDict(_PdfDict dict, _PdfFile file) {
    final subtype = file.nameOf(dict.values['Subtype']);
    final encoding = file.nameOf(dict.values['Encoding']);
    final twoByte = subtype == 'Type0' || encoding == 'Identity-H';

    final toUnicode = <int, String>{};
    final cmap = file.resolve(dict.values['ToUnicode']);
    if (cmap is _PdfStream) {
      final text = latin1.decode(file.decodeStream(cmap));
      toUnicode.addAll(_parseCMap(text));
    }

    final widths = <int, double>{};
    var defaultWidth = twoByte ? 600.0 : 500.0;

    if (subtype == 'Type0') {
      final descendants = file.resolve(dict.values['DescendantFonts']);
      if (descendants is _PdfArray && descendants.items.isNotEmpty) {
        final font = file.resolve(descendants.items.first);
        if (font is _PdfDict) {
          defaultWidth = (font.values['DW'] is num)
              ? (font.values['DW'] as num).toDouble()
              : 1000;
          final w = file.resolve(font.values['W']);
          if (w is _PdfArray) _parseCidWidths(w, widths, file);
        }
      }
    } else {
      final firstChar = dict.values['FirstChar'];
      final widthArray = file.resolve(dict.values['Widths']);
      if (firstChar is num && widthArray is _PdfArray) {
        final start = firstChar.toInt();
        for (var i = 0; i < widthArray.items.length; i++) {
          final w = widthArray.items[i];
          if (w is num) widths[start + i] = w.toDouble();
        }
      }
      final missing = dict.values['MissingWidth'];
      if (missing is num) defaultWidth = missing.toDouble();
    }

    return _FontDecoder(
      twoByte: twoByte,
      toUnicode: toUnicode,
      widths: widths,
      defaultWidth: defaultWidth <= 0 ? 500 : defaultWidth,
    );
  }

  static void _parseCidWidths(
    _PdfArray w,
    Map<int, double> widths,
    _PdfFile file,
  ) {
    var index = 0;
    while (index < w.items.length) {
      final first = w.items[index];
      if (first is! num) {
        index++;
        continue;
      }
      final next = index + 1 < w.items.length ? w.items[index + 1] : null;
      if (next is _PdfArray) {
        for (var i = 0; i < next.items.length; i++) {
          final width = next.items[i];
          if (width is num) widths[first.toInt() + i] = width.toDouble();
        }
        index += 2;
        continue;
      }
      final last = next;
      final width = index + 2 < w.items.length ? w.items[index + 2] : null;
      if (last is num && width is num) {
        for (var code = first.toInt(); code <= last.toInt(); code++) {
          widths[code] = width.toDouble();
        }
        index += 3;
        continue;
      }
      index++;
    }
  }

  List<int> codesOf(List<int> bytes) {
    if (!twoByte) return bytes;
    final codes = <int>[];
    for (var i = 0; i + 1 < bytes.length; i += 2) {
      codes.add((bytes[i] << 8) | bytes[i + 1]);
    }
    return codes;
  }

  String decodeCodes(List<int> codes) {
    final buffer = StringBuffer();
    for (final code in codes) {
      final mapped = toUnicode[code];
      if (mapped != null) {
        buffer.write(mapped);
      } else if (!twoByte) {
        buffer.write(_winAnsi(code));
      }
      // A two-byte code with no ToUnicode entry is unknowable; dropping it is
      // better than inventing a character that would make search wrong.
    }
    return buffer.toString();
  }

  double widthOf(int code) => widths[code] ?? defaultWidth;

  /// CP1252 for the range where it differs from Latin-1, which is enough for
  /// the Latin text this app writes with the built-in font.
  static String _winAnsi(int code) {
    const specials = <int, String>{
      0x80: '€',
      0x82: '‚',
      0x83: 'ƒ',
      0x84: '„',
      0x85: '…',
      0x86: '†',
      0x87: '‡',
      0x88: 'ˆ',
      0x89: '‰',
      0x8A: 'Š',
      0x8B: '‹',
      0x8C: 'Œ',
      0x8E: 'Ž',
      0x91: "'",
      0x92: "'",
      0x93: '"',
      0x94: '"',
      0x95: '•',
      0x96: '–',
      0x97: '—',
      0x98: '˜',
      0x99: '™',
      0x9A: 'š',
      0x9B: '›',
      0x9C: 'œ',
      0x9E: 'ž',
      0x9F: 'Ÿ',
    };
    final special = specials[code];
    if (special != null) return special;
    if (code < 0x20) return '';
    return String.fromCharCode(code);
  }
}

/// Parses a `/ToUnicode` CMap into code → string.
Map<int, String> _parseCMap(String text) {
  final map = <int, String>{};

  for (final block in RegExp(
    r'beginbfchar(.*?)endbfchar',
    dotAll: true,
  ).allMatches(text)) {
    for (final entry in RegExp(
      r'<([0-9A-Fa-f]+)>\s*<([0-9A-Fa-f]+)>',
    ).allMatches(block.group(1)!)) {
      final code = int.parse(entry.group(1)!, radix: 16);
      map[code] = _utf16be(entry.group(2)!);
    }
  }

  for (final block in RegExp(
    r'beginbfrange(.*?)endbfrange',
    dotAll: true,
  ).allMatches(text)) {
    final body = block.group(1)!;
    for (final entry in RegExp(
      r'<([0-9A-Fa-f]+)>\s*<([0-9A-Fa-f]+)>\s*(<([0-9A-Fa-f]+)>|\[(.*?)\])',
      dotAll: true,
    ).allMatches(body)) {
      final low = int.parse(entry.group(1)!, radix: 16);
      final high = int.parse(entry.group(2)!, radix: 16);
      final single = entry.group(4);
      final list = entry.group(5);

      if (single != null) {
        final units = _utf16Units(single);
        for (var code = low; code <= high && code - low < 65536; code++) {
          final copy = List<int>.from(units);
          if (copy.isNotEmpty) copy[copy.length - 1] += code - low;
          map[code] = String.fromCharCodes(copy);
        }
      } else if (list != null) {
        final items = RegExp(
          r'<([0-9A-Fa-f]+)>',
        ).allMatches(list).map((m) => _utf16be(m.group(1)!)).toList();
        for (var i = 0; i < items.length; i++) {
          map[low + i] = items[i];
        }
      }
    }
  }

  return map;
}

List<int> _utf16Units(String hex) {
  final bytes = <int>[];
  for (var i = 0; i + 1 < hex.length; i += 2) {
    bytes.add(int.parse(hex.substring(i, i + 2), radix: 16));
  }
  final units = <int>[];
  for (var i = 0; i + 1 < bytes.length; i += 2) {
    units.add((bytes[i] << 8) | bytes[i + 1]);
  }
  return units;
}

String _utf16be(String hex) => String.fromCharCodes(_utf16Units(hex));

// --- content stream interpretation -----------------------------------------

class _Matrix {
  const _Matrix(this.a, this.b, this.c, this.d, this.e, this.f);

  static const _Matrix identity = _Matrix(1, 0, 0, 1, 0, 0);

  final double a;
  final double b;
  final double c;
  final double d;
  final double e;
  final double f;

  static _Matrix translate(double x, double y) => _Matrix(1, 0, 0, 1, x, y);

  /// `this` applied first, then [other] — the PDF row-vector composition.
  _Matrix multiply(_Matrix other) => _Matrix(
    a * other.a + b * other.c,
    a * other.b + b * other.d,
    c * other.a + d * other.c,
    c * other.b + d * other.d,
    e * other.a + f * other.c + other.e,
    e * other.b + f * other.d + other.f,
  );

  (double, double) transform(double x, double y) =>
      (a * x + c * y + e, b * x + d * y + f);
}

class _GState {
  _Matrix ctm = _Matrix.identity;
  _Matrix tm = _Matrix.identity;
  _Matrix tlm = _Matrix.identity;
  String? fontName;
  double fontSize = 12;
  double leading = 0;
  double charSpacing = 0;
  double wordSpacing = 0;
  double horizontalScale = 1;

  _GState copy() => _GState()
    ..ctm = ctm
    ..tm = tm
    ..tlm = tlm
    ..fontName = fontName
    ..fontSize = fontSize
    ..leading = leading
    ..charSpacing = charSpacing
    ..wordSpacing = wordSpacing
    ..horizontalScale = horizontalScale;

  void assign(_GState other) {
    ctm = other.ctm;
    tm = other.tm;
    tlm = other.tlm;
    fontName = other.fontName;
    fontSize = other.fontSize;
    leading = other.leading;
    charSpacing = other.charSpacing;
    wordSpacing = other.wordSpacing;
    horizontalScale = other.horizontalScale;
  }
}

/// Walks one page's content stream and records every shown text run.
class _TextExtractor {
  _TextExtractor({required this.fonts, required this.page});

  final Map<String, _FontDecoder> fonts;
  final _PageInfo page;

  final List<PdfTextRun> runs = <PdfTextRun>[];
  final List<_GState> _stack = <_GState>[];
  final _GState _state = _GState();

  void run(Uint8List content) {
    final lexer = _Lexer(content);
    final operands = <Object?>[];

    while (true) {
      lexer.skipSpace();
      if (lexer.atEnd) break;

      final c = lexer.data[lexer.pos];
      final isValue =
          c == 0x2F ||
          c == 0x28 ||
          c == 0x3C ||
          c == 0x5B ||
          c == 0x2B ||
          c == 0x2D ||
          c == 0x2E ||
          (c >= 0x30 && c <= 0x39);

      if (isValue) {
        final value = _parseValue(lexer);
        if (value != null) operands.add(value);
        continue;
      }

      final operator = lexer.readWord();
      if (operator.isEmpty) {
        lexer.pos++;
        continue;
      }
      _apply(operator, operands);
      operands.clear();
    }
  }

  void _apply(String operator, List<Object?> args) {
    switch (operator) {
      case 'q':
        _stack.add(_state.copy());
      case 'Q':
        if (_stack.isNotEmpty) _state.assign(_stack.removeLast());
      case 'cm':
        if (args.length >= 6) {
          final m = _Matrix(
            _num(args[0]),
            _num(args[1]),
            _num(args[2]),
            _num(args[3]),
            _num(args[4]),
            _num(args[5]),
          );
          _state.ctm = m.multiply(_state.ctm);
        }
      case 'BT':
        _state.tm = _Matrix.identity;
        _state.tlm = _Matrix.identity;
      case 'Tf':
        if (args.length >= 2) {
          final name = args[0];
          _state.fontName = name is _PdfName ? name.value : null;
          _state.fontSize = _num(args[1], 12);
        }
      case 'TL':
        if (args.isNotEmpty) _state.leading = _num(args[0]);
      case 'Td':
      case 'TD':
        if (args.length >= 2) {
          final tx = _num(args[0]);
          final ty = _num(args[1]);
          if (operator == 'TD') _state.leading = -ty;
          _state.tlm = _Matrix.translate(tx, ty).multiply(_state.tlm);
          _state.tm = _state.tlm;
        }
      case 'Tm':
        if (args.length >= 6) {
          _state.tlm = _Matrix(
            _num(args[0]),
            _num(args[1]),
            _num(args[2]),
            _num(args[3]),
            _num(args[4]),
            _num(args[5]),
          );
          _state.tm = _state.tlm;
        }
      case 'T*':
        _state.tlm = _Matrix.translate(0, -_state.leading).multiply(_state.tlm);
        _state.tm = _state.tlm;
      case 'Tj':
        if (args.isNotEmpty && args.last is _PdfString) {
          _show((args.last as _PdfString).bytes);
        }
      case 'TJ':
        if (args.isNotEmpty && args.last is _PdfArray) {
          _showArray((args.last as _PdfArray));
        }
      case "'":
        _state.tlm = _Matrix.translate(0, -_state.leading).multiply(_state.tlm);
        _state.tm = _state.tlm;
        if (args.isNotEmpty && args.last is _PdfString) {
          _show((args.last as _PdfString).bytes);
        }
      case '"':
        if (args.length >= 3) {
          _state.wordSpacing = _num(args[0]);
          _state.charSpacing = _num(args[1]);
          _state.tlm = _Matrix.translate(
            0,
            -_state.leading,
          ).multiply(_state.tlm);
          _state.tm = _state.tlm;
          final text = args[2];
          if (text is _PdfString) _show(text.bytes);
        }
      case 'Tz':
        if (args.isNotEmpty) {
          _state.horizontalScale = _num(args[0], 100) / 100;
        }
      case 'Tc':
        if (args.isNotEmpty) _state.charSpacing = _num(args[0]);
      case 'Tw':
        if (args.isNotEmpty) _state.wordSpacing = _num(args[0]);
    }
  }

  void _showArray(_PdfArray array) {
    final font = _font;
    for (final item in array.items) {
      if (item is _PdfString) {
        _show(item.bytes);
      } else if (item is num) {
        final shift = -item / 1000 * _state.fontSize;
        _state.tm = _Matrix.translate(shift, 0).multiply(_state.tm);
      }
    }
    // Referenced so the analyzer sees the local for what it documents: the
    // advance of a numeric element is in the same text space as the glyphs.
    assert(font == _font);
  }

  _FontDecoder? get _font {
    final name = _state.fontName;
    return name == null ? null : fonts[name];
  }

  void _show(List<int> bytes) {
    final font = _font;
    final codes = font?.codesOf(bytes) ?? bytes;
    final text = font?.decodeCodes(codes) ?? latin1.decode(bytes);
    final size = _state.fontSize;

    var advance = 0.0;
    for (final code in codes) {
      final width = font?.widthOf(code) ?? 500;
      advance += width / 1000 * size * _state.horizontalScale;
      advance += _state.charSpacing;
      if (code == 0x20) advance += _state.wordSpacing;
    }

    if (text.trim().isNotEmpty) {
      // The baseline sits below the printed line: the ascent is most of the em,
      // the descent a quarter of it. Those offsets belong in *text* space. On a
      // run turned ninety degrees the ascent points sideways, so adding it to
      // the page's y (the old arithmetic) collapses the run to a zero-width
      // horizontal sliver and drops it as unusable. Transform all four corners
      // of the glyph box through the text matrix and then the CTM; the box of
      // the result is exact at every angle, and is the same rectangle the old
      // arithmetic produced when the run is horizontal.
      final ascent = size;
      final descent = size * 0.25;
      final corners = <(double, double)>[];
      for (final (x, y) in <(double, double)>[
        (0, -descent),
        (advance, -descent),
        (0, ascent),
        (advance, ascent),
      ]) {
        final (tx, ty) = _state.tm.transform(x, y);
        corners.add(_state.ctm.transform(tx, ty));
      }

      final rect = _displayCorners(corners);
      final run = PdfTextRun(
        text: text,
        left: rect.$1,
        top: rect.$2,
        right: rect.$3,
        bottom: rect.$4,
      );
      if (run.width > 0 && run.height > 0) runs.add(run);
    }

    _state.tm = _Matrix.translate(advance, 0).multiply(_state.tm);
  }

  /// A PDF-space rectangle as normalised, displayed-page coordinates.
  ///
  /// CropBox offset comes first, then the `/Rotate` quarter turn. All four
  /// corners are transformed and the axis-aligned box of the result is used: a
  /// run that is horizontal in the content stream is vertical on a page turned
  /// 90°, and a width/height swap alone would put its corners in the wrong
  /// places for an asymmetric box.
  /// The normalised displayed-page box of a set of PDF-space points.
  ///
  /// Every point is mapped through the page's CropBox, offset and `/Rotate`
  /// first; only then are the extents taken. Doing it in that order is what
  /// keeps a rotated glyph box (a sideways word) from being squashed into a
  /// horizontal line by an axis-aligned assumption.
  (double, double, double, double) _displayCorners(
    List<(double, double)> points,
  ) {
    var minU = double.infinity;
    var minV = double.infinity;
    var maxU = -double.infinity;
    var maxV = -double.infinity;

    for (final (x, y) in points) {
      final (u, v) = _displayPoint(x, y);
      if (u < minU) minU = u;
      if (v < minV) minV = v;
      if (u > maxU) maxU = u;
      if (v > maxV) maxV = v;
    }

    return (
      minU.clamp(0.0, 1.0),
      minV.clamp(0.0, 1.0),
      maxU.clamp(0.0, 1.0),
      maxV.clamp(0.0, 1.0),
    );
  }

  /// One PDF-space point in normalised displayed-page coordinates.
  ///
  /// The page's visible area is its CropBox, whose origin need not be (0, 0).
  /// `v` is measured from the top, matching [PdfTextRun] and the viewer.
  (double, double) _displayPoint(double x, double y) {
    final box = page.box;
    final u0 = (x - box.left) / box.width;
    final v0 = 1 - (y - box.bottom) / box.height;
    return switch (page.rotation) {
      90 => (1 - v0, u0),
      180 => (1 - u0, 1 - v0),
      270 => (v0, 1 - u0),
      _ => (u0, v0),
    };
  }
}

double _num(Object? value, [double fallback = 0]) =>
    value is num ? value.toDouble() : fallback;
