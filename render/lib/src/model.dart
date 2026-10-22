import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutterware/render_contract.dart';

// The policy vocabulary and the result/warning types are the wire contract,
// shared with the pure-Dart side through `render_contract.dart`; the capture
// re-exports them so in-process users need one import.
export 'package:flutterware/render_contract.dart'
    show
        PdfResult,
        PngResult,
        RenderWarning,
        RenderWarningKind,
        SvgResult,
        TextPolicy,
        UnsupportedPolicy;

class CaptureOptions {
  CaptureOptions({
    TextPolicy Function(TextRun run)? text,
    this.unsupported = UnsupportedPolicy.rasterize,
    this.rasterScale = 3,
  }) : text = text ?? ((_) => TextPolicy.embedFont);

  /// Called per run, so icons and body text can take different roads.
  final TextPolicy Function(TextRun run) text;
  final UnsupportedPolicy unsupported;

  /// Pixel ratio for raster patches placed by [UnsupportedPolicy.rasterize].
  final double rasterScale;
}

/// A font file the writers may embed or read glyph outlines from, matched to
/// runs by family + bold/italic.
class RenderFont {
  RenderFont({
    required this.family,
    required this.bytes,
    this.bold = false,
    this.italic = false,
  });

  final String family;
  final Uint8List bytes;
  final bool bold;
  final bool italic;
}

/// The captured draw-command stream: what crossed the [ui.Canvas] boundary,
/// lifted back into inspectable values.
class VgRecording {
  final ops = <VgOp>[];
  final images = <int, ui.Image>{};
  final unhandled = <String>{};
  final unreplayableLayers = <String>[];

  /// Layers that needed a raster patch for a blend or a mask but had no
  /// bounds to size it by; they stay op by op, without the blend — unless
  /// a layer around them is patched whole, which takes them out again.
  final unboundedLayers = <VgSaveLayer>{};

  /// PNG bytes per image id, filled by [encodeImages] after the sync capture.
  final imagePngs = <int, Uint8List>{};
  final imageRgba = <int, Uint8List>{};

  /// Where a rasterized op's patch lands on the page, keyed by image id.
  final rasterRects = <int, Rect>{};
  var _nextRasterId = -1;

  /// Replays everything no vector writer can express onto a real canvas and
  /// keeps the result as an image patch. Possible because the ops kept their
  /// original dart:ui objects (paint with its live shader, path, paragraph)
  /// alongside the lifted values.
  ///
  /// Effect spans go first: a whole [VgBeginEffect]..[VgEndEffect] range
  /// replays as one patch with the effect applied — bar a layer's blend,
  /// which the writer places the patch with — and the single-op pass skips
  /// anything such a patch already covers.
  Future<void> rasterizeUnsupported({double pixelRatio = 3}) async {
    var consumed = List<bool>.filled(ops.length, false);
    for (var i = 0; i < ops.length; i++) {
      if (consumed[i]) continue;
      var op = ops[i];
      if (op is! VgBeginEffect || !op.reproducible) continue;
      var end = _matchingEnd(i);
      if (end == null) continue;
      var bounds = op.patchBounds;
      var image = await _renderPatch(bounds, pixelRatio, (canvas) {
        if (op.kind != VgEffectKind.layer) {
          replayOps(canvas, from: i, to: end + 1);
          return;
        }
        // A layer's own blend is the writer's to apply, against what lies
        // under the patch; in here it composites plainly, and everything
        // nested keeps its blend.
        canvas.saveLayer(null, _layerPaint(op.opacity));
        replayOps(canvas, from: i + 1, to: end);
        canvas.restore();
      });
      if (image == null) continue;
      var id = _nextRasterId--;
      images[id] = image;
      rasterRects[id] = bounds;
      op.rasterId = id;
      for (var j = i; j <= end; j++) {
        consumed[j] = true;
      }
    }

    for (var i = 0; i < ops.length; i++) {
      if (consumed[i]) continue;
      var op = ops[i];
      var plan = switch (op) {
        VgDrawShadow s => (
          s.source.getBounds().inflate(4 + s.elevation * 2),
          (ui.Canvas c) => c.drawShadow(s.source, s.color, s.elevation, false),
          (int id) => s.rasterId = id,
        ),
        VgDrawUnknownParagraph u => (
          u.bounds.inflate(1),
          (ui.Canvas c) => c.drawParagraph(u.paragraph, u.bounds.topLeft),
          (int id) => u.rasterId = id,
        ),
        VgDrawRect r when r.paint.needsRaster => (
          r.rect.inflate(r.paint.strokeWidth + 1),
          (ui.Canvas c) => c.drawRect(r.rect, r.paint.source!),
          (int id) => r.rasterId = id,
        ),
        VgDrawRRect r when r.paint.needsRaster => (
          r.rrect.outerRect.inflate(r.paint.strokeWidth + 1),
          (ui.Canvas c) => c.drawRRect(r.rrect, r.paint.source!),
          (int id) => r.rasterId = id,
        ),
        VgDrawOval o when o.paint.needsRaster => (
          o.rect.inflate(o.paint.strokeWidth + 1),
          (ui.Canvas c) => c.drawOval(o.rect, o.paint.source!),
          (int id) => o.rasterId = id,
        ),
        VgDrawCircle o when o.paint.needsRaster => (
          Rect.fromCircle(
            center: o.center,
            radius: o.radius + o.paint.strokeWidth + 1,
          ),
          (ui.Canvas c) => c.drawCircle(o.center, o.radius, o.paint.source!),
          (int id) => o.rasterId = id,
        ),
        VgDrawPath p when p.paint.needsRaster && p.source != null => (
          p.source!.getBounds().inflate(p.paint.strokeWidth + 1),
          (ui.Canvas c) => c.drawPath(p.source!, p.paint.source!),
          (int id) => p.rasterId = id,
        ),
        _ => null,
      };
      if (plan == null) continue;
      var (bounds, draw, assign) = plan;
      var image = await _renderPatch(bounds, pixelRatio, draw);
      if (image == null) continue;
      var id = _nextRasterId--;
      images[id] = image;
      rasterRects[id] = bounds;
      assign(id);
    }
  }

  Future<ui.Image?> _renderPatch(
    Rect bounds,
    double pixelRatio,
    void Function(ui.Canvas canvas) draw,
  ) async {
    if (bounds.isEmpty || !bounds.isFinite) return null;
    var recorder = ui.PictureRecorder();
    var canvas = ui.Canvas(recorder);
    canvas.scale(pixelRatio);
    canvas.translate(-bounds.left, -bounds.top);
    draw(canvas);
    return recorder.endRecording().toImage(
      (bounds.width * pixelRatio).ceil(),
      (bounds.height * pixelRatio).ceil(),
    );
  }

  int? _matchingEnd(int begin) {
    var depth = 0;
    for (var i = begin; i < ops.length; i++) {
      if (ops[i] is VgBeginEffect) depth++;
      if (ops[i] is VgEndEffect) {
        depth--;
        if (depth == 0) return i;
      }
    }
    return null;
  }

  /// Replays `ops[from..to)` onto a real canvas, using the live dart:ui
  /// objects each op kept. Effects apply through save layers, so a nested
  /// effect inside a rasterized span still lands in the patch.
  void replayOps(ui.Canvas canvas, {int? from, int? to}) {
    var endActions = <void Function()>[];
    for (var i = from ?? 0; i < (to ?? ops.length); i++) {
      switch (ops[i]) {
        case VgSave():
          canvas.save();
        case VgSaveLayer(:var opacity, :var bounds, :var blendMode):
          canvas.saveLayer(bounds, _layerPaint(opacity, blendMode));
        case VgRestore():
          canvas.restore();
        case VgTransform(:var matrix):
          canvas.transform(matrix);
        case VgClipRect(:var rect):
          canvas.clipRect(rect);
        case VgClipRRect(:var rrect):
          canvas.clipRRect(rrect);
        case VgClipPath(:var source):
          if (source != null) canvas.clipPath(source);
        case VgDrawRect(:var rect, :var paint):
          canvas.drawRect(rect, paint.livePaint);
        case VgDrawRRect(:var rrect, :var paint):
          canvas.drawRRect(rrect, paint.livePaint);
        case VgDrawDRRect(:var outer, :var inner, :var paint):
          canvas.drawDRRect(outer, inner, paint.livePaint);
        case VgDrawCircle(:var center, :var radius, :var paint):
          canvas.drawCircle(center, radius, paint.livePaint);
        case VgDrawOval(:var rect, :var paint):
          canvas.drawOval(rect, paint.livePaint);
        case VgDrawLine(:var a, :var b, :var paint):
          canvas.drawLine(a, b, paint.livePaint);
        case VgDrawPath(:var source, :var paint):
          if (source != null) canvas.drawPath(source, paint.livePaint);
        case VgDrawShadow(:var source, :var color, :var elevation):
          canvas.drawShadow(source, color, elevation, false);
        case VgDrawImageRect(:var imageId, :var src, :var dst):
          var image = images[imageId];
          if (image != null) {
            canvas.drawImageRect(image, src, dst, ui.Paint());
          }
        case VgDrawText(:var paragraph, :var paragraphOffset):
          if (paragraph != null && paragraphOffset != null) {
            canvas.drawParagraph(paragraph, paragraphOffset);
          }
        case VgDrawUnknownParagraph(:var bounds, :var paragraph):
          canvas.drawParagraph(paragraph, bounds.topLeft);
        case VgBeginEffect e:
          switch (e.kind) {
            case VgEffectKind.imageFilter:
              canvas.saveLayer(
                e.patchBounds,
                ui.Paint()..imageFilter = e.imageFilter,
              );
              endActions.add(canvas.restore);
            case VgEffectKind.colorFilter:
              canvas.saveLayer(
                e.bounds,
                ui.Paint()..colorFilter = e.colorFilter,
              );
              endActions.add(canvas.restore);
            case VgEffectKind.shaderMask:
              canvas.saveLayer(e.bounds, ui.Paint());
              endActions.add(() {
                var mask = e.maskRect!;
                // The shader was built for a rect at the origin; the engine
                // evaluates it relative to maskRect's corner.
                canvas.save();
                canvas.translate(mask.left, mask.top);
                canvas.drawRect(
                  Offset.zero & mask.size,
                  ui.Paint()
                    ..shader = e.shader
                    ..blendMode = e.blendMode ?? ui.BlendMode.modulate,
                );
                canvas.restore();
                canvas.restore();
              });
            case VgEffectKind.backdropFilter:
              // Its input is everything painted before it — not
              // reproducible here. The child paints plain.
              endActions.add(() {});
            case VgEffectKind.layer:
              canvas.saveLayer(
                e.bounds,
                _layerPaint(e.opacity, e.blendMode ?? ui.BlendMode.srcOver),
              );
              endActions.add(canvas.restore);
          }
        case VgEndEffect():
          if (endActions.isNotEmpty) endActions.removeLast()();
      }
    }
  }

  Future<void> encodeImages() async {
    for (var entry in images.entries) {
      var png = await entry.value.toByteData(format: ui.ImageByteFormat.png);
      imagePngs[entry.key] = png!.buffer.asUint8List();
      var raw = await entry.value.toByteData(
        format: ui.ImageByteFormat.rawRgba,
      );
      imageRgba[entry.key] = raw!.buffer.asUint8List();
    }
  }

  /// Everything this capture knows it does not carry exactly, phrased for
  /// the result's warnings channel. Call after [rasterizeUnsupported] so
  /// effect warnings can tell a patch from a drop.
  List<RenderWarning> collectWarnings(CaptureOptions options) {
    var warnings = <RenderWarning>[];
    var fate = switch (options.unsupported) {
      UnsupportedPolicy.rasterize => 'rasterized',
      UnsupportedPolicy.flatten => 'flattened to a stand-in',
      UnsupportedPolicy.skip => 'left out',
    };
    for (var name in unhandled) {
      warnings.add(
        RenderWarning(
          RenderWarningKind.unhandledOp,
          'canvas op $name is not captured; its output is missing',
        ),
      );
    }
    for (var layer in unreplayableLayers) {
      warnings.add(
        RenderWarning(
          RenderWarningKind.unreplayableLayer,
          '$layer cannot be replayed (texture or platform view); '
          'its content is missing',
        ),
      );
    }
    var unrecovered = ops.whereType<VgDrawUnknownParagraph>().length;
    if (unrecovered > 0) {
      warnings.add(
        RenderWarning(
          RenderWarningKind.unrecoveredText,
          '$unrecovered paragraph(s) drawn by a painter could not be '
          'recovered as text; $fate',
        ),
      );
    }
    var shaders = 0;
    for (var op in ops) {
      if (drawPaintOf(op)?.hadUnresolvedShader ?? false) shaders++;
    }
    if (shaders > 0) {
      warnings.add(
        RenderWarning(
          RenderWarningKind.unresolvedShader,
          '$shaders paint(s) carried a shader the capture could not see '
          'through; $fate',
        ),
      );
    }
    var rasterize = options.unsupported == UnsupportedPolicy.rasterize;

    // An effect span nested inside a span that became one raster patch was
    // replayed as part of that patch — it just never got a rasterId of its
    // own, because the outer patch is the one [rasterizeUnsupported] walked.
    // Left uncounted here, for every effect kind, so it is neither warned as
    // dropped nor double-counted as its own rasterized patch.
    var nestedInPatch = <VgBeginEffect>{};
    var openEffects = <VgBeginEffect>[];
    for (var op in ops) {
      if (op is VgBeginEffect) {
        if (openEffects.any((e) => e.rasterId != null)) {
          nestedInPatch.add(op);
        }
        openEffects.add(op);
      } else if (op is VgEndEffect) {
        openEffects.removeLast();
      }
    }

    var layers = [
      for (var op in ops)
        if (op is VgBeginEffect &&
            op.kind == VgEffectKind.layer &&
            !nestedInPatch.contains(op))
          op,
    ];
    var patched = [
      for (var layer in layers)
        if (layer.rasterId != null && rasterize) layer,
    ];
    if (patched.isNotEmpty) {
      warnings.add(
        RenderWarning(
          RenderWarningKind.effectRasterized,
          '${patched.length} layer(s) with a blend or a mask were replayed '
          'as raster patches',
        ),
      );
    }
    if (patched.length < layers.length) {
      warnings.add(
        RenderWarning(
          RenderWarningKind.effectDropped,
          '${layers.length - patched.length} layer(s) with a blend or a mask '
          'could not be expressed; $fate',
        ),
      );
    }
    var nameless = [
      for (var layer in patched)
        if (layer.blendMode case var mode?
            when mode != ui.BlendMode.srcOver &&
                !documentBlendModes.containsKey(mode))
          mode.name,
    ];
    if (nameless.isNotEmpty) {
      warnings.add(
        RenderWarning(
          RenderWarningKind.effectDropped,
          '${nameless.length} raster patch(es) blend with '
          '${nameless.toSet().join(', ')}, which neither SVG nor PDF can '
          'express; placed without the blend',
        ),
      );
    }
    if (unboundedLayers.isNotEmpty) {
      warnings.add(
        RenderWarning(
          RenderWarningKind.effectDropped,
          '${unboundedLayers.length} layer(s) with a blend or a mask gave no '
          'bounds and had no box to take them from; exported op by op, '
          'without the blend',
        ),
      );
    }
    for (var op in ops.whereType<VgBeginEffect>()) {
      if (op.kind == VgEffectKind.layer) continue;
      if (nestedInPatch.contains(op)) continue;
      if (op.kind == VgEffectKind.backdropFilter) {
        warnings.add(
          RenderWarning(
            RenderWarningKind.effectDropped,
            'a backdrop filter cannot be reproduced outside the engine; '
            'its child is drawn without the effect'
            '${options.unsupported == UnsupportedPolicy.skip ? ' (left out entirely under skip)' : ''}',
          ),
        );
      } else if (op.rasterId != null &&
          options.unsupported == UnsupportedPolicy.rasterize) {
        warnings.add(
          RenderWarning(
            RenderWarningKind.effectRasterized,
            'a ${op.kind.name} effect was replayed as a raster patch',
          ),
        );
      } else {
        warnings.add(
          RenderWarning(
            RenderWarningKind.effectDropped,
            'a ${op.kind.name} effect could not be expressed; $fate',
          ),
        );
      }
    }
    return warnings;
  }
}

sealed class VgOp {}

class VgSave extends VgOp {}

class VgSaveLayer extends VgOp {
  VgSaveLayer(
    this.opacity, {
    this.bounds,
    this.blendMode = ui.BlendMode.srcOver,
  });
  final double opacity;
  final Rect? bounds;

  /// How the layer composites onto what is beneath it. Anything but
  /// [ui.BlendMode.srcOver] turns the layer into a [VgEffectKind.layer]
  /// span when it closes, so a layer that reaches a writer as a
  /// [VgSaveLayer] is, bar a warning, only an opacity.
  final ui.BlendMode blendMode;
}

class VgRestore extends VgOp {}

class VgTransform extends VgOp {
  VgTransform(this.matrix);
  final Float64List matrix;
}

class VgClipRect extends VgOp {
  VgClipRect(this.rect);
  final Rect rect;
}

class VgClipRRect extends VgOp {
  VgClipRRect(this.rrect);
  final RRect rrect;
}

class VgClipPath extends VgOp {
  VgClipPath(this.path, {this.source});
  final VgPathData path;
  final ui.Path? source;
}

enum VgEffectKind {
  backdropFilter,
  imageFilter,
  colorFilter,
  shaderMask,

  /// A `saveLayer` that blends onto what is beneath it, or holds a draw
  /// that blends with what the layer already has — a glyph mask a
  /// gradient is drawn `srcIn` over. Neither survives being written op by
  /// op, so the span becomes one patch, and the writer composites the
  /// patch with the layer's own blend.
  layer,
}

/// Opens a layer effect the paint stream itself cannot carry. The ops until
/// the matching [VgEndEffect] are the child's; what happens to the pair is
/// [CaptureOptions.unsupported]'s call — most effects can replay their whole
/// span into a raster patch, a backdrop filter cannot (its input is
/// everything painted before it).
class VgBeginEffect extends VgOp {
  VgBeginEffect(
    this.kind,
    this.bounds, {
    this.imageFilter,
    this.colorFilter,
    this.shader,
    this.maskRect,
    this.blendMode,
    this.opacity = 1,
  });

  final VgEffectKind kind;

  /// The effect's coverage, in the frame the surrounding ops draw in.
  final Rect bounds;
  final ui.ImageFilter? imageFilter;
  final ui.ColorFilter? colorFilter;
  final ui.Shader? shader;
  final Rect? maskRect;

  /// How a shader mask's shader meets its child; how a [VgEffectKind.layer]
  /// composites onto what is beneath it.
  final ui.BlendMode? blendMode;

  /// A [VgEffectKind.layer]'s own opacity, baked into its patch.
  final double opacity;
  int? rasterId;

  /// The blend a writer places this span's patch with: a layer's own, when
  /// a document can name it.
  ui.BlendMode? get documentBlend =>
      kind == VgEffectKind.layer && documentBlendModes.containsKey(blendMode)
      ? blendMode
      : null;

  bool get reproducible =>
      kind != VgEffectKind.backdropFilter && bounds.isFinite && !bounds.isEmpty;

  /// A filter's output bleeds past its child (a blur most of all); the
  /// patch takes a margin since the filter itself is opaque about its reach.
  Rect get patchBounds =>
      kind == VgEffectKind.imageFilter ? bounds.inflate(20) : bounds;
}

class VgEndEffect extends VgOp {}

class VgDrawRect extends VgOp {
  VgDrawRect(this.rect, this.paint);
  final Rect rect;
  final VgPaint paint;
  int? rasterId;
}

class VgDrawRRect extends VgOp {
  VgDrawRRect(this.rrect, this.paint);
  final RRect rrect;
  final VgPaint paint;
  int? rasterId;
}

class VgDrawDRRect extends VgOp {
  VgDrawDRRect(this.outer, this.inner, this.paint);
  final RRect outer;
  final RRect inner;
  final VgPaint paint;
}

class VgDrawCircle extends VgOp {
  VgDrawCircle(this.center, this.radius, this.paint);
  final Offset center;
  final double radius;
  final VgPaint paint;
  int? rasterId;
}

class VgDrawOval extends VgOp {
  VgDrawOval(this.rect, this.paint);
  final Rect rect;
  final VgPaint paint;
  int? rasterId;
}

class VgDrawLine extends VgOp {
  VgDrawLine(this.a, this.b, this.paint);
  final Offset a;
  final Offset b;
  final VgPaint paint;
}

class VgDrawPath extends VgOp {
  VgDrawPath(this.path, this.paint, {this.source});
  final VgPathData path;
  final VgPaint paint;
  final ui.Path? source;
  int? rasterId;
}

class VgDrawShadow extends VgOp {
  VgDrawShadow(this.path, this.color, this.elevation, this.source);
  final VgPathData path;
  final Color color;
  final double elevation;
  final ui.Path source;
  int? rasterId;
}

class VgDrawImageRect extends VgOp {
  VgDrawImageRect(this.imageId, this.src, this.dst);
  final int imageId;
  final Rect src;
  final Rect dst;
}

/// A paragraph whose content could be recovered from the render tree:
/// positioned styled runs, one per (line × style run) cell. The live
/// [ui.Paragraph] rides along so the raster lane can replay it.
class VgDrawText extends VgOp {
  VgDrawText(this.runs, {this.paragraph, this.paragraphOffset});
  final List<TextRun> runs;
  final ui.Paragraph? paragraph;
  final Offset? paragraphOffset;
}

/// A paragraph whose owner we could not read text out of; the live
/// [ui.Paragraph] is kept so the raster lane can still draw it.
class VgDrawUnknownParagraph extends VgOp {
  VgDrawUnknownParagraph(this.bounds, this.paragraph);
  final Rect bounds;
  final ui.Paragraph paragraph;
  int? rasterId;
}

class TextRun {
  TextRun({
    required this.text,
    required this.x,
    required this.baseline,
    required this.fontFamily,
    required this.fontSize,
    required this.fontWeight,
    required this.fontStyle,
    required this.color,
    this.letterSpacing,
    this.clusters,
  });

  final String text;
  final double x;
  final double baseline;
  final String? fontFamily;
  final double fontSize;
  final FontWeight fontWeight;
  final FontStyle fontStyle;
  final Color color;
  final double? letterSpacing;

  /// Per-character positions from the laid-out paragraph, for writers that
  /// place each glyph themselves instead of emitting the run as a string.
  final List<TextCluster>? clusters;
}

class TextCluster {
  TextCluster(this.text, this.x);
  final String text;
  final double x;
}

class VgPaint {
  VgPaint({
    required this.color,
    required this.style,
    required this.strokeWidth,
    required this.strokeCap,
    required this.strokeJoin,
    this.gradient,
    this.hadUnresolvedShader = false,
    this.source,
    this.blendMode = ui.BlendMode.srcOver,
  });

  factory VgPaint.from(ui.Paint paint, {VgLinearGradient? gradient}) {
    return VgPaint(
      color: paint.color,
      style: paint.style,
      strokeWidth: paint.strokeWidth,
      strokeCap: paint.strokeCap,
      strokeJoin: paint.strokeJoin,
      gradient: gradient,
      hadUnresolvedShader: paint.shader != null && gradient == null,
      blendMode: paint.blendMode,
      // Snapshot the live paint (shader included) so the raster lane can
      // replay this op faithfully.
      source: ui.Paint.from(paint),
    );
  }

  final Color color;
  final PaintingStyle style;
  final double strokeWidth;
  final StrokeCap strokeCap;
  final StrokeJoin strokeJoin;
  final VgLinearGradient? gradient;

  /// The paint carried a [ui.Shader] the capture could not see through; what
  /// happens then is [CaptureOptions.unsupported]'s call.
  final bool hadUnresolvedShader;
  final ui.Paint? source;

  /// How the draw composites onto what is already there. The writers draw
  /// every op source-over; a draw that does not is only faithful inside a
  /// [VgEffectKind.layer] patch, which is what the capture makes of the
  /// layer around it.
  final ui.BlendMode blendMode;

  bool get needsRaster => hadUnresolvedShader && source != null;

  /// The snapshot when there is one, a rebuild from the lifted values when
  /// not — replay always has a paint to draw with.
  ui.Paint get livePaint =>
      source ??
      (ui.Paint()
        ..color = color
        ..style = style
        ..strokeWidth = strokeWidth
        ..strokeCap = strokeCap
        ..strokeJoin = strokeJoin
        ..blendMode = blendMode);
}

/// The paint a draw op carries, or null for an op that is not a draw with
/// one.
VgPaint? drawPaintOf(VgOp op) => switch (op) {
  VgDrawRect(:var paint) ||
  VgDrawRRect(:var paint) ||
  VgDrawDRRect(:var paint) ||
  VgDrawCircle(:var paint) ||
  VgDrawOval(:var paint) ||
  VgDrawLine(:var paint) ||
  VgDrawPath(:var paint) => paint,
  _ => null,
};

/// Flutter's blend modes that SVG (CSS `mix-blend-mode`) and PDF (`/BM`)
/// both name, with the CSS spelling; PDF's is Flutter's own name. The rest
/// — the Porter-Duff operators, `plus`, `modulate` — have no counterpart in
/// either document.
const documentBlendModes = <ui.BlendMode, String>{
  ui.BlendMode.multiply: 'multiply',
  ui.BlendMode.screen: 'screen',
  ui.BlendMode.overlay: 'overlay',
  ui.BlendMode.darken: 'darken',
  ui.BlendMode.lighten: 'lighten',
  ui.BlendMode.colorDodge: 'color-dodge',
  ui.BlendMode.colorBurn: 'color-burn',
  ui.BlendMode.hardLight: 'hard-light',
  ui.BlendMode.softLight: 'soft-light',
  ui.BlendMode.difference: 'difference',
  ui.BlendMode.exclusion: 'exclusion',
  ui.BlendMode.hue: 'hue',
  ui.BlendMode.saturation: 'saturation',
  ui.BlendMode.color: 'color',
  ui.BlendMode.luminosity: 'luminosity',
};

ui.Paint _layerPaint(
  double opacity, [
  ui.BlendMode blendMode = ui.BlendMode.srcOver,
]) => ui.Paint()
  ..color = ui.Color.from(alpha: opacity, red: 0, green: 0, blue: 0)
  ..blendMode = blendMode;

class VgLinearGradient {
  VgLinearGradient(this.from, this.to, this.colors, this.stops);
  final Offset from;
  final Offset to;
  final List<Color> colors;
  final List<double>? stops;
}

/// A [ui.Path] flattened to polyline contours.
///
/// dart:ui exposes no way to iterate a path's verbs, so the capture samples
/// each contour through [ui.PathMetrics]. Curves become dense polylines: the
/// output stays vector but loses the analytic curve.
class VgPathData {
  VgPathData(this.contours, this.evenOdd);

  factory VgPathData.fromPath(ui.Path path) {
    var contours = <VgContour>[];
    for (var metric in path.computeMetrics()) {
      var length = metric.length;
      if (length == 0) continue;
      var steps = (length / 1.5).ceil().clamp(8, 512);
      var points = <Offset>[];
      for (var i = 0; i <= steps; i++) {
        var tangent = metric.getTangentForOffset(length * i / steps);
        if (tangent != null) points.add(tangent.position);
      }
      contours.add(VgContour(points, metric.isClosed));
    }
    return VgPathData(contours, path.fillType == PathFillType.evenOdd);
  }

  final List<VgContour> contours;
  final bool evenOdd;
}

class VgContour {
  VgContour(this.points, this.closed);
  final List<Offset> points;
  final bool closed;
}
