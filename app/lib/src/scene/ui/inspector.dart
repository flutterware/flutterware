// The inspector, rebuilt on the design system and on the salvaged number
// editors — the first panel of the spike's four to be redone in its final
// home.
//
// Two things it does that the toy's inspector did not. Every number is a
// SceneNumberField, so a property's own metadata decides whether it is
// dragged, dragged beside a slider, or turned on a dial, and one gesture is
// one undo entry (the field commits once, on release, under the door's merge
// key). And every colour, weight and alignment goes through the studio's own
// controls rather than stock Material.
import 'package:material_ui/material_ui.dart';
import 'package:flutterware/scene_authoring.dart';
import 'package:path/path.dart' as paths;

import '../externals_file.dart';
import '../model_assets.dart';
import '../shader_library.dart';

import '../../ui/context_menu.dart';
import '../../ui/disclosure.dart';
import '../../assets/model/font_axes.dart';
import '../type_axes.dart';
import '../../ui/design/design.dart';
import '../../ui/action_button.dart';
import '../../ui/menu.dart';
import '../../ui/picker.dart';
import '../../ui/tappable.dart';
import '../editor.dart';
import 'curve_picker.dart';
import 'layer_list.dart';
import 'number_shape.dart';
import 'number_field.dart';
import 'property_row.dart';
import 'swatches.dart';

/// The three states a size can be in, in the order the menu offers them.
enum _SizeMode {
  fixed('fixed'),
  hug('hug'),
  fill('fill');

  const _SizeMode(this.label);
  final String label;
}

class SceneInspector extends StatelessWidget {
  const SceneInspector(
    this.editor, {
    super.key,
    this.externals = const [],
    this.axesFor,
    this.packageRoot,
    this.shaders,
    this.onOpenParam,
    this.onEnterNested,
  });

  final SceneEditor editor;

  /// The package the file belongs to — where a row that picks a model
  /// file, or a mesh or clip in one, finds what there is to pick. Null in
  /// a test that has no package; the pickers then say so.
  final String? packageRoot;

  /// The package's declared shaders, for a text layer painted with one.
  /// Null in a test that has no package; the shader picker then says so.
  final SceneShaders? shaders;

  /// Opens a parameter below the canvas — where a bound property's row
  /// leads.
  final ValueChanged<String>? onOpenParam;

  /// Drills into the scene a nested instance stands for — its main.
  final ValueChanged<SceneNode>? onEnterNested;

  /// The widgets the app declares. This is the whole of what the editor
  /// knows about a foreign widget — nothing here resolves the app package —
  /// and it is why an external node's arguments can be shown with their
  /// types and their defaults rather than guessed from whatever value the
  /// scene happens to carry.
  final List<ExternalWidgetDecl> externals;

  /// The variable axes of a family the package declares, read out of the
  /// font file itself. Null where nothing has scanned — the panel then draws
  /// the discrete weights, which is what a static family gets anyway.
  final AxesLookup? axesFor;

  List<FontAxis> _axesOf(TextNode t) => sceneAxesOf(t, axesFor);

  SceneDocument get doc => editor.doc;

  /// Every edit is a door, and consecutive edits of one property on one node
  /// merge into a single undo entry — which is what makes a drag one entry
  /// rather than sixty.
  void _door(String prop, void Function() fn) {
    var name = (editor.primary ?? doc.root).name;
    editor.perform('Edit $prop', mergeKey: 'inspect:$prop:$name', fn);
  }

  /// What a field shows for [prop]: while recording, what the motion has
  /// the node at — the key under the playhead, which the field is editing —
  /// and the node's own value otherwise. A field showing the authored value
  /// while its edits went to a key would snap back on every frame.
  T _shown<T>(SceneNode node, String prop, T authored) =>
      editor.records(node, prop) ? node.fxRendered(prop) as T : authored;

  /// An edit to an animatable property: a key at the playhead while
  /// recording, the node's own value otherwise.
  void _set(String prop, Object value, void Function() apply) {
    var node = editor.primary ?? doc.root;
    var name = node.name;
    if (editor.recordKey(node, prop, value, mergeKey: 'record:$prop:$name')) {
      return;
    }
    _door(prop, apply);
  }

  @override
  Widget build(BuildContext context) {
    if (editor.selectedClip case var block?) return _block(context, block);
    if (editor.selectedKeys.isNotEmpty) return _keys(context);
    var node = editor.primary ?? doc.root;
    var parent = node == doc.root ? null : doc.parentOf(node);
    var inFlex = parent != null && parent.layout != NodeLayout.absolute;
    var isRow = parent != null && parent.layout == NodeLayout.table;

    return ListView(
      key: ValueKey('inspector:${node.name}'),
      padding: const EdgeInsets.all(FwSpacing.lg),
      children: [
        Text(
          node == doc.root
              ? 'Artboard · ${node.name}'
              : '${node.typeName} · ${node.name}',
          style: context.type.bodyStrong,
        ),
        // The root is not selectable — it is the page, not a thing on it —
        // and this panel falls back to it when nothing is selected. Saying
        // so is the difference between "here is your selection" and "you
        // have none", which the tree was telling the truth about all along.
        if (node == doc.root && editor.selectedNodes.isEmpty)
          Padding(
            padding: const EdgeInsets.only(top: FwSpacing.xxs),
            child: Text(
              'nothing selected',
              style: context.type.caption.copyWith(color: context.colors.mut2),
            ),
          ),
        if (node != doc.root)
          _check(
            context,
            node,
            'visible',
            'Visible',
            node.visible,
            () => _door('visible', () => node.visible = !node.visible),
          ),
        _section(context, 'Layout'),
        if (isRow)
          // A row under a table is not laid out at all: the table places the
          // cells, and the row is what paints behind them. Saying so beats
          // leaving a column of controls that quietly do nothing.
          Padding(
            padding: const EdgeInsets.only(bottom: FwSpacing.md),
            child: Text(
              'A row of ${parent.name}. It paints the fill, the border and '
              'the corner; ${parent.name} lays out the cells.',
              style: context.type.caption.copyWith(color: context.colors.mut2),
            ),
          )
        else if (inFlex)
          Padding(
            padding: const EdgeInsets.only(bottom: FwSpacing.md),
            child: Text(
              'Position measured by parent layout',
              style: context.type.caption.copyWith(color: context.colors.mut2),
            ),
          ),
        _row([
          _number(
            'x',
            'X',
            node.x,
            SceneNumberShape.pixels,
            enabled: !inFlex && node != doc.root,
            apply: (v) => node.x = v,
          ),
          _number(
            'y',
            'Y',
            node.y,
            SceneNumberShape.pixels,
            enabled: !inFlex && node != doc.root,
            apply: (v) => node.y = v,
          ),
        ]),
        _row([
          _size(
            context,
            'W',
            node,
            'width',
            node.width,
            horizontal: true,
            onChanged: (v) => node.width = v,
          ),
          _size(
            context,
            'H',
            node,
            'height',
            node.height,
            horizontal: false,
            onChanged: (v) => node.height = v,
          ),
        ]),
        ..._bounds(context, node),
        _section(context, 'Fill & stroke'),
        _prop(
          context,
          node,
          'fill',
          'Fill',
          SceneColorField(
            current: editor.records(node, 'fill') && node.hasFx('fill')
                ? node.fxRendered('fill') as SceneColor
                : node.fill,
            // No fill is not a colour a key can hold: that one edits the
            // node.
            onPick: (c) => c == null
                ? _door('fill', () => node.fill = null)
                : _set('fill', c, () => node.fill = c),
          ),
        ),
        _prop(
          context,
          node,
          'borderColor',
          'Border',
          SceneColorField(
            current: node.borderColor,
            onPick: (c) => _door('borderColor', () => node.borderColor = c),
          ),
        ),
        if (node.borderColor != null)
          _row([
            _number(
              'borderWidth',
              'Width',
              node.borderWidth,
              SceneNumberShape.pixels,
              apply: (v) => node.borderWidth = v,
            ),
          ]),
        _row([
          // One number while the four agree; when they do not, this field
          // could only lie, so the section below is the only one shown.
          if (node.corners.isUniform)
            _number(
              'corner',
              'Corner',
              node.corner,
              SceneNumberShape.pixels,
              apply: (v) => node.corner = v,
            ),
          _number(
            'opacity',
            'Opacity',
            _shown(node, 'opacity', node.opacity),
            SceneNumberShape.of(propSpecFor(node, 'opacity')),
            apply: (v) => node.opacity = v.clamp(0, 1),
          ),
        ]),
        ..._corners(context, node),
        if (node != doc.root) ..._repeat(context, node),
        if (node is! FrameNode || !isRow) _section(context, _sectionOf(node)),
        ...switch (node) {
          TextNode t => _textProps(context, t),
          FrameNode f => isRow ? const [] : _frameProps(context, f),
          ShapeNode s => _shapeProps(context, s),
          ExternalNode e => _extProps(context, e),
          SceneRefNode r => _sceneProps(context, r),
          KindNode k => _kindProps(context, k),
        },
      ],
    );
  }

  // A live drag writes through on every sample — the canvas is the feedback —
  // and closes its merge run on release, so one gesture is one undo entry and
  // the next gesture is a different one.
  Widget _number(
    String prop,
    String label,
    double value,
    SceneNumberShape shape, {
    required void Function(double) apply,
    bool enabled = true,
  }) => Builder(
    builder: (context) => _prop(
      context,
      editor.primary ?? doc.root,
      prop,
      label,
      Opacity(
        opacity: enabled ? 1 : 0.4,
        child: IgnorePointer(
          ignoring: !enabled,
          child: SceneNumberField(
            value: value,
            shape: shape,
            onChanged: (v) => _set(prop, v, () => apply(v)),
            onCommit: (v) {
              _set(prop, v, () => apply(v));
              editor.endMerge();
            },
          ),
        ),
      ),
    ),
  );

  /// A number with a label and no row of its own — one of the four sides
  /// inside a grouped property, where the plug and the origin belong to the
  /// group and not to each side.
  Widget _side(
    String prop,
    String label,
    double value, {
    required void Function(double) apply,
  }) => SceneNumberField(
    label: label,
    value: value,
    shape: SceneNumberShape.pixels,
    onChanged: (v) => _set(prop, v, () => apply(v)),
    onCommit: (v) {
      _set(prop, v, () => apply(v));
      editor.endMerge();
    },
  );

  /// One axis of the face, over the range the font itself declares.
  ///
  /// A key of its own — `axes.wght` — so it binds to a parameter and takes a
  /// motion track like any other number. That is the whole point of the axis
  /// over the enum: a discrete weight cannot morph.
  Widget _axisField(BuildContext context, TextNode t, FontAxis axis) {
    var prop = '$sceneAxesPrefix${axis.tag}';
    return _prop(
      context,
      t,
      prop,
      axis.label,
      SceneNumberField(
        // An axis the node has not set sits where the FONT puts it, which
        // is not always 400 — Archivo's weight rests at 600 — and is a
        // number only the file knows.
        value: _shown(t, prop, t.axes[axis.tag] ?? axis.def),
        shape: SceneNumberShape(
          // The whole range under a few hundred pixels of drag, whatever it
          // is: `wght` runs 800 wide and `slnt` maybe 15.
          perPixel: (axis.max - axis.min) / 300,
          decimals: axis.max - axis.min > 10 ? 0 : 1,
          softMin: axis.min,
          softMax: axis.max,
          min: axis.min,
          max: axis.max,
          slider: true,
        ),
        onChanged: (v) => _set(prop, v, () => _writeAxis(t, axis.tag, v)),
        onCommit: (v) {
          _set(prop, v, () => _writeAxis(t, axis.tag, v));
          editor.endMerge();
        },
      ),
    );
  }

  void _writeAxis(TextNode t, String tag, double v) =>
      setSceneProperty(t, '$sceneAxesPrefix$tag', v);

  /// The face's axis with this tag, when it has one.
  FontAxis? _axisNamed(TextNode t, String tag) {
    for (var a in _axesOf(t)) {
      if (a.tag == tag) return a;
    }
    return null;
  }

  /// A property whose value is one of a fixed set — the picker, in a row
  /// that says where the value comes from like any other.
  Widget _choice<T>(
    SceneNode node,
    String prop,
    String label,
    T? selected,
    List<FwChoice<T>> choices,
    ValueChanged<T> onChanged,
  ) => Builder(
    builder: (context) => _prop(
      context,
      node,
      prop,
      label,
      FwPicker<T>(selected: selected, choices: choices, onChanged: onChanged),
    ),
  );

  /// One property, one row: the label, the control, and where the value
  /// comes from — the whole of what the panel used to say in a separate
  /// block at the top and on the field itself not at all.
  ///
  /// A bound property shows its source instead of a control. That is the
  /// decision the old panel got wrong in both directions: a bound field was
  /// fully draggable, and dragging it silently moved the parameter every
  /// sibling reads.
  Widget _prop(
    BuildContext context,
    SceneNode node,
    String prop,
    String label,
    Widget control, {
    Widget? trailing,
    bool inline = false,
    bool strongLabel = false,
  }) {
    var origin = _originOf(node, prop);
    var bindable = !sceneBindSources(doc, node, prop).isEmpty;
    // What the chip says the property currently is. A style has no single
    // value to show, so it says what it decides instead — which is the one
    // thing a reader wants from a name like `tokens.title`.
    var isStyle = resolveSceneKey(node, prop)?.prop.kind == ScenePropKind.style;
    var value = origin == PropertyOrigin.appValue || isStyle
        ? null
        : getSceneProperty(node, prop);
    var styleSets = isStyle ? styleOf(doc, node)?.values.keys : null;
    return PropertyRow(
      label: label,
      origin: origin,
      sourceName: _sourceOf(node, prop),
      valueLabel: styleSets != null
          ? styleSets.map(_propLabel).join(' · ')
          : value == null
          ? null
          : _valueLabel(value),
      swatch: value is SceneColor ? Color(value.argb) : null,
      overridden:
          origin == PropertyOrigin.style && !inheritsFromStyle(doc, node, prop),
      trailing: trailing,
      inline: inline,
      strongLabel: strongLabel,
      onBind: bindable ? (at) => _bindMenu(context, node, prop, at) : null,
      onUnbind: () => editor.unbind(node, prop),
      onOpenSource: switch (node.bindings[prop]) {
        ParamRef(:var name) when onOpenParam != null => () => onOpenParam!(
          name,
        ),
        _ => null,
      },
      onReset: () => editor.resetToStyle(node, prop),
      child: control,
    );
  }

  /// Where [prop] of [node] gets its value. A binding beats a style: the
  /// style is what the node would otherwise say, and a bound property says
  /// nothing of its own at all.
  PropertyOrigin _originOf(SceneNode node, String prop) {
    switch (node.bindings[prop]) {
      case ParamRef() || ItemRef():
        return PropertyOrigin.parameter;
      case TokenRef(:var name):
        return doc.tokenNamed(name)?.isExport == true
            ? PropertyOrigin.appValue
            : PropertyOrigin.token;
      case StyleRef(:var name):
        return doc.tokenNamed(name)?.isExport == true
            ? PropertyOrigin.appValue
            : PropertyOrigin.token;
      case null:
        break;
    }
    if (styleOf(doc, node)?.sets(prop) ?? false) return PropertyOrigin.style;
    return PropertyOrigin.own;
  }

  /// What the row names as the source: a parameter by its bare name, a token
  /// the way a scene file spells it.
  String? _sourceOf(SceneNode node, String prop) {
    if (styleOf(doc, node)?.sets(prop) ?? false) {
      if (node.bindings[prop] == null) {
        return switch (node.bindings[styleBindingKey]) {
          StyleRef(:var name) => name,
          _ => null,
        };
      }
    }
    return switch (node.bindings[prop]) {
      ParamRef(:var name) => name,
      ItemRef(:var list, :var field) => '$list.$field',
      TokenRef(:var name) => 'tokens.$name',
      StyleRef(:var name) => 'tokens.$name',
      null => null,
    };
  }

  /// Make a parameter of a property, bind it to one that exists, or bind it
  /// to a token. Reached from the row's plug, and still from a right-click
  /// anywhere on the row.
  void _bindMenu(BuildContext context, SceneNode node, String prop, Offset at) {
    var sources = sceneBindSources(doc, node, prop);
    if (sources.isEmpty) return;
    var bound = node.bindings[prop];
    showContextMenu(context, at, [
      MenuHeader(_propLabel(prop)),
      if (bound != null) ...[
        MenuItem('Reads $bound', icon: Icons.link),
        MenuItem(
          'Its own values',
          icon: Icons.link_off,
          onSelected: () => editor.unbind(node, prop),
        ),
      ] else ...[
        if (sources.canPromote)
          MenuItem(
            'Make a parameter',
            icon: Icons.add,
            shortcut: editor.freeParamName(prop),
            onSelected: () => editor.promote(node, prop),
          ),
        if (sources.params.isNotEmpty) ...[
          const MenuDivider(),
          const MenuHeader('Bind to'),
          for (var p in sources.params)
            MenuItem(
              p.name,
              icon: Icons.link,
              onSelected: () => editor.bind(node, prop, p.name),
            ),
        ],
        // The package's shared values, of this property's type. What it is
        // rides along as the shortcut, so a colour can be picked by its
        // value and a style by what it sets — not only by their names.
        if (sources.tokens.isNotEmpty) ...[
          const MenuDivider(),
          const MenuHeader('Tokens'),
          for (var t in sources.tokens)
            MenuItem(
              'tokens.${t.name}',
              icon: Icons.style_outlined,
              shortcut: _tokenValue(t),
              onSelected: () => _bindToken(node, prop, t),
            ),
        ],
        // The app's own values of this type: a name to pick, and the canvas
        // to see the result on — the editor holds no value.
        if (sources.exports.isNotEmpty) ...[
          const MenuDivider(),
          const MenuHeader('From the app'),
          for (var t in sources.exports)
            MenuItem(
              'tokens.${t.name}',
              icon: Icons.ios_share_outlined,
              shortcut: t.type,
              onSelected: () => _bindToken(node, prop, t),
            ),
        ],
      ],
    ]);
  }

  /// A style is applied — every property it sets lands on the node and stays
  /// the node's to override — where an ordinary token is bound.
  void _bindToken(SceneNode node, String prop, SceneTokenDecl t) =>
      resolveSceneKey(node, prop)?.prop.kind == ScenePropKind.style
      ? editor.applyStyle(node, t.name)
      : editor.bindToken(node, prop, t.name);

  /// A token's value, short enough for a menu's right edge.
  static String _tokenValue(SceneTokenDecl t) {
    if (t.style case var style?) {
      return 'sets ${style.values.keys.map(_propLabel).join(' · ')}';
    }
    return _valueLabel(t.value);
  }

  /// A value, short enough to ride beside a name — in a bound row's chip
  /// and at a menu's right edge.
  static String _valueLabel(Object? value) => switch (value) {
    SceneColor c =>
      '#${c.argb.toRadixString(16).toUpperCase().padLeft(8, '0').substring(2)}',
    double d when d.isInfinite => 'fill',
    double d => d == d.roundToDouble() ? '${d.round()}' : d.toStringAsFixed(2),
    bool b => b ? 'on' : 'off',
    String t => t.length > 18 ? "'${t.substring(0, 17)}…'" : "'$t'",
    var v => '$v',
  };

  /// A size, in the three states one can be in: a number, hug, or fill.
  ///
  /// The mode is a word you tap rather than a picker, because the three live
  /// in a 96 pixel column beside a number, and the word is also the answer to
  /// "what is this doing" — which a dropdown showing the same word would only
  /// repeat. It rides in the row's trailing slot, beside the plug.
  Widget _size(
    BuildContext context,
    String label,
    SceneNode node,
    String prop,
    double? value, {
    required bool horizontal,
    required void Function(double?) onChanged,
  }) {
    var mode = value == null
        ? _SizeMode.hug
        : value.isInfinite
        ? _SizeMode.fill
        : _SizeMode.fixed;
    var warning = _sizeWarning(node, mode, horizontal: horizontal);
    var colors = context.colors;
    return _prop(
      context,
      node,
      prop,
      label,
      Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (mode == _SizeMode.fixed)
            SceneScrubNumber(
              value: value!,
              shape: SceneNumberShape.pixels,
              onChanged: (v) => _door(label, () => onChanged(v)),
              onCommit: (v) {
                _door(label, () => onChanged(v));
                editor.endMerge();
              },
            )
          else
            // Hugging or filling, the box has no number to edit — so it says
            // what the layout arrived at instead of repeating the mode word
            // that is already on the line above it.
            Container(
              height: 27,
              alignment: Alignment.centerLeft,
              padding: const EdgeInsets.symmetric(horizontal: FwSpacing.md),
              decoration: BoxDecoration(
                border: Border.all(color: colors.line),
                borderRadius: BorderRadius.circular(context.radii.radiusSmall),
              ),
              child: Text(switch (node.measured) {
                null => '—',
                var r => '${_pt(horizontal ? r.width : r.height)} px',
              }, style: context.type.body.copyWith(color: colors.mut3)),
            ),
          if (warning != null)
            Padding(
              padding: const EdgeInsets.only(top: FwSpacing.xs),
              child: Text(
                warning,
                style: context.type.micro.copyWith(color: colors.red),
              ),
            ),
        ],
      ),
      trailing: GestureDetector(
        onTapDown: (d) => showContextMenu(context, d.globalPosition, [
          for (var option in _SizeMode.values)
            MenuItem(
              option.label,
              icon: option == mode ? Icons.check : null,
              onSelected: () => _door(
                label,
                () => onChanged(switch (option) {
                  _SizeMode.hug => null,
                  _SizeMode.fill => double.infinity,
                  // Back from hug or fill to a number: the measured size, so
                  // the box does not jump when you pin it.
                  _SizeMode.fixed => _measuredOf(node, horizontal: horizontal),
                }),
              ),
            ),
        ]),
        child: Text(
          mode.label,
          style: context.type.caption.copyWith(
            color: warning == null ? colors.accent : colors.red,
          ),
        ),
      ),
    );
  }

  /// What the node is actually that big, so pinning a hugging box to a
  /// number starts from what is on screen.
  double _measuredOf(SceneNode node, {required bool horizontal}) {
    var rect = node.measured;
    if (rect == null) return 100;
    return _half(horizontal ? rect.width : rect.height);
  }

  /// The two ways a size can be a contradiction, in the author's words.
  ///
  /// Neither is a renderer bug: the renderer does the honest thing and this
  /// is where it gets said, because an author who cannot see why a fill did
  /// nothing will go looking in the wrong place.
  String? _sizeWarning(
    SceneNode node,
    _SizeMode mode, {
    required bool horizontal,
  }) {
    var parent = doc.parentOf(node);
    // Two nodes sit inside a table and neither owns its own width: a row is
    // placed entirely by the table, and a cell is as wide as its column. A
    // size set here is not honoured, and looking ignored is worse than
    // being refused in words.
    if (parent != null && parent.layout == NodeLayout.table) {
      return mode == _SizeMode.hug ? null : '${parent.name} lays this out';
    }
    var table = parent == null ? null : doc.parentOf(parent);
    if (table != null &&
        table.layout == NodeLayout.table &&
        horizontal &&
        mode != _SizeMode.hug) {
      var index = parent!.children.indexOf(node);
      return 'column ${index + 1} of ${table.name} decides this';
    }
    if (mode == _SizeMode.fill) {
      if (parent == null || parent.layout == NodeLayout.absolute) {
        return horizontal
            ? null
            : null; // free parents give a box; fill is legal there
      }
      var alongParentsMain = (parent.layout == NodeLayout.row) == horizontal;
      if (!alongParentsMain) return null;
      var parentSize = horizontal ? parent.width : parent.height;
      if (parentSize == null) {
        return 'nothing to fill: ${parent.name} hugs this axis';
      }
      return null;
    }
    if (mode == _SizeMode.hug &&
        node is FrameNode &&
        node.layout == NodeLayout.absolute &&
        node.children.isNotEmpty) {
      return 'a free frame takes the room it is given';
    }
    return null;
  }

  /// Two or three property rows across. Each owns its own bottom rhythm, so
  /// this only distributes the width.
  Widget _row(List<Widget> children) => Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      for (var (index, child) in children.indexed) ...[
        if (index > 0) const SizedBox(width: FwSpacing.md),
        Expanded(child: child),
      ],
    ],
  );

  /// Where one group of properties ends and the next begins. A panel of
  /// thirty controls with nothing but vertical rhythm between them is the
  /// reason a reader cannot tell where a field starts.
  Widget _section(BuildContext context, String title) => Padding(
    padding: const EdgeInsets.only(top: FwSpacing.md, bottom: FwSpacing.md),
    child: Row(
      children: [
        Text(title, style: context.type.bodyStrong),
        const Gap(FwSpacing.md),
        Expanded(child: Divider(height: 1, color: context.colors.line)),
      ],
    ),
  );

  static String _sectionOf(SceneNode node) => switch (node) {
    TextNode() => 'Text',
    FrameNode() => 'Frame',
    ShapeNode() => 'Shape',
    ExternalNode() => 'Widget',
    SceneRefNode() => 'Scene',
    KindNode k => k.kind.constructor,
  };

  Widget _label(BuildContext context, String text) => Padding(
    padding: const EdgeInsets.only(bottom: FwSpacing.xs),
    child: Text(
      text,
      style: context.type.caption.copyWith(color: context.colors.mut2),
    ),
  );

  /// A text is two arguments — `TextNode(text, style: …)` — and the panel
  /// says so: the content, then everything the style carries, inside one
  /// railed block under its own header. Which properties ARE the style was
  /// the thing a reader could not see; a fold called *More type* holding
  /// four of them did not help.
  List<Widget> _textProps(BuildContext context, TextNode t) => [
    _prop(
      context,
      t,
      'text',
      'Content',
      TextFormField(
        // Keyed on the binding too: binding rewrites the text from outside
        // this field, and a field keeps its own buffer otherwise.
        key: ValueKey('text:${t.name}:${t.bindings['text']}'),
        initialValue: t.text,
        maxLines: 3,
        minLines: 1,
        onChanged: (v) => _door('text', () => t.text = v),
      ),
    ),
    // A paragraph of runs shows as its joined string, and typing here
    // collapses it — which is what typing into one field means, and is worth
    // saying before it happens rather than after.
    if (t.runs.length > 1)
      Padding(
        padding: const EdgeInsets.only(bottom: FwSpacing.md),
        child: Text(
          '${t.runs.length} runs — typing here makes them one',
          style: context.type.caption.copyWith(color: context.colors.mut2),
        ),
      ),
    // The paragraph's own: where the lines break and how they sit in the
    // box. Two texts in one display face routinely differ on both, which is
    // why a shared style does not decide them.
    _row([
      _choice(t, 'align', 'Align', t.align, const [
        FwChoice(value: SceneTextAlign.left, label: 'Left'),
        FwChoice(value: SceneTextAlign.center, label: 'Center'),
        FwChoice(value: SceneTextAlign.right, label: 'Right'),
        FwChoice(value: SceneTextAlign.justify, label: 'Justify'),
      ], (v) => _door('align', () => t.align = v)),
      _number(
        'maxLines',
        'Max lines',
        (t.maxLines ?? 0).toDouble(),
        const SceneNumberShape(perPixel: 0.1, decimals: 0, min: 0, softMax: 10),
        apply: (v) => t.maxLines = v < 1 ? null : v.round(),
      ),
    ]),
    ..._styleHeader(context, t),
    Container(
      margin: const EdgeInsets.only(bottom: FwSpacing.md),
      padding: const EdgeInsets.only(left: FwSpacing.md),
      decoration: BoxDecoration(
        border: Border(left: BorderSide(color: context.colors.line)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: _styleFields(context, t),
      ),
    ),
  ];

  /// Every field a [SceneTextStyle] carries, in the order they are reached
  /// for. Nothing is behind a fold but the decoration family, which is four
  /// properties nobody sets one of.
  List<Widget> _styleFields(BuildContext context, TextNode t) => [
    _prop(
      context,
      t,
      'fontFamily',
      'Typeface',
      TextFormField(
        key: ValueKey('family:${t.name}:${t.bindings['fontFamily']}'),
        initialValue: t.fontFamily ?? '',
        decoration: const InputDecoration(hintText: "the app's own"),
        onChanged: (v) => _door(
          'fontFamily',
          () => t.fontFamily = v.trim().isEmpty ? null : v.trim(),
        ),
      ),
    ),
    // A variable face's own weight axis replaces the five named weights: one
    // control means one thing, and where the font runs 100 to 900 continuously
    // a picker with five stops is a worse instrument, not a simpler one.
    _row([
      _number(
        'fontSize',
        'Size',
        _shown(t, 'fontSize', t.fontSize),
        SceneNumberShape.of(propSpecFor(t, 'fontSize')),
        apply: (v) => t.fontSize = v,
      ),
      if (_axisNamed(t, 'wght') case var axis?)
        _axisField(context, t, axis)
      else
        _choice(t, 'weight', 'Weight', t.weight, const [
          FwChoice(value: SceneFontWeight.w400, label: 'Regular'),
          FwChoice(value: SceneFontWeight.w500, label: 'Medium'),
          FwChoice(value: SceneFontWeight.w600, label: 'Semibold'),
          FwChoice(value: SceneFontWeight.w700, label: 'Bold'),
          FwChoice(value: SceneFontWeight.w900, label: 'Black'),
        ], (v) => _door('weight', () => t.weight = v)),
    ]),
    // The rest of the face's dials, each with the font's own range. Nothing
    // is drawn for a static family, which is every family until one says
    // otherwise.
    for (var axis in _axesOf(t))
      if (axis.tag != 'wght') _axisField(context, t, axis),
    // Slant is a face, so it sits with the face; Case transforms the words,
    // and the pair is what a display line is set with.
    _row([
      _choice(t, 'italic', 'Slant', t.italic, const [
        FwChoice(value: false, label: 'Roman'),
        FwChoice(value: true, label: 'Italic'),
      ], (v) => _door('italic', () => t.italic = v)),
      _choice(t, 'textCase', 'Case', t.textCase, const [
        FwChoice(value: SceneTextCase.none, label: 'As typed'),
        FwChoice(value: SceneTextCase.upper, label: 'UPPER'),
        FwChoice(value: SceneTextCase.lower, label: 'lower'),
        FwChoice(value: SceneTextCase.title, label: 'Title'),
      ], (v) => _door('textCase', () => t.textCase = v)),
    ]),
    // Tracking and leading, together: they are read together and a display
    // size wants both moved at once.
    _row([
      _number(
        'letterSpacing',
        'Tracking',
        _shown(t, 'letterSpacing', t.letterSpacing),
        SceneNumberShape.of(propSpecFor(t, 'letterSpacing')),
        apply: (v) => t.letterSpacing = v,
      ),
      _number(
        'lineHeight',
        'Leading',
        _shown(t, 'lineHeight', t.lineHeight),
        SceneNumberShape.of(propSpecFor(t, 'lineHeight')),
        apply: (v) => t.lineHeight = v,
      ),
    ]),
    _number(
      'wordSpacing',
      'Word spacing',
      _shown(t, 'wordSpacing', t.wordSpacing),
      SceneNumberShape.of(propSpecFor(t, 'wordSpacing')),
      apply: (v) => t.wordSpacing = v,
    ),
    _prop(
      context,
      t,
      'color',
      'Color',
      SceneColorField(
        current: _shown(t, 'color', t.color),
        allowNone: false,
        onPick: (c) => _set('color', c!, () => t.color = c),
      ),
    ),
    SceneLayerList(
      layers: t.layers,
      fontSize: t.fontSize,
      color: Color(t.color.argb),
      marker: PropertyOriginMark(
        origin: _originOf(t, 'layers'),
        sourceName: _sourceOf(t, 'layers'),
        overridden: !inheritsFromStyle(doc, t, 'layers'),
        onReset: () => editor.resetToStyle(t, 'layers'),
      ),
      shaders: shaders,
      onChanged: (next, {required label, mergeKey}) =>
          editor.perform(label, () => t.layers = next, mergeKey: mergeKey),
    ),
    const SizedBox(height: FwSpacing.md),
    // Four properties nobody sets one of, behind the word that names them.
    Disclosure(
      label: 'Decoration',
      initiallyOpen: t.decoration != SceneTextDecoration.none,
      children: [
        _choice(t, 'decoration', 'Line', t.decoration, const [
          FwChoice(value: SceneTextDecoration.none, label: 'None'),
          FwChoice(value: SceneTextDecoration.underline, label: 'Underline'),
          FwChoice(value: SceneTextDecoration.overline, label: 'Overline'),
          FwChoice(
            value: SceneTextDecoration.lineThrough,
            label: 'Strikethrough',
          ),
        ], (v) => _door('decoration', () => t.decoration = v)),
        if (t.decoration != SceneTextDecoration.none) ...[
          _row([
            _choice(
              t,
              'decorationStyle',
              'Line style',
              t.decorationStyle,
              const [
                FwChoice(value: SceneTextDecorationStyle.solid, label: 'Solid'),
                FwChoice(
                  value: SceneTextDecorationStyle.double,
                  label: 'Double',
                ),
                FwChoice(
                  value: SceneTextDecorationStyle.dotted,
                  label: 'Dotted',
                ),
                FwChoice(
                  value: SceneTextDecorationStyle.dashed,
                  label: 'Dashed',
                ),
                FwChoice(value: SceneTextDecorationStyle.wavy, label: 'Wavy'),
              ],
              (v) => _door('decorationStyle', () => t.decorationStyle = v),
            ),
            _number(
              'decorationThickness',
              'Line thickness',
              _shown(t, 'decorationThickness', t.decorationThickness),
              SceneNumberShape.of(propSpecFor(t, 'decorationThickness')),
              apply: (v) => t.decorationThickness = v,
            ),
          ]),
          _prop(
            context,
            t,
            'decorationColor',
            'Line color',
            SceneColorField(
              current: t.decorationColor,
              onPick: (c) =>
                  _door('decorationColor', () => t.decorationColor = c),
            ),
          ),
        ],
      ],
    ),
  ];

  /// The block's own header, and the shared style it reads — which is one
  /// property row like every other, because that is what it is. It used to
  /// be a dropdown, and the dropdown was the reason a reader could not tell
  /// whether a style was a binding: it looked like a control that set a
  /// value, listed its options with a second line nobody could read, and
  /// shared no vocabulary with the plug on every field under it.
  List<Widget> _styleHeader(BuildContext context, TextNode t) {
    var boundDecl = switch (t.bindings[styleBindingKey]) {
      StyleRef(:var name) => doc.tokenNamed(name),
      _ => null,
    };
    return [
      _prop(
        context,
        t,
        styleBindingKey,
        'Text style',
        const SizedBox.shrink(),
        strongLabel: true,
      ),
      // An export's style: the app's own, laid under the values here by the
      // canvas. Nothing to inherit or reset — what is set here is set.
      if (boundDecl?.isExport == true)
        Padding(
          padding: const EdgeInsets.only(bottom: FwSpacing.md),
          child: Text(
            "the app's ${boundDecl!.type}, under the values here",
            style: context.type.caption.copyWith(color: context.colors.mut2),
          ),
        ),
    ];
  }

  List<Widget> _frameProps(BuildContext context, FrameNode f) => [
    _check(
      context,
      f,
      'clip',
      'Clip children at the edge',
      f.clip,
      () => _door('clip', () => f.clip = !f.clip),
    ),
    _choice(
      f,
      'layout',
      'Layout',
      f.layout,
      const [
        FwChoice(value: NodeLayout.absolute, label: 'Free'),
        FwChoice(value: NodeLayout.row, label: 'Row'),
        FwChoice(value: NodeLayout.column, label: 'Column'),
        FwChoice(
          value: NodeLayout.table,
          label: 'Table',
          detail: 'children are rows, their children are cells',
        ),
      ],
      // A layout switch is a geometry transaction, not a flag flip: entering
      // Free bakes each child's measured position into authored x/y; entering
      // a flex re-derives order from visual position.
      (next) => _door('layout', () {
        var origin = f.measured;
        if (next == NodeLayout.absolute) {
          for (var c in f.children) {
            var rect = c.measured;
            if (rect != null) {
              // A measured position carries the layout's float noise;
              // what gets authored is a half-pixel, not 32.180908203125.
              c.x = _half(rect.left - (origin?.left ?? 0));
              c.y = _half(rect.top - (origin?.top ?? 0));
            }
          }
        } else {
          f.children.sort((a, b) {
            var ra = a.measured, rb = b.measured;
            if (ra == null || rb == null) return 0;
            return next == NodeLayout.row
                ? ra.left.compareTo(rb.left)
                : ra.top.compareTo(rb.top);
          });
        }
        f.layout = next;
      }),
    ),
    if (f.layout == NodeLayout.table) ...[
      ..._tableProps(context, f),
    ] else
      _row([
        _number(
          'gap',
          'Gap',
          _shown(f, 'gap', f.gap),
          SceneNumberShape.of(propSpecFor(f, 'gap')),
          apply: (v) => f.gap = v,
        ),
      ]),
    // Four sides, one property: an edges binding sets them together, so the
    // plug belongs to the group and each side is a plain field.
    _prop(
      context,
      f,
      'padding',
      'Padding',
      Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          _row([
            _side(
              'padding',
              'Left',
              f.padding.left,
              apply: (v) => f.padding = f.padding.copyWith(left: v),
            ),
            _side(
              'padding',
              'Top',
              f.padding.top,
              apply: (v) => f.padding = f.padding.copyWith(top: v),
            ),
          ]),
          const SizedBox(height: FwSpacing.md),
          _row([
            _side(
              'padding',
              'Right',
              f.padding.right,
              apply: (v) => f.padding = f.padding.copyWith(right: v),
            ),
            _side(
              'padding',
              'Bottom',
              f.padding.bottom,
              apply: (v) => f.padding = f.padding.copyWith(bottom: v),
            ),
          ]),
        ],
      ),
    ),
    if (f.layout == NodeLayout.table) ...[
      _choice(f, 'crossAlign', 'Cells sit', f.crossAlign, const [
        FwChoice(value: SceneCrossAxisAlignment.start, label: 'Top'),
        FwChoice(value: SceneCrossAxisAlignment.center, label: 'Middle'),
        FwChoice(value: SceneCrossAxisAlignment.end, label: 'Bottom'),
        FwChoice(
          value: SceneCrossAxisAlignment.stretch,
          label: 'Filling the row',
        ),
      ], (v) => _door('crossAlign', () => f.crossAlign = v)),
    ] else if (f.layout != NodeLayout.absolute) ...[
      // Both axes, always, and each says when it has nothing to do. Cross
      // align alone was read as "align the contents", which is what main
      // align does — and a frame that hugs the axis it is aligning on has
      // no spare room, so every option looks the same and the control
      // looks broken.
      _prop(
        context,
        f,
        'mainAlign',
        'Main align',
        Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            _alignNote(context, f, main: true),
            FwPicker<SceneMainAxisAlignment>(
              selected: f.mainAlign,
              choices: const [
                FwChoice(value: SceneMainAxisAlignment.start, label: 'Start'),
                FwChoice(value: SceneMainAxisAlignment.center, label: 'Center'),
                FwChoice(value: SceneMainAxisAlignment.end, label: 'End'),
                FwChoice(
                  value: SceneMainAxisAlignment.spaceBetween,
                  label: 'Space between',
                ),
                FwChoice(
                  value: SceneMainAxisAlignment.spaceAround,
                  label: 'Space around',
                ),
                FwChoice(
                  value: SceneMainAxisAlignment.spaceEvenly,
                  label: 'Space evenly',
                ),
              ],
              onChanged: (v) => _door('mainAlign', () => f.mainAlign = v),
            ),
          ],
        ),
      ),
      _prop(
        context,
        f,
        'crossAlign',
        'Cross align',
        Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            _alignNote(context, f, main: false),
            FwPicker<SceneCrossAxisAlignment>(
              selected: f.crossAlign,
              choices: const [
                FwChoice(value: SceneCrossAxisAlignment.start, label: 'Start'),
                FwChoice(
                  value: SceneCrossAxisAlignment.center,
                  label: 'Center',
                ),
                FwChoice(value: SceneCrossAxisAlignment.end, label: 'End'),
                FwChoice(
                  value: SceneCrossAxisAlignment.stretch,
                  label: 'Stretch',
                ),
              ],
              onChanged: (v) => _door('crossAlign', () => f.crossAlign = v),
            ),
          ],
        ),
      ),
    ],
  ];

  /// What a repeat is, when the selected frame is one.
  ///
  /// Read-only, and honestly so: the rule is a closure in the file, and
  /// turning a frame into a repeat means writing one. There is no gesture
  /// here that could — so rather than a control that lies, this says what
  /// the frame is drawn from and how many times.
  List<Widget> _repeat(BuildContext context, SceneNode node) {
    if (node is! FrameNode) return const [];
    var source = node.repeated?.source;
    if (source == null || source.isEmpty) return const [];
    var items = doc.itemsOf(source);
    var fields = items.isEmpty ? '' : items.first.keys.join(' · ');
    return [
      const SizedBox(height: FwSpacing.md),
      _label(context, 'Repeat'),
      Text(
        items.isEmpty
            ? 'once per $source — no items, so nothing is drawn'
            : 'once per $source — ${items.length} rows, this one the first',
        style: context.type.caption,
      ),
      if (fields.isNotEmpty)
        Padding(
          padding: const EdgeInsets.only(top: FwSpacing.xxs),
          child: Text(
            'each item carries $fields',
            style: context.type.micro.copyWith(color: context.colors.mut2),
          ),
        ),
      Padding(
        padding: const EdgeInsets.only(top: FwSpacing.xs),
        child: Text(
          'The cells are written inline in the file and have no names, so '
          'they are edited there rather than here.',
          style: context.type.micro.copyWith(color: context.colors.mut2),
        ),
      ),
    ];
  }

  /// A table's own controls: the column tracks, and the room inside a cell.
  ///
  /// The tracks are the table — a column that hugs is as wide as the widest
  /// cell in ANY row, which is the thing stacked rows cannot do — so they
  /// come first, before anything about one cell.
  List<Widget> _tableProps(BuildContext context, FrameNode f) {
    var widest = 0;
    for (var row in f.children) {
      if (row.children.length > widest) widest = row.children.length;
    }
    return [
      Row(
        children: [
          Expanded(child: _label(context, 'Columns')),
          Tappable(
            onTap: () =>
                _door('columns', () => f.columns = [...f.columns, null]),
            child: Icon(
              Icons.add,
              size: FwIconSize.md,
              color: context.colors.accent,
            ),
          ),
        ],
      ),
      if (f.columns.length < widest)
        Padding(
          padding: const EdgeInsets.only(bottom: FwSpacing.xs),
          child: Text(
            '$widest cells in the widest row — '
            '${widest - f.columns.length} column'
            '${widest - f.columns.length == 1 ? '' : 's'} '
            'undeclared, and hugging',
            style: context.type.micro.copyWith(color: context.colors.mut2),
          ),
        ),
      for (var i = 0; i < f.columns.length; i++) _column(context, f, i),
      const SizedBox(height: FwSpacing.md),
      _label(context, 'Cell padding'),
      _row([
        _number(
          'cellPadding',
          'Left',
          f.cellPadding.left,
          SceneNumberShape.pixels,
          apply: (v) => f.cellPadding = f.cellPadding.copyWith(left: v),
        ),
        _number(
          'cellPadding',
          'Top',
          f.cellPadding.top,
          SceneNumberShape.pixels,
          apply: (v) => f.cellPadding = f.cellPadding.copyWith(top: v),
        ),
      ]),
      _row([
        _number(
          'cellPadding',
          'Right',
          f.cellPadding.right,
          SceneNumberShape.pixels,
          apply: (v) => f.cellPadding = f.cellPadding.copyWith(right: v),
        ),
        _number(
          'cellPadding',
          'Bottom',
          f.cellPadding.bottom,
          SceneNumberShape.pixels,
          apply: (v) => f.cellPadding = f.cellPadding.copyWith(bottom: v),
        ),
      ]),
    ];
  }

  /// One column track, in the same three words a node's size uses.
  Widget _column(BuildContext context, FrameNode f, int index) {
    var value = f.columns[index];
    var mode = value == null
        ? _SizeMode.hug
        : value.isInfinite
        ? _SizeMode.fill
        : _SizeMode.fixed;
    void set(double? v) =>
        _door('columns', () => f.columns = [...f.columns]..[index] = v);
    return Padding(
      padding: const EdgeInsets.only(bottom: FwSpacing.sm),
      child: Row(
        children: [
          SizedBox(
            width: 20,
            child: Text(
              '${index + 1}',
              style: context.type.caption.copyWith(color: context.colors.mut2),
            ),
          ),
          Expanded(
            child: mode == _SizeMode.fixed
                ? SceneScrubNumber(
                    value: value!,
                    shape: SceneNumberShape.pixels,
                    onChanged: set,
                    onCommit: (v) {
                      set(v);
                      editor.endMerge();
                    },
                  )
                : Text(
                    mode == _SizeMode.hug
                        ? 'as wide as its widest cell'
                        : 'what is left',
                    style: context.type.caption.copyWith(
                      color: context.colors.mut2,
                    ),
                  ),
          ),
          const SizedBox(width: FwSpacing.sm),
          GestureDetector(
            onTapDown: (d) => showContextMenu(context, d.globalPosition, [
              for (var option in _SizeMode.values)
                MenuItem(
                  option.label,
                  icon: option == mode ? Icons.check : null,
                  onSelected: () => set(switch (option) {
                    _SizeMode.hug => null,
                    _SizeMode.fill => double.infinity,
                    _SizeMode.fixed => 96,
                  }),
                ),
              MenuItem(
                'Remove',
                onSelected: () => _door(
                  'columns',
                  () => f.columns = [...f.columns]..removeAt(index),
                ),
              ),
            ]),
            child: Text(
              mode.label,
              style: context.type.caption.copyWith(
                color: context.colors.accent,
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Says when an alignment has no room to move anything: the frame hugs
  /// that axis, so every option lands in the same place.
  Widget _alignNote(BuildContext context, FrameNode f, {required bool main}) {
    var horizontal = (f.layout == NodeLayout.row) == main;
    var size = horizontal ? f.width : f.height;
    if (size != null) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: FwSpacing.xs),
      child: Text(
        'no room: ${f.name} hugs its ${horizontal ? 'width' : 'height'}',
        style: context.type.micro.copyWith(color: context.colors.mut2),
      ),
    );
  }

  List<Widget> _shapeProps(BuildContext context, ShapeNode s) => [
    _check(
      context,
      s,
      'circle',
      'Circle',
      s.circle,
      () => _door('circle', () => s.circle = !s.circle),
    ),
  ];

  /// A number, in points, with no row of its own.
  static String _pt(double v) =>
      v == v.roundToDouble() ? '${v.round()}' : v.toStringAsFixed(1);

  /// Min and max width and height, behind a section most nodes never open.
  ///
  /// Opening it shows fields; it does not WRITE one. The old word set
  /// `minWidth` to the measured width so that the section's own visibility
  /// test would pass — a document edit, an undo entry, and no way back short
  /// of clearing all four by hand.
  List<Widget> _bounds(BuildContext context, SceneNode node) {
    var set = [
      if (node.minWidth != null) 'min W ${_pt(node.minWidth!)}',
      if (node.maxWidth != null) 'max W ${_pt(node.maxWidth!)}',
      if (node.minHeight != null) 'min H ${_pt(node.minHeight!)}',
      if (node.maxHeight != null) 'max H ${_pt(node.maxHeight!)}',
    ];
    Widget bound(
      String prop,
      String label,
      double? value,
      void Function(double?) set,
    ) => _number(
      prop,
      '$label (0 = none)',
      value ?? 0,
      SceneNumberShape.pixels,
      apply: (v) => set(v <= 0 ? null : v),
    );
    return [
      Disclosure(
        label: set.isEmpty ? 'Size limits' : 'Size limits · ${set.join(' · ')}',
        initiallyOpen: set.isNotEmpty,
        children: [
          _row([
            bound('minWidth', 'Min W', node.minWidth, (v) => node.minWidth = v),
            bound('maxWidth', 'Max W', node.maxWidth, (v) => node.maxWidth = v),
          ]),
          _row([
            bound(
              'minHeight',
              'Min H',
              node.minHeight,
              (v) => node.minHeight = v,
            ),
            bound(
              'maxHeight',
              'Max H',
              node.maxHeight,
              (v) => node.maxHeight = v,
            ),
          ]),
        ],
      ),
    ];
  }

  /// The corners one by one, behind a section: most nodes never open it, and
  /// the ones that do can close it again.
  List<Widget> _corners(BuildContext context, SceneNode node) {
    var c = node.corners;
    Widget corner(
      String prop,
      String label,
      double value,
      SceneCorners Function(double) set,
    ) => _number(
      prop,
      label,
      value,
      SceneNumberShape.pixels,
      apply: (v) => node.corners = set(v),
    );
    return [
      Disclosure(
        label: c.isUniform
            ? 'Corners one by one'
            : 'Corners · ${_pt(c.topLeft)} · ${_pt(c.topRight)} · '
                  '${_pt(c.bottomRight)} · ${_pt(c.bottomLeft)}',
        initiallyOpen: !c.isUniform,
        children: [
          _row([
            corner(
              'cornerTopLeft',
              'Top left',
              c.topLeft,
              (v) => c.copyWith(topLeft: v),
            ),
            corner(
              'cornerTopRight',
              'Top right',
              c.topRight,
              (v) => c.copyWith(topRight: v),
            ),
          ]),
          _row([
            corner(
              'cornerBottomLeft',
              'Bottom left',
              c.bottomLeft,
              (v) => c.copyWith(bottomLeft: v),
            ),
            corner(
              'cornerBottomRight',
              'Bottom right',
              c.bottomRight,
              (v) => c.copyWith(bottomRight: v),
            ),
          ]),
          if (!c.isUniform)
            Padding(
              padding: const EdgeInsets.only(bottom: FwSpacing.md),
              child: Tappable(
                onTap: () => _door(
                  'corner',
                  () => node.corners = SceneCorners.all(c.topLeft),
                ),
                child: Text(
                  'make them all ${_pt(c.topLeft)}',
                  style: context.type.caption.copyWith(
                    color: context.colors.accent,
                  ),
                ),
              ),
            ),
        ],
      ),
    ];
  }

  /// A boolean, on the label's own line: the word is the row's label and
  /// this is only the box, so a checkbox costs one line rather than three.
  Widget _check(
    BuildContext context,
    SceneNode node,
    String prop,
    String label,
    bool value,
    VoidCallback onTap,
  ) => _prop(
    context,
    node,
    prop,
    label,
    _checkBox(context, value, onTap),
    inline: true,
  );

  Widget _checkBox(BuildContext context, bool value, VoidCallback onTap) =>
      Tappable(
        onTap: onTap,
        child: Icon(
          value ? Icons.check_box : Icons.check_box_outline_blank,
          size: FwIconSize.md,
          color: value ? context.colors.accent : context.colors.mut2,
        ),
      );

  /// A registered kind's rows, laid out from the table: a number scrubs
  /// with the row's own unit, range and dial, a string types, a boolean
  /// checks, a choice picks. The first table-driven section, and what the
  /// next kind's inspector costs: nothing.
  List<Widget> _kindProps(BuildContext context, KindNode k) => [
    if (k.kind.help case var help?)
      Padding(
        padding: const EdgeInsets.only(bottom: FwSpacing.md),
        child: Text(help, style: context.type.caption),
      ),
    for (var p in k.kind.props)
      if (p.pick case var pick?)
        _pickRow(context, k, p, pick)
      else
        switch (p.kind) {
          ScenePropKind.number => _number(
            p.name,
            p.name,
            _shown(k, p.name, (p.read(k) as num?)?.toDouble() ?? 0),
            SceneNumberShape(
              perPixel: p.angular
                  ? 1
                  : ((p.softMax ?? 100) - (p.softMin ?? 0)) / 200,
              decimals: 2,
              unit: p.unit ?? '',
              angular: p.angular,
              softMin: p.softMin,
              softMax: p.softMax,
            ),
            apply: (v) => p.write(k, v),
          ),
          ScenePropKind.boolean => Padding(
            padding: const EdgeInsets.only(bottom: FwSpacing.md),
            child: _check(
              context,
              k,
              p.name,
              p.name,
              p.read(k) == true,
              () => _door(p.name, () => p.write(k, p.read(k) != true)),
            ),
          ),
          ScenePropKind.choice => Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _label(context, p.name),
              FwPicker<Object>(
                selected: p.read(k) ?? p.defaultValue!,
                choices: [
                  for (var v in p.choices!.values)
                    FwChoice(value: v, label: p.choices!.nameOf(v)),
                ],
                onChanged: (v) => _door(p.name, () => p.write(k, v)),
              ),
              const SizedBox(height: FwSpacing.md),
            ],
          ),
          _ => Padding(
            padding: const EdgeInsets.only(bottom: FwSpacing.md),
            child: TextFormField(
              key: ValueKey('${k.name}:${p.name}'),
              initialValue: '${p.read(k) ?? ''}',
              decoration: InputDecoration(labelText: p.name, isDense: true),
              onChanged: (v) => _door(p.name, () => p.write(k, v)),
            ),
          ),
        },
  ];

  /// A string row whose choices are in the project: the model files under
  /// `assets/`, or the meshes or clips of the one the node's `asset` row
  /// names. A value the project does not have stays pickable — it is what
  /// the file says — and is flagged, with what the asset does carry.
  Widget _pickRow(
    BuildContext context,
    KindNode k,
    SceneProp p,
    ScenePick pick,
  ) {
    var root = packageRoot;
    var current = '${p.read(k) ?? ''}';
    var choices = <FwChoice<String>>[];
    var empty = 'No package to look in.';
    String? missing;
    if (root != null) {
      switch (pick) {
        case ScenePick.modelAsset:
          choices = [
            for (var a in ModelAssets.shared.assets(root))
              FwChoice(value: a, label: paths.basename(a), detail: a),
          ];
          empty = 'No .glb or .gltf under assets/.';
          missing = 'no such file under the package';
        case ScenePick.modelMesh || ScenePick.modelClip:
          var asset = '${scenePropNamed(k, 'asset')?.read(k) ?? ''}';
          var info = asset.isEmpty
              ? null
              : ModelAssets.shared.info(root, asset);
          if (asset.isEmpty) {
            empty = 'Name an asset first.';
          } else if (info == null) {
            empty =
                '${paths.basename(asset)} is not a model file this can read.';
          } else if (pick == ScenePick.modelMesh) {
            choices = [
              const FwChoice(
                value: '',
                label: 'first mesh',
                detail: 'whichever the file lists first',
              ),
              for (var m in info.meshes) FwChoice(value: m, label: m),
            ];
            missing =
                'no mesh "$current" in ${paths.basename(asset)} — it has: '
                '${info.meshes.join(', ')}';
          } else {
            choices = [
              const FwChoice(value: '', label: 'none', detail: 'no clip'),
              for (var c in info.clips)
                FwChoice(
                  value: c.name,
                  label: c.name,
                  detail: '${c.seconds.toStringAsFixed(2)} s',
                ),
            ];
            missing =
                'no clip "$current" in ${paths.basename(asset)} — it has: '
                '${info.clips.map((c) => c.name).join(', ')}';
          }
      }
    }
    var known = current.isEmpty || choices.any((c) => c.value == current);
    if (!known) {
      choices = [
        FwChoice(value: current, label: current, detail: 'not found'),
        ...choices,
      ];
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _label(context, p.name),
        FwPicker<String>(
          selected: current,
          choices: choices,
          empty: empty,
          onChanged: (v) => _door(p.name, () => p.write(k, v)),
        ),
        if (!known && missing != null)
          Padding(
            padding: const EdgeInsets.only(top: FwSpacing.xs),
            child: Text(
              missing,
              style: context.type.caption.copyWith(color: context.colors.red),
            ),
          ),
        const SizedBox(height: FwSpacing.md),
      ],
    );
  }

  /// The widget's declared arguments, each at its override or its default —
  /// the same shape as a nested scene's parameters, because a declaration is
  /// the same promise a scene header makes.
  List<Widget> _extProps(BuildContext context, ExternalNode e) {
    var declared = externals.where((w) => w.entry == e.entry).firstOrNull;
    return [
      _label(context, 'Entry'),
      Text(e.entry, style: context.type.body),
      if (declared == null)
        Padding(
          padding: const EdgeInsets.only(top: FwSpacing.xs),
          child: Text(
            'Not declared in this package',
            style: context.type.caption.copyWith(color: context.colors.red),
          ),
        ),
      const SizedBox(height: FwSpacing.md),
      for (var arg in declared?.args ?? const <ExternalArgDecl>[]) ...[
        if (!isValueArgType(arg.typeName))
          _opaqueArg(context, e, arg)
        else if (arg.typeName == 'double')
          _number(
            'args.${arg.name}',
            arg.name,
            switch (e.args[arg.name] ?? _fallback(arg)) {
              num n => n.toDouble(),
              _ => 0,
            },
            const SceneNumberShape(perPixel: 1, decimals: 2),
            apply: (v) => e.args[arg.name] = v,
          )
        else
          // The label goes above the field like every other row's, not
          // inside it as a Material floating label — one panel, one anatomy.
          _prop(
            context,
            e,
            'args.${arg.name}',
            arg.name,
            TextFormField(
              key: ValueKey('${e.name}:${arg.name}'),
              initialValue: '${e.args[arg.name] ?? _fallback(arg) ?? ''}',
              onChanged: (v) => _door('args', () => e.args[arg.name] = v),
            ),
          ),
      ],
    ];
  }

  /// An argument of the app's own type: nothing the editor can show a value
  /// of, so the row is a picker over the opaque tokens of that type — the
  /// only thing a scene can put there — with `none` for the widget's own
  /// fallback.
  Widget _opaqueArg(BuildContext context, ExternalNode e, ExternalArgDecl arg) {
    var prop = 'args.${arg.name}';
    var bound = switch (e.bindings[prop]) {
      TokenRef(:var name) => name,
      _ => null,
    };
    var tokens = [
      for (var t in doc.tokens)
        if (t.isExport && t.type == arg.typeName) t,
    ];
    return Padding(
      padding: const EdgeInsets.only(bottom: FwSpacing.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _label(context, '${arg.name} · ${arg.typeName}'),
          FwPicker<String?>(
            selected: bound,
            choices: [
              const FwChoice(
                value: null,
                label: 'none',
                detail: "the widget's own",
              ),
              for (var t in tokens)
                FwChoice(value: t.name, label: 'tokens.${t.name}'),
            ],
            empty: 'No ${arg.typeName} token declared in scene_tokens.dart',
            onChanged: (name) => name == null
                ? editor.unbind(e, prop)
                : editor.bindToken(e, prop, name),
          ),
        ],
      ),
    );
  }

  /// The declaration's fallback, as a value. It is kept as source text —
  /// what goes back out as the generated field's default — and only the two
  /// spellings a field shows are read back here.
  Object? _fallback(ExternalArgDecl arg) {
    var text = arg.defaultSource;
    if (text == null) return null;
    if (arg.typeName == 'double') return double.tryParse(text);
    return text.length >= 2 && (text.startsWith("'") || text.startsWith('"'))
        ? text.substring(1, text.length - 1)
        : text;
  }

  /// The selected keys: one key edits time, value and curve; several share a
  /// curve and nothing else, because their values are each their own.
  Widget _keys(BuildContext context) {
    var refs = editor.selectedKeys.toList();
    var colors = context.colors;
    var single = refs.length == 1 ? refs.single : null;
    var key = single == null ? null : editor.keyOf(single);
    var group = single == null
        ? null
        : editor.motions[single.motion]?.groupNamed(single.group);
    var node = group == null ? null : doc.nodeNamed(group.node.name);
    var spec = node == null || single == null
        ? null
        : propSpecFor(node, single.prop);
    var shared = {for (var ref in refs) editor.keyOf(ref)?.curve?.name};
    return ListView(
      key: ValueKey('keys:${refs.join(',')}'),
      padding: const EdgeInsets.all(FwSpacing.lg),
      children: [
        Text(
          single == null
              ? '${refs.length} keys'
              : 'Key · ${single.group}.${_propLabel(single.prop)}',
          style: context.type.bodyStrong,
        ),
        if (group != null)
          Padding(
            padding: const EdgeInsets.only(top: FwSpacing.xxs),
            child: Text(
              'on ${group.node.name}',
              style: context.type.caption.copyWith(color: colors.mut2),
            ),
          ),
        const SizedBox(height: FwSpacing.lg),
        if (single != null && key != null) ...[
          SceneNumberField(
            label: 'Time',
            value: key.at.inMilliseconds.toDouble(),
            shape: SceneNumberShape.milliseconds,
            onChanged: (v) => editor.setKeyTime(
              single,
              Duration(milliseconds: v.round()),
              mergeKey: 'keytime',
            ),
            onCommit: (v) {
              editor.setKeyTime(single, Duration(milliseconds: v.round()));
              editor.endMerge();
            },
          ),
          const SizedBox(height: FwSpacing.md),
          if (key.value case double number)
            SceneNumberField(
              label: 'Value',
              value: number,
              shape: SceneNumberShape.of(spec),
              onChanged: (v) =>
                  editor.setKeyValue(single, v, mergeKey: 'keyvalue'),
              onCommit: (v) {
                editor.setKeyValue(single, v);
                editor.endMerge();
              },
            )
          else if (key.value case SceneColor color) ...[
            _label(context, 'Value'),
            SceneColorField(
              current: color,
              allowNone: false,
              onPick: (c) => editor.setKeyValue(single, c!),
            ),
          ],
          const SizedBox(height: FwSpacing.md),
        ],
        _label(context, 'Ease into this key'),
        SceneCurvePicker(
          name: shared.length == 1 ? shared.single : null,
          // The picker speaks names because a menu is a list of words; the
          // model holds the curve itself.
          onPick: (name) => editor.setKeyCurve(
            refs,
            name == null ? null : sceneCurvesByName[name],
          ),
        ),
        if (shared.length > 1)
          Padding(
            padding: const EdgeInsets.only(top: FwSpacing.xs),
            child: Text(
              'Mixed — picking one sets them all',
              style: context.type.caption.copyWith(color: colors.mut2),
            ),
          ),
        const SizedBox(height: FwSpacing.xl),
        Align(
          alignment: Alignment.centerLeft,
          child: FwActionButton(
            label: refs.length == 1 ? 'Delete' : 'Delete ${refs.length} keys',
            tooltip: 'Also Backspace, with the timeline focused',
            onPressed: () async => editor.deleteKeys(),
          ),
        ),
      ],
    );
  }

  /// The selected clip block: which clip, where it sits, how it plays.
  /// Every fact of a block is a field here; the timeline's menu keeps only
  /// the one-click verbs.
  Widget _block(BuildContext context, MotionClipRef ref) {
    var colors = context.colors;
    var block = editor.clipOf(ref)!;
    var group = editor.motions[ref.motion]!.groupNamed(ref.group)!;
    var node = doc.nodeNamed(group.node.name);
    var asset = node is KindNode
        ? '${scenePropNamed(node, 'asset')?.read(node) ?? ''}'
        : '';
    var rowClip = node is KindNode
        ? '${scenePropNamed(node, 'animation')?.read(node) ?? ''}'
        : '';
    var root = packageRoot;
    var info = root == null || asset.isEmpty
        ? null
        : ModelAssets.shared.info(root, asset);
    var clips = info?.clips ?? const [];
    var known = block.clip.isEmpty || clips.any((c) => c.name == block.clip);
    var choices = <FwChoice<String>>[
      if (!known)
        FwChoice(value: block.clip, label: block.clip, detail: 'not found'),
      FwChoice(
        value: '',
        label: rowClip.isEmpty ? 'the animation row' : rowClip,
        detail: 'whatever the animation row names',
      ),
      for (var c in clips)
        FwChoice(
          value: c.name,
          label: c.name,
          detail: '${c.seconds.toStringAsFixed(2)} s',
        ),
    ];
    void set({
      String? clip,
      Duration? at,
      Duration? length,
      double? speed,
      Duration? offset,
      bool? reverse,
      String? mergeKey,
    }) => editor.setClip(
      ref.motion,
      ref.group,
      ref.prop,
      editor.clipIndexOf(ref)!,
      clip: clip,
      at: at,
      length: length,
      speed: speed,
      offset: offset,
      reverse: reverse,
      mergeKey: mergeKey,
    );
    Widget ms(
      String label,
      Duration value,
      void Function(Duration, {String? mergeKey}) apply,
    ) => SceneNumberField(
      label: label,
      value: value.inMilliseconds.toDouble(),
      shape: SceneNumberShape.milliseconds,
      onChanged: (v) =>
          apply(Duration(milliseconds: v.round()), mergeKey: 'block:$label'),
      onCommit: (v) {
        apply(Duration(milliseconds: v.round()));
        editor.endMerge();
      },
    );
    var clipSeconds = clips
        .where((c) => c.name == (block.clip.isEmpty ? rowClip : block.clip))
        .firstOrNull
        ?.seconds;
    return ListView(
      key: ValueKey('block:$ref'),
      padding: const EdgeInsets.all(FwSpacing.lg),
      children: [
        Text(
          'Block · ${ref.group}.${_propLabel(ref.prop)}',
          style: context.type.bodyStrong,
        ),
        Padding(
          padding: const EdgeInsets.only(top: FwSpacing.xxs),
          child: Text(
            'on ${group.node.name}',
            style: context.type.caption.copyWith(color: colors.mut2),
          ),
        ),
        const SizedBox(height: FwSpacing.lg),
        _label(context, 'Clip'),
        FwPicker<String>(
          selected: block.clip,
          choices: choices,
          empty: asset.isEmpty
              ? 'The placement names no asset.'
              : 'No clips read from ${paths.basename(asset)}.',
          onChanged: (v) => set(clip: v),
        ),
        if (!known)
          Padding(
            padding: const EdgeInsets.only(top: FwSpacing.xs),
            child: Text(
              'no clip "${block.clip}" in ${paths.basename(asset)}',
              style: context.type.caption.copyWith(color: colors.red),
            ),
          ),
        const SizedBox(height: FwSpacing.md),
        ms(
          'Start',
          block.at,
          (v, {mergeKey}) => set(at: v, mergeKey: mergeKey),
        ),
        const SizedBox(height: FwSpacing.md),
        ms(
          'Length',
          block.length,
          (v, {mergeKey}) => set(length: v, mergeKey: mergeKey),
        ),
        if (clipSeconds != null)
          Padding(
            padding: const EdgeInsets.only(top: FwSpacing.xs),
            child: Text(
              'The clip is ${clipSeconds.toStringAsFixed(2)} s long; at this '
              'speed the block plays '
              '${(block.length.inMilliseconds / 1000 * block.speed).toStringAsFixed(2)} s '
              'of it.',
              style: context.type.caption.copyWith(color: colors.mut2),
            ),
          ),
        const SizedBox(height: FwSpacing.md),
        SceneNumberField(
          label: 'Speed',
          value: block.speed,
          shape: const SceneNumberShape(
            perPixel: 0.01,
            decimals: 2,
            unit: '×',
            softMin: 0.1,
            softMax: 4,
            min: 0.01,
          ),
          onChanged: (v) => set(speed: v, mergeKey: 'block:speed'),
          onCommit: (v) {
            set(speed: v);
            editor.endMerge();
          },
        ),
        const SizedBox(height: FwSpacing.md),
        ms(
          'Skip the first',
          block.offset,
          (v, {mergeKey}) => set(offset: v, mergeKey: mergeKey),
        ),
        Padding(
          padding: const EdgeInsets.only(top: FwSpacing.xs),
          child: Text(
            'Of the clip: the block starts that far into it.',
            style: context.type.caption.copyWith(color: colors.mut2),
          ),
        ),
        const SizedBox(height: FwSpacing.md),
        Row(
          children: [
            _checkBox(
              context,
              block.reverse,
              () => set(reverse: !block.reverse),
            ),
            const SizedBox(width: FwSpacing.sm),
            Flexible(child: Text('Play backwards', style: context.type.body)),
          ],
        ),
        const SizedBox(height: FwSpacing.xl),
        Align(
          alignment: Alignment.centerLeft,
          child: FwActionButton(
            label: 'Delete',
            tooltip: 'Also Backspace, with the timeline focused',
            onPressed: () async => editor.deleteSelected(),
          ),
        ),
      ],
    );
  }

  static double _half(double v) => (v * 2).round() / 2;

  static String _propLabel(String prop) => switch (prop) {
    styleBindingKey => 'Text style',
    _ => sceneArgName(prop) ?? prop,
  };

  /// The child's declared parameters, each at its override or its default.
  /// A parameter the child does not declare cannot be set here — the args
  /// map is the child's contract, not a free bag.
  /// An instance of another scene: its arguments, each at one of three
  /// places in the cascade — the child's default, an override written here,
  /// or a parameter of THIS scene it reads. Editing here writes the
  /// override (or the parameter it reads, the M1 rule); the child's own
  /// mockup is edited in its main, one door away.
  List<Widget> _sceneProps(BuildContext context, SceneRefNode r) {
    var inst = r.instance;
    var caption = context.type.caption.copyWith(color: context.colors.mut2);
    Widget state(SceneParamDecl p) {
      var prop = 'args.${p.name}';
      if (r.bindings[prop] case var b?) {
        return Text(
          '← $b',
          style: caption.copyWith(color: context.colors.accentDark),
        );
      }
      if (r.args.containsKey(p.name)) {
        return Tappable(
          onTap: () => _door('args', () => r.args.remove(p.name)),
          child: Tooltip(
            message: 'Back to the default: ${p.defaultValue}',
            child: Text(
              'overridden · reset',
              style: caption.copyWith(color: context.colors.accent),
            ),
          ),
        );
      }
      return Text('default', style: caption);
    }

    Object? value(SceneParamDecl p) => r.args[p.name] ?? p.defaultValue;
    return [
      Row(
        children: [
          Expanded(child: _label(context, 'Instance of ${r.sceneClassName}')),
          if (inst != null && onEnterNested != null)
            Tappable(
              onTap: () => onEnterNested!(r),
              child: Text(
                'go to main ›',
                style: caption.copyWith(color: context.colors.accent),
              ),
            ),
        ],
      ),
      if (inst == null)
        Padding(
          padding: const EdgeInsets.only(top: FwSpacing.xs),
          child: Text(
            'No scene file by that name in this package',
            style: context.type.caption.copyWith(color: context.colors.red),
          ),
        )
      else if (inst.params.isEmpty)
        Text('${r.sceneClassName} takes no arguments', style: caption),
      const SizedBox(height: FwSpacing.md),
      for (var p in inst?.params ?? const <SceneParamDecl>[])
        _prop(
          context,
          r,
          'args.${p.name}',
          p.name,
          trailing: state(p),
          Builder(
            builder: (context) => switch (p.kind) {
              SceneParamKind.number => SceneNumberField(
                value: (value(p)! as num).toDouble(),
                shape: const SceneNumberShape(perPixel: 1, decimals: 2),
                onChanged: (v) =>
                    _set('args.${p.name}', v, () => r.args[p.name] = v),
                onCommit: (v) {
                  _set('args.${p.name}', v, () => r.args[p.name] = v);
                  editor.endMerge();
                },
              ),
              SceneParamKind.bool => _checkBox(
                context,
                value(p)! as bool,
                () =>
                    _door('args', () => r.args[p.name] = !(value(p)! as bool)),
              ),
              SceneParamKind.string => TextFormField(
                key: ValueKey(
                  '${r.name}:${p.name}:${r.bindings['args.${p.name}']}',
                ),
                initialValue: '${value(p)}',
                onChanged: (v) => _door('args', () => r.args[p.name] = v),
              ),
              SceneParamKind.color => SceneColorField(
                current: value(p) as SceneColor?,
                allowNone: false,
                onPick: (c) =>
                    _set('args.${p.name}', c!, () => r.args[p.name] = c),
              ),
              // A list is data, not a value with a field: the nested
              // scene repeats over whatever it declares, and passing a
              // different one is the caller's job.
              SceneParamKind.list => Text(
                '${p.items.length} items, from the scene itself',
                style: caption,
              ),
            },
          ),
        ),
    ];
  }
}
