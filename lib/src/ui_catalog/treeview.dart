import 'package:material_ui/material_ui.dart';

const selectionColor = Color(0xff2675bf);
const iconLightBlue = Color(0xffaeb9c0);
const folderColor = Color(0xff8cd3ec);

class TreeEntryAdapter<T> {
  final Iterable<T>? Function(T) children;
  final String Function(T) title;
  final List<T> Function(T) ancestors;

  TreeEntryAdapter({
    required this.children,
    required this.title,
    required this.ancestors,
  });
}

class TreeView<T> extends StatefulWidget {
  final Iterable<T> entries;
  final T? selected;
  final void Function(T) onSelected;
  final TreeEntryAdapter<T> adapter;

  const TreeView({
    super.key,
    required this.entries,
    this.selected,
    required this.onSelected,
    required this.adapter,
  });

  @override
  State<TreeView<T>> createState() => TreeViewState<T>();
}

class TreeViewState<T> extends State<TreeView<T>> {
  final _expanded = <T>{};

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.only(bottom: 20),
      children: _flattenedEntries().toList(),
    );
  }

  void expandAll() {
    setState(() {
      _expanded.addAll(
        widget.entries.where((e) => widget.adapter.children(e) != null),
      );
    });
  }

  void collapseAll() {
    setState(() {
      _expanded.clear();
    });
  }

  Iterable<_LineView> _flattenedEntries() {
    return _flatten(widget.entries, depth: 0);
  }

  Iterable<_LineView> _flatten(
    Iterable<T> entries, {
    required int depth,
  }) sync* {
    var selected = widget.selected;
    var selectedAncestors = selected != null
        ? widget.adapter.ancestors(selected)
        : [];
    for (var entry in entries) {
      var children = widget.adapter.children(entry);
      var isExpanded =
          _expanded.contains(entry) || selectedAncestors.contains(entry);
      yield _LineView(
        title: widget.adapter.title(entry),
        isLeaf: children == null,
        depth: depth,
        expanded: isExpanded,
        onTap: () {
          widget.onSelected(entry);
          if (children != null) {
            _expanded.add(entry);
          }
        },
        onToggleExpanded: () {
          setState(() {
            if (!_expanded.remove(entry)) {
              _expanded.add(entry);
            }
          });
        },
        selected: entry == selected,
      );

      if (children != null && isExpanded) {
        yield* _flatten(children, depth: depth + 1);
      }
    }
  }
}

class _LineView extends StatelessWidget {
  final int depth;
  final bool expanded;
  final VoidCallback onToggleExpanded;
  final VoidCallback onTap;
  final bool selected;
  final String title;
  final bool isLeaf;

  const _LineView({
    required this.depth,
    required this.expanded,
    required this.onTap,
    required this.onToggleExpanded,
    required this.selected,
    required this.title,
    required this.isLeaf,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Container(
        color: selected ? selectionColor : null,
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            SizedBox(width: 12.0 * depth),
            GestureDetector(
              onTap: isLeaf ? null : onToggleExpanded,
              child: Icon(
                expanded
                    ? Icons.keyboard_arrow_down
                    : Icons.keyboard_arrow_right,
                size: 17,
                color: isLeaf ? Colors.transparent : Colors.black54,
              ),
            ),
            const SizedBox(width: 1),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4.0),
              child: Icon(
                isLeaf ? Icons.insert_drive_file : Icons.folder,
                size: 16,
                color: isLeaf ? iconLightBlue : folderColor,
              ),
            ),
            Expanded(
              child: Text(
                title,
                style: TextStyle(color: selected ? Colors.white : null),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
