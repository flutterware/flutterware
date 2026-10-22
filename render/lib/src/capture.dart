import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';

import 'model.dart';
import 'text_extract.dart';

/// Replays [root]'s paint pass into a [VgRecording] instead of the engine.
///
/// Nothing composites: every layer the tree would push is inlined into one
/// command stream, and the context keeps a stack of the render objects being
/// painted so canvas calls can be joined back to the semantics that produced
/// them (text content from [RenderParagraph] and [RenderEditable], gradients
/// from [RenderDecoratedBox]). Layer effects the stream cannot carry —
/// backdrop filters, image filters, color filters, shader masks, a
/// `saveLayer` that blends — become [VgBeginEffect]..[VgEndEffect] spans
/// for the unsupported-op policy to decide over, instead of silently
/// vanishing.
VgRecording captureVector(RenderObject root) {
  var recording = VgRecording();
  var context = CapturePaintingContext(recording);
  context.paintChild(root, Offset.zero);
  return recording;
}

class CapturePaintingContext extends ClipContext implements PaintingContext {
  CapturePaintingContext(this.recording) {
    canvas = _canvas = _RecordingCanvas(recording, this);
  }

  final VgRecording recording;

  @override
  late final ui.Canvas canvas;
  late final _RecordingCanvas _canvas;

  final renderObjectStack = <RenderObject>[];

  /// Where each object on [renderObjectStack] was told to paint, and the
  /// canvas transform at the time — what it takes to find its box again
  /// from inside a painter that has since moved the canvas.
  final _paintFrames = <({Offset offset, Matrix4 transform})>[];

  @override
  void paintChild(RenderObject child, Offset offset) {
    renderObjectStack.add(child);
    _paintFrames.add((offset: offset, transform: _canvas._matrix.clone()));
    // A repaint boundary may carry its effect on the composited layer
    // instead of the paint stream — RenderOpacity holds its alpha there and
    // paints the child at full opacity.
    double? layerOpacity;
    if (child.isRepaintBoundary) {
      var layer = child.updateCompositedLayer(oldLayer: null);
      if (layer is OpacityLayer) layerOpacity = (layer.alpha ?? 255) / 255;
      layer.dispose();
    }
    if (layerOpacity != null && layerOpacity < 1) {
      recording.ops.add(VgSaveLayer(layerOpacity));
      child.paint(this, offset);
      recording.ops.add(VgRestore());
    } else {
      child.paint(this, offset);
    }
    _paintFrames.removeLast();
    renderObjectStack.removeLast();
  }

  @override
  ClipRectLayer? pushClipRect(
    bool needsCompositing,
    Offset offset,
    Rect clipRect,
    PaintingContextCallback painter, {
    Clip clipBehavior = Clip.hardEdge,
    ClipRectLayer? oldLayer,
  }) {
    clipRectAndPaint(
      clipRect.shift(offset),
      clipBehavior,
      clipRect.shift(offset),
      () => painter(this, offset),
    );
    return null;
  }

  @override
  ClipRRectLayer? pushClipRRect(
    bool needsCompositing,
    Offset offset,
    Rect bounds,
    RRect clipRRect,
    PaintingContextCallback painter, {
    Clip clipBehavior = Clip.antiAlias,
    ClipRRectLayer? oldLayer,
  }) {
    clipRRectAndPaint(
      clipRRect.shift(offset),
      clipBehavior,
      bounds.shift(offset),
      () => painter(this, offset),
    );
    return null;
  }

  @override
  ClipPathLayer? pushClipPath(
    bool needsCompositing,
    Offset offset,
    Rect bounds,
    Path clipPath,
    PaintingContextCallback painter, {
    Clip clipBehavior = Clip.antiAlias,
    ClipPathLayer? oldLayer,
  }) {
    clipPathAndPaint(
      clipPath.shift(offset),
      clipBehavior,
      bounds.shift(offset),
      () => painter(this, offset),
    );
    return null;
  }

  @override
  TransformLayer? pushTransform(
    bool needsCompositing,
    Offset offset,
    Matrix4 transform,
    PaintingContextCallback painter, {
    TransformLayer? oldLayer,
  }) {
    // The transform applies around the paint offset, same as the real
    // PaintingContext.pushTransform.
    var effective = Matrix4.translationValues(offset.dx, offset.dy, 0)
      ..multiply(transform)
      ..translateByDouble(-offset.dx, -offset.dy, 0, 1);
    canvas.save();
    canvas.transform(effective.storage);
    painter(this, offset);
    canvas.restore();
    return null;
  }

  @override
  OpacityLayer pushOpacity(
    Offset offset,
    int alpha,
    PaintingContextCallback painter, {
    OpacityLayer? oldLayer,
  }) {
    recording.ops.add(VgSaveLayer(alpha / 255));
    painter(this, offset);
    recording.ops.add(VgRestore());
    return OpacityLayer();
  }

  @override
  ColorFilterLayer pushColorFilter(
    Offset offset,
    ColorFilter colorFilter,
    PaintingContextCallback painter, {
    ColorFilterLayer? oldLayer,
  }) {
    _pushEffect(
      VgBeginEffect(
        VgEffectKind.colorFilter,
        _effectBounds(offset, null),
        colorFilter: colorFilter,
      ),
      painter,
      offset,
    );
    return ColorFilterLayer();
  }

  @override
  void pushLayer(
    Layer childLayer,
    PaintingContextCallback painter,
    Offset offset, {
    Rect? childPaintBounds,
  }) {
    switch (childLayer) {
      case OpacityLayer layer:
        recording.ops.add(VgSaveLayer((layer.alpha ?? 255) / 255));
        painter(this, offset);
        recording.ops.add(VgRestore());
      case BackdropFilterLayer():
        _pushEffect(
          VgBeginEffect(
            VgEffectKind.backdropFilter,
            _effectBounds(offset, childPaintBounds),
          ),
          painter,
          offset,
        );
      case ImageFilterLayer layer:
        _pushEffect(
          VgBeginEffect(
            VgEffectKind.imageFilter,
            _effectBounds(offset, childPaintBounds),
            imageFilter: layer.imageFilter,
          ),
          painter,
          offset,
        );
      case ColorFilterLayer layer:
        _pushEffect(
          VgBeginEffect(
            VgEffectKind.colorFilter,
            _effectBounds(offset, childPaintBounds),
            colorFilter: layer.colorFilter,
          ),
          painter,
          offset,
        );
      case ShaderMaskLayer layer:
        _pushEffect(
          VgBeginEffect(
            VgEffectKind.shaderMask,
            _effectBounds(offset, childPaintBounds),
            shader: layer.shader,
            maskRect: layer.maskRect,
            blendMode: layer.blendMode,
          ),
          painter,
          offset,
        );
      default:
        // Container/offset layers carry no effect of their own.
        painter(this, offset);
    }
  }

  void _pushEffect(
    VgBeginEffect begin,
    PaintingContextCallback painter,
    Offset offset,
  ) {
    recording.ops.add(begin);
    painter(this, offset);
    recording.ops.add(VgEndEffect());
  }

  /// The effect's coverage in the current canvas frame: the render object
  /// pushing the layer knows its own size.
  Rect _effectBounds(Offset offset, Rect? childPaintBounds) {
    var ro = renderObjectStack.isEmpty ? null : renderObjectStack.last;
    if (ro is RenderBox && ro.hasSize) return offset & ro.size;
    return childPaintBounds ?? Rect.zero;
  }

  /// The same estimate for a `saveLayer` given no bounds: the painting
  /// object's box, carried into the canvas frame the layer opens in — a
  /// custom painter, say, draws after translating to its offset.
  Rect? _layerBounds(Matrix4 canvasTransform) {
    var ro = renderObjectStack.isEmpty ? null : renderObjectStack.last;
    if (ro is! RenderBox || !ro.hasSize) return null;
    var toCanvas = Matrix4.tryInvert(canvasTransform);
    if (toCanvas == null) return null;
    var frame = _paintFrames.last;
    toCanvas.multiply(frame.transform);
    return MatrixUtils.transformRect(toCanvas, frame.offset & ro.size);
  }

  @override
  void addLayer(Layer layer) {
    // A leaf layer arrives whole (texture, platform view, performance
    // overlay): there is no paint pass to capture behind it.
    recording.unreplayableLayers.add(layer.runtimeType.toString());
  }

  @override
  VoidCallback addCompositionCallback(CompositionCallback callback) => () {};

  @override
  dynamic noSuchMethod(Invocation invocation) => null;

  /// The semantic joins: canvas calls ask the render object being painted.
  VgLinearGradient? resolveGradient(ui.Paint paint, Rect bounds) {
    if (paint.shader == null) return null;
    for (var ro in renderObjectStack.reversed) {
      if (ro is RenderDecoratedBox) {
        var decoration = ro.decoration;
        if (decoration is BoxDecoration &&
            decoration.gradient is LinearGradient) {
          var gradient = decoration.gradient! as LinearGradient;
          var begin = gradient.begin.resolve(TextDirection.ltr);
          var end = gradient.end.resolve(TextDirection.ltr);
          return VgLinearGradient(
            begin.withinRect(bounds),
            end.withinRect(bounds),
            gradient.colors,
            gradient.stops,
          );
        }
      }
    }
    return null;
  }

  VgOp resolveParagraph(ui.Paragraph paragraph, Offset offset) {
    for (var ro in renderObjectStack.reversed) {
      var span = switch (ro) {
        RenderParagraph p => p.text,
        RenderEditable e => e.text,
        _ => null,
      };
      if (span != null) {
        return VgDrawText(
          extractTextRuns(paragraph, span, offset),
          paragraph: paragraph,
          paragraphOffset: offset,
        );
      }
    }
    // A paragraph laid out without a max width reports width = Infinity;
    // the ink is bounded by its longest line.
    var width = paragraph.width.isFinite
        ? paragraph.width
        : paragraph.longestLine;
    return VgDrawUnknownParagraph(
      Rect.fromLTWH(offset.dx, offset.dy, width, paragraph.height),
      paragraph,
    );
  }
}

class _RecordingCanvas implements ui.Canvas {
  _RecordingCanvas(this.recording, this.context);

  final VgRecording recording;
  final CapturePaintingContext context;
  var _saveCount = 1;

  /// The current transform, from the recording's frame to the one the
  /// next op draws in, and one saved per open save.
  var _matrix = Matrix4.identity();
  final _savedTransforms = <Matrix4>[];

  /// The layers still open: where each one's [VgSaveLayer] sits, the save
  /// count it opened at, and the bounds to fall back on if it gave none.
  final _openLayers = <({int index, int saveCount, Rect? fallback})>[];

  List<VgOp> get _ops => recording.ops;

  VgPaint _paint(ui.Paint paint, Rect bounds) {
    return VgPaint.from(
      paint,
      gradient: context.resolveGradient(paint, bounds),
    );
  }

  @override
  void save() {
    _saveCount++;
    _savedTransforms.add(_matrix.clone());
    _ops.add(VgSave());
  }

  @override
  void saveLayer(Rect? bounds, ui.Paint paint) {
    _saveCount++;
    _savedTransforms.add(_matrix.clone());
    _openLayers.add((
      index: _ops.length,
      saveCount: _saveCount,
      fallback: bounds == null ? context._layerBounds(_matrix) : null,
    ));
    _ops.add(
      VgSaveLayer(paint.color.a, bounds: bounds, blendMode: paint.blendMode),
    );
  }

  @override
  void restore() {
    if (_saveCount <= 1) return;
    var closesLayer =
        _openLayers.isNotEmpty && _openLayers.last.saveCount == _saveCount;
    _saveCount--;
    _matrix = _savedTransforms.removeLast();
    if (closesLayer && _closeAsPatch(_openLayers.removeLast())) return;
    _ops.add(VgRestore());
  }

  /// A layer that blends onto what is beneath it, or holds a draw that
  /// blends into the layer, becomes one [VgEffectKind.layer] span: written
  /// op by op, every draw would land source-over on the page instead. A
  /// stock `Text(overflow: TextOverflow.fade)` that overflows draws exactly
  /// this — a saveLayer with a modulate rect blended inside it — so such a
  /// paragraph now exports as a raster patch instead of vector text (it used
  /// to export as vector text with an opaque gradient rect laid over it);
  /// that trade is deliberate, not a regression to chase.
  bool _closeAsPatch(({int index, int saveCount, Rect? fallback}) open) {
    var layer = _ops[open.index] as VgSaveLayer;
    if (layer.blendMode == ui.BlendMode.srcOver &&
        !_ops.skip(open.index + 1).any(_blends)) {
      return false;
    }
    var bounds = layer.bounds ?? open.fallback;
    if (bounds == null) {
      recording.unboundedLayers.add(layer);
      return false;
    }
    recording.unboundedLayers.removeAll(
      _ops.skip(open.index + 1).whereType<VgSaveLayer>(),
    );
    _ops[open.index] = VgBeginEffect(
      VgEffectKind.layer,
      bounds,
      blendMode: layer.blendMode,
      opacity: layer.opacity,
    );
    _ops.add(VgEndEffect());
    return true;
  }

  static bool _blends(VgOp op) {
    var mode = switch (op) {
      VgSaveLayer(:var blendMode) => blendMode,
      VgBeginEffect(kind: VgEffectKind.layer, :var blendMode) => blendMode,
      _ => drawPaintOf(op)?.blendMode,
    };
    return mode != null && mode != ui.BlendMode.srcOver;
  }

  @override
  int getSaveCount() => _saveCount;

  @override
  void restoreToCount(int count) {
    while (_saveCount > count) {
      restore();
    }
  }

  void _concat(Matrix4 matrix) {
    _matrix.multiply(matrix);
    _ops.add(VgTransform(matrix.storage));
  }

  @override
  void translate(double dx, double dy) {
    _concat(Matrix4.translationValues(dx, dy, 0));
  }

  @override
  void scale(double sx, [double? sy]) {
    _concat(Matrix4.diagonal3Values(sx, sy ?? sx, 1));
  }

  @override
  void rotate(double radians) {
    _concat(Matrix4.rotationZ(radians));
  }

  @override
  void skew(double sx, double sy) {
    var m = Matrix4.identity();
    m.setEntry(0, 1, sx);
    m.setEntry(1, 0, sy);
    _concat(m);
  }

  @override
  void transform(Float64List matrix4) {
    _concat(Matrix4.fromFloat64List(Float64List.fromList(matrix4)));
  }

  @override
  void clipRect(
    Rect rect, {
    ui.ClipOp clipOp = ui.ClipOp.intersect,
    bool doAntiAlias = true,
  }) {
    _ops.add(VgClipRect(rect));
  }

  @override
  void clipRRect(RRect rrect, {bool doAntiAlias = true}) {
    _ops.add(VgClipRRect(rrect));
  }

  @override
  void clipPath(ui.Path path, {bool doAntiAlias = true}) {
    _ops.add(VgClipPath(VgPathData.fromPath(path), source: ui.Path.from(path)));
  }

  @override
  void drawRect(Rect rect, ui.Paint paint) {
    _ops.add(VgDrawRect(rect, _paint(paint, rect)));
  }

  @override
  void drawRRect(RRect rrect, ui.Paint paint) {
    _ops.add(VgDrawRRect(rrect, _paint(paint, rrect.outerRect)));
  }

  @override
  void drawDRRect(RRect outer, RRect inner, ui.Paint paint) {
    _ops.add(VgDrawDRRect(outer, inner, _paint(paint, outer.outerRect)));
  }

  @override
  void drawCircle(Offset c, double radius, ui.Paint paint) {
    _ops.add(
      VgDrawCircle(
        c,
        radius,
        _paint(paint, Rect.fromCircle(center: c, radius: radius)),
      ),
    );
  }

  @override
  void drawOval(Rect rect, ui.Paint paint) {
    _ops.add(VgDrawOval(rect, _paint(paint, rect)));
  }

  @override
  void drawArc(
    Rect rect,
    double startAngle,
    double sweepAngle,
    bool useCenter,
    ui.Paint paint,
  ) {
    // An arc is a path with better publicity; the path lane keeps the
    // stroke's cap and the live paint for the raster fallback.
    var path = ui.Path();
    if (useCenter) {
      path.moveTo(rect.center.dx, rect.center.dy);
      path.arcTo(rect, startAngle, sweepAngle, false);
      path.close();
    } else {
      path.addArc(rect, startAngle, sweepAngle);
    }
    drawPath(path, paint);
  }

  @override
  void drawLine(Offset p1, Offset p2, ui.Paint paint) {
    _ops.add(VgDrawLine(p1, p2, _paint(paint, Rect.fromPoints(p1, p2))));
  }

  @override
  void drawPath(ui.Path path, ui.Paint paint) {
    _ops.add(
      VgDrawPath(
        VgPathData.fromPath(path),
        _paint(paint, path.getBounds()),
        source: ui.Path.from(path),
      ),
    );
  }

  @override
  void drawShadow(
    ui.Path path,
    Color color,
    double elevation,
    bool transparentOccluder,
  ) {
    _ops.add(
      VgDrawShadow(
        VgPathData.fromPath(path),
        color,
        elevation,
        ui.Path.from(path),
      ),
    );
  }

  @override
  void drawPaint(ui.Paint paint) {
    _ops.add(VgDrawRect(Rect.largest, _paint(paint, Rect.largest)));
  }

  @override
  void drawColor(Color color, ui.BlendMode blendMode) {
    _ops.add(
      VgDrawRect(
        Rect.largest,
        VgPaint(
          color: color,
          style: PaintingStyle.fill,
          strokeWidth: 0,
          strokeCap: StrokeCap.butt,
          strokeJoin: StrokeJoin.miter,
          blendMode: blendMode,
        ),
      ),
    );
  }

  @override
  void drawParagraph(ui.Paragraph paragraph, Offset offset) {
    _ops.add(context.resolveParagraph(paragraph, offset));
  }

  @override
  void drawImage(ui.Image image, Offset offset, ui.Paint paint) {
    drawImageRect(
      image,
      Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()),
      Rect.fromLTWH(
        offset.dx,
        offset.dy,
        image.width.toDouble(),
        image.height.toDouble(),
      ),
      paint,
    );
  }

  @override
  void drawImageRect(ui.Image image, Rect src, Rect dst, ui.Paint paint) {
    var id = identityHashCode(image);
    recording.images[id] = image;
    _ops.add(VgDrawImageRect(id, src, dst));
  }

  @override
  dynamic noSuchMethod(Invocation invocation) {
    var name = invocation.memberName.toString();
    recording.unhandled.add(name);
    return null;
  }
}
