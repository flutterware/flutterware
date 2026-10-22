import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutterware/render_contract.dart';
import 'package:pdf/widgets.dart' as pw;

import 'model.dart';
import 'render_capture.dart';

/// Marks the one function `fw render bundle` compiles as the guest's
/// registrar:
///
/// ```dart
/// @RenderRegistry()
/// void registerRenders(RenderHost host) {
///   host.widget(monthlyChart, (context, args) => MonthlyChart(args));
/// }
/// ```
///
/// The render points themselves live in a pure-Dart contract package both
/// the app and the server import; the registrar is where the app binds
/// implementations to them.
class RenderRegistry {
  const RenderRegistry();
}

/// What the registrar receives: bind each declared render point to its
/// implementation.
abstract class RenderHost {
  void widget<A>(
    WidgetRender<A> point,
    Widget Function(RenderContext context, A args) builder,
  );

  void document<A>(
    DocumentRender<A> point,
    FutureOr<pw.Document> Function(RenderContext context, A args) builder,
  );
}

/// What a builder runs against: the request's compiled options and fonts,
/// and in-process capture — the seam a document builder uses to drop a
/// widget block into its pw layout as SVG.
class RenderContext {
  RenderContext({CaptureOptions? options, this.fonts = const []})
    : options = options ?? CaptureOptions();

  /// The request's wire options, already compiled to the callback form.
  final CaptureOptions options;
  final List<RenderFont> fonts;

  /// Every warning the captures made through this context produced — so a
  /// document's result can carry the honesty of each block inside it.
  final warnings = <RenderWarning>[];

  Future<SvgResult> captureSvg(
    Widget widget, {
    required Size size,
    CaptureOptions? options,
  }) async {
    var result = await captureWidgetSvg(
      widget,
      size: size,
      fonts: fonts,
      options: options ?? this.options,
    );
    warnings.addAll(result.warnings);
    return result;
  }

  Future<PdfResult> capturePdf(
    Widget widget, {
    required Size size,
    CaptureOptions? options,
  }) async {
    var result = await captureWidgetPdf(
      widget,
      size: size,
      fonts: fonts,
      options: options ?? this.options,
    );
    warnings.addAll(result.warnings);
    return result;
  }

  Future<PngResult> capturePng(
    Widget widget, {
    required Size size,
    double pixelRatio = 3,
  }) => captureWidgetPng(widget, size: size, pixelRatio: pixelRatio);
}

/// The registrar's bindings, collected: what this registry can render.
class RenderBindings implements RenderHost {
  final _byName = <String, BoundRender>{};

  List<BoundRender> get entries => List.unmodifiable(_byName.values);

  BoundRender? operator [](String name) => _byName[name];

  @override
  void widget<A>(
    WidgetRender<A> point,
    Widget Function(RenderContext context, A args) builder,
  ) {
    _add(BoundWidgetRender<A>._(point, builder));
  }

  @override
  void document<A>(
    DocumentRender<A> point,
    FutureOr<pw.Document> Function(RenderContext context, A args) builder,
  ) {
    _add(BoundDocumentRender<A>._(point, builder));
  }

  void _add(BoundRender bound) {
    var name = bound.point.name;
    if (_byName.containsKey(name)) {
      throw StateError('render point "$name" is bound twice');
    }
    _byName[name] = bound;
  }
}

/// One render point tied to its implementation. The args type is erased at
/// this level; the json door re-enters it through the point's own codec.
sealed class BoundRender {
  RenderPoint<dynamic> get point;
}

final class BoundWidgetRender<A> extends BoundRender {
  BoundWidgetRender._(this.point, this.builder);

  @override
  final WidgetRender<A> point;
  final Widget Function(RenderContext context, A args) builder;

  Widget build(RenderContext context, A args) => builder(context, args);

  Widget buildFromJson(RenderContext context, Map<String, Object?> args) =>
      builder(context, point.decodeArgs(args));
}

final class BoundDocumentRender<A> extends BoundRender {
  BoundDocumentRender._(this.point, this.builder);

  @override
  final DocumentRender<A> point;
  final FutureOr<pw.Document> Function(RenderContext context, A args) builder;

  Future<pw.Document> build(RenderContext context, A args) async =>
      await builder(context, args);

  Future<pw.Document> buildFromJson(
    RenderContext context,
    Map<String, Object?> args,
  ) => build(context, point.decodeArgs(args));
}

extension RenderOptionsToCapture on RenderOptions {
  /// Wire data to the in-process callback form: the per-family map becomes
  /// the per-run policy.
  CaptureOptions toCaptureOptions() => CaptureOptions(
    text: (run) => textFor(run.fontFamily),
    unsupported: unsupported,
    rasterScale: rasterScale,
  );
}
