// The paint stack, as a list you can add to, reorder and take apart.
//
// The pattern every design tool already teaches — a row per pass, a swatch, a
// number, and the rest one tap in — because a stack is read top-down and the
// order IS the meaning. The model is back to front (the first layer is
// painted first, so it sits behind); the list shows it FRONT first, which is
// what "the top layer" means to everyone who has used one of these.
import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';
import 'package:flutterware/scene_authoring.dart';

import '../../ui/design/design.dart';
import '../../ui/menu.dart';
import '../../ui/picker.dart';
import '../../ui/popover.dart';
import '../../ui/tappable.dart';
import '../layer_presets.dart';
import '../shader_library.dart';
import 'number_field.dart';
import 'number_shape.dart';
import 'paint_field.dart';

/// What a change to the stack is: the whole next list, with the words for
/// the undo entry it makes.
typedef LayersChanged = void Function(
  List<TextLayer> next, {
  required String label,
  String? mergeKey,
});

class SceneLayerList extends StatefulWidget {
  const SceneLayerList({
    super.key,
    required this.layers,
    required this.fontSize,
    required this.color,
    required this.onChanged,
    this.marker,
    this.shaders,
  });

  /// A text node's own stack, or a shared style's — the control is the same
  /// list of the same values either way, and the two hosts differ only in
  /// where the next list is written.
  final List<TextLayer> layers;

  /// What a preset scales its numbers to, and what a new stroke's default
  /// width is derived from.
  final double fontSize;

  /// What a pass with no paint of its own is drawn in — the swatch a row
  /// shows when it says "the text's own colour".
  final Color color;

  final LayersChanged onChanged;

  /// Where the stack comes from, for the header's right edge — a shared
  /// style's `← name`, or the way back when this text has typed over it. The
  /// paint stack is a style property like every other one, and the panel
  /// says so in the same words here as it does on a row.
  final Widget? marker;

  /// What a shader pass picks from — see [ScenePaintField.shaders].
  final SceneShaders? shaders;

  @override
  State<SceneLayerList> createState() => _SceneLayerListState();
}

class _SceneLayerListState extends State<SceneLayerList> {
  /// Which pass is open, by its position in the MODEL — an index survives a
  /// rebuild, and nothing else about a layer is stable, because a layer is a
  /// value and has no identity by decision.
  int? _open;

  List<TextLayer> get _layers => widget.layers;

  void _write(String label, List<TextLayer> next, {String? mergeKey}) {
    widget.onChanged(next, label: label, mergeKey: mergeKey);
  }

  void _replace(
    int i,
    TextLayer layer, {
    String label = 'Layer',
    String? mergeKey,
  }) {
    var next = [..._layers];
    next[i] = layer;
    _write(label, next, mergeKey: mergeKey);
  }

  void _add(TextLayer layer) {
    // On top, which is where a new pass is expected to land and where it can
    // actually be seen.
    _write('Add layer', [..._layers, layer]);
    setState(() => _open = _layers.length - 1);
  }

  void _remove(int i) {
    _write('Remove layer', [..._layers]..removeAt(i));
    setState(() => _open = null);
  }

  void _move(int i, int by) {
    var to = i + by;
    if (to < 0 || to >= _layers.length) return;
    var next = [..._layers];
    next.insert(to, next.removeAt(i));
    _write('Reorder layers', next);
    setState(() => _open = to);
  }

  void _applyPreset(LayerPreset preset) {
    _write('${preset.name} layers', preset.forSize(widget.fontSize));
    setState(() => _open = null);
  }

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    var caption = context.type.caption.copyWith(color: colors.mut2);
    // Front first: the last layer painted is the one on top.
    var rows = [for (var i = _layers.length - 1; i >= 0; i--) _row(context, i)];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // The `+` sits next to the word, not at the far right: this list is
        // as wide as whatever holds it, and in the library's full-width card
        // an edge-pinned button was a hand's travel away from the label that
        // names it.
        Row(
          children: [
            Text('Paint', style: caption),
            const Gap(FwSpacing.xs),
            _addButton(context),
            const Spacer(),
            if (widget.marker != null) widget.marker!,
          ],
        ),
        const Gap(FwSpacing.xs),
        if (_layers.isEmpty)
          Text('painted once, in the colour above', style: caption)
        else
          ...rows,
      ],
    );
  }

  Widget _addButton(BuildContext context) => Menu(
    align: PopoverAlign.end,
    entries: [
      const MenuHeader('Add a pass'),
      MenuItem(
        'Fill',
        icon: Icons.format_color_fill_outlined,
        onSelected: () => _add(const FillLayer()),
      ),
      MenuItem(
        'Stroke',
        icon: Icons.border_color_outlined,
        onSelected: () => _add(
          StrokeLayer(
            // A seventh of the face is a stroke you can see; the rounding
            // is so a 54pt title does not open with a width of
            // 7.714285714285714.
            width: (widget.fontSize / 7 * 100).roundToDouble() / 100,
            join: SceneStrokeJoin.round,
          ),
        ),
      ),
      const MenuDivider(),
      // A stack nobody could have guessed at, one click away — and then
      // ordinary layers, with no link back to the preset.
      const MenuHeader('Start from'),
      for (var preset in layerPresets)
        MenuItem(
          preset.name,
          icon: Icons.auto_awesome_outlined,
          shortcut: '${preset.layers.length}',
          onSelected: () => _applyPreset(preset),
        ),
      if (_layers.isNotEmpty) ...[
        const MenuDivider(),
        MenuItem(
          'Clear',
          icon: Icons.layers_clear_outlined,
          onSelected: () {
            _write('Clear layers', const []);
            setState(() => _open = null);
          },
        ),
      ],
    ],
    builder: (context, controller) => Tappable(
      onTap: controller.toggle,
      child: Padding(
        padding: const EdgeInsets.all(FwSpacing.xxs),
        child: Icon(Icons.add, size: FwIconSize.sm, color: context.colors.mut2),
      ),
    ),
  );

  Widget _row(BuildContext context, int i) {
    var layer = _layers[i];
    var colors = context.colors;
    var open = _open == i;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Tappable.builder(
          onTap: () => setState(() => _open = open ? null : i),
          borderRadius: BorderRadius.circular(context.radii.radiusSmall),
          builder: (context, hovered) => Padding(
            padding: const EdgeInsets.symmetric(vertical: FwSpacing.xxs),
            child: Row(
              children: [
                _chip(context, layer),
                const Gap(FwSpacing.sm),
                Expanded(
                  child: Text(
                    _describe(layer),
                    style: context.type.caption,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (hovered) ...[
                  _icon(
                    context,
                    Icons.arrow_upward,
                    () => _move(i, 1),
                    enabled: i < _layers.length - 1,
                  ),
                  _icon(
                    context,
                    Icons.arrow_downward,
                    () => _move(i, -1),
                    enabled: i > 0,
                  ),
                  _icon(context, Icons.close, () => _remove(i)),
                ] else
                  Icon(
                    open ? Icons.keyboard_arrow_down : Icons.chevron_right,
                    size: FwIconSize.sm,
                    color: colors.mut2,
                  ),
              ],
            ),
          ),
        ),
        if (open) _detail(context, i, layer),
      ],
    );
  }

  Widget _icon(
    BuildContext context,
    IconData icon,
    VoidCallback onTap, {
    bool enabled = true,
  }) => Tappable(
    onTap: enabled ? onTap : null,
    child: Padding(
      padding: const EdgeInsets.all(FwSpacing.xxs),
      child: Icon(
        icon,
        size: FwIconSize.xs,
        color: enabled ? context.colors.mut2 : context.colors.line,
      ),
    ),
  );

  /// What the pass paints, as a small square — the way a fill list is read at
  /// a glance in every tool that has one.
  Widget _chip(BuildContext context, TextLayer layer) {
    var size = FwIconSize.md;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(context.radii.micro),
        border: Border.all(color: context.colors.line),
        color: switch (layer.paint) {
          SolidPaint(:var color) => Color(color.argb),
          null => widget.color,
          SceneGradient(:var colors) when colors.length < 2 =>
            colors.isEmpty ? widget.color : Color(colors.first.argb),
          SceneGradient() => null,
          ShaderPaint() => null,
        },
        gradient: switch (layer.paint) {
          SceneGradient g when g.colors.length >= 2 => _swatch(g),
          // Not a colour: a fixed sweep says so, rather than guessing at
          // what the shader itself will paint.
          ShaderPaint() => SweepGradient(
            colors: [
              context.colors.mut,
              context.colors.mut2,
              context.colors.mut3,
            ],
          ),
          _ => null,
        },
      ),
    );
  }

  /// A gradient as a swatch draws it — Flutter's own gradient classes, since
  /// a swatch is a decoration; the pass itself goes through the scene's
  /// shader.
  static Gradient _swatch(SceneGradient g) {
    var colors = [for (var c in g.colors) Color(c.argb)];
    return switch (g) {
      LinearPaint(:var begin, :var end) => LinearGradient(
        colors: colors,
        stops: g.resolvedStops,
        begin: Alignment(begin.x, begin.y),
        end: Alignment(end.x, end.y),
      ),
      RadialPaint(:var center, :var radius) => RadialGradient(
        colors: colors,
        stops: g.resolvedStops,
        center: Alignment(center.x, center.y),
        // A swatch is square, so the box-stretched radius is Flutter's
        // shortest-side one at half the number.
        radius: radius / 2,
      ),
      SweepPaint(:var center, :var startAngle, :var endAngle) => SweepGradient(
        colors: colors,
        stops: g.resolvedStops,
        center: Alignment(center.x, center.y),
        endAngle: (endAngle - startAngle).clamp(0.01, 360) * math.pi / 180,
        transform: GradientRotation((startAngle - 90) * math.pi / 180),
      ),
    };
  }

  String _describe(TextLayer layer) {
    var what = switch (layer) {
      StrokeLayer(:var width) => 'Stroke ${_short(width)}',
      FillLayer() => 'Fill',
    };
    var notes = [
      if (layer.paint == null) 'text colour',
      if (layer.paint case SceneGradient g)
        switch (g) {
          LinearPaint() => 'linear',
          RadialPaint() => 'radial',
          SweepPaint() => 'sweep',
        },
      if (layer.paint case ShaderPaint()) 'shader',
      if (layer.box == SceneLayerBox.line &&
          (layer.paint is SceneGradient || layer.paint is ShaderPaint))
        'per line',
      if (layer.blend != SceneBlendMode.normal)
        _blendLabel(layer.blend).toLowerCase(),
      if (layer.blur > 0) 'blur ${_short(layer.blur)}',
      if (layer.dx != 0 || layer.dy != 0)
        '${_short(layer.dx)},${_short(layer.dy)}',
      if (layer.opacity != 1) '${(layer.opacity * 100).round()}%',
    ];
    return notes.isEmpty ? what : '$what · ${notes.join(' · ')}';
  }

  static String _short(double v) =>
      v == v.roundToDouble() ? '${v.round()}' : v.toStringAsFixed(1);

  /// A mode in the words a design tool uses — Flutter's names are camel-case
  /// identifiers, and this panel spells colour the British way throughout.
  static String _blendLabel(SceneBlendMode m) => switch (m) {
    SceneBlendMode.normal => 'Normal',
    SceneBlendMode.multiply => 'Multiply',
    SceneBlendMode.screen => 'Screen',
    SceneBlendMode.overlay => 'Overlay',
    SceneBlendMode.darken => 'Darken',
    SceneBlendMode.lighten => 'Lighten',
    SceneBlendMode.colorDodge => 'Colour dodge',
    SceneBlendMode.colorBurn => 'Colour burn',
    SceneBlendMode.hardLight => 'Hard light',
    SceneBlendMode.softLight => 'Soft light',
    SceneBlendMode.difference => 'Difference',
    SceneBlendMode.exclusion => 'Exclusion',
    SceneBlendMode.hue => 'Hue',
    SceneBlendMode.saturation => 'Saturation',
    SceneBlendMode.color => 'Colour',
    SceneBlendMode.luminosity => 'Luminosity',
  };

  Widget _detail(BuildContext context, int i, TextLayer layer) {
    return Padding(
      padding: const EdgeInsets.only(
        left: FwSpacing.xl,
        bottom: FwSpacing.md,
        top: FwSpacing.xs,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ScenePaintField(
            paint: layer.paint,
            own: SceneColor(widget.color.toARGB32()),
            shaders: widget.shaders,
            onChanged: (next, {required label, mergeKey}) => _replace(
              i,
              // "Laid across" has no control once the paint is not a
              // gradient, so a hidden box: line would otherwise survive
              // in the file with nothing left to change it back.
              next is SceneGradient || next is ShaderPaint
                  ? layer.withPaint(next)
                  : layer.withPaint(next).copyWith(box: SceneLayerBox.text),
              label: label,
              mergeKey: mergeKey == null ? null : 'layer:$i:paint:$mergeKey',
            ),
          ),
          if (layer.paint is SceneGradient || layer.paint is ShaderPaint) ...[
            const Gap(FwSpacing.sm),
            _labelled(
              context,
              'Laid across',
              FwPicker<SceneLayerBox>(
                key: const ValueKey('layer:box'),
                choices: [
                  FwChoice(value: SceneLayerBox.text, label: 'The whole text'),
                  FwChoice(
                    value: SceneLayerBox.line,
                    label: 'Each line',
                    detail: layer.paint is ShaderPaint
                        ? 'the shader runs once per line, sized to it'
                        : 'every line runs the whole gradient',
                  ),
                ],
                selected: layer.box,
                onChanged: (b) =>
                    _replace(i, layer.copyWith(box: b), label: 'Layer box'),
              ),
            ),
          ],
          const Gap(FwSpacing.sm),
          if (layer case StrokeLayer stroke)
            _number(
              context,
              'Width',
              stroke.width,
              const SceneNumberShape(perPixel: 0.2, decimals: 1, min: 0),
              (v) => _replace(
                i,
                stroke.copyWith(width: v),
                mergeKey: 'layer:$i:width',
              ),
            ),
          Row(
            children: [
              Expanded(
                child: _number(
                  context,
                  'X',
                  layer.dx,
                  const SceneNumberShape(perPixel: 0.2, decimals: 1),
                  (v) => _replace(
                    i,
                    layer.copyWith(dx: v),
                    mergeKey: 'layer:$i:dx',
                  ),
                ),
              ),
              const Gap(FwSpacing.md),
              Expanded(
                child: _number(
                  context,
                  'Y',
                  layer.dy,
                  const SceneNumberShape(perPixel: 0.2, decimals: 1),
                  (v) => _replace(
                    i,
                    layer.copyWith(dy: v),
                    mergeKey: 'layer:$i:dy',
                  ),
                ),
              ),
            ],
          ),
          const Gap(FwSpacing.sm),
          Row(
            children: [
              Expanded(
                child: _number(
                  context,
                  'Blur',
                  layer.blur,
                  const SceneNumberShape(perPixel: 0.2, decimals: 1, min: 0),
                  (v) => _replace(
                    i,
                    layer.copyWith(blur: v),
                    mergeKey: 'layer:$i:blur',
                  ),
                ),
              ),
              const Gap(FwSpacing.md),
              Expanded(
                child: _number(
                  context,
                  'Opacity',
                  layer.opacity,
                  // softMin/softMax are where a slider sits; min/max are what
                  // the value may BE. Only the hints were set, so a drag ran
                  // a pass past fully opaque and out the other side.
                  const SceneNumberShape(
                    perPixel: 0.005,
                    decimals: 2,
                    min: 0,
                    max: 1,
                    softMin: 0,
                    softMax: 1,
                  ),
                  (v) => _replace(
                    i,
                    layer.copyWith(opacity: v),
                    mergeKey: 'layer:$i:opacity',
                  ),
                ),
              ),
            ],
          ),
          const Gap(FwSpacing.sm),
          _labelled(
            context,
            'Blend',
            FwPicker<SceneBlendMode>(
              key: const ValueKey('layer:blend'),
              choices: [
                for (var m in SceneBlendMode.values)
                  FwChoice(value: m, label: _blendLabel(m)),
              ],
              selected: layer.blend,
              onChanged: (m) =>
                  _replace(i, layer.copyWith(blend: m), label: 'Layer blend'),
            ),
          ),
        ],
      ),
    );
  }

  Widget _number(
    BuildContext context,
    String label,
    double value,
    SceneNumberShape shape,
    ValueChanged<double> apply,
  ) => SceneNumberField(
    label: label,
    value: value,
    shape: shape,
    onChanged: apply,
    onCommit: apply,
  );

  /// A control under a caption, the way [SceneNumberField] labels itself —
  /// so a picker in this column reads as the same kind of row as a number.
  Widget _labelled(BuildContext context, String label, Widget control) =>
      Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.only(bottom: FwSpacing.xs),
            child: Text(
              label,
              style: context.type.caption.copyWith(color: context.colors.mut2),
            ),
          ),
          control,
        ],
      );
}
