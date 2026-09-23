import 'dart:convert';

import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';

import '../utils/string/plural.dart';
import 'tappable.dart';
import 'design/design.dart';

// Ported 2026-07-31 from the cms project's admin_ui
// (packages/admin_ui/lib/src/common/ui/json_view.dart), onto this app's own
// design tokens — the two systems share the same shape, so the diff is the
// palette names and the copy button. Fix bugs here; there is no vendoring
// script keeping the two in sync.

/// The structural class of a [JsonNode], used to pick its highlight colour and
/// whether it folds.
enum JsonNodeKind { object, array, string, number, boolean, nul }

/// One node of a parsed JSON document. Built once by [buildJsonTree] and walked
/// by [flattenJson] to produce the visible rows. [path] is a stable id
/// (`$.user.tags[0]`) used as the expansion-set key.
class JsonNode {
  final String path;
  final int depth;

  /// The owning object member's key, unquoted; null for the root and array
  /// elements.
  final String? key;

  /// The element index within the owning array; null otherwise.
  final int? index;

  final JsonNodeKind kind;

  /// The original decoded value (`Map`/`List` for containers, the scalar for
  /// leaves) — re-encoded for copy and used for leaf display/search.
  final Object? raw;

  final List<JsonNode> children;

  JsonNode({
    required this.path,
    required this.depth,
    required this.key,
    required this.index,
    required this.kind,
    required this.raw,
    required this.children,
  });

  bool get isContainer =>
      kind == JsonNodeKind.object || kind == JsonNodeKind.array;

  bool get isEmpty => isContainer && children.isEmpty;

  int get childCount => children.length;

  /// The leaf text used for display, JSON-encoded so strings keep their quotes
  /// and escapes (`"hi"`, `14.5`, `true`, `null`). Memoised — encoded once per
  /// node, on first access, so rebuilds don't re-serialise.
  late final String encoded = jsonEncode(raw);

  /// The unquoted text matched against a search query. Memoised likewise so a
  /// per-keystroke search doesn't re-encode every leaf.
  late final String searchText = raw is String ? raw! as String : encoded;
}

/// Parses an already-decoded JSON value (`Map`/`List`/`String`/`num`/`bool`/
/// `null`) into a [JsonNode] tree rooted at `$`.
JsonNode buildJsonTree(Object? value) => _node(value, r'$', 0, null, null);

JsonNode _node(Object? value, String path, int depth, String? key, int? index) {
  if (value is Map) {
    final children = <JsonNode>[];
    for (final entry in value.entries) {
      final k = entry.key.toString();
      children.add(_node(entry.value, '$path.$k', depth + 1, k, null));
    }
    return JsonNode(
      path: path,
      depth: depth,
      key: key,
      index: index,
      kind: JsonNodeKind.object,
      raw: value,
      children: children,
    );
  }
  if (value is List) {
    final children = <JsonNode>[];
    for (var i = 0; i < value.length; i++) {
      children.add(_node(value[i], '$path[$i]', depth + 1, null, i));
    }
    return JsonNode(
      path: path,
      depth: depth,
      key: key,
      index: index,
      kind: JsonNodeKind.array,
      raw: value,
      children: children,
    );
  }
  final kind = switch (value) {
    String() => JsonNodeKind.string,
    num() => JsonNodeKind.number,
    bool() => JsonNodeKind.boolean,
    _ => JsonNodeKind.nul,
  };
  return JsonNode(
    path: path,
    depth: depth,
    key: key,
    index: index,
    kind: kind,
    raw: value,
    children: const [],
  );
}

/// A single rendered line. A container yields an open line and — when expanded —
/// a [closing] line; collapsed it folds to one line ([collapsed] is true).
/// [last] drives the trailing comma.
class JsonRow {
  final JsonNode node;
  final bool closing;
  final bool collapsed;
  final bool last;

  const JsonRow(
    this.node, {
    required this.closing,
    required this.collapsed,
    required this.last,
  });
}

/// Walks [root] into the flat, ordered list of currently-visible [JsonRow]s.
///
/// Without [visible] (no active search) a container is expanded when its path is
/// in [expanded]. With [visible] (a search filter), only nodes whose path is in
/// the set are kept, and kept containers are forced open so every match stays
/// revealed.
List<JsonRow> flattenJson(
  JsonNode root, {
  required Set<String> expanded,
  Set<String>? visible,
}) {
  final out = <JsonRow>[];

  void visit(JsonNode node, bool last) {
    final searching = visible != null;
    if (searching && !visible.contains(node.path)) return;

    final foldable = node.isContainer && !node.isEmpty;
    final kids = searching
        ? node.children.where((c) => visible.contains(c.path)).toList()
        : node.children;
    // While searching, a container opens only when it still has a kept child;
    // one matched by its own key alone stays collapsed for the user to open.
    final isOpen =
        foldable &&
        (searching ? kids.isNotEmpty : expanded.contains(node.path));

    if (!isOpen) {
      out.add(JsonRow(node, closing: false, collapsed: foldable, last: last));
      return;
    }

    out.add(JsonRow(node, closing: false, collapsed: false, last: last));
    for (var i = 0; i < kids.length; i++) {
      visit(kids[i], i == kids.length - 1);
    }
    out.add(JsonRow(node, closing: true, collapsed: false, last: last));
  }

  visit(root, true);
  return out;
}

/// The outcome of a [jsonSearch]: every node [matched] by the query, and the
/// [keep] set (matches plus their ancestors) used to filter and force-expand.
class JsonSearchResult {
  final Set<String> matched;
  final Set<String> keep;

  const JsonSearchResult(this.matched, this.keep);
}

/// Case-insensitive substring search over keys and leaf values. Returns the
/// matched paths and the closure of paths to keep visible (each match and all
/// its ancestors).
JsonSearchResult jsonSearch(JsonNode root, String query) {
  final q = query.toLowerCase();
  final matched = <String>{};
  final keep = <String>{};

  bool visit(JsonNode node) {
    var self = false;
    if (node.key != null && node.key!.toLowerCase().contains(q)) self = true;
    if (!node.isContainer && node.searchText.toLowerCase().contains(q)) {
      self = true;
    }
    if (self) matched.add(node.path);

    var keptChild = false;
    for (final c in node.children) {
      if (visit(c)) keptChild = true;
    }
    final kept = self || keptChild;
    if (kept) keep.add(node.path);
    return kept;
  }

  visit(root);
  return JsonSearchResult(matched, keep);
}

/// A read-only, collapsible JSON tree viewer. Built for inspecting payloads —
/// API responses, webhook bodies, `jsonb` columns — including large ones: rows
/// are virtualised, so a multi-thousand-node document scrolls smoothly.
///
/// It complements (rather than duplicates) the `CodeBody` editor: that edits raw
/// text, this folds parsed structure. Pass already-decoded data, or
/// [JsonView.source] to decode a raw string and surface a parse error inline.
class JsonView extends StatefulWidget {
  /// The decoded value to display (`Map`/`List`/scalar/null).
  final Object? data;

  /// Raw JSON text to decode internally; mutually exclusive with [data].
  final String? source;

  /// Containers shallower than this auto-expand on first render. 0 collapses
  /// everything but the root.
  final int initialExpandDepth;

  /// Show the header: root summary, expand/collapse-all, search, copy-all.
  final bool showToolbar;

  /// Offer the search field in the toolbar.
  final bool searchable;

  /// Tallest the viewport grows before it scrolls.
  final double maxHeight;

  const JsonView({
    super.key,
    required this.data,
    this.initialExpandDepth = 2,
    this.showToolbar = true,
    this.searchable = true,
    this.maxHeight = 480,
  }) : source = null;

  const JsonView.source(
    String this.source, {
    super.key,
    this.initialExpandDepth = 2,
    this.showToolbar = true,
    this.searchable = true,
    this.maxHeight = 480,
  }) : data = null;

  @override
  State<JsonView> createState() => _JsonViewState();
}

const _rowH = 22.0;
const _indent = 16.0;
const _listPadV = 8.0;

class _JsonViewState extends State<JsonView> {
  final _scroll = ScrollController();
  final _search = TextEditingController();

  JsonNode? _root;
  String? _parseError;

  /// The whole document pretty-printed for the toolbar's copy action. Serialised
  /// once per data change, not per rebuild.
  String _pretty = '';

  final _expanded = <String>{};
  String _query = '';

  /// [jsonSearch] is an O(N) tree walk; cache it so it only re-runs when the
  /// query text actually changes, not on every unrelated rebuild.
  String? _searchKey;
  JsonSearchResult? _searchCache;

  @override
  void initState() {
    super.initState();
    _rebuild();
    _search.addListener(() {
      if (_search.text == _query) return;
      setState(() => _query = _search.text);
    });
  }

  @override
  void didUpdateWidget(covariant JsonView old) {
    super.didUpdateWidget(old);
    if (widget.data != old.data || widget.source != old.source) {
      _expanded.clear();
      _rebuild();
    }
  }

  void _rebuild() {
    _parseError = null;
    _searchKey = null;
    _searchCache = null;
    var value = widget.data;
    if (widget.source != null) {
      try {
        value = jsonDecode(widget.source!);
      } on FormatException catch (e) {
        _root = null;
        _parseError = e.message;
        return;
      }
    }
    _root = buildJsonTree(value);
    _pretty = const JsonEncoder.withIndent('  ').convert(value);
    _seedExpansion(_root!);
  }

  /// The search result for the active query, recomputed only when the query
  /// changes; null when not searching.
  JsonSearchResult? _activeSearch() {
    final q = _query.trim();
    if (q.isEmpty) {
      _searchKey = null;
      _searchCache = null;
      return null;
    }
    if (q != _searchKey) {
      _searchKey = q;
      _searchCache = jsonSearch(_root!, q);
    }
    return _searchCache;
  }

  void _seedExpansion(JsonNode node) {
    if (node.isContainer &&
        !node.isEmpty &&
        node.depth < widget.initialExpandDepth) {
      _expanded.add(node.path);
    }
    for (final c in node.children) {
      _seedExpansion(c);
    }
  }

  @override
  void dispose() {
    _scroll.dispose();
    _search.dispose();
    super.dispose();
  }

  void _toggle(String path) {
    setState(() {
      if (!_expanded.remove(path)) _expanded.add(path);
    });
  }

  void _expandAll() {
    setState(() {
      void walk(JsonNode n) {
        if (n.isContainer && !n.isEmpty) _expanded.add(n.path);
        n.children.forEach(walk);
      }

      walk(_root!);
    });
  }

  void _collapseAll() {
    setState(() {
      _expanded
        ..clear()
        ..add(_root!.path);
    });
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final radius = context.radii.radius;

    return Container(
      decoration: BoxDecoration(
        color: colors.panel,
        borderRadius: BorderRadius.circular(radius),
        border: Border.all(color: colors.line),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(radius),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (widget.showToolbar) _toolbar(context),
            if (_parseError != null) _errorBanner(context) else _body(context),
          ],
        ),
      ),
    );
  }

  Widget _body(BuildContext context) {
    final root = _root!;
    final search = _activeSearch();
    final rows = flattenJson(root, expanded: _expanded, visible: search?.keep);

    if (rows.isEmpty) {
      return _hint(context, 'No matches');
    }

    final contentH = rows.length * _rowH + _listPadV * 2;
    final height = contentH.clamp(0.0, widget.maxHeight);

    return SizedBox(
      height: height,
      child: Scrollbar(
        controller: _scroll,
        child: ListView.builder(
          controller: _scroll,
          itemExtent: _rowH,
          padding: const EdgeInsets.symmetric(vertical: _listPadV),
          itemCount: rows.length,
          itemBuilder: (context, i) {
            final row = rows[i];
            return _JsonRowView(
              row: row,
              matched: search?.matched.contains(row.node.path) ?? false,
              onToggle: _toggle,
            );
          },
        ),
      ),
    );
  }

  Widget _toolbar(BuildContext context) {
    final colors = context.colors;
    final root = _root;

    return Container(
      height: 38,
      padding: const EdgeInsets.only(left: 12, right: 6),
      decoration: BoxDecoration(
        color: colors.panel2,
        border: Border(bottom: BorderSide(color: colors.line)),
      ),
      child: Row(
        children: [
          if (root != null)
            Text(
              _rootSummary(root),
              style: _mono(context, colors.mut2).copyWith(fontSize: 12),
            ),
          const Spacer(),
          if (widget.searchable && root != null) ...[
            _searchField(context),
            const SizedBox(width: 4),
          ],
          if (root != null) ...[
            _iconButton(
              context,
              Icons.unfold_more_rounded,
              'Expand all',
              _expandAll,
            ),
            _iconButton(
              context,
              Icons.unfold_less_rounded,
              'Collapse all',
              _collapseAll,
            ),
            _CopyButton(_pretty),
          ],
        ],
      ),
    );
  }

  Widget _searchField(BuildContext context) {
    final colors = context.colors;
    return SizedBox(
      width: 180,
      height: 28,
      child: TextField(
        controller: _search,
        style: context.type.bodySmall,
        cursorColor: colors.accent,
        decoration: InputDecoration(
          isDense: true,
          filled: true,
          fillColor: colors.panel,
          hintText: 'Search',
          hintStyle: context.type.bodySmall.copyWith(color: colors.mut2),
          prefixIcon: Icon(
            Icons.search_rounded,
            size: FwIconSize.md,
            color: colors.mut2,
          ),
          prefixIconConstraints: const BoxConstraints(
            minWidth: 28,
            minHeight: 28,
          ),
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 8,
            vertical: 6,
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(context.radii.radiusSmall),
            borderSide: BorderSide(color: colors.line),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(context.radii.radiusSmall),
            borderSide: BorderSide(color: colors.accent, width: 1.5),
          ),
        ),
      ),
    );
  }

  Widget _iconButton(
    BuildContext context,
    IconData icon,
    String tooltip,
    VoidCallback onTap,
  ) {
    final colors = context.colors;
    return Tooltip(
      message: tooltip,
      child: Tappable(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(6),
          child: Icon(icon, size: FwIconSize.lg, color: colors.mut),
        ),
      ),
    );
  }

  Widget _errorBanner(BuildContext context) {
    final colors = context.colors;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            Icons.error_outline_rounded,
            size: FwIconSize.md,
            color: colors.red,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'Invalid JSON — $_parseError',
              style: _mono(context, colors.red).copyWith(fontSize: 12),
            ),
          ),
        ],
      ),
    );
  }

  Widget _hint(BuildContext context, String text) {
    return Container(
      height: 60,
      alignment: Alignment.center,
      child: Text(
        text,
        style: context.type.bodySmall.copyWith(color: context.colors.mut2),
      ),
    );
  }

  String _rootSummary(JsonNode root) => switch (root.kind) {
    JsonNodeKind.object =>
      '{ } ${root.childCount} ${plural(root.childCount, 'key')}',
    JsonNodeKind.array =>
      '[ ] ${root.childCount} ${plural(root.childCount, 'item')}',
    _ => root.kind.name,
  };
}

/// Copies the pretty-printed document, with a moment of confirmation.
class _CopyButton extends StatefulWidget {
  final String text;

  const _CopyButton(this.text);

  @override
  State<_CopyButton> createState() => _CopyButtonState();
}

class _CopyButtonState extends State<_CopyButton> {
  var _copied = false;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Tooltip(
      message: 'Copy JSON',
      child: Tappable(
        onTap: () async {
          await Clipboard.setData(ClipboardData(text: widget.text));
          if (!mounted) return;
          setState(() => _copied = true);
          await Future<void>.delayed(const Duration(seconds: 1));
          if (mounted) setState(() => _copied = false);
        },
        child: Padding(
          padding: const EdgeInsets.all(6),
          child: Icon(
            _copied ? Icons.check_rounded : Icons.copy_rounded,
            size: FwIconSize.md,
            color: _copied ? colors.grn : colors.mut,
          ),
        ),
      ),
    );
  }
}

/// A single line of the tree. Container open/collapsed/closing lines are tap
/// targets that fold; leaf lines are inert so their value stays selectable.
class _JsonRowView extends StatelessWidget {
  final JsonRow row;
  final bool matched;
  final ValueChanged<String> onToggle;

  const _JsonRowView({
    required this.row,
    required this.matched,
    required this.onToggle,
  });

  @override
  Widget build(BuildContext context) {
    final node = row.node;
    final foldable = node.isContainer && !node.isEmpty;
    final tappable = foldable; // open, collapsed and closing lines all fold

    final content = Padding(
      padding: EdgeInsets.only(left: 8 + node.depth * _indent, right: 8),
      child: Row(
        children: [
          _disclosure(context),
          Expanded(child: _line(context)),
        ],
      ),
    );

    if (!tappable) {
      return Container(
        height: _rowH,
        color: matched ? context.colors.amber.withValues(alpha: 0.12) : null,
        child: content,
      );
    }

    return Tappable(
      onTap: () => onToggle(node.path),
      child: Container(
        height: _rowH,
        color: matched ? context.colors.amber.withValues(alpha: 0.12) : null,
        child: content,
      ),
    );
  }

  Widget _disclosure(BuildContext context) {
    final node = row.node;
    if (row.closing || !node.isContainer || node.isEmpty) {
      return const SizedBox(width: _indent);
    }
    return SizedBox(
      width: _indent,
      child: Icon(
        row.collapsed ? Icons.chevron_right_rounded : Icons.expand_more_rounded,
        size: FwIconSize.md,
        color: context.colors.mut2,
      ),
    );
  }

  Widget _line(BuildContext context) {
    final colors = context.colors;
    final node = row.node;
    final spans = <InlineSpan>[];

    final open = node.kind == JsonNodeKind.array ? '[' : '{';
    final close = node.kind == JsonNodeKind.array ? ']' : '}';

    if (row.closing) {
      spans.add(_span(context, close, colors.mut));
      if (!row.last) spans.add(_span(context, ',', colors.mut));
      return _text(context, spans);
    }

    if (node.key != null) {
      spans
        ..add(_span(context, jsonEncode(node.key), colors.accent))
        ..add(_span(context, ': ', colors.mut));
    }

    if (node.isContainer) {
      if (node.isEmpty) {
        spans.add(_span(context, '$open$close', colors.mut));
        if (!row.last) spans.add(_span(context, ',', colors.mut));
      } else if (row.collapsed) {
        final n = node.childCount;
        final unit = node.kind == JsonNodeKind.array ? 'item' : 'key';
        spans
          ..add(_span(context, '$open ', colors.mut))
          ..add(_span(context, '$n ${plural(n, unit)}', colors.mut3))
          ..add(_span(context, ' $close', colors.mut));
        if (!row.last) spans.add(_span(context, ',', colors.mut));
      } else {
        spans.add(_span(context, open, colors.mut));
      }
      return _text(context, spans);
    }

    spans.add(_span(context, node.encoded, _leafColor(node.kind, colors)));
    if (!row.last) spans.add(_span(context, ',', colors.mut));
    return _text(context, spans);
  }

  Widget _text(BuildContext context, List<InlineSpan> spans) {
    return Text.rich(
      TextSpan(children: spans),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
    );
  }

  InlineSpan _span(BuildContext context, String text, Color color) =>
      TextSpan(text: text, style: _mono(context, color));
}

Color _leafColor(JsonNodeKind kind, FwPalette colors) => switch (kind) {
  JsonNodeKind.string => colors.grn,
  JsonNodeKind.number => colors.amber,
  JsonNodeKind.boolean => colors.red,
  JsonNodeKind.nul => colors.red,
  _ => colors.ink,
};

/// [FwTypography.mono] with the tree's own line height — rows this dense read
/// better a notch tighter than the token's default.
TextStyle _mono(BuildContext context, Color color) =>
    context.type.mono.copyWith(color: color, height: 1.2);
