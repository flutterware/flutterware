// ignore: implementation_imports
import 'package:flutterware/src/inspect/node.dart';
// ignore: implementation_imports
import 'package:flutterware/src/inspect/screen.dart';

/// One tree, shaped into whatever the call asked for.
///
/// The whole of a reply's screen half, in one place, because it is one
/// reading: the screen, the scoped tree, `find`, `at` and `styles` all come out
/// of the same nodes, and answering them from separate reads would be
/// answering about separate moments.
///
/// Shared by run, previews and scenarios. Each surface answers a different
/// question to get *which* tree — a live app, an entry it re-renders, a step
/// of a finished run — and from there the grammar is identical: same parameter
/// names, same reply shape, one implementation over [InspectTree]. The
/// selector is the only thing the three cannot share, which is why it is the
/// caller's job and this takes a tree.
class ScreenRead {
  const ScreenRead({
    this.screen,
    this.tree,
    this.nodes,
    this.find,
    this.at,
    this.styles,
    this.note,
  });

  /// How many nodes a `find` brings back before it stops listing them.
  ///
  /// A query that matches nearly everything is a question about the *set*
  /// rather than about its members — `find "Text("` matched 63 nodes and cost
  /// 2451 tokens without finishing. The cap keeps the answer readable and the
  /// count says what was left out; `styles` is the shape to reach for when the
  /// aggregate is what was wanted.
  static const findLimit = 30;

  /// How deep an `at` chain goes, counting inward.
  ///
  /// Measured: the full chain under a point is 35 nodes and 1258 tokens, of
  /// which the outermost 20 are the root wrapper run that sits under every
  /// point on every screen. The innermost eight carry the answer.
  static const chainDepth = 8;

  final Screen? screen;
  final Map<String, Object?>? tree;
  final int? nodes;
  final List<Map<String, Object?>>? find;
  final List<Map<String, Object?>>? at;
  final List<InspectStyle>? styles;

  /// A query that could not be answered, said in a way the caller can act on.
  ///
  /// It rides the note rather than `error` for the same reason a refused
  /// `treeRoot` always did on the drive path: the verb landed. Saying
  /// otherwise would send the caller back to redo something that already
  /// happened.
  final String? note;

  /// What this read handed back, for a journal's testimony half.
  List<String> reported({required bool wantsShot}) => [
    if (screen != null) 'screen',
    if (tree != null) 'tree',
    if (find != null) 'find',
    if (at != null) 'at',
    if (styles != null) 'styles',
    if (wantsShot) 'screenshot',
  ];

  /// One node, flat.
  ///
  /// Without its children, which is the whole point. `find` and `at`
  /// return nodes out of the middle of a tree, and a node serialised whole
  /// carries its subtree: measured, `find "Watching"` matched a container near
  /// the root and came back as 36,512 tokens — a hundred times the tree it was
  /// supposed to be an alternative to. The source is spelled relative to the
  /// worktree for the same reason the tree's compact spelling exists: the same
  /// absolute path on thirty nodes is most of the reply.
  ///
  /// `style` is [InspectNode.styleLine] rather than the whole resolved map,
  /// and that is the same trade: the map is ten keys and ~70 tokens, thirty of
  /// which would be most of a `find`. The line is the four fields anyone
  /// scanning a list is scanning for. It is also what makes
  /// `matching`'s promise — *"`find "Watching"` answers what colour and size
  /// is that label"* — true for a text that took its style from the theme,
  /// which until the resolved style existed it was not.
  static Map<String, Object?> describe(InspectNode node, String? worktree) => {
    'id': node.id,
    'type': node.type,
    if (node.description != null) 'is': node.description,
    if (node.label != null) 'label': node.label,
    if (node.selected != null) 'sel': node.selected,
    if (node.layout case var layout?)
      'box': [
        layout.x.round(),
        layout.y.round(),
        layout.width.round(),
        layout.height.round(),
      ],
    if (node.layout?.flex case var flex?) 'flex': flex.toJson(),
    if (node.source case var source?)
      'src': source.describe(relativeTo: worktree),
    if (node.properties.isNotEmpty) 'props': node.properties,
    'style': ?node.styleLine,
    if (node.children.isNotEmpty) 'children': node.children.length,
  };

  /// The one line a default reply carries so the drill-down gets used.
  ///
  /// A schema an agent read once at connection time is not where it will look
  /// on step forty, so the reply that could have answered more says what it
  /// could have answered. ~20 tokens.
  static const offer =
      'More off this same frame, no re-read: find "Save" · at "120,300" · '
      'styles: true · tree: true (~20k tokens) · lens: look for a picture.';

  static ScreenRead of(
    InspectTree? full,
    Map<String, Object?> arguments, {
    required bool wantsTree,
    required bool wantsStyles,
    String? worktree,
  }) {
    if (full == null) return const ScreenRead();

    var wantsScreen = arguments['screen'] == null
        ? true
        : boolArgument(arguments['screen']);
    var projected = wantsScreen
        ? Screen.tryOf(full)
        : (screen: null, note: null);
    var screen = projected.screen;

    // `find`, `at` and `styles` run over the *filtered* tree — the wrappers
    // are never the answer to any of the three, and an unfiltered `at` chain
    // is 20 nodes of root scaffolding before it reaches the screen.
    var narrowed = full.filtered(const InspectFilter());

    List<Map<String, Object?>>? found;
    if (arguments['find'] case var query? when '$query'.isNotEmpty) {
      found = [
        for (var node in narrowed.matching('$query').take(findLimit))
          describe(node, worktree),
      ];
    }

    List<Map<String, Object?>>? at;
    var note = projected.note;
    if (arguments['at'] case var point? when '$point'.isNotEmpty) {
      var parts = '$point'.split(',');
      var x = parts.length == 2 ? double.tryParse(parts[0].trim()) : null;
      var y = parts.length == 2 ? double.tryParse(parts[1].trim()) : null;
      if (x == null || y == null) {
        var refused =
            'at: "$point" is not a point. Give it as "x,y" in logical '
            'pixels, the same space every box in this reply is in.';
        note = [?note, refused].join(' ');
      } else {
        var chain = narrowed.chainAt(x, y);
        var innermost = chain.length <= chainDepth
            ? chain
            : chain.sublist(chain.length - chainDepth);
        at = [for (var node in innermost) describe(node, worktree)];
      }
    }

    var styles = wantsStyles ? narrowed.styles() : null;

    Map<String, Object?>? tree;
    int? nodes;
    if (wantsTree) {
      try {
        var scoped = full.filtered(
          InspectFilter(
            root: arguments['treeRoot'] as String?,
            maxDepth: int.tryParse('${arguments['treeDepth'] ?? ''}'),
            noise: arguments['treeNoise'] == null
                ? true
                : boolArgument(arguments['treeNoise']),
          ),
        );
        tree = scoped.toJson(compact: true);
        nodes = scoped.length;
      } on ArgumentError catch (e) {
        note = [?note, '${e.message}'].join(' ');
      }
    } else {
      nodes = narrowed.length;
    }

    return ScreenRead(
      screen: screen,
      tree: tree,
      nodes: nodes,
      find: found,
      at: at,
      styles: styles,
      note: note,
    );
  }

  /// A flag as it arrives from a JSON tool call or from `fw`'s argv, where the
  /// same `true` is a bool in one and a string in the other.
  static bool boolArgument(Object? value) => switch (value) {
    bool b => b,
    String s => s == 'true',
    _ => false,
  };
}
