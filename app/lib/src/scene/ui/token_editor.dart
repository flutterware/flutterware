import 'package:material_ui/material_ui.dart';
import 'package:flutterware/scene_authoring.dart';

import '../../ui/context_menu.dart';
import '../../ui/design/design.dart';
import '../../ui/disclosure.dart';
import '../../ui/menu.dart';
import '../../ui/picker.dart';
import '../../ui/tappable.dart';
import '../tokens_library.dart';
import 'inline_name.dart';
import 'layer_list.dart';
import 'number_field.dart';
import 'number_shape.dart';
import 'param_pane.dart';
import 'swatches.dart';

/// One token, opened where it stands on the library's sheet: what it is,
/// its value in the kind's own control or a style's fields, who reads it,
/// and the two verbs that are not an edit — rename and delete.
///
/// It sits **under its own picture** — a style's fields beneath that
/// style's specimen, a colour's picker beneath the palette — which is what
/// neither the drawer nor the side column could do: sixteen fields do not
/// fit in a third of a window's height, and a 290px column shows a specimen
/// too small to judge. The sheet scrolls, so this is a column that measures
/// itself, never one that scrolls on its own.
///
/// An export is the app's: a name, a type and its readers, nothing to edit.
class SceneTokenEditor extends StatefulWidget {
  const SceneTokenEditor(
    this.decl, {
    super.key,
    this.library,
    this.readers = const [],
    this.deleteProblem,
    this.onRename,
    this.onDelete,
    this.showName = true,
    this.renaming = false,
    this.onRenaming,
  });

  final SceneTokenDecl decl;

  /// The document to edit through; null for an export, and for a token whose
  /// library this page did not open.
  final TokensLibrary? library;

  /// Who reads it, as `Scene · node.prop`, across every group that lists the
  /// library.
  final List<String> readers;

  /// Why it cannot be deleted now, or null. Shown on the item rather than
  /// hiding it: a refusal that says why is the point.
  final String? deleteProblem;

  /// Renames across the library and its readers. Throws an [ArgumentError]
  /// to refuse, whose message the field shows. Null hides the verb.
  final void Function(String wanted)? onRename;

  final VoidCallback? onDelete;

  /// Whether to draw the name. False when whatever opened this already
  /// carries it — a style's card shows its own, over the specimen.
  final bool showName;

  /// Whether the name is being typed, and how to say it started or stopped.
  /// Held by the sheet, so a token added and a token renamed are one state.
  final bool renaming;
  final ValueChanged<bool>? onRenaming;

  @override
  State<SceneTokenEditor> createState() => _SceneTokenEditorState();
}

class _SceneTokenEditorState extends State<SceneTokenEditor> {
  @override
  Widget build(BuildContext context) {
    var decl = widget.decl;
    var colors = context.colors;
    return Column(
      key: ValueKey('token:${decl.name}'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        _header(context, decl),
        const Gap(FwSpacing.lg),
        if (decl.isExport)
          Text(
            'A ${decl.type} the app exports — its own value, drawn by the '
            'canvas. Nothing to edit here: change it in the app.',
            style: context.type.body,
          )
        else if (widget.library == null)
          Text(
            'Declared in a library this page did not open.',
            style: context.type.micro.copyWith(color: colors.mut2),
          )
        else if (decl.isStyle)
          _styleFields(context, widget.library!, decl)
        else
          _valueControl(context, widget.library!, decl),
        const Gap(FwSpacing.lg),
        _readers(context),
      ],
    );
  }

  Widget _header(BuildContext context, SceneTokenDecl decl) {
    var colors = context.colors;
    var rename = widget.onRename;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            Expanded(
              child: !widget.showName
                  ? Text(
                      _what(decl),
                      style: context.type.caption.copyWith(color: colors.mut2),
                    )
                  : widget.renaming && rename != null
                  ? InlineNameField(
                      initial: decl.name,
                      dense: true,
                      style: context.type.bodyStrong,
                      onCommit: (wanted) {
                        try {
                          rename(wanted);
                        } on ArgumentError catch (e) {
                          return '${e.message}';
                        }
                        widget.onRenaming?.call(false);
                        return null;
                      },
                      onCancel: () => widget.onRenaming?.call(false),
                    )
                  : Tappable(
                      onTap: rename == null
                          ? null
                          : () => widget.onRenaming?.call(true),
                      borderRadius: BorderRadius.circular(
                        context.radii.radiusSmall,
                      ),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          vertical: FwSpacing.xxs,
                        ),
                        child: Text(
                          decl.name,
                          overflow: TextOverflow.ellipsis,
                          style: context.type.bodyStrong,
                        ),
                      ),
                    ),
            ),
            if (widget.onDelete != null || rename != null)
              Builder(
                builder: (context) => Tappable(
                  key: const ValueKey('token:menu'),
                  onTap: () {
                    var box = context.findRenderObject()! as RenderBox;
                    showContextMenu(
                      context,
                      box.localToGlobal(Offset(0, box.size.height)),
                      _menu(),
                    );
                  },
                  borderRadius: BorderRadius.circular(
                    context.radii.radiusSmall,
                  ),
                  child: Padding(
                    padding: const EdgeInsets.all(FwSpacing.xxs),
                    child: Icon(
                      Icons.more_horiz,
                      size: FwIconSize.md,
                      color: colors.mut,
                    ),
                  ),
                ),
              ),
          ],
        ),
        if (widget.showName)
          Text(
            _what(decl),
            style: context.type.caption.copyWith(color: colors.mut2),
          ),
      ],
    );
  }

  static String _what(SceneTokenDecl decl) => decl.isExport
      ? "the app's · ${decl.type}"
      : decl.isStyle
      ? 'style · SceneTextStyle'
      : '${paramKindLabel(decl.kind!)} · ${decl.typeName}';

  List<MenuEntry> _menu() => [
    if (widget.onRename != null)
      MenuItem(
        'Rename',
        icon: Icons.edit_outlined,
        shortcut: 'click the name',
        onSelected: () => widget.onRenaming?.call(true),
      ),
    if (widget.onDelete case var delete?) ...[
      const MenuDivider(),
      MenuItem(
        widget.deleteProblem == null
            ? 'Delete'
            : 'Delete — ${widget.deleteProblem}',
        icon: Icons.delete_outline,
        danger: true,
        onSelected: widget.deleteProblem == null ? delete : null,
      ),
    ],
  ];

  Widget _readers(BuildContext context) {
    var colors = context.colors;
    var readers = widget.readers;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          readers.isEmpty
              ? 'READ BY NOTHING'
              : 'READ BY ${readers.length}'
                    '${readers.length == 1 ? ' PROPERTY' : ' PROPERTIES'}',
          style: context.type.caption.copyWith(color: colors.mut3),
        ),
        const Gap(FwSpacing.xs),
        if (readers.isEmpty)
          Text(
            'Nothing binds to it yet — a property takes it from the '
            "inspector's token menu.",
            style: context.type.micro.copyWith(color: colors.mut2),
          )
        else
          for (var reader in readers)
            Padding(
              padding: const EdgeInsets.only(bottom: FwSpacing.xxs),
              child: Text(
                reader,
                style: context.type.micro.copyWith(color: colors.mut),
              ),
            ),
      ],
    );
  }

  Widget _valueControl(
    BuildContext context,
    TokensLibrary library,
    SceneTokenDecl decl,
  ) => _control(context, decl, decl.value!, (v, {String? mergeKey}) {
    library.setValue(decl.name, v, mergeKey: mergeKey);
  }, endMerge: library.endMerge);

  Widget _control(
    BuildContext context,
    SceneTokenDecl decl,
    Object value,
    void Function(Object value, {String? mergeKey}) set, {
    required VoidCallback endMerge,
  }) {
    var key = 'token:${decl.name}';
    switch (decl.kind!) {
      case SceneParamKind.number:
        return SceneNumberField(
          value: value as double,
          shape: const SceneNumberShape(perPixel: 1, decimals: 2),
          onChanged: (v) => set(v, mergeKey: key),
          onCommit: (v) {
            set(v, mergeKey: key);
            endMerge();
          },
        );
      case SceneParamKind.string:
        return TextFormField(
          key: ValueKey('$key:${value.hashCode}'),
          initialValue: value as String,
          maxLines: 3,
          minLines: 1,
          onChanged: (v) => set(v, mergeKey: key),
        );
      case SceneParamKind.color:
        return SceneColorField(
          current: value as SceneColor,
          allowNone: false,
          onPick: (c) => set(c!),
        );
      case SceneParamKind.bool:
        var on = value as bool;
        return Tappable(
          onTap: () => set(!on),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                on ? Icons.check_box : Icons.check_box_outline_blank,
                size: FwIconSize.md,
                color: on ? context.colors.accent : context.colors.mut2,
              ),
              const SizedBox(width: FwSpacing.sm),
              Text(on ? 'on' : 'off', style: context.type.body),
            ],
          ),
        );
      case SceneParamKind.list:
        return const SizedBox.shrink();
    }
  }

  /// A style's fields. Every field the table carries, each unset-able,
  /// because a style sets only what it sets and a text takes it whole.
  ///
  /// The write goes through [SceneTextStyle.values] and
  /// [SceneTextStyle.fromValues] — the table's own round trip — rather than
  /// through a hand-written constructor call. The hand-written one named
  /// five fields and silently dropped the other eleven: setting the weight
  /// on a token that had a tracking, a stack of paint passes or a typeface
  /// deleted them from the file on the next autosave.
  Widget _styleFields(
    BuildContext context,
    TokensLibrary library,
    SceneTokenDecl decl,
  ) {
    var style = decl.style!;
    var key = 'style:${decl.name}';
    var colors = context.colors;
    var caption = context.type.caption.copyWith(color: colors.mut2);
    // The drag rate and the slider come from the property's own metadata,
    // read off a node carrying this style — the same door the inspector
    // uses. Hardcoding one-unit-per-pixel for every field made Leading, a
    // multiple of the font size that lives between 0.8 and 2, move 250×
    // faster than it should: one pixel of drag doubled the line box.
    var probe = TextNode('', name: 'probe', style: style);

    void put(String prop, Object? value, {String? mergeKey}) {
      var values = Map<String, Object?>.of(style.values);
      if (value == null) {
        values.remove(prop);
      } else {
        values[prop] = value;
      }
      library.setStyle(
        decl.name,
        SceneTextStyle.fromValues(values),
        mergeKey: mergeKey,
      );
    }

    Widget field(String prop, String label, Widget control) => Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: FwSpacing.xs),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  style.sets(prop) ? label : '$label · unset',
                  overflow: TextOverflow.ellipsis,
                  style: caption,
                ),
              ),
              // A cross, not the word: the label already says `· unset` for
              // a field that is not set, and the same word as the verb read
              // as the state one line above the value it contradicted.
              if (style.sets(prop))
                Tooltip(
                  message: 'Unset $label',
                  waitDuration: const Duration(milliseconds: 600),
                  child: Tappable(
                    onTap: () => put(prop, null),
                    borderRadius: BorderRadius.circular(
                      context.radii.radiusSmall,
                    ),
                    child: Padding(
                      padding: const EdgeInsets.all(FwSpacing.xxs),
                      child: Icon(
                        Icons.close,
                        size: FwIconSize.xs,
                        color: colors.mut3,
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
        control,
      ],
    );

    Widget number(String prop, String label, double fallback) => field(
      prop,
      label,
      SceneNumberField(
        value: (style.values[prop] as double?) ?? fallback,
        shape: shapeFor(probe, prop),
        onChanged: (v) => put(prop, v, mergeKey: '$key:$prop'),
        onCommit: (v) {
          put(prop, v, mergeKey: '$key:$prop');
          library.endMerge();
        },
      ),
    );

    Widget choice<T>(String prop, String label, List<FwChoice<T?>> choices) =>
        field(
          prop,
          label,
          FwPicker<T?>(
            selected: style.values[prop] as T?,
            choices: [
              const FwChoice(value: null, label: 'unset'),
              ...choices,
            ],
            onChanged: (v) => put(prop, v),
          ),
        );

    Widget colour(String prop, String label) => field(
      prop,
      label,
      SceneColorField(
        current: style.values[prop] as SceneColor?,
        onPick: (c) => put(prop, c),
      ),
    );

    Widget row(List<Widget> children) => Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (var (i, child) in children.indexed) ...[
          if (i > 0) const Gap(FwSpacing.md),
          Expanded(child: child),
        ],
      ],
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      spacing: FwSpacing.md,
      children: [
        field(
          'fontFamily',
          'Typeface',
          TextFormField(
            key: ValueKey('$key:family:${style.fontFamily}'),
            initialValue: style.fontFamily ?? '',
            decoration: const InputDecoration(hintText: "the app's own"),
            onChanged: (v) =>
                put('fontFamily', v.trim().isEmpty ? null : v.trim()),
          ),
        ),
        row([
          number('fontSize', 'Size', 16),
          choice<SceneFontWeight>('weight', 'Weight', const [
            FwChoice(value: SceneFontWeight.w400, label: 'Regular'),
            FwChoice(value: SceneFontWeight.w500, label: 'Medium'),
            FwChoice(value: SceneFontWeight.w600, label: 'Semibold'),
            FwChoice(value: SceneFontWeight.w700, label: 'Bold'),
            FwChoice(value: SceneFontWeight.w900, label: 'Black'),
          ]),
        ]),
        row([
          number('letterSpacing', 'Tracking', 0),
          number('lineHeight', 'Leading', 1.15),
        ]),
        row([
          choice<bool>('italic', 'Slant', const [
            FwChoice(value: false, label: 'Roman'),
            FwChoice(value: true, label: 'Italic'),
          ]),
          choice<SceneTextCase>('textCase', 'Case', const [
            FwChoice(value: SceneTextCase.none, label: 'As typed'),
            FwChoice(value: SceneTextCase.upper, label: 'UPPER'),
            FwChoice(value: SceneTextCase.lower, label: 'lower'),
            FwChoice(value: SceneTextCase.title, label: 'Title'),
          ]),
        ]),
        colour('color', 'Colour'),
        // A treatment is what a shared style is FOR — a poster's outline
        // belongs in the library beside the size it was drawn at, not
        // copied onto each text that wants it.
        SceneLayerList(
          layers: style.layers ?? const [],
          fontSize: style.fontSize ?? 16,
          color: Color(style.color?.argb ?? 0xFF000000),
          onChanged: (next, {required label, mergeKey}) =>
              put('layers', next, mergeKey: mergeKey),
        ),
        Disclosure(
          label: 'More type',
          children: [
            number('wordSpacing', 'Word spacing', 0),
            const Gap(FwSpacing.md),
            row([
              choice<SceneTextDecoration>('decoration', 'Decoration', const [
                FwChoice(value: SceneTextDecoration.none, label: 'None'),
                FwChoice(
                  value: SceneTextDecoration.underline,
                  label: 'Underline',
                ),
                FwChoice(
                  value: SceneTextDecoration.overline,
                  label: 'Overline',
                ),
                FwChoice(
                  value: SceneTextDecoration.lineThrough,
                  label: 'Strikethrough',
                ),
              ]),
            ]),
            if (style.decoration != null &&
                style.decoration != SceneTextDecoration.none) ...[
              const Gap(FwSpacing.md),
              row([
                choice<SceneTextDecorationStyle>(
                  'decorationStyle',
                  'Line style',
                  const [
                    FwChoice(
                      value: SceneTextDecorationStyle.solid,
                      label: 'Solid',
                    ),
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
                    FwChoice(
                      value: SceneTextDecorationStyle.wavy,
                      label: 'Wavy',
                    ),
                  ],
                ),
                number('decorationThickness', 'Line thickness', 1),
              ]),
              const Gap(FwSpacing.md),
              colour('decorationColor', 'Line color'),
            ],
          ],
        ),
      ],
    );
  }
}
