import 'dart:typed_data';
import 'dart:ui';

import 'model.dart';

/// Reads glyph outlines straight out of a font file.
///
/// dart:ui exposes no glyph geometry, but the export already holds the font
/// bytes it would otherwise embed. Two outline flavors exist behind the same
/// sfnt wrapper: TrueType keeps quadratic beziers in a `glyf` table,
/// CFF-flavored OpenType (`OTTO`) keeps PostScript Type2 charstrings in a
/// `CFF ` table — cubics behind a small stack interpreter. Character to
/// glyph goes through `cmap` either way; positions do NOT come from here
/// (no GSUB/kerning) but from the laid-out paragraph's own per-cluster
/// boxes.
class GlyphSource {
  GlyphSource._(this.unitsPerEm, this._cmap, this._outlines);

  static GlyphSource? tryParse(Uint8List bytes) {
    var data = ByteData.sublistView(bytes);
    var numTables = data.getUint16(4);
    var tables = <String, (int, int)>{};
    for (var i = 0; i < numTables; i++) {
      var o = 12 + i * 16;
      var tag = String.fromCharCodes(bytes, o, o + 4);
      tables[tag] = (data.getUint32(o + 8), data.getUint32(o + 12));
    }
    var head = tables['head'];
    var cmap = tables['cmap'];
    if (head == null || cmap == null) return null;
    var unitsPerEm = data.getUint16(head.$1 + 18);
    var charToGlyph = _parseCmap(data, cmap.$1);
    if (charToGlyph == null) return null;

    _OutlineTable? outlines;
    var loca = tables['loca'];
    var glyf = tables['glyf'];
    var maxp = tables['maxp'];
    var cff = tables['CFF '];
    if (loca != null && glyf != null && maxp != null) {
      var longLoca = data.getInt16(head.$1 + 50) == 1;
      var numGlyphs = data.getUint16(maxp.$1 + 4);
      var offsets = Uint32List(numGlyphs + 1);
      for (var i = 0; i <= numGlyphs; i++) {
        offsets[i] = longLoca
            ? data.getUint32(loca.$1 + i * 4)
            : data.getUint16(loca.$1 + i * 2) * 2;
      }
      outlines = _TtfOutlines(data, offsets, glyf.$1);
    } else if (cff != null) {
      outlines = _CffOutlines.tryParse(data, cff.$1);
    }
    if (outlines == null) return null;
    return GlyphSource._(unitsPerEm, charToGlyph, outlines);
  }

  final int unitsPerEm;
  final Map<int, int> _cmap;
  final _OutlineTable _outlines;
  final _cache = <int, List<GlyphContour>?>{};

  /// Contours for one code point, in font units (y up), or null when the
  /// font has no glyph for it.
  List<GlyphContour>? outlineForChar(int rune) {
    var glyphId = _cmap[rune];
    if (glyphId == null) return null;
    return _cache.putIfAbsent(
      glyphId,
      () => _outlines.outlineForGlyph(glyphId),
    );
  }

  static Map<int, int>? _parseCmap(ByteData data, int cmapOffset) {
    var numTables = data.getUint16(cmapOffset + 2);
    var best = -1;
    for (var i = 0; i < numTables; i++) {
      var o = cmapOffset + 4 + i * 8;
      var platform = data.getUint16(o);
      var encoding = data.getUint16(o + 2);
      var offset = data.getUint32(o + 4);
      var unicode =
          platform == 0 || (platform == 3 && (encoding == 1 || encoding == 10));
      if (unicode) best = cmapOffset + offset;
    }
    if (best == -1) return null;
    var format = data.getUint16(best);
    var map = <int, int>{};
    if (format == 4) {
      var segCount = data.getUint16(best + 6) ~/ 2;
      var endsAt = best + 14;
      var startsAt = endsAt + segCount * 2 + 2;
      var deltasAt = startsAt + segCount * 2;
      var rangeOffsetsAt = deltasAt + segCount * 2;
      for (var seg = 0; seg < segCount; seg++) {
        var endCode = data.getUint16(endsAt + seg * 2);
        var startCode = data.getUint16(startsAt + seg * 2);
        var idDelta = data.getInt16(deltasAt + seg * 2);
        var idRangeOffset = data.getUint16(rangeOffsetsAt + seg * 2);
        if (startCode == 0xFFFF) continue;
        for (var c = startCode; c <= endCode; c++) {
          int glyph;
          if (idRangeOffset == 0) {
            glyph = (c + idDelta) & 0xFFFF;
          } else {
            var addr =
                rangeOffsetsAt + seg * 2 + idRangeOffset + (c - startCode) * 2;
            glyph = data.getUint16(addr);
            if (glyph != 0) glyph = (glyph + idDelta) & 0xFFFF;
          }
          if (glyph != 0) map[c] = glyph;
        }
      }
    } else if (format == 12) {
      var nGroups = data.getUint32(best + 12);
      for (var g = 0; g < nGroups; g++) {
        var o = best + 16 + g * 12;
        var startChar = data.getUint32(o);
        var endChar = data.getUint32(o + 4);
        var startGlyph = data.getUint32(o + 8);
        for (var c = startChar; c <= endChar; c++) {
          map[c] = startGlyph + (c - startChar);
        }
      }
    } else {
      return null;
    }
    return map;
  }
}

/// Picks the closest declared face for a run and parses it once.
GlyphSource? glyphSourceForRun(
  List<RenderFont> fonts,
  TextRun run,
  Map<RenderFont, GlyphSource?> cache,
) {
  RenderFont? best;
  var wantBold = run.fontWeight.value >= FontWeight.w600.value;
  var wantItalic = run.fontStyle == FontStyle.italic;
  for (var face in fonts) {
    if (face.family != run.fontFamily) continue;
    best ??= face;
    if (face.bold == wantBold && face.italic == wantItalic) best = face;
  }
  var face = best;
  if (face == null) return null;
  return cache.putIfAbsent(face, () => GlyphSource.tryParse(face.bytes));
}

abstract class _OutlineTable {
  List<GlyphContour>? outlineForGlyph(int glyphId);
}

// --- TrueType: quadratics from the glyf table -------------------------------

class _TtfOutlines implements _OutlineTable {
  _TtfOutlines(this._data, this._loca, this._glyfOffset);

  final ByteData _data;
  final Uint32List _loca;
  final int _glyfOffset;

  @override
  List<GlyphContour>? outlineForGlyph(int glyphId) =>
      _outline(glyphId, depth: 0);

  List<GlyphContour>? _outline(int glyphId, {required int depth}) {
    if (depth > 4 || glyphId + 1 >= _loca.length) return null;
    var start = _loca[glyphId];
    var end = _loca[glyphId + 1];
    if (end <= start) return const []; // no outline: space and friends
    var o = _glyfOffset + start;
    var numberOfContours = _data.getInt16(o);
    return numberOfContours >= 0
        ? _parseSimple(o, numberOfContours)
        : _parseComposite(o, depth);
  }

  List<GlyphContour> _parseSimple(int o, int numberOfContours) {
    var endPts = List<int>.generate(
      numberOfContours,
      (i) => _data.getUint16(o + 10 + i * 2),
    );
    var numPoints = endPts.isEmpty ? 0 : endPts.last + 1;
    var p = o + 10 + numberOfContours * 2;
    var instructionLength = _data.getUint16(p);
    p += 2 + instructionLength;

    var flags = Uint8List(numPoints);
    for (var i = 0; i < numPoints;) {
      var flag = _data.getUint8(p++);
      flags[i++] = flag;
      if (flag & 8 != 0) {
        var repeat = _data.getUint8(p++);
        for (var r = 0; r < repeat; r++) {
          flags[i++] = flag;
        }
      }
    }

    var xs = Int32List(numPoints);
    var x = 0;
    for (var i = 0; i < numPoints; i++) {
      var flag = flags[i];
      if (flag & 2 != 0) {
        var dx = _data.getUint8(p++);
        x += flag & 16 != 0 ? dx : -dx;
      } else if (flag & 16 == 0) {
        x += _data.getInt16(p);
        p += 2;
      }
      xs[i] = x;
    }
    var ys = Int32List(numPoints);
    var y = 0;
    for (var i = 0; i < numPoints; i++) {
      var flag = flags[i];
      if (flag & 4 != 0) {
        var dy = _data.getUint8(p++);
        y += flag & 32 != 0 ? dy : -dy;
      } else if (flag & 32 == 0) {
        y += _data.getInt16(p);
        p += 2;
      }
      ys[i] = y;
    }

    var contours = <GlyphContour>[];
    var first = 0;
    for (var endPt in endPts) {
      contours.add(
        _buildContour([
          for (var i = first; i <= endPt; i++)
            (Offset(xs[i].toDouble(), ys[i].toDouble()), flags[i] & 1 != 0),
        ]),
      );
      first = endPt + 1;
    }
    return contours;
  }

  List<GlyphContour> _parseComposite(int o, int depth) {
    var contours = <GlyphContour>[];
    var p = o + 10;
    while (true) {
      var flags = _data.getUint16(p);
      var glyphIndex = _data.getUint16(p + 2);
      p += 4;
      double dx, dy;
      if (flags & 1 != 0) {
        dx = _data.getInt16(p).toDouble();
        dy = _data.getInt16(p + 2).toDouble();
        p += 4;
      } else {
        dx = _data.getInt8(p).toDouble();
        dy = _data.getInt8(p + 1).toDouble();
        p += 2;
      }
      var scaleX = 1.0, scaleY = 1.0;
      if (flags & 8 != 0) {
        scaleX = scaleY = _data.getInt16(p) / 16384;
        p += 2;
      } else if (flags & 64 != 0) {
        scaleX = _data.getInt16(p) / 16384;
        scaleY = _data.getInt16(p + 2) / 16384;
        p += 4;
      } else if (flags & 128 != 0) {
        // 2x2 transform: take the diagonal, good enough for the spike.
        scaleX = _data.getInt16(p) / 16384;
        scaleY = _data.getInt16(p + 6) / 16384;
        p += 8;
      }
      var component = _outline(glyphIndex, depth: depth + 1);
      if (component != null && (flags & 2 != 0)) {
        for (var contour in component) {
          contours.add(contour.transformed(scaleX, scaleY, dx, dy));
        }
      }
      if (flags & 32 == 0) break;
    }
    return contours;
  }

  static GlyphContour _buildContour(List<(Offset, bool)> points) {
    // TrueType point streams: consecutive off-curve points imply an
    // on-curve midpoint between them.
    var startIdx = points.indexWhere((p) => p.$2);
    Offset start;
    if (startIdx == -1) {
      start = Offset.lerp(points[0].$1, points[1].$1, 0.5)!;
      startIdx = 0;
    } else {
      start = points[startIdx].$1;
      startIdx += 1;
    }
    var segments = <GlyphSegment>[];
    Offset? control;
    for (var i = 0; i < points.length; i++) {
      var (point, onCurve) = points[(startIdx + i) % points.length];
      if (onCurve) {
        segments.add(
          control == null ? GlyphLine(point) : GlyphQuad(control, point),
        );
        control = null;
      } else {
        if (control != null) {
          segments.add(GlyphQuad(control, Offset.lerp(control, point, 0.5)!));
        }
        control = point;
      }
    }
    if (control != null) {
      segments.add(GlyphQuad(control, start));
    }
    return GlyphContour(start, segments);
  }
}

// --- CFF: Type2 charstrings, cubics behind a stack interpreter --------------

class _CffOutlines implements _OutlineTable {
  _CffOutlines(
    this._data,
    this._charStrings,
    this._localSubrs,
    this._globalSubrs,
  );

  static _CffOutlines? tryParse(ByteData data, int cffStart) {
    var hdrSize = data.getUint8(cffStart + 2);
    var pos = cffStart + hdrSize;
    var (_, afterNames) = _readIndex(data, pos); // Name INDEX
    var (topDicts, afterTop) = _readIndex(data, afterNames);
    var (_, afterStrings) = _readIndex(data, afterTop); // String INDEX
    var (globalSubrs, _) = _readIndex(data, afterStrings);
    if (topDicts.isEmpty) return null;
    var topDict = _parseDict(data, topDicts.first.$1, topDicts.first.$2);
    if (topDict.containsKey(0xc1e)) return null; // ROS: CID-keyed, out of scope
    var charStringsOffset = topDict[17]?.first.toInt();
    if (charStringsOffset == null) return null;
    var (charStrings, _) = _readIndex(data, cffStart + charStringsOffset);

    var localSubrs = <(int, int)>[];
    var private = topDict[18];
    if (private != null && private.length == 2) {
      var privStart = cffStart + private[1].toInt();
      var privDict = _parseDict(
        data,
        privStart,
        privStart + private[0].toInt(),
      );
      var subrsOffset = privDict[19]?.first.toInt();
      if (subrsOffset != null) {
        (localSubrs, _) = _readIndex(data, privStart + subrsOffset);
      }
    }
    return _CffOutlines(data, charStrings, localSubrs, globalSubrs);
  }

  final ByteData _data;
  final List<(int, int)> _charStrings;
  final List<(int, int)> _localSubrs;
  final List<(int, int)> _globalSubrs;

  static int _bias(List<(int, int)> subrs) => subrs.length < 1240
      ? 107
      : subrs.length < 33900
      ? 1131
      : 32768;

  @override
  List<GlyphContour>? outlineForGlyph(int glyphId) {
    if (glyphId >= _charStrings.length) return null;
    var interp = _Type2Interpreter(this);
    var (start, end) = _charStrings[glyphId];
    interp.run(start, end, 0);
    interp.closeContour();
    return interp.contours;
  }

  /// An INDEX: count, offSize, count+1 offsets, then the packed data. The
  /// returned slices are absolute (start, end) offsets into the file.
  static (List<(int, int)>, int) _readIndex(ByteData data, int pos) {
    var count = data.getUint16(pos);
    if (count == 0) return (const [], pos + 2);
    var offSize = data.getUint8(pos + 2);
    int offsetAt(int i) {
      var o = pos + 3 + i * offSize;
      var v = 0;
      for (var b = 0; b < offSize; b++) {
        v = (v << 8) | data.getUint8(o + b);
      }
      return v;
    }

    var dataStart = pos + 3 + (count + 1) * offSize - 1;
    var slices = <(int, int)>[
      for (var i = 0; i < count; i++)
        (dataStart + offsetAt(i), dataStart + offsetAt(i + 1)),
    ];
    return (slices, dataStart + offsetAt(count));
  }

  /// DICT: operands then a 1- or 2-byte operator; two-byte ops are keyed
  /// as 0xc00 | second byte.
  static Map<int, List<double>> _parseDict(ByteData data, int start, int end) {
    var dict = <int, List<double>>{};
    var operands = <double>[];
    var p = start;
    while (p < end) {
      var b0 = data.getUint8(p);
      if (b0 <= 21) {
        var op = b0;
        p += 1;
        if (b0 == 12) {
          op = 0xc00 | data.getUint8(p);
          p += 1;
        }
        dict[op] = List.of(operands);
        operands.clear();
      } else if (b0 == 28) {
        operands.add(data.getInt16(p + 1).toDouble());
        p += 3;
      } else if (b0 == 29) {
        operands.add(data.getInt32(p + 1).toDouble());
        p += 5;
      } else if (b0 == 30) {
        var (value, next) = _readReal(data, p + 1);
        operands.add(value);
        p = next;
      } else if (b0 >= 32 && b0 <= 246) {
        operands.add((b0 - 139).toDouble());
        p += 1;
      } else if (b0 >= 247 && b0 <= 250) {
        operands.add(
          ((b0 - 247) * 256 + data.getUint8(p + 1) + 108).toDouble(),
        );
        p += 2;
      } else if (b0 >= 251 && b0 <= 254) {
        operands.add(
          (-(b0 - 251) * 256 - data.getUint8(p + 1) - 108).toDouble(),
        );
        p += 2;
      } else {
        break;
      }
    }
    return dict;
  }

  static (double, int) _readReal(ByteData data, int p) {
    var s = StringBuffer();
    const nibbles = '0123456789.EE?-?';
    while (true) {
      var b = data.getUint8(p++);
      for (var half in [b >> 4, b & 15]) {
        if (half == 15) return (double.tryParse(s.toString()) ?? 0, p);
        if (half == 12) {
          s.write('E-');
        } else {
          s.write(nibbles[half]);
        }
      }
    }
  }
}

class _Type2Interpreter {
  _Type2Interpreter(this.font);

  final _CffOutlines font;
  final contours = <GlyphContour>[];
  final stack = <double>[];
  var x = 0.0, y = 0.0;
  var nStems = 0;
  var widthParsed = false;
  var ended = false;

  Offset? _start;
  List<GlyphSegment>? _segments;

  void moveTo(double nx, double ny) {
    closeContour();
    x = nx;
    y = ny;
    _start = Offset(x, y);
    _segments = [];
  }

  void lineTo(double nx, double ny) {
    x = nx;
    y = ny;
    _segments?.add(GlyphLine(Offset(x, y)));
  }

  void curveTo(
    double c1x,
    double c1y,
    double c2x,
    double c2y,
    double nx,
    double ny,
  ) {
    x = nx;
    y = ny;
    _segments?.add(
      GlyphCubic(Offset(c1x, c1y), Offset(c2x, c2y), Offset(x, y)),
    );
  }

  void closeContour() {
    var start = _start;
    var segments = _segments;
    if (start != null && segments != null && segments.isNotEmpty) {
      contours.add(GlyphContour(start, segments));
    }
    _start = null;
    _segments = null;
  }

  /// One extra leading operand on the first stack-clearing operator is the
  /// glyph width.
  void _takeWidth(int arity) {
    if (!widthParsed) {
      widthParsed = true;
      if ((stack.length - arity).isOdd && stack.isNotEmpty) {
        stack.removeAt(0);
      }
    }
  }

  void run(int start, int end, int depth) {
    if (depth > 10 || ended) return;
    var d = font._data;
    var p = start;
    while (p < end && !ended) {
      var b0 = d.getUint8(p);
      if (b0 >= 32 || b0 == 28) {
        // Operand.
        if (b0 == 28) {
          stack.add(d.getInt16(p + 1).toDouble());
          p += 3;
        } else if (b0 <= 246) {
          stack.add((b0 - 139).toDouble());
          p += 1;
        } else if (b0 <= 250) {
          stack.add(((b0 - 247) * 256 + d.getUint8(p + 1) + 108).toDouble());
          p += 2;
        } else if (b0 <= 254) {
          stack.add((-(b0 - 251) * 256 - d.getUint8(p + 1) - 108).toDouble());
          p += 2;
        } else {
          stack.add(d.getInt32(p + 1) / 65536);
          p += 5;
        }
        continue;
      }
      p += 1;
      switch (b0) {
        case 1 || 3 || 18 || 23: // hstem vstem hstemhm vstemhm
          _takeWidth(0);
          nStems += stack.length ~/ 2;
          stack.clear();
        case 19 || 20: // hintmask cntrmask
          _takeWidth(0);
          nStems += stack.length ~/ 2;
          stack.clear();
          p += (nStems + 7) >> 3;
        case 21: // rmoveto
          _takeWidth(2);
          moveTo(x + stack[0], y + stack[1]);
          stack.clear();
        case 22: // hmoveto
          _takeWidth(1);
          moveTo(x + stack[0], y);
          stack.clear();
        case 4: // vmoveto
          _takeWidth(1);
          moveTo(x, y + stack[0]);
          stack.clear();
        case 5: // rlineto
          for (var i = 0; i + 1 < stack.length; i += 2) {
            lineTo(x + stack[i], y + stack[i + 1]);
          }
          stack.clear();
        case 6 || 7: // hlineto vlineto: alternating axis deltas
          var horizontal = b0 == 6;
          for (var value in stack) {
            if (horizontal) {
              lineTo(x + value, y);
            } else {
              lineTo(x, y + value);
            }
            horizontal = !horizontal;
          }
          stack.clear();
        case 8: // rrcurveto
          for (var i = 0; i + 5 < stack.length; i += 6) {
            _relCurve(stack, i);
          }
          stack.clear();
        case 24: // rcurveline
          var i = 0;
          for (; i + 5 < stack.length - 2; i += 6) {
            _relCurve(stack, i);
          }
          lineTo(x + stack[i], y + stack[i + 1]);
          stack.clear();
        case 25: // rlinecurve
          var i = 0;
          for (; i + 1 < stack.length - 6; i += 2) {
            lineTo(x + stack[i], y + stack[i + 1]);
          }
          _relCurve(stack, i);
          stack.clear();
        case 26 || 27: // vvcurveto hhcurveto
          var i = 0;
          var d1 = 0.0;
          if (stack.length.isOdd) {
            d1 = stack[0];
            i = 1;
          }
          for (; i + 3 < stack.length; i += 4) {
            if (b0 == 27) {
              var c1x = x + stack[i], c1y = y + d1;
              var c2x = c1x + stack[i + 1], c2y = c1y + stack[i + 2];
              curveTo(c1x, c1y, c2x, c2y, c2x + stack[i + 3], c2y);
            } else {
              var c1x = x + d1, c1y = y + stack[i];
              var c2x = c1x + stack[i + 1], c2y = c1y + stack[i + 2];
              curveTo(c1x, c1y, c2x, c2y, c2x, c2y + stack[i + 3]);
            }
            d1 = 0;
          }
          stack.clear();
        case 30 || 31: // vhcurveto hvcurveto: alternating tangents
          var horizontal = b0 == 31;
          var i = 0;
          while (stack.length - i >= 4) {
            var lastExtra = stack.length - i == 5 ? stack[i + 4] : 0.0;
            if (horizontal) {
              var c1x = x + stack[i], c1y = y;
              var c2x = c1x + stack[i + 1], c2y = c1y + stack[i + 2];
              curveTo(c1x, c1y, c2x, c2y, c2x + lastExtra, c2y + stack[i + 3]);
            } else {
              var c1x = x, c1y = y + stack[i];
              var c2x = c1x + stack[i + 1], c2y = c1y + stack[i + 2];
              curveTo(c1x, c1y, c2x, c2y, c2x + stack[i + 3], c2y + lastExtra);
            }
            horizontal = !horizontal;
            i += 4;
          }
          stack.clear();
        case 10: // callsubr
          var index =
              stack.removeLast().toInt() + _CffOutlines._bias(font._localSubrs);
          if (index >= 0 && index < font._localSubrs.length) {
            var (s, e) = font._localSubrs[index];
            run(s, e, depth + 1);
          }
        case 29: // callgsubr
          var index =
              stack.removeLast().toInt() +
              _CffOutlines._bias(font._globalSubrs);
          if (index >= 0 && index < font._globalSubrs.length) {
            var (s, e) = font._globalSubrs[index];
            run(s, e, depth + 1);
          }
        case 11: // return
          return;
        case 14: // endchar
          _takeWidth(0);
          ended = true;
        case 12:
          var b1 = d.getUint8(p);
          p += 1;
          _escape(b1);
        default:
          stack.clear();
      }
    }
  }

  void _relCurve(List<double> a, int i) {
    var c1x = x + a[i], c1y = y + a[i + 1];
    var c2x = c1x + a[i + 2], c2y = c1y + a[i + 3];
    curveTo(c1x, c1y, c2x, c2y, c2x + a[i + 4], c2y + a[i + 5]);
  }

  void _escape(int b1) {
    switch (b1) {
      case 35: // flex: two curves, fd ignored
        _relCurve(stack, 0);
        _relCurve(stack, 6);
      case 34: // hflex
        var startY = y;
        var c1x = x + stack[0], c1y = y;
        var c2x = c1x + stack[1], c2y = c1y + stack[2];
        curveTo(c1x, c1y, c2x, c2y, c2x + stack[3], c2y);
        var d1x = x + stack[4], d1y = y;
        var d2x = d1x + stack[5], d2y = startY;
        curveTo(d1x, d1y, d2x, d2y, d2x + stack[6], startY);
      case 36: // hflex1
        var startY = y;
        var c1x = x + stack[0], c1y = y + stack[1];
        var c2x = c1x + stack[2], c2y = c1y + stack[3];
        curveTo(c1x, c1y, c2x, c2y, c2x + stack[4], c2y);
        var d1x = x + stack[5], d1y = y;
        var d2x = d1x + stack[6], d2y = d1y + stack[7];
        curveTo(d1x, d1y, d2x, d2y, d2x + stack[8], startY);
      case 37: // flex1: the final point returns to the start along one axis
        var startX = x, startY = y;
        var dx = stack[0] + stack[2] + stack[4] + stack[6] + stack[8];
        var dy = stack[1] + stack[3] + stack[5] + stack[7] + stack[9];
        _relCurve(stack, 0);
        var c1x = x + stack[6], c1y = y + stack[7];
        var c2x = c1x + stack[8], c2y = c1y + stack[9];
        if (dx.abs() > dy.abs()) {
          curveTo(c1x, c1y, c2x, c2y, c2x + stack[10], startY);
        } else {
          curveTo(c1x, c1y, c2x, c2y, startX, c2y + stack[10]);
        }
      default:
        break;
    }
    stack.clear();
  }
}

class GlyphContour {
  GlyphContour(this.start, this.segments);
  final Offset start;
  final List<GlyphSegment> segments;

  GlyphContour transformed(double sx, double sy, double dx, double dy) {
    Offset t(Offset p) => Offset(p.dx * sx + dx, p.dy * sy + dy);
    return GlyphContour(t(start), [
      for (var s in segments)
        switch (s) {
          GlyphLine(:var to) => GlyphLine(t(to)),
          GlyphQuad(:var control, :var to) => GlyphQuad(t(control), t(to)),
          GlyphCubic(:var control1, :var control2, :var to) => GlyphCubic(
            t(control1),
            t(control2),
            t(to),
          ),
        },
    ]);
  }
}

sealed class GlyphSegment {}

class GlyphLine extends GlyphSegment {
  GlyphLine(this.to);
  final Offset to;
}

class GlyphQuad extends GlyphSegment {
  GlyphQuad(this.control, this.to);
  final Offset control;
  final Offset to;
}

class GlyphCubic extends GlyphSegment {
  GlyphCubic(this.control1, this.control2, this.to);
  final Offset control1;
  final Offset control2;
  final Offset to;
}
