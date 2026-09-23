// What the token surfaces — the outline's section, the drawer's pane and
// header — need from whoever opened the workspace: the libraries the group
// lists, and the doors that reach past this one file.
//
// A token is shared by every scene of every group that lists its library,
// so renaming or deleting one is not this editor's call alone: the host
// (the panel, which can scan the package) says whether a delete is refused
// and follows a rename into the files that are not open. Without a host —
// a test, the catalog — the surfaces fall back to this file and the
// library alone.
import 'package:material_ui/material_ui.dart';
import 'package:flutterware/scene_authoring.dart';

import '../../ui/menu.dart';
import '../editor.dart';
import '../tokens_library.dart';
import 'param_pane.dart';

class SceneTokensHost {
  const SceneTokensHost({
    required this.libraries,
    this.onNewLibrary,
    this.rename,
    this.delete,
    this.deleteProblem,
    this.readersElsewhere,
    this.importInto,
  });

  /// Picks a design file's variables JSON and merges it into the library
  /// at [path] — the open document, so the pane follows and the autosave
  /// writes. Null hides the door.
  final Future<void> Function(String path)? importInto;

  /// The libraries the open file's group lists, in the declaration's order.
  final List<TokensLibrary> libraries;

  /// Creates a library in the group's folder and lists it there; null
  /// hides the door.
  final VoidCallback? onNewLibrary;

  /// Renames [name] across the group — the library, this file, and every
  /// other scene reading it. Throws an [ArgumentError] to refuse.
  final void Function(String name, String wanted)? rename;

  /// Deletes [name] from its library — refused while anything reads it,
  /// which [deleteProblem] says first.
  final void Function(String name)? delete;

  /// Why [name] cannot be deleted now — read by nodes in other scenes —
  /// or null.
  final String? Function(String name)? deleteProblem;

  /// The readers of [name] in scenes other than the open one, as
  /// `Scene · node.prop`, for the pane.
  final List<String> Function(String name)? readersElsewhere;

  /// The library at [path], or null when the group does not list it.
  TokensLibrary? libraryAt(String path) =>
      libraries.where((l) => l.path == path).firstOrNull;

  /// The library declaring [name], or null for an export.
  TokensLibrary? libraryOf(String name) {
    for (var library in libraries) {
      if (library.named(name) != null) return library;
    }
    return null;
  }

  /// Every token name the group uses — what a new or renamed token must
  /// not collide with.
  Set<String> takenIn(SceneEditor editor) => {
    for (var t in editor.doc.tokens) t.name,
    for (var l in libraries)
      for (var t in l.tokens) t.name,
  };

  /// The default rename: the library, then this file's readers.
  void renameHere(SceneEditor editor, String name, String wanted) {
    var library = libraryOf(name);
    if (library == null) {
      throw ArgumentError("\"$name\" is the app's — rename it in the app");
    }
    library.rename(name, wanted, taken: takenIn(editor)..remove(name));
    editor.renameTokenRefs(name, wanted);
  }
}

/// The entries that add a token to [library] — one per kind, then a style
/// — named after the kind and opened at once, so the name is the first
/// thing typed. [onAdded] takes the new token's name.
List<MenuEntry> newTokenEntries(
  SceneEditor editor,
  SceneTokensHost host,
  TokensLibrary library, {
  required ValueChanged<String> onAdded,
}) {
  Set<String> taken() =>
      host.takenIn(editor)..removeAll(library.tokens.map((t) => t.name));
  return [
    MenuHeader('New token in ${library.symbol}'),
    for (var (kind, label, type) in paramKinds)
      MenuItem(
        label,
        icon: paramKindIcon(kind),
        shortcut: type,
        onSelected: () {
          var free = taken();
          var name = library.freeName(kind.name, taken: free);
          library.add(name, kind, taken: free);
          onAdded(name);
        },
      ),
    MenuItem(
      'Style',
      icon: Icons.text_format,
      shortcut: 'SceneTextStyle',
      onSelected: () {
        var free = taken();
        var name = library.freeName('style', taken: free);
        library.addStyle(name, taken: free);
        onAdded(name);
      },
    ),
  ];
}

/// The word a token's value is shown as beside its name.
String tokenValueLabel(SceneTokenDecl t) {
  if (t.isExport) return t.type;
  if (t.style case var s?) {
    return [
      if (s.fontSize case var v?) shortNumber(v),
      if (s.weight case var w?) 'w${w.value}',
      if (s.color != null) 'colour',
    ].join(' · ');
  }
  return switch (t.value) {
    SceneColor c =>
      '#${c.argb.toRadixString(16).toUpperCase().padLeft(8, '0').substring(2)}',
    double d => shortNumber(d),
    String s => s.length > 14 ? "'${s.substring(0, 13)}…'" : "'$s'",
    bool b => b ? 'on' : 'off',
    var v => '$v',
  };
}

/// A number as a label: whole when it is whole, two decimals at most, and
/// no trailing zeros. A value the editor wrote is rounded already; one a
/// hand-written file carries may not be, and a caption is not the place to
/// print seventeen digits of it.
String shortNumber(double v) {
  if (v == v.roundToDouble() && v.abs() < 1e15) return '${v.round()}';
  return v
      .toStringAsFixed(2)
      .replaceFirst(RegExp(r'0+$'), '')
      .replaceFirst(RegExp(r'\.$'), '');
}

IconData tokenIcon(SceneTokenDecl t) {
  if (t.isExport) return Icons.ios_share_outlined;
  if (t.isStyle) return Icons.text_format;
  return paramKindIcon(t.kind ?? SceneParamKind.string);
}

/// What a token is, in the drawer header's caption.
String tokenFacts(SceneEditor editor, SceneTokensHost? host, String name) {
  var decl = editor.doc.tokenNamed(name);
  if (decl == null) return '';
  var readers = editor.readersOfToken(name).length;
  var where = decl.isExport
      ? 'from the app'
      : (host?.libraryOf(name)?.fileName ?? 'library');
  var what = decl.isStyle
      ? 'style'
      : decl.isExport
      ? decl.type
      : '${paramKindLabel(decl.kind!)} · ${decl.typeName}';
  return '$what · $where · read by $readers here';
}

/// The menu a token offers, wherever it is asked for — its row in the
/// tree, the drawer's header: rename, make local, delete. Delete is
/// refused, not hidden, while something reads the token, and says what.
List<MenuEntry> tokenMenu(
  SceneEditor editor,
  SceneTokensHost? host,
  String name, {
  required VoidCallback onRename,
}) {
  var decl = editor.doc.tokenNamed(name);
  if (decl == null) return const [];
  var readersHere = editor.readersOfToken(name);
  var here = readersHere.isEmpty
      ? null
      : 'read by ${readersHere.map((r) => '${r.$1.name}.${r.$2}').join(', ')}';
  var elsewhere = host?.deleteProblem?.call(name);
  var problem = here ?? elsewhere;
  var localizable = decl.hasValue && !decl.isStyle;
  return [
    if (!decl.isExport)
      MenuItem(
        'Rename',
        icon: Icons.edit_outlined,
        shortcut: 'double-click',
        onSelected: onRename,
      ),
    if (localizable)
      MenuItem(
        'Make local',
        icon: Icons.call_received,
        shortcut: 'a parameter of this scene',
        onSelected: () => editor.localizeToken(name),
      ),
    if (!decl.isExport) ...[
      const MenuDivider(),
      MenuItem(
        problem == null ? 'Delete' : 'Delete — $problem',
        icon: Icons.delete_outline,
        danger: true,
        onSelected: problem != null
            ? null
            : () =>
                  (host?.delete ?? (n) => host?.libraryOf(n)?.delete(n))(name),
      ),
    ],
  ];
}
