// A shader pass, edited: which of the package's declared shaders it runs,
// then one control per uniform the shader asks for — drawn from what the
// compiler reflected and the source's own `// @range`, `// @color` and
// `// @default` comments, never from a table of names.
import 'package:material_ui/material_ui.dart';
import 'package:flutterware/scene_authoring.dart';
import 'package:path/path.dart' as p;

import '../../ui/design/design.dart';
import '../../ui/picker.dart';
import '../shader_library.dart';
import 'number_field.dart';
import 'number_shape.dart';
import 'paint_changed.dart';
import 'swatches.dart';

class SceneShaderField extends StatelessWidget {
  const SceneShaderField({
    super.key,
    required this.paint,
    required this.shaders,
    required this.onChanged,
  });

  final ShaderPaint paint;

  /// The package's shaders; null where there is no package to look in.
  final SceneShaders? shaders;

  final PaintChanged onChanged;

  static const _scrub = SceneNumberShape(perPixel: 0.01, decimals: 3);

  static const _components = ['x', 'y', 'z', 'w'];

  @override
  Widget build(BuildContext context) => switch (shaders) {
    null => _body(context, null),
    var shaders => ListenableBuilder(
      listenable: shaders,
      builder: (context, _) => _body(context, shaders),
    ),
  };

  Widget _body(BuildContext context, SceneShaders? shaders) {
    var asset = paint.asset;
    // With no package there is nothing to check the asset against, so it is
    // shown as it stands rather than called undeclared.
    var declared = shaders?.declared ?? [if (asset.isNotEmpty) asset];
    var known = asset.isEmpty || declared.contains(asset);
    // Only a declared shader is worth reading: the renderer loads a pass
    // from the asset bundle, and anything the pubspec does not list is not
    // in it.
    var reflected = shaders != null && asset.isNotEmpty && known;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        FwPicker<String>(
          key: const ValueKey('paint:shader'),
          selected: asset,
          choices: [
            if (!known)
              FwChoice(
                value: asset,
                label: p.basename(asset),
                detail: 'not declared',
              ),
            for (var key in declared)
              FwChoice(value: key, label: p.basename(key), detail: key),
          ],
          empty: shaders == null
              ? 'No package to look in.'
              : 'No shaders under flutter: shaders: in pubspec.yaml.',
          onChanged: (key) {
            if (key == asset) return;
            onChanged(
              ShaderPaint(key, uniforms: shaders?.info(key)?.defaults ?? {}),
              label: 'Shader',
            );
          },
        ),
        if (!known)
          _caption(
            context,
            "'$asset' is not declared under flutter: shaders:",
            red: true,
          )
        else if (shaders == null && asset.isNotEmpty)
          _caption(context, 'No package to look in.'),
        if (reflected)
          ..._uniforms(context, shaders.info(asset))
        else if (asset.isNotEmpty)
          ..._plain(context),
      ],
    );
  }

  List<Widget> _uniforms(BuildContext context, SceneShaderInfo? info) {
    if (info == null) return [_caption(context, 'Reading uniforms…')];
    // An error with nothing reflected is a shader that did not compile: the
    // file's own numbers are all there is to show. One that still lists
    // uniforms — a sampler the scene cannot feed — keeps its controls.
    if (info.error case var error? when info.uniforms.isEmpty) {
      return [_caption(context, error, red: true), ..._plain(context)];
    }
    var name = p.basename(paint.asset);
    var byName = {for (var u in info.uniforms) u.name: u};
    return [
      if (info.error case var error?) _caption(context, error, red: true),
      for (var u in info.uniforms)
        if (!u.rendererOwned) ...[
          const Gap(FwSpacing.sm),
          _uniform(context, u),
          if (paint.uniforms[u.name] case var set? when set.length != u.size)
            _caption(
              context,
              '${u.name} is set as ${set.length} numbers, and $name '
              'declares ${u.size}',
              red: true,
            ),
        ],
      for (var stray in paint.uniforms.keys)
        if (_isRenderers(stray))
          _rendererCaption(context, stray)
        else if (!byName.containsKey(stray))
          _caption(
            context,
            '$stray is set, and $name declares no such uniform',
            red: true,
          ),
    ];
  }

  /// What a uniform's control shows: what the renderer paints with — the
  /// value's own numbers when they are the right count, and zeros otherwise.
  /// A `@default` is written once, when the asset is picked, never shown in
  /// place of a value that is not there.
  List<double> _valueOf(SceneShaderUniform u) {
    if (paint.uniforms[u.name] case var set? when set.length == u.size) {
      return set;
    }
    return List.filled(u.size, 0);
  }

  Widget _uniform(BuildContext context, SceneShaderUniform u) {
    var value = _valueOf(u);
    if (u.size == 1) {
      var shape = switch (u.range) {
        (var a, var b) => SceneNumberShape(
          perPixel: (b - a) / 200,
          decimals: 3,
          softMin: a,
          softMax: b,
          slider: true,
        ),
        null => _scrub,
      };
      return _number(u.name, u.name, value.first, shape, (v) => [v]);
    }
    if (u.isColor && (u.size == 3 || u.size == 4)) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _label(context, u.name),
          SceneColorField(
            current: _colorOf(value),
            allowNone: false,
            onPick: (c) => _write(u.name, _floatsOf(c!, u.size)),
          ),
        ],
      );
    }
    return _vector(u.name, value);
  }

  /// One scrub field per component, `name.x` to `name.w`.
  Widget _vector(String name, List<double> value) => Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      for (var i = 0; i < value.length; i++) ...[
        if (i > 0) const Gap(FwSpacing.md),
        Expanded(
          child: _number(
            name,
            '$name.${_components[i]}',
            value[i],
            _scrub,
            (v) => [...value]..[i] = v,
          ),
        ),
      ],
    ],
  );

  /// With no reflection to go by — no package, an undeclared asset, or a
  /// shader that did not compile — the numbers the value already carries,
  /// as plain fields, so nothing in the file is out of reach.
  List<Widget> _plain(BuildContext context) => [
    for (var MapEntry(key: name, value: value) in paint.uniforms.entries)
      if (_isRenderers(name))
        _rendererCaption(context, name)
      else if (value.isNotEmpty && value.length <= 4) ...[
        const Gap(FwSpacing.sm),
        value.length == 1
            ? _number(name, name, value.first, _scrub, (v) => [v])
            : _vector(name, value),
      ],
  ];

  void _write(String name, List<double> next, {String? mergeKey}) => onChanged(
    ShaderPaint(paint.asset, uniforms: {...paint.uniforms, name: next}),
    label: 'Shader uniform',
    mergeKey: mergeKey,
  );

  // The drag and the commit carry the same merge key, as every other number
  // in the paint field does: the commit lands in the drag's undo entry
  // rather than opening a second one that undoes nothing.
  Widget _number(
    String name,
    String label,
    double value,
    SceneNumberShape shape,
    List<double> Function(double) next,
  ) {
    void apply(double v) => _write(name, next(v), mergeKey: 'shader:$name');
    return SceneNumberField(
      label: label,
      value: value,
      shape: shape,
      onChanged: apply,
      onCommit: apply,
    );
  }

  static SceneColor _colorOf(List<double> v) {
    int channel(double x) => (x.clamp(0, 1) * 255).round();
    var alpha = v.length == 4 ? channel(v[3]) : 0xFF;
    return SceneColor(
      alpha << 24 | channel(v[0]) << 16 | channel(v[1]) << 8 | channel(v[2]),
    );
  }

  static List<double> _floatsOf(SceneColor c, int size) {
    double unit(int x) => (x / 255 * 1000).roundToDouble() / 1000;
    return [
      unit(c.red),
      unit(c.green),
      unit(c.blue),
      if (size == 4) unit(c.alpha),
    ];
  }

  /// Whether the renderer sets [name] itself — at any size, since it skips
  /// a stored value under that name whatever the shader declares.
  static bool _isRenderers(String name) =>
      ShaderPaint.rendererUniforms.containsKey(name);

  Widget _rendererCaption(BuildContext context, String name) => _caption(
    context,
    '$name is set by the renderer; the stored value is ignored',
  );

  Widget _label(BuildContext context, String text) => Padding(
    padding: const EdgeInsets.only(bottom: FwSpacing.xs),
    child: Text(
      text,
      style: context.type.caption.copyWith(color: context.colors.mut2),
    ),
  );

  Widget _caption(BuildContext context, String text, {bool red = false}) =>
      Padding(
        padding: const EdgeInsets.only(top: FwSpacing.xs),
        child: Text(
          text,
          style: context.type.caption.copyWith(
            color: red ? context.colors.red : context.colors.mut2,
          ),
        ),
      );
}
