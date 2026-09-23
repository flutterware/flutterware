import 'package:material_ui/material_ui.dart';

import 'treeview.dart';

class SearchResults<T> extends StatefulWidget {
  final String query;
  final Iterable<T> entries;
  final T? selected;
  final void Function(T) onSelected;
  final TreeEntryAdapter<T> adapter;
  final Widget Function(T entry) breadcrumbBuilder;

  const SearchResults({
    super.key,
    required this.query,
    required this.entries,
    this.selected,
    required this.onSelected,
    required this.adapter,
    required this.breadcrumbBuilder,
  });

  @override
  State<SearchResults<T>> createState() => SearchResultsState<T>();
}

class SearchResultsState<T> extends State<SearchResults<T>> {
  late String _query = widget.query.toLowerCase();

  @override
  void didUpdateWidget(covariant SearchResults<T> oldWidget) {
    super.didUpdateWidget(oldWidget);

    _query = widget.query.toLowerCase();
  }

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.only(bottom: 20),
      children: _flattenedEntries().toList(),
    );
  }

  Iterable<_LineView> _flattenedEntries() {
    return _flatten(widget.entries, depth: 0);
  }

  Iterable<_LineView> _flatten(
    Iterable<T> entries, {
    required int depth,
  }) sync* {
    var selected = widget.selected;
    for (var entry in entries) {
      var children = widget.adapter.children(entry);
      var title = widget.adapter.title(entry);
      var ancestors = widget.adapter.ancestors(entry);
      if (title.toLowerCase().contains(_query)) {
        Widget? breadcrumb;
        if (ancestors.isNotEmpty) {
          breadcrumb = widget.breadcrumbBuilder(entry);
        }

        yield _LineView(
          title: title,
          isLeaf: children == null,
          query: _query,
          onTap: () {
            widget.onSelected(entry);
          },
          selected: entry == selected,
          breadcrumb: breadcrumb,
        );
      }

      if (children != null) {
        yield* _flatten(children, depth: depth + 1);
      }
    }
  }
}

class _LineView extends StatelessWidget {
  final VoidCallback onTap;
  final bool selected;
  final String title;
  final String query;
  final bool isLeaf;
  final Widget? breadcrumb;

  const _LineView({
    required this.onTap,
    required this.selected,
    required this.title,
    required this.isLeaf,
    required this.query,
    required this.breadcrumb,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Container(
        color: selected ? selectionColor : null,
        padding: const EdgeInsets.symmetric(vertical: 2).copyWith(left: 18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4.0),
                  child: Icon(
                    isLeaf ? Icons.insert_drive_file : Icons.folder,
                    size: 16,
                    color: isLeaf ? iconLightBlue : folderColor,
                  ),
                ),
                Expanded(
                  child: _HighlightText(
                    text: title,
                    highlight: query,
                    highlightStyle: TextStyle(backgroundColor: Colors.yellow),
                    ignoreCase: true,
                    style: TextStyle(color: selected ? Colors.white : null),
                  ),
                ),
              ],
            ),
            if (breadcrumb != null)
              DefaultTextStyle.merge(
                style: TextStyle(color: selected ? Colors.white : null),
                child: IconTheme.merge(
                  data: IconThemeData(color: selected ? Colors.white : null),
                  child: Padding(
                    padding: const EdgeInsets.only(left: 22),
                    child: breadcrumb!,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _HighlightText extends StatelessWidget {
  final String text;
  final String highlight;
  final TextStyle style;
  final TextStyle highlightStyle;
  final bool ignoreCase;

  _HighlightText({
    required this.text,
    required this.highlight,
    required this.style,
    required this.highlightStyle,
    this.ignoreCase = false,
  });

  @override
  Widget build(BuildContext context) {
    if (highlight.isEmpty || text.isEmpty) {
      return Text(text, style: style);
    }

    var sourceText = ignoreCase ? text.toLowerCase() : text;
    var targetHighlight = ignoreCase ? highlight.toLowerCase() : highlight;

    var spans = <TextSpan>[];
    var start = 0;
    int indexOfHighlight;
    do {
      indexOfHighlight = sourceText.indexOf(targetHighlight, start);
      if (indexOfHighlight < 0) {
        // no highlight
        spans.add(_normalSpan(text.substring(start)));
        break;
      }
      if (indexOfHighlight > start) {
        // normal text before highlight
        spans.add(_normalSpan(text.substring(start, indexOfHighlight)));
      }
      start = indexOfHighlight + highlight.length;
      spans.add(_highlightSpan(text.substring(indexOfHighlight, start)));
    } while (true);

    return Text.rich(TextSpan(children: spans));
  }

  TextSpan _highlightSpan(String content) {
    return TextSpan(text: content, style: highlightStyle);
  }

  TextSpan _normalSpan(String content) {
    return TextSpan(text: content, style: style);
  }
}
