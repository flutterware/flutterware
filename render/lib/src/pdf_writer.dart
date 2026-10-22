import 'dart:typed_data';
import 'dart:ui';

import 'package:pdf/pdf.dart';
import 'package:vector_math/vector_math_64.dart' show Matrix4;

import 'glyph_outlines.dart';
import 'model.dart';

/// Replays a [VgRecording] into a single-page PDF via package:pdf's low-level
/// graphics API. Text is real text: the TTFs are embedded and each run is a
/// `drawString` at its measured baseline.
///
/// The op stream is in Flutter coordinates (y down); PDF is y up. One global
/// flip on the CTM maps all geometry, and the two op kinds that would come
/// out mirrored under it — glyphs and images — each un-flip locally.
Future<Uint8List> writePdf(
  VgRecording rec,
  Size size,
  List<RenderFont> fonts, {
  CaptureOptions? options,
  List<RenderWarning>? warnings,
}) async {
  var opts = options ?? CaptureOptions();
  var warningSink = warnings ?? [];
  var doc = PdfDocument();
  var page = PdfPage(doc, pageFormat: PdfPageFormat(size.width, size.height));
  var g = page.getGraphics();

  var pdfFonts = <RenderFont, PdfTtfFont>{};
  for (var face in fonts) {
    try {
      pdfFonts[face] = PdfTtfFont(doc, face.bytes.buffer.asByteData());
    } catch (e) {
      // A face the parser cannot take (e.g. CFF-flavored OTF) loses its runs
      // to the fallback font rather than the whole export.
    }
  }

  PdfTtfFont? fontFor(TextRun run) {
    RenderFont? best;
    var wantBold = run.fontWeight.value >= FontWeight.w600.value;
    var wantItalic = run.fontStyle == FontStyle.italic;
    for (var face in pdfFonts.keys) {
      if (face.family != run.fontFamily) continue;
      best ??= face;
      if (face.bold == wantBold && face.italic == wantItalic) best = face;
    }
    if (best == null && pdfFonts.isNotEmpty) {
      for (var face in pdfFonts.keys) {
        if (!face.bold && !face.italic) return pdfFonts[face];
      }
    }
    return best == null ? null : pdfFonts[best];
  }

  PdfColor color(Color c) => PdfColor(c.r, c.g, c.b, c.a);

  // Base-14 faces for TextPolicy.systemFont: nothing embedded, the viewer's
  // own Helvetica renders the string.
  var base14 = <String, PdfFont>{};
  PdfFont helveticaFor(TextRun run) {
    var bold = run.fontWeight.value >= FontWeight.w600.value;
    var italic = run.fontStyle == FontStyle.italic;
    return base14.putIfAbsent('$bold-$italic', () {
      if (bold && italic) return PdfFont.helveticaBoldOblique(doc);
      if (bold) return PdfFont.helveticaBold(doc);
      if (italic) return PdfFont.helveticaOblique(doc);
      return PdfFont.helvetica(doc);
    });
  }

  var rasterImages = <int, PdfImage>{};
  bool drawRaster(int? rasterId, {BlendMode? blend}) {
    if (rasterId == null) return false;
    var bounds = rec.rasterRects[rasterId];
    var image = rec.images[rasterId];
    var rgba = rec.imageRgba[rasterId];
    if (bounds == null || image == null || rgba == null) return false;
    var pdfImage = rasterImages.putIfAbsent(
      rasterId,
      () =>
          PdfImage(doc, image: rgba, width: image.width, height: image.height),
    );
    g.saveContext();
    if (documentBlendModes.containsKey(blend)) {
      // PDF spells the modes it shares with Flutter the way Flutter does.
      g.setGraphicState(
        PdfGraphicState(blendMode: PdfBlendMode.values.byName(blend!.name)),
      );
    }
    g.setTransform(
      Matrix4.translationValues(bounds.left, bounds.bottom, 0)
        ..multiply(Matrix4.diagonal3Values(1, -1, 1)),
    );
    g.drawImage(pdfImage, 0, 0, bounds.width, bounds.height);
    g.restoreContext();
    return true;
  }

  /// Applies the unsupported-op policy to a shader the capture could not
  /// see through. True when the op is fully dealt with; false to draw the
  /// flat-color stand-in.
  bool tookUnsupported(VgPaint paint, int? rasterId) {
    if (!paint.hadUnresolvedShader) return false;
    return switch (opts.unsupported) {
      UnsupportedPolicy.rasterize => drawRaster(rasterId),
      UnsupportedPolicy.flatten => false,
      UnsupportedPolicy.skip => true,
    };
  }

  var glyphSources = <RenderFont, GlyphSource?>{};

  /// Draws a run as glyph outlines read from the font file — the road for
  /// text the embedded-font machinery cannot take (CFF faces, unencodable
  /// code points). Geometry is in Flutter coordinates like every other op;
  /// the global flip maps it, so unlike drawString no local transform is
  /// needed.
  bool drawRunAsOutlines(TextRun run) {
    var clusters = run.clusters;
    if (clusters == null) return false;
    var source = glyphSourceForRun(fonts, run, glyphSources);
    if (source == null) return false;
    var scale = run.fontSize / source.unitsPerEm;
    var drewAnything = false;
    for (var cluster in clusters) {
      var outline = source.outlineForChar(cluster.text.runes.first);
      if (outline == null) return false;
      for (var contour in outline) {
        double px(double v) => cluster.x + v * scale;
        double py(double v) => run.baseline - v * scale;
        var x = px(contour.start.dx);
        var y = py(contour.start.dy);
        g.moveTo(x, y);
        for (var segment in contour.segments) {
          switch (segment) {
            case GlyphLine(:var to):
              x = px(to.dx);
              y = py(to.dy);
              g.lineTo(x, y);
            case GlyphQuad(:var control, :var to):
              // PDF has no quadratics; elevate to a cubic.
              var cx = px(control.dx), cy = py(control.dy);
              var tx = px(to.dx), ty = py(to.dy);
              g.curveTo(
                x + 2 / 3 * (cx - x),
                y + 2 / 3 * (cy - y),
                tx + 2 / 3 * (cx - tx),
                ty + 2 / 3 * (cy - ty),
                tx,
                ty,
              );
              x = tx;
              y = ty;
            case GlyphCubic(:var control1, :var control2, :var to):
              x = px(to.dx);
              y = py(to.dy);
              g.curveTo(
                px(control1.dx),
                py(control1.dy),
                px(control2.dx),
                py(control2.dy),
                x,
                y,
              );
          }
        }
        g.closePath();
        drewAnything = true;
      }
    }
    if (drewAnything) {
      g.setFillColor(color(run.color));
      g.fillPath();
    }
    return true;
  }

  void emitPath(VgPathData path) {
    for (var contour in path.contours) {
      if (contour.points.isEmpty) continue;
      g.moveTo(contour.points.first.dx, contour.points.first.dy);
      for (var point in contour.points.skip(1)) {
        g.lineTo(point.dx, point.dy);
      }
      if (contour.closed) g.closePath();
    }
  }

  void emitRRect(RRect r) {
    const k = 0.5522847498;
    g.moveTo(r.left + r.tlRadiusX, r.top);
    g.lineTo(r.right - r.trRadiusX, r.top);
    g.curveTo(
      r.right - r.trRadiusX * (1 - k),
      r.top,
      r.right,
      r.top + r.trRadiusY * (1 - k),
      r.right,
      r.top + r.trRadiusY,
    );
    g.lineTo(r.right, r.bottom - r.brRadiusY);
    g.curveTo(
      r.right,
      r.bottom - r.brRadiusY * (1 - k),
      r.right - r.brRadiusX * (1 - k),
      r.bottom,
      r.right - r.brRadiusX,
      r.bottom,
    );
    g.lineTo(r.left + r.blRadiusX, r.bottom);
    g.curveTo(
      r.left + r.blRadiusX * (1 - k),
      r.bottom,
      r.left,
      r.bottom - r.blRadiusY * (1 - k),
      r.left,
      r.bottom - r.blRadiusY,
    );
    g.lineTo(r.left, r.top + r.tlRadiusY);
    g.curveTo(
      r.left,
      r.top + r.tlRadiusY * (1 - k),
      r.left + r.tlRadiusX * (1 - k),
      r.top,
      r.left + r.tlRadiusX,
      r.top,
    );
    g.closePath();
  }

  void finish(VgPaint p, {bool evenOdd = false}) {
    if (p.style == PaintingStyle.fill) {
      // PDF has no per-path gradient fill op at this API level without a
      // shading pattern; the spike fills with the mean gradient color.
      var c = p.gradient != null ? _average(p.gradient!.colors) : p.color;
      g.setFillColor(color(c));
      g.fillPath(evenOdd: evenOdd);
    } else {
      g.setStrokeColor(color(p.color));
      g.setLineWidth(p.strokeWidth);
      g.setLineCap(switch (p.strokeCap) {
        StrokeCap.butt => PdfLineCap.butt,
        StrokeCap.round => PdfLineCap.round,
        StrokeCap.square => PdfLineCap.square,
      });
      g.strokePath();
    }
  }

  g.saveContext();
  g.setTransform(
    Matrix4.translationValues(0, size.height, 0)
      ..multiply(Matrix4.diagonal3Values(1, -1, 1)),
  );

  // An effect span whose patch is placed — or that the policy leaves out —
  // must not also paint its child ops; skipDepth swallows the span.
  var skipDepth = 0;
  for (var op in rec.ops) {
    if (skipDepth > 0) {
      if (op is VgBeginEffect) skipDepth++;
      if (op is VgEndEffect) skipDepth--;
      continue;
    }
    switch (op) {
      case VgBeginEffect begin:
        if (opts.unsupported == UnsupportedPolicy.skip ||
            (opts.unsupported == UnsupportedPolicy.rasterize &&
                drawRaster(begin.rasterId, blend: begin.documentBlend))) {
          skipDepth = 1;
          break;
        }
        // Otherwise the effect is dropped and its child paints plain,
        // flagged by the warnings channel — in a context of its own, since a
        // layer's child may transform without a save of its own, and keeping
        // a layer's opacity, which needs no patch.
        g.saveContext();
        if (begin.kind == VgEffectKind.layer && begin.opacity < 1) {
          g.setGraphicState(PdfGraphicState(opacity: begin.opacity));
        }
      case VgEndEffect():
        g.restoreContext();
      case VgSave():
        g.saveContext();
      case VgSaveLayer(:var opacity):
        g.saveContext();
        g.setGraphicState(PdfGraphicState(opacity: opacity));
      case VgRestore():
        g.restoreContext();
      case VgTransform(:var matrix):
        g.setTransform(Matrix4.fromFloat64List(matrix));
      case VgClipRect(:var rect):
        g.moveTo(rect.left, rect.top);
        g.lineTo(rect.right, rect.top);
        g.lineTo(rect.right, rect.bottom);
        g.lineTo(rect.left, rect.bottom);
        g.closePath();
        g.clipPath();
      case VgClipRRect(:var rrect):
        emitRRect(rrect);
        g.clipPath();
      case VgClipPath(:var path):
        emitPath(path);
        g.clipPath(evenOdd: path.evenOdd);
      case VgDrawRect(:var rect, :var paint, :var rasterId):
        if (tookUnsupported(paint, rasterId)) break;
        var r = rect == Rect.largest
            ? Rect.fromLTWH(0, 0, size.width, size.height)
            : rect;
        g.moveTo(r.left, r.top);
        g.lineTo(r.right, r.top);
        g.lineTo(r.right, r.bottom);
        g.lineTo(r.left, r.bottom);
        g.closePath();
        finish(paint);
      case VgDrawRRect(:var rrect, :var paint, :var rasterId):
        if (tookUnsupported(paint, rasterId)) break;
        emitRRect(rrect);
        finish(paint);
      case VgDrawDRRect(:var outer, :var inner, :var paint):
        emitRRect(outer);
        emitRRect(inner);
        finish(paint, evenOdd: true);
      case VgDrawCircle(:var center, :var radius, :var paint, :var rasterId):
        if (tookUnsupported(paint, rasterId)) break;
        var rect = Rect.fromCircle(center: center, radius: radius);
        emitRRect(RRect.fromRectXY(rect, radius, radius));
        finish(paint);
      case VgDrawOval(:var rect, :var paint, :var rasterId):
        if (tookUnsupported(paint, rasterId)) break;
        emitRRect(RRect.fromRectXY(rect, rect.width / 2, rect.height / 2));
        finish(paint);
      case VgDrawLine(:var a, :var b, :var paint):
        g.moveTo(a.dx, a.dy);
        g.lineTo(b.dx, b.dy);
        finish(
          VgPaint(
            color: paint.color,
            style: PaintingStyle.stroke,
            strokeWidth: paint.strokeWidth,
            strokeCap: paint.strokeCap,
            strokeJoin: paint.strokeJoin,
          ),
        );
      case VgDrawPath(:var path, :var paint, :var rasterId):
        if (tookUnsupported(paint, rasterId)) break;
        emitPath(path);
        finish(paint, evenOdd: path.evenOdd);
      case VgDrawShadow(:var rasterId):
        if (opts.unsupported == UnsupportedPolicy.rasterize) {
          drawRaster(rasterId);
        }
      case VgDrawImageRect(:var imageId, :var dst):
        var image = rec.images[imageId]!;
        var pdfImage = PdfImage(
          doc,
          image: rec.imageRgba[imageId]!,
          width: image.width,
          height: image.height,
        );
        g.saveContext();
        g.setTransform(
          Matrix4.translationValues(dst.left, dst.bottom, 0)
            ..multiply(Matrix4.diagonal3Values(1, -1, 1)),
        );
        g.drawImage(pdfImage, 0, 0, dst.width, dst.height);
        g.restoreContext();
      case VgDrawText(:var runs):
        for (var run in runs) {
          var mode = opts.text(run);
          if (mode == TextPolicy.vectorize && drawRunAsOutlines(run)) {
            continue;
          }
          // A failed drawString leaves a half-written text object in the
          // content stream, so encodability is checked before writing: the
          // glyphs must exist, and a non-unicode font (base-14 or a
          // CFF-flavored OTF) can only take Latin-1.
          PdfFont? font;
          if (mode == TextPolicy.systemFont) {
            var helvetica = helveticaFor(run);
            if (run.text.runes.every((r) => r < 256)) font = helvetica;
          } else {
            var ttf = fontFor(run);
            if (ttf != null &&
                run.text.runes.every(ttf.isRuneSupported) &&
                (ttf.font.unicode || run.text.runes.every((r) => r < 256))) {
              font = ttf;
            }
          }
          if (font == null) {
            if (!drawRunAsOutlines(run)) {
              warningSink.add(
                RenderWarning(
                  RenderWarningKind.droppedText,
                  'text run "${run.text}" dropped: no available font can '
                  'write it',
                ),
              );
            }
            continue;
          }
          g.saveContext();
          g.setTransform(
            Matrix4.translationValues(run.x, run.baseline, 0)
              ..multiply(Matrix4.diagonal3Values(1, -1, 1)),
          );
          g.setFillColor(color(run.color));
          g.drawString(
            font,
            run.fontSize,
            run.text,
            0,
            0,
            charSpace: run.letterSpacing ?? 0,
          );
          g.restoreContext();
        }
      case VgDrawUnknownParagraph(:var bounds, :var rasterId):
        if (opts.unsupported == UnsupportedPolicy.rasterize &&
            drawRaster(rasterId)) {
          break;
        }
        if (opts.unsupported == UnsupportedPolicy.skip) break;
        g.moveTo(bounds.left, bounds.top);
        g.lineTo(bounds.right, bounds.top);
        g.lineTo(bounds.right, bounds.bottom);
        g.lineTo(bounds.left, bounds.bottom);
        g.closePath();
        g.setFillColor(const PdfColor(1, 0, 1, 0.3));
        g.fillPath();
    }
  }
  g.restoreContext();

  return doc.save();
}

Color _average(List<Color> colors) {
  var r = 0.0, g = 0.0, b = 0.0, a = 0.0;
  for (var c in colors) {
    r += c.r;
    g += c.g;
    b += c.b;
    a += c.a;
  }
  var n = colors.length;
  return Color.from(alpha: a / n, red: r / n, green: g / n, blue: b / n);
}
