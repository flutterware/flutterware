import 'action.dart';
import 'child.dart';
import 'status_badge.dart';
import 'guard.dart';
import 'status.dart';
import 'teardown.dart';
import 'view.dart';

/// Everything a plugin says about itself right now — **all of it data**.
///
/// A native plugin draws a real Flutter widget for humans, but it emits one of
/// these too, so the shell, `fw`, a file projection and an agent all read the
/// same thing. Nothing
/// here may become a widget, a `Color`, or a closure: the moment it does, every
/// non-GUI renderer loses that capability permanently.
class PluginReport {
  const PluginReport({
    required this.id,
    required this.label,
    this.description,
    this.status = Status.none,
    this.badge = StatusBadge.none,
    this.actions = const [],
    this.teardown = const [],
    this.guards = const [],
    this.children = const [],
    this.view = PluginView.empty,
  });

  final String id;
  final String label;

  /// One sentence saying what this *kind* of plugin is for, or null.
  ///
  /// The subject is the core rather than the project: "which lint rules this
  /// repo evaluated, and which it never did" is true of every project that
  /// declares the plugin, which is why nothing here comes from
  /// `PluginDeclaration`. What *this* project declared is [label] and the
  /// config behind it.
  ///
  /// It exists because a reader with only the id has to infer the subject
  /// from the action names, and `flutterware.dev_stack` does not survive that
  /// inference. `docs/capabilities.md` is the reader it was written for — the
  /// document an agent reads *instead of* calling, where until now a plugin
  /// section was a heading and a list of verbs.
  ///
  /// Optional, and null-tolerant everywhere it is read: this type is
  /// published, so a report built against a version of it that predates the
  /// field is still a report.
  final String? description;

  final Status status;
  final StatusBadge badge;
  final List<PluginAction> actions;
  final List<TeardownStep> teardown;
  final List<Guard> guards;

  /// Sub-entries — one per package for a package-scoped plugin. The sidebar
  /// collapses to [status] and expands to these.
  final List<PluginChild> children;

  /// What the panel is currently showing.
  final PluginView view;

  /// [includeActions] is off for a renderer whose caller has another way to
  /// read the declarations, and for whom carrying them is not free. It covers
  /// [description] too, which is a declaration in the same sense — one static
  /// sentence, the same on every project and in every reply.
  ///
  /// Measured, not tidied. An action declaration is static — the same bytes
  /// every time — and it dominates a report: on flutterware's own repo the
  /// Previews report is 39k characters of JSON, 38k of it declarations. A
  /// terminal pays nothing for that, so `fw status --json` keeps them. An agent
  /// pays for every one of them in every reply, and already has a tool that
  /// serves them on request.
  ///
  /// [viewRows] caps every list and table in the projection, counting the rest
  /// — see [PluginView.capped]. Null keeps the projection whole, which is what
  /// a panel and a terminal want.
  ///
  /// [includeView] drops the projection entirely, leaving what the sidebar
  /// shows collapsed: the status line, the badge and the children. Measured on
  /// this repo, the view is **90%** of a status reply — 19.2k of 21.7k
  /// characters — because it is the inventory, and an inventory is what each
  /// plugin's own actions serve in full. A reader that wants to know which
  /// plugins are unhappy is asking about the other 10%.
  Map<String, Object?> toJson({
    bool includeActions = true,
    bool includeView = true,
    int? viewRows,
  }) => {
    'id': id,
    'label': label,
    if (includeActions && description != null) 'description': description,
    'status': status.toJson(),
    if (!badge.isEmpty) 'badge': badge.toJson(),
    if (includeActions && actions.isNotEmpty)
      'actions': [for (var a in actions) a.toJson()],
    if (teardown.isNotEmpty) 'teardown': [for (var t in teardown) t.toJson()],
    if (guards.isNotEmpty) 'guards': [for (var g in guards) g.toJson()],
    if (children.isNotEmpty) 'children': [for (var c in children) c.toJson()],
    if (includeView && !view.isEmpty)
      'view': (viewRows == null ? view : view.capped(viewRows)).toJson(),
  };

  /// The whole plugin as plain text — the shape `fw` prints and an agent reads.
  ///
  /// [includeView] off drops the panel projection, as [toJson]'s does and for
  /// the same measured reason: the view is the inventory, and a reader asking
  /// which plugins are unhappy is asking about the rest.
  String toText({bool includeView = true}) {
    var out = StringBuffer();
    out.write(label);
    if (!status.isEmpty) out.write('  ${status.message}');
    out.writeln();

    // A package-scoped plugin names each package twice: once as a child, once
    // as the title of the section its projection gives that package. Printed
    // straight through that is the package on two adjacent lines with nothing
    // between them — sometimes spelled two ways, `root` over `.`, which reads
    // as two packages rather than one said twice. So a section that belongs
    // to a child is retitled with the child's own label and status, and the
    // standalone line goes: one line per package, and nothing lost. Children
    // the projection has no section for still print; `--brief` renders no
    // view at all and is untouched.
    var byName = {
      for (var child in children) ...{child.label: child, child.id: child},
    };
    var folded = <String>{};
    var nodes = <ViewNode>[];
    if (includeView) {
      for (var node in view.nodes) {
        if (node is ViewSection) {
          var child = byName[node.title];
          if (child != null && !folded.contains(child.id)) {
            folded.add(child.id);
            node = ViewSection(
              child.status.isEmpty
                  ? child.label
                  : '${child.label}  ${child.status.message}',
              node.children,
            );
          }
        }
        nodes.add(node);
      }
    }

    for (var child in children) {
      if (folded.contains(child.id)) continue;
      out.write('  ${child.label}');
      if (!child.status.isEmpty) out.write('  ${child.status.message}');
      out.writeln();
    }
    if (includeView) {
      var body = PluginView(nodes).toText();
      if (body.isNotEmpty) {
        for (var line in body.split('\n')) {
          out.writeln('  $line');
        }
      }
    }
    return out.toString().trimRight();
  }

  @override
  String toString() => toText();
}
