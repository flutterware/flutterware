import 'dart:async';
import 'dart:convert';

import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:lottie/lottie.dart';
import 'package:path/path.dart' as p;

import '../ui/code_block.dart';
import '../ui/design/design.dart';
import '../ui/theme.dart';
import 'model/asset_scan.dart';

/// What sits behind a preview.
///
/// Not decoration: a white logo on a white panel looks like a missing file, and
/// a PNG with a soft alpha edge looks solid on anything opaque. The checker is
/// the default because it is the only one that shows transparency as
/// transparency.
enum PreviewBackground {
  checker('Checker'),
  light('Light'),
  dark('Dark');

  const PreviewBackground(this.label);

  final String label;
}

/// One asset, drawn.
///
/// Takes bytes, not a path. The read is the screen's job, which keeps this
/// widget demoable from a catalog entry with no filesystem behind it — and
/// keeps the three formats that need bytes anyway (`SvgPicture.memory`,
/// `LottieComposition.fromBytes`, `FontLoader`) from being the odd ones out.
///
/// Renders with the *GUI's* decoders, not the project's. For an SVG or a Lottie
/// that is a real difference, and the design doc's D6 records it: the guest
/// renderer is where fidelity comes from, and this is what ships before it.
class AssetPreview extends StatelessWidget {
  const AssetPreview({
    super.key,
    required this.bytes,
    required this.kind,
    required this.name,
    this.background = PreviewBackground.checker,
    this.zoom = 1,
    this.frame,
    this.onFrame,
  });

  final Uint8List bytes;
  final AssetKind kind;

  /// The asset key, used to label the specimen and to name the font family this
  /// preview registers.
  final String name;

  final PreviewBackground background;

  /// A whole-number magnification. Above 1 the image is drawn without
  /// smoothing, because at that point the pixels *are* the subject.
  final double zoom;

  /// The Lottie frame to sit on, or null to let it play.
  final int? frame;
  final ValueChanged<int>? onFrame;

  @override
  Widget build(BuildContext context) {
    return _Backdrop(
      background: background,
      child: Center(child: _content(context)),
    );
  }

  Widget _content(BuildContext context) {
    switch (kind) {
      case AssetKind.image:
        // `scaleDown`, so a large raster fits the pane and a small one is *not*
        // blown up: at 1× the pixels on screen are the pixels in the file, and
        // anything else would be the preview inventing resolution. Zoom is the
        // control for looking closer, and it says by how much.
        return _zoomed(
          Image.memory(
            bytes,
            fit: BoxFit.scaleDown,
            filterQuality: FilterQuality.none,
            errorBuilder: (context, error, stack) {
              _evictFailedDecode(bytes);
              return _Unreadable(message: '$error');
            },
          ),
        );
      case AssetKind.vector:
        // A vector has no resolution to invent, so it fills the pane. A 24px
        // icon shown at 24px in a half-screen panel is technically honest and
        // practically useless.
        return _zoomed(
          SizedBox.expand(
            child: SvgPicture.memory(
              bytes,
              fit: BoxFit.contain,
              errorBuilder: (context, error, stack) =>
                  _Unreadable(message: '$error'),
            ),
          ),
        );
      case AssetKind.font:
        return FontSpecimen(bytes: bytes, family: name);
      case AssetKind.data:
        // A Lottie is a `.json` and there is no way to know *which* `.json`
        // but to parse it, so the parse is the classification — for JSON only.
        // A `.txt` or a `.csv` is not a candidate, and handing one to an
        // animation parser is a wasted isolate and a preview that shows
        // nothing while it finds out.
        if (p.extension(name).toLowerCase() != '.json') {
          return _NoPreview(kind: kind, name: name);
        }
        return LottiePreview(
          bytes: bytes,
          frame: frame,
          onFrame: onFrame,
          fallback: (context) => _JsonSource(bytes: bytes),
        );
      case AssetKind.media:
      case AssetKind.other:
        return _NoPreview(kind: kind, name: name);
    }
  }

  Widget _zoomed(Widget child) =>
      zoom == 1 ? child : _Zoomed(zoom: zoom, child: child);
}

/// Drops a decode that failed from the image cache.
///
/// `MemoryImage` is the one provider that does not do this for itself:
/// `NetworkImage`, `FileImage` and `ResizeImage` each evict their key when the
/// decode reports an error, and nothing else does — the listener the cache
/// registers in `putIfAbsent` carries no `onError`, so a failed decode is
/// simply never taken out of `_pendingImages`. It stays there for the life of
/// the process, and `pendingImageCount` is read by more than the cache:
/// flutterware's own settle and the scenario landing both treat a non-zero
/// count as "work is still in flight" and wait for it. One unreadable asset
/// looked at once would make every later drive step and every later preview
/// pay the full wait — measured at 2.4s each, catalog-wide.
///
/// Out of build in a microtask, which is the same spelling `ResizeImage` uses
/// for its own eviction.
void _evictFailedDecode(Uint8List bytes) {
  scheduleMicrotask(() => MemoryImage(bytes).evict());
}

/// A magnified preview you can drag around.
///
/// Two things `Transform.scale` alone gets wrong, both of which were visible
/// before this existed: it does not clip, so a zoomed 1024px image painted
/// straight over the sidebar and the metadata below it; and it has no origin
/// worth having, so magnifying jumps to a corner instead of growing from what
/// you were looking at.
///
/// `InteractiveViewer` supplies the clip and the panning. The scale comes from
/// the toolbar rather than from a pinch, because zoom is in the address and a
/// gesture that changed it silently would put an unchosen number into a
/// link. `Image`'s own `filterQuality` still governs sampling under this
/// transform, so magnified pixels stay square.
class _Zoomed extends StatefulWidget {
  const _Zoomed({required this.zoom, required this.child});

  final double zoom;
  final Widget child;

  @override
  State<_Zoomed> createState() => _ZoomedState();
}

class _ZoomedState extends State<_Zoomed> {
  final _controller = TransformationController();
  Size? _viewport;

  @override
  void didUpdateWidget(_Zoomed old) {
    super.didUpdateWidget(old);
    if (old.zoom != widget.zoom) _apply();
  }

  /// Scales about the middle of the pane, so what was in the centre stays
  /// there. `translate` then `scale` post-multiply, so a point maps to
  /// `zoom * p + offset` — and at the centre the two cancel.
  void _apply() {
    var size = _viewport;
    if (size == null) return;
    var offset = -(widget.zoom - 1) / 2;
    _controller.value = Matrix4.identity()
      ..translateByDouble(offset * size.width, offset * size.height, 0, 1)
      ..scaleByDouble(widget.zoom, widget.zoom, 1, 1);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        var size = constraints.biggest;
        if (size != _viewport) {
          _viewport = size;
          // After the frame: the controller has listeners, and moving it during
          // layout marks them dirty in the middle of building them.
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) _apply();
          });
        }
        return InteractiveViewer(
          transformationController: _controller,
          panEnabled: true,
          scaleEnabled: false,
          // Room to drag a magnified asset fully past the edges, rather than
          // stopping with its corner pinned mid-pane.
          boundaryMargin: EdgeInsets.all(size.longestSide),
          child: widget.child,
        );
      },
    );
  }
}

class _Backdrop extends StatelessWidget {
  const _Backdrop({required this.background, required this.child});

  final PreviewBackground background;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return switch (background) {
      PreviewBackground.checker => CustomPaint(
        painter: _CheckerPainter(context.colors.line2),
        child: child,
      ),
      PreviewBackground.light => ColoredBox(
        color: const Color(0xffffffff),
        child: child,
      ),
      PreviewBackground.dark => ColoredBox(
        color: const Color(0xff1c1c1e),
        child: child,
      ),
    };
  }
}

class _CheckerPainter extends CustomPainter {
  _CheckerPainter(this.tint);

  final Color tint;

  static const _square = 8.0;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(
      Offset.zero & size,
      Paint()..color = const Color(0xffffffff),
    );
    var paint = Paint()..color = tint;
    for (var y = 0.0; y < size.height; y += _square) {
      for (var x = 0.0; x < size.width; x += _square) {
        var odd = ((x / _square).floor() + (y / _square).floor()).isOdd;
        if (odd) canvas.drawRect(Rect.fromLTWH(x, y, _square, _square), paint);
      }
    }
  }

  @override
  bool shouldRepaint(_CheckerPainter oldDelegate) => oldDelegate.tint != tint;
}

/// A font, rendered in itself.
///
/// The family is registered under a name derived from the asset key, so two
/// specimens on screen at once cannot end up drawing each other — `FontLoader`
/// *appends* when a family name is reused, and the second load would silently
/// win for glyphs the first one lacks.
class FontSpecimen extends StatefulWidget {
  const FontSpecimen({super.key, required this.bytes, required this.family});

  final Uint8List bytes;
  final String family;

  @override
  State<FontSpecimen> createState() => _FontSpecimenState();
}

class _FontSpecimenState extends State<FontSpecimen> {
  late String _family;
  Object? _error;
  var _loaded = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(FontSpecimen old) {
    super.didUpdateWidget(old);
    if (old.bytes != widget.bytes || old.family != widget.family) _load();
  }

  Future<void> _load() async {
    _family = 'fw-specimen-${widget.family}';
    _loaded = false;
    _error = null;
    // Checked before loading, because `FontLoader` does not reliably refuse:
    // hand it a PNG and the engine may simply register a family with no glyphs,
    // which draws as a blank panel that looks like a working preview of an
    // empty font. A wrong answer that looks right is the one worth spending
    // four bytes to avoid.
    if (!_looksLikeFont(widget.bytes)) {
      setState(() => _error = 'Its first bytes are not a font signature.');
      return;
    }
    try {
      await (FontLoader(
        _family,
      )..addFont(Future.value(widget.bytes.buffer.asByteData()))).load();
      if (mounted) setState(() => _loaded = true);
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_error case var error?) {
      return _Unreadable(message: 'Not a usable font file.\n$error');
    }
    if (!_loaded) return const SizedBox.shrink();

    return SingleChildScrollView(
      padding: const EdgeInsets.all(FwSpacing.xl),
      child: DefaultTextStyle(
        style: TextStyle(fontFamily: _family, color: context.colors.ink),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          spacing: FwSpacing.lg,
          children: const [
            Text('Handgloves', style: TextStyle(fontSize: 34)),
            Text('ABCDEFGHIJKLM NOPQRSTUVWXYZ', style: TextStyle(fontSize: 17)),
            Text('abcdefghijklm nopqrstuvwxyz', style: TextStyle(fontSize: 17)),
            Text(r'0123456789 &@$€ ?!', style: TextStyle(fontSize: 17)),
            Text(
              'The quick brown fox jumps over the lazy dog.',
              style: TextStyle(fontSize: 13),
            ),
          ],
        ),
      ),
    );
  }
}

/// Whether [bytes] open with a signature the engine could plausibly read.
///
/// The sfnt tags plus the two web formats. Not validation — a truncated but
/// correctly-tagged file still fails at load, and that path is caught — just
/// enough to tell "this is not a font" from "this font is broken".
bool _looksLikeFont(Uint8List bytes) {
  if (bytes.length < 4) return false;
  var tag = bytes.buffer.asByteData().getUint32(0);
  return const {
    0x00010000, // TrueType
    0x74727565, // 'true'
    0x74746366, // 'ttcf', a collection
    0x4f54544f, // 'OTTO', CFF outlines
    0x774f4646, // 'wOFF'
    0x774f4632, // 'wOF2'
  }.contains(tag);
}

/// A Lottie animation, with somewhere to stand still.
///
/// The scrubber is the reason this is not one `Lottie.memory` call: a frame you
/// can stop on is a frame you can point at, and [onFrame] is what lets the
/// screen put it in the address.
class LottiePreview extends StatefulWidget {
  const LottiePreview({
    super.key,
    required this.bytes,
    required this.fallback,
    this.frame,
    this.onFrame,
  });

  final Uint8List bytes;

  /// What to draw when these bytes are not an animation — which is most `.json`
  /// files, and not an error.
  final WidgetBuilder fallback;

  final int? frame;
  final ValueChanged<int>? onFrame;

  @override
  State<LottiePreview> createState() => _LottiePreviewState();
}

class _LottiePreviewState extends State<LottiePreview>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(vsync: this);
  LottieComposition? _composition;
  var _failed = false;
  var _playing = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      var composition = await LottieComposition.fromBytes(widget.bytes);
      if (!mounted) return;
      setState(() {
        _composition = composition;
        _controller.duration = composition.duration;
      });
      _seek();
    } catch (_) {
      // Not an animation. The fallback says so in the language of the file it
      // actually is, rather than reporting a parse error for a plain JSON.
      if (mounted) setState(() => _failed = true);
    }
  }

  @override
  void didUpdateWidget(LottiePreview old) {
    super.didUpdateWidget(old);
    if (old.bytes != widget.bytes) {
      _composition = null;
      _failed = false;
      _playing = false;
      _load();
    } else if (old.frame != widget.frame) {
      _seek();
    }
  }

  int get _frameCount => (_composition?.durationFrames ?? 0).round();

  void _seek() {
    var frame = widget.frame;
    if (frame == null || _frameCount == 0) return;
    _controller.stop();
    _controller.value = (frame / _frameCount).clamp(0, 1);
    _playing = false;
  }

  void _toggle() {
    setState(() {
      _playing = !_playing;
      if (_playing) {
        _controller.repeat();
      } else {
        _controller.stop();
        widget.onFrame?.call((_controller.value * _frameCount).round());
      }
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_failed) return widget.fallback(context);
    var composition = _composition;
    if (composition == null) return const SizedBox.shrink();

    return Column(
      children: [
        Expanded(
          child: Lottie(
            composition: composition,
            controller: _controller,
            fit: BoxFit.contain,
          ),
        ),
        _controls(context, composition),
      ],
    );
  }

  Widget _controls(BuildContext context, LottieComposition composition) {
    return Container(
      color: context.colors.panel.withValues(alpha: 0.9),
      padding: const EdgeInsets.symmetric(horizontal: FwSpacing.md),
      child: Row(
        children: [
          IconButton(
            onPressed: _toggle,
            iconSize: FwIconSize.lg,
            icon: Icon(_playing ? Icons.pause : Icons.play_arrow),
          ),
          Expanded(
            child: AnimatedBuilder(
              animation: _controller,
              builder: (context, _) => Slider(
                value: _controller.value.clamp(0, 1),
                onChanged: (value) {
                  setState(() {
                    _playing = false;
                    _controller.stop();
                    _controller.value = value;
                  });
                  widget.onFrame?.call((value * _frameCount).round());
                },
              ),
            ),
          ),
          AnimatedBuilder(
            animation: _controller,
            builder: (context, _) => Text(
              '${(_controller.value * _frameCount).round()} / $_frameCount',
              style: context.type.micro,
            ),
          ),
        ],
      ),
    );
  }
}

/// A `.json` that is not an animation, shown as what it is: its text.
///
/// The other preview in this file draws pixels; this one draws the document,
/// because for configuration the document *is* the thing you opened the asset
/// to check. "No preview for .json files" was never true — the bytes are right
/// there and they are human-readable.
///
/// Re-encoded with an indent when it parses, because a bundled config is
/// usually minified and one 4,000-character line is not a preview of anything.
/// When it does **not** parse the raw text is shown instead, unindented and
/// unaltered: a malformed JSON is precisely the file somebody is here to look
/// at, and hiding it behind a parse error would take away the only view of it.
class _JsonSource extends StatelessWidget {
  const _JsonSource({required this.bytes});

  final Uint8List bytes;

  /// Enough to read, and short of what makes a `TextSpan` per token expensive.
  /// A bundle can hold a megabyte of translations, and highlighting all of it
  /// to show the first screenful is work nobody asked for.
  static const _maxCharacters = 20000;

  @override
  Widget build(BuildContext context) {
    String source;
    try {
      source = utf8.decode(bytes);
    } catch (_) {
      // Named `.json` and not text at all. Nothing to show, and the raw bytes
      // would be worse than nothing.
      return const _Unreadable(message: 'Not readable as UTF-8 text.');
    }

    try {
      source = const JsonEncoder.withIndent('  ').convert(jsonDecode(source));
    } catch (_) {
      // Left as it is on disk — see above.
    }

    var truncated = source.length > _maxCharacters;
    return Padding(
      padding: const EdgeInsets.all(FwSpacing.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        spacing: FwSpacing.xs,
        children: [
          Flexible(
            child: FwCodeBlock(
              truncated ? source.substring(0, _maxCharacters) : source,
              language: 'json',
            ),
          ),
          if (truncated)
            Text(
              'First ${_maxCharacters ~/ 1000}k characters of '
              '${source.length ~/ 1000}k.',
              style: context.type.micro,
            ),
        ],
      ),
    );
  }
}

class _NoPreview extends StatelessWidget {
  const _NoPreview({required this.kind, required this.name});

  final AssetKind kind;
  final String name;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      spacing: FwSpacing.md,
      children: [
        Icon(
          Icons.description_outlined,
          size: FwIconSize.xl,
          color: context.colors.mut2,
        ),
        Text(
          // The extension, because that is what the reader is holding. "No
          // preview for data" names our own taxonomy back at them.
          p.extension(name).isEmpty
              ? 'No preview for this file'
              : 'No preview for ${p.extension(name)} files',
          style: context.type.bodyMuted,
        ),
      ],
    );
  }
}

class _Unreadable extends StatelessWidget {
  const _Unreadable({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(FwSpacing.xl),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        spacing: FwSpacing.md,
        children: [
          Icon(
            Icons.broken_image_outlined,
            size: FwIconSize.xl,
            color: context.colors.red,
          ),
          Text(
            message,
            textAlign: TextAlign.center,
            style: context.type.caption.copyWith(color: context.colors.red),
          ),
        ],
      ),
    );
  }
}
