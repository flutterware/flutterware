/// The shared contract between a Flutter app's render points and the pure
/// Dart side that invokes them.
///
/// A render point is a value — a name, codecs for its args, and the args
/// type pinned in the type argument — declared once in a package both the
/// app and the server import. No code generation: the descriptor is the
/// contract. The app binds implementations against it (see
/// `package:flutterware/render.dart`); the server hands it back with typed
/// args and gets a typed result.
library;

import 'dart:typed_data';

/// A named entry the render guest can produce, with its args type pinned.
///
/// Names are slash-pathed (`charts/monthly`) and unique per registry.
sealed class RenderPoint<A> {
  RenderPoint(this.name, {required this.encodeArgs, required this.decodeArgs})
    : assert(name.isNotEmpty);

  final String name;
  final Map<String, Object?> Function(A args) encodeArgs;
  final A Function(Map<String, Object?> json) decodeArgs;
}

/// A render point that builds a widget; the caller chooses the output —
/// SVG, PNG, or a single-page PDF — and the options.
final class WidgetRender<A> extends RenderPoint<A> {
  WidgetRender(
    super.name, {
    required super.encodeArgs,
    required super.decodeArgs,
  });
}

/// A render point that composes a whole PDF document itself — multi-page,
/// flowing text, captured widget blocks dropped in as SVG.
final class DocumentRender<A> extends RenderPoint<A> {
  DocumentRender(
    super.name, {
    required super.encodeArgs,
    required super.decodeArgs,
  });
}

/// What to do with a text run.
enum TextPolicy {
  /// Draw each glyph as a path read from the font file.
  vectorize,

  /// Emit real text and embed the font bytes.
  embedFont,

  /// Emit real text naming the family and let the viewer resolve it.
  systemFont,
}

/// What to do with an op the writer cannot express (shadows, unresolvable
/// shaders, layer effects, paragraphs whose text could not be recovered).
enum UnsupportedPolicy {
  /// Replay the op onto a real canvas at capture time and place the raster.
  rasterize,

  /// Cheapest visible stand-in: a solid color, a plain box, the effect's
  /// child without the effect.
  flatten,

  /// Leave it out.
  skip,
}

/// The wire form of the export policies: plain data, serializable, compiled
/// by the guest to its per-run callback form.
class RenderOptions {
  const RenderOptions({
    this.text = TextPolicy.embedFont,
    this.textByFamily = const {},
    this.unsupported = UnsupportedPolicy.rasterize,
    this.rasterScale = 3,
  });

  factory RenderOptions.fromJson(Map<String, Object?> json) {
    return RenderOptions(
      text: _policy(json['text']) ?? TextPolicy.embedFont,
      textByFamily: {
        for (var entry
            in (json['textByFamily'] as Map<String, Object?>? ?? const {})
                .entries)
          entry.key: ?_policy(entry.value),
      },
      unsupported: switch (json['unsupported']) {
        String name => UnsupportedPolicy.values.byName(name),
        _ => UnsupportedPolicy.rasterize,
      },
      rasterScale: (json['rasterScale'] as num?)?.toDouble() ?? 3,
    );
  }

  static TextPolicy? _policy(Object? value) =>
      value is String ? TextPolicy.values.byName(value) : null;

  final TextPolicy text;

  /// Per-family override — the real per-run need is icons vs body text.
  final Map<String, TextPolicy> textByFamily;
  final UnsupportedPolicy unsupported;

  /// Pixel ratio for raster patches placed by [UnsupportedPolicy.rasterize].
  final double rasterScale;

  TextPolicy textFor(String? fontFamily) => textByFamily[fontFamily] ?? text;

  Map<String, Object?> toJson() => {
    'text': text.name,
    if (textByFamily.isNotEmpty)
      'textByFamily': {
        for (var entry in textByFamily.entries) entry.key: entry.value.name,
      },
    'unsupported': unsupported.name,
    'rasterScale': rasterScale,
  };
}

/// A logical size, kept free of any Flutter dependency.
class RenderSize {
  const RenderSize(this.width, this.height);

  factory RenderSize.fromJson(Map<String, Object?> json) => RenderSize(
    (json['width']! as num).toDouble(),
    (json['height']! as num).toDouble(),
  );

  final double width;
  final double height;

  Map<String, Object?> toJson() => {'width': width, 'height': height};

  @override
  String toString() => '${width}x$height';
}

enum RenderWarningKind {
  /// A canvas op the capture does not record; its output is missing.
  unhandledOp,

  /// A leaf layer (texture, platform view) nothing can replay.
  unreplayableLayer,

  /// A paint carried a shader the capture could not see through.
  unresolvedShader,

  /// A paragraph whose text could not be recovered from the render tree.
  unrecoveredText,

  /// A text run no available font could write (PDF only).
  droppedText,

  /// The widget threw while building, laying out or painting; the framework
  /// substituted its error box and the output shows that, not the widget.
  buildError,

  /// A layer effect replayed into a raster patch.
  effectRasterized,

  /// A layer effect that could not be expressed; its child is drawn
  /// without it, or left out under [UnsupportedPolicy.skip].
  effectDropped,
}

/// One honest statement about something the rendered output does not carry
/// exactly as the engine would have drawn it.
class RenderWarning {
  RenderWarning(this.kind, this.message);

  factory RenderWarning.fromJson(Map<String, Object?> json) => RenderWarning(
    RenderWarningKind.values.byName(json['kind']! as String),
    json['message']! as String,
  );

  final RenderWarningKind kind;
  final String message;

  Map<String, Object?> toJson() => {'kind': kind.name, 'message': message};

  @override
  String toString() => message;
}

class SvgResult {
  SvgResult(this.text, this.warnings);

  final String text;
  final List<RenderWarning> warnings;
}

class PngResult {
  PngResult(this.bytes, this.warnings);

  final Uint8List bytes;
  final List<RenderWarning> warnings;
}

class PdfResult {
  PdfResult(this.bytes, this.warnings);

  final Uint8List bytes;
  final List<RenderWarning> warnings;
}
