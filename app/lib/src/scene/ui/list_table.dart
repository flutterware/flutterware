import 'package:material_ui/material_ui.dart';
import 'package:flutterware/scene_authoring.dart';

import '../../ui/design/design.dart';
import '../../ui/tappable.dart';
import '../editor.dart';
import 'number_field.dart';
import 'number_shape.dart';

/// A list parameter's items as a table in the drawer under the canvas: a
/// column per field, a row per item, every cell edited in place.
///
/// Rows are the timeline's height — 26px, a hairline under each — because
/// the drawer is a band and twelve rows have to fit in it; a boxed form
/// field would show seven. A row is added as a copy of the last, so the
/// shape is kept, and removed with its cross. Every change is one door on
/// the parameter: the repeat that draws the list redraws above, as you type.
/// The FIELDS are the record type every row shares and every cell binding
/// names, so they stay in the file.
class SceneListTable extends StatelessWidget {
  const SceneListTable(this.editor, this.name, {super.key});

  final SceneEditor editor;
  final String name;

  static const rowHeight = 26.0;

  @override
  Widget build(BuildContext context) {
    var param = editor.doc.paramNamed(name);
    if (param == null || param.kind != SceneParamKind.list) {
      return const SizedBox.shrink();
    }
    var items = param.items;
    var colors = context.colors;
    var caption = context.type.micro.copyWith(color: colors.mut2);
    if (items.isEmpty) {
      return Container(
        color: colors.panel,
        padding: const EdgeInsets.all(FwSpacing.lg),
        alignment: Alignment.topLeft,
        child: Text(
          'No items. The first one is written in the file — it is the shape '
          'every row shares.',
          style: caption,
        ),
      );
    }
    var fields = items.first.keys.toList();
    void set(List<SceneItem> next, {String? mergeKey}) =>
        editor.setParamDefault(name, next, mergeKey: mergeKey);
    return Container(
      color: colors.panel,
      padding: const EdgeInsets.symmetric(
        horizontal: FwSpacing.lg,
        vertical: FwSpacing.sm,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              for (var (j, f) in fields.indexed)
                Expanded(
                  flex: j == 0 ? 3 : 1,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: FwSpacing.sm,
                    ),
                    child: Text(f, style: caption),
                  ),
                ),
              const SizedBox(width: FwIconSize.sm + FwSpacing.md),
            ],
          ),
          Expanded(
            child: ListView(
              children: [
                for (var (i, item) in items.indexed)
                  SizedBox(
                    height: rowHeight,
                    child: Row(
                      children: [
                        for (var (j, f) in fields.indexed)
                          Expanded(
                            flex: j == 0 ? 3 : 1,
                            child: _cell(
                              context,
                              key: 'list:$name:$i:$f',
                              value: item[f],
                              onChanged: (v) => set([
                                for (var (k, it) in items.indexed)
                                  k == i ? {...it, f: v} : it,
                              ], mergeKey: 'list:$name:$i:$f'),
                            ),
                          ),
                        const SizedBox(width: FwSpacing.sm),
                        Tooltip(
                          message: 'Remove this item',
                          child: Tappable(
                            onTap: () => set([
                              for (var (k, it) in items.indexed)
                                if (k != i) it,
                            ]),
                            child: Icon(
                              Icons.close,
                              size: FwIconSize.sm,
                              color: colors.mut2,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                Padding(
                  padding: const EdgeInsets.only(
                    top: FwSpacing.sm,
                    left: FwSpacing.sm,
                  ),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Tappable(
                      onTap: () => set([
                        ...items,
                        {...items.last},
                      ]),
                      child: Text(
                        'add row',
                        style: context.type.caption.copyWith(
                          color: colors.accent,
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// One cell: a number scrubs, anything else is text edited in place, both
  /// on a hairline rather than in a box, so the row stays 26px.
  Widget _cell(
    BuildContext context, {
    required String key,
    required Object? value,
    required ValueChanged<Object> onChanged,
  }) {
    var colors = context.colors;
    Widget inner = switch (value) {
      double d => SceneScrubNumber(
        value: d,
        shape: const SceneNumberShape(perPixel: 1, decimals: 2),
        onChanged: onChanged,
        onCommit: (v) {
          onChanged(v);
          editor.endMerge();
        },
      ),
      _ => TextField(
        key: ValueKey(key),
        controller: TextEditingController(text: '$value')
          ..selection = TextSelection.collapsed(offset: '$value'.length),
        style: context.type.body,
        decoration: const InputDecoration.collapsed(hintText: null),
        onChanged: onChanged,
        onSubmitted: (_) => editor.endMerge(),
      ),
    };
    return Container(
      alignment: Alignment.centerLeft,
      padding: const EdgeInsets.symmetric(horizontal: FwSpacing.sm),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: colors.line)),
      ),
      child: inner,
    );
  }
}
