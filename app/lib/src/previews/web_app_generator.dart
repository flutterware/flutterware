import 'dart:io';

// ignore: implementation_imports
import 'package:flutterware/src/clock.dart' show pinnedClockOrigin;
import 'package:path/path.dart' as p;

import '../utils/source_code/escape_dart_string.dart';
import 'catalog_entry.dart';
import 'catalog_tree.dart';
import 'catalog_wrapper.dart';
import 'preview_setup.dart';

/// Writes a standalone Flutter app that browses the whole catalog, for
/// `flutter build web` to turn into a page.
///
/// The old catalog was a widget you put in your own `main.dart`, so building it
/// for the web was building your app. Entries are discovered now and rendered
/// one at a time into a guest engine, so there is no such app any more — this
/// writes one.
///
/// It hosts the old [UICatalog] widget, and that is not a stopgap. The
/// tree, the search, the device frames and the parameters panel all already
/// work against the model the new demos produce: a demo declares its knobs by
/// calling `context.knobs.*`, which is the same API the old
/// catalog reads, and `DetailView` owns an `EditableKnobs` and installs
/// the provider itself. Knobs travel over the VM service in the GUI only
/// because the panel is in another process; here the panel and the demo are one
/// isolate and there is no wire at all.
///
/// The axes carry over on the same terms, and for the same reason. Nothing
/// drove `CatalogAxes` here, so a `PreviewShell` declared its axes and then
/// answered with the defaults it had written — silently, because a bar that is
/// absent does not look broken the way a dead one would, so a page published
/// to be read in a second language quietly only ever showed the first.
/// `AxesControls` reads `describe()` and calls `apply` directly; the shell
/// already rebuilds on `CatalogAxes.revision` by itself.
class WebAppGenerator {
  WebAppGenerator({
    required this.outputDir,
    required this.projectRoot,
    required this.title,
    this.clock,
    this.setup,
  });

  /// Where the generated sources go. Cleared on each run, so it must not be a
  /// directory anything else owns.
  final String outputDir;

  /// Resolves each entry's [CatalogEntry.path].
  final String projectRoot;

  /// What the page calls itself, in the menu's header.
  final String title;

  /// What `clock.now()` reads on the page, or null for `pinnedClockOrigin` —
  /// the project's own `fw.clock(...)`. It has to be the same instant the
  /// guest is given, which is why it travels rather than being read here.
  final DateTime? clock;

  /// The package's declared setup, awaited before the page is built — the
  /// same hook the guest and the harness run. See `PreviewsPackage.setup`.
  final PreviewSetup? setup;

  late final _wrappers = CatalogWrapperWriter(
    outputDir: outputDir,
    projectRoot: projectRoot,
  );

  String get entrypointPath => p.join(outputDir, 'main.dart');

  /// Writes a wrapper per entry and the `main.dart` that browses them.
  ///
  /// Returns the entrypoint's path, which is what `flutter build web -t` takes.
  String generate(List<CatalogEntry> entries) {
    // Before anything is cleared or written: a page importing a setup that is
    // not there fails `flutter build web` inside generated code.
    setup?.check(projectRoot);
    var dir = Directory(outputDir);
    // Cleared rather than merged into: an entry deleted since the last build
    // would otherwise keep its wrapper on disk, and a stale wrapper naming a
    // demo that no longer exists fails the build with a resolution error
    // pointing at generated code.
    if (dir.existsSync()) dir.deleteSync(recursive: true);
    dir.createSync(recursive: true);

    var index = <String, int>{};
    for (var (i, entry) in entries.indexed) {
      index[entry.id] = i;
      File(p.join(outputDir, 'entry_$i.dart'))
          .writeAsStringSync(_wrappers.source(entry, i));
    }

    File(entrypointPath).writeAsStringSync(_main(entries, index));
    return entrypointPath;
  }

  String _main(List<CatalogEntry> entries, Map<String, int> index) {
    var imports = StringBuffer();
    for (var i = 0; i < entries.length; i++) {
      imports.writeln("import 'entry_$i.dart' as fw$i;");
    }
    var setup = this.setup;
    if (setup != null) {
      imports.writeln(
        'import ${_literal(_wrappers.uriFor(p.join(projectRoot, setup.path)))} '
        'as fw_setup;',
      );
    }

    // The same tree the panel draws, from the same function, so an entry sits
    // in the same place on the page as it does in the GUI. Building a second
    // arrangement here would be two answers to "where is this demo".
    var tree = buildCatalogTree(entries);
    // Round-tripped through ISO for the reason the guest's entrypoint does it:
    // a `DateTime(y, m, d, h, min)` literal silently drops seconds and UTC.
    var clockLiteral =
        'DateTime.parse(${_literal((clock ?? pinnedClockOrigin).toIso8601String())})';

    return '''
// GENERATED — do not edit.
import 'package:flutter/widgets.dart';
import 'package:flutter/widget_previews.dart';
import 'package:clock/clock.dart';
import 'package:flutterware/ui_catalog.dart';

$imports
// Pinned here for the reason the guest pins it, and pinned *identically*: a
// page and a panel that disagree about what time it is are two pictures of
// the same entry that do not match. Which is why it is the instant the host
// worked out and passed down, not a constant read twice.
void main() => withClock(Clock.fixed($clockLiteral), () ${setup == null ? '' : 'async '}{
${setup == null ? '' : '  WidgetsFlutterBinding.ensureInitialized();\n${setup.statements}'}  runApp(
    UICatalog(
      title: ${_literal(title)},
      catalog: () => _catalog,
      // A pass-through, because in this model the chrome is the entry's own:
      // the annotation's `wrapper:` supplies the MaterialApp, exactly as it does
      // for the guest, whose host adds nothing either. An entry with no wrapper still
      // has the catalog's own MaterialApp above it for a Directionality and a
      // theme.
      appBuilder: (context, child) => child,
    ),
  );
});

// A getter, never a top-level final: the leaves below are widgets, and widgets
// built once and handed back on every build are the ones that do not rebuild
// when a knob moves.
Map<String, dynamic> get _catalog => ${_map(tree, index, 1)};

/// One entry, wrapped the way the guest wraps it.
///
/// Wrapper only — not `size`, `theme` or `brightness`. That is what
/// `_CatalogHost` in the guest's entrypoint applies, and the two have to agree:
/// an entry that looks one way in the panel and another on the page is worse
/// than one that ignores an annotation in both.
///
/// Typed as `Preview` rather than any subclass: the page hosts whatever the
/// scan accepted, and the scan accepts Flutter's own annotation.
Widget _entry(Preview demo, Widget Function() builder) {
  var wrapper = demo.transform().wrapper;
  var child = builder();
  return wrapper == null ? child : wrapper(child);
}
''';
  }

  /// The nested map [UICatalog] reads: a `Map` is a folder, anything else is a
  /// leaf.
  String _map(List<CatalogNode> nodes, Map<String, int> index, int depth) {
    var pad = '  ' * depth;
    var inner = '  ' * (depth + 1);
    if (nodes.isEmpty) return '<String, dynamic>{}';
    // The map is keyed by what a row *says*, and two rows are allowed to say
    // the same thing — discovery rejects a duplicate id, not a duplicate name,
    // so `demo/a.dart` and `demo/b.dart` may both declare `@Preview(name:
    // 'Default')`. A folder may also share a name with an entry beside it.
    // Emitted as-is that is a repeated key in a map literal: the last one wins
    // at run time and the others are simply not on the page, which is the one
    // failure this generator must not have — the panel keys its tree by id and
    // shows them all.
    var taken = <String>{};
    var buffer = StringBuffer('<String, dynamic>{\n');
    for (var node in nodes) {
      switch (node) {
        case CatalogBranch(:var children):
          buffer.writeln(
            '$inner${_literal(_uniqueKey(node.label, null, taken))}: '
            '${_map(children, index, depth + 1)},',
          );
        case CatalogLeaf(:var entry):
          var i = index[entry.id]!;
          var key = _uniqueKey(node.label, entry, taken);
          buffer.writeln(
            '$inner${_literal(key)}: _entry(fw$i.fwPreview, fw$i.fwBuilder),',
          );
      }
    }
    buffer.write('$pad}');
    return buffer.toString();
  }

  /// [label], or something derived from it that no sibling has taken yet.
  ///
  /// The suffix is chosen to be worth reading rather than merely unique: the
  /// symbol is what tells two same-named demos apart in the source, and it is
  /// what `fw` prints. Two files declaring the same name *and* the same symbol
  /// fall back to the entry id, which discovery guarantees is unique — so this
  /// always terminates, and a branch with no entry behind it counts up.
  static String _uniqueKey(
    String label,
    CatalogEntry? entry,
    Set<String> taken,
  ) {
    if (taken.add(label)) return label;
    if (entry != null) {
      for (var candidate in [
        '$label (${entry.symbol})',
        '$label (${entry.id})',
      ]) {
        if (taken.add(candidate)) return candidate;
      }
    }
    for (var n = 2; ; n++) {
      if (taken.add('$label ($n)')) return '$label ($n)';
    }
  }

  /// A quoted Dart string literal.
  ///
  /// Escaped rather than raw: an entry's display name is written by a human in
  /// an annotation and may hold a quote or a `$`, and a raw string cannot
  /// escape its own delimiter. Shared with the harness and the guest entrypoint
  /// rather than hand-rolled here — a private copy of this rule is how the
  /// harness came to be the one emitter that had never learned it.
  static String _literal(String value) => escapeDartString(value);
}
