import 'address.dart';
import 'tone.dart';

/// A plugin's answer to "what are you showing right now?", as data.
///
/// Native plugins draw real Flutter widgets for humans. They *also* emit one of
/// these, so the same state reaches `fw`, a file projection, and an agent. The
/// panel forks; the contract does not.
///
/// This is deliberately **not** a rendering kit — nothing interprets these
/// nodes to build the GUI. It is a projection: a summary faithful enough that
/// reading it tells you what is on screen.
class PluginView {
  const PluginView(this.nodes);

  static const empty = PluginView([]);

  final List<ViewNode> nodes;

  bool get isEmpty => nodes.isEmpty;

  /// Renders the projection as an indented plain-text tree — what `fw` prints
  /// and what an agent reads.
  String toText() {
    var out = StringBuffer();
    for (var node in nodes) {
      node.writeText(out, 0);
    }
    return out.toString().trimRight();
  }

  List<Map<String, Object?>> toJson() => [for (var n in nodes) n.toJson()];

  /// The same projection with no list or table longer than [maxRows], the rest
  /// counted in [ViewItems.truncated].
  ///
  /// For a reader that pays by the row. An agent's whole reply has a size
  /// ceiling, and a plugin that lists every dependency of every package spends
  /// it on a catalog it has an action for: `flutterware_status` was 10k tokens
  /// on this repo, three quarters of it item rows, before a question had been
  /// asked. The panel and `fw` keep the full list — a window scrolls and a
  /// terminal pipes.
  ///
  /// Capping, never dropping: the count rides along, so a short answer says it
  /// is short.
  PluginView capped(int maxRows) =>
      PluginView([for (var n in nodes) n.capped(maxRows)]);

  @override
  String toString() => toText();
}

sealed class ViewNode {
  const ViewNode();

  Map<String, Object?> toJson();

  void writeText(StringBuffer out, int depth);

  /// This node with its rows capped — see [PluginView.capped]. A node that
  /// holds no rows is its own answer.
  ViewNode capped(int maxRows) => this;

  static String _pad(int depth) => '  ' * depth;
}

/// A titled group. The only node that nests.
class ViewSection extends ViewNode {
  const ViewSection(this.title, this.children);

  final String title;
  final List<ViewNode> children;

  @override
  Map<String, Object?> toJson() => {
    'node': 'section',
    'title': title,
    'children': [for (var c in children) c.toJson()],
  };

  @override
  void writeText(StringBuffer out, int depth) {
    out.writeln('${ViewNode._pad(depth)}$title');
    for (var child in children) {
      child.writeText(out, depth + 1);
    }
  }

  @override
  ViewNode capped(int maxRows) =>
      ViewSection(title, [for (var c in children) c.capped(maxRows)]);
}

/// A free line of prose — a summary, a hint, an error message.
class ViewText extends ViewNode {
  const ViewText(this.text, {this.tone = Tone.neutral});

  final String text;
  final Tone tone;

  @override
  Map<String, Object?> toJson() => {
    'node': 'text',
    'text': text,
    if (tone != Tone.neutral) 'tone': tone.name,
  };

  @override
  void writeText(StringBuffer out, int depth) {
    out.writeln('${ViewNode._pad(depth)}$text');
  }
}

/// A labelled value — the workhorse.
class ViewField extends ViewNode {
  const ViewField(this.label, this.value, {this.tone = Tone.neutral});

  final String label;
  final String value;
  final Tone tone;

  @override
  Map<String, Object?> toJson() => {
    'node': 'field',
    'label': label,
    'value': value,
    if (tone != Tone.neutral) 'tone': tone.name,
  };

  @override
  void writeText(StringBuffer out, int depth) {
    out.writeln('${ViewNode._pad(depth)}$label: $value');
  }
}

/// One row of a [ViewItems] list: a name plus optional trailing state.
class ViewItem {
  const ViewItem(
    this.label, {
    this.detail,
    this.tone = Tone.neutral,
    this.address,
  });

  final String label;
  final String? detail;
  final Tone tone;

  /// Where this row *is*, when it is a thing rather than a line of output.
  ///
  /// Identity, not decoration — which is why it belongs in a projection that
  /// otherwise refuses anything a non-GUI renderer could not use. An address is
  /// the one string the GUI, `fw`, MCP and an artifact all already carry, so a
  /// row that has one becomes equally reachable from all four: search navigates
  /// to it, `fw` prints something you can paste back, and an agent can act on it
  /// without a second lookup to ask "which entry was that?".
  ///
  /// Null for rows that name no destination — a count, a diagnostic, a version.
  /// A plugin that leaves it null loses nothing it had; the row is simply found
  /// and not followed.
  final Address? address;

  Map<String, Object?> toJson() => {
    'label': label,
    if (detail != null) 'detail': detail,
    if (tone != Tone.neutral) 'tone': tone.name,
    if (address != null) 'address': address!.toString(),
  };
}

/// A flat list — catalog entries, failing tests, running processes.
class ViewItems extends ViewNode {
  const ViewItems(this.items, {this.truncated = 0});

  final List<ViewItem> items;

  /// How many further items exist but were left out. Never silently drop rows:
  /// a projection that looks complete when it is not is worse than a long one.
  final int truncated;

  @override
  Map<String, Object?> toJson() => {
    'node': 'items',
    'items': [for (var i in items) i.toJson()],
    if (truncated > 0) 'truncated': truncated,
  };

  @override
  void writeText(StringBuffer out, int depth) {
    var pad = ViewNode._pad(depth);
    var width = items.fold(
      0,
      (w, i) => i.label.length > w ? i.label.length : w,
    );
    for (var item in items) {
      out.write('$pad- ${item.label}');
      if (item.detail != null) {
        out.write('${' ' * (width - item.label.length + 2)}${item.detail}');
      }
      out.writeln();
    }
    if (truncated > 0) {
      out.writeln('$pad… $truncated more');
    }
  }

  @override
  ViewNode capped(int maxRows) => items.length <= maxRows
      ? this
      : ViewItems(
          items.take(maxRows).toList(),
          truncated: truncated + items.length - maxRows,
        );
}

/// A table with a header row. Columns are aligned in the text rendering.
class ViewTable extends ViewNode {
  const ViewTable(this.columns, this.rows, {this.truncated = 0});

  final List<String> columns;
  final List<List<String>> rows;

  /// Rows omitted from this projection — see [ViewItems.truncated].
  final int truncated;

  @override
  Map<String, Object?> toJson() => {
    'node': 'table',
    'columns': columns,
    'rows': rows,
    if (truncated > 0) 'truncated': truncated,
  };

  @override
  void writeText(StringBuffer out, int depth) {
    var pad = ViewNode._pad(depth);
    var widths = [
      for (var (i, column) in columns.indexed)
        rows.fold(column.length, (w, row) {
          var cell = i < row.length ? row[i] : '';
          return cell.length > w ? cell.length : w;
        }),
    ];

    void writeRow(List<String> cells) {
      var parts = [
        for (var (i, width) in widths.indexed)
          (i < cells.length ? cells[i] : '').padRight(width),
      ];
      out.writeln('$pad${parts.join('  ').trimRight()}');
    }

    writeRow(columns);
    for (var row in rows) {
      writeRow(row);
    }
    if (truncated > 0) {
      out.writeln('$pad… $truncated more');
    }
  }

  @override
  ViewNode capped(int maxRows) => rows.length <= maxRows
      ? this
      : ViewTable(
          columns,
          rows.take(maxRows).toList(),
          truncated: truncated + rows.length - maxRows,
        );
}
