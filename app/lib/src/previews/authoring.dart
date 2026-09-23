/// What to show for a package with no previews yet.
///
/// One string, in one place, reached by four surfaces: the `entries` result an
/// agent reads, the panel's empty state, the sidebar's status, and the daemon's
/// refusal. They used to say nothing, three different ways, and the fourth said
/// it thirty seconds late under a stack trace.
library;

/// What a package scans when it does not say otherwise: **all of it**.
///
/// The empty string is the package root. It is spelled here rather than left
/// implicit because scanning everything is a decision — previews used to be
/// findable only under `demo/`, and the single most common way to arrive at an
/// empty catalog was to have written one somewhere else.
const defaultCatalogRoot = '';

/// Where `new` writes a scaffold, and the directory the hint's example names.
///
/// Not the scan root. Nothing has to be here to be found; this is only the
/// answer to "where should this file go" when nothing says. A package that
/// declares `directory:` moves both at once — a narrowed scan and the place new
/// files land are then the same directory, which is the only reading of that
/// setting that is not surprising.
const defaultAuthoringDirectory = 'demo';

/// The annotations that mark an entry when a package registers none of its own.
///
/// Flutter's `@Preview`, and nothing of ours — one declaration serves both this
/// catalog and Flutter's own previewer because it *is* their declaration. A
/// project wanting fields the annotation does not carry declares its own
/// subclass and registers it here; the scan reads arguments by name, so
/// whatever it calls itself, an `id:` on it is still an `id:`.
const defaultPreviewAnnotations = ['Preview'];

/// How to write the first preview, given what [directory] this package scans.
///
/// Empty means the whole package, which is the default. A project that narrowed
/// the scan is told about *its* directory rather than about the convention it
/// chose not to follow.
String catalogAuthoringHint(String directory) {
  var scanned = directory.isEmpty
      ? 'every `.dart` file in the package is scanned, wherever it sits'
      : 'every `.dart` file under `$directory/` is scanned';
  var example = directory.isEmpty ? defaultAuthoringDirectory : directory;
  return '''
A preview is an ordinary function returning a Widget, annotated with Flutter's
own `@Preview`. Nothing of flutterware's is imported, and there is no map to
register it in — $scanned.

  // $example/buttons.dart
  import 'package:material_ui/material_ui.dart';
  import 'package:flutter/widget_previews.dart';

  @Preview(name: 'Buttons')
  Widget buttons() => const Column(
        children: [
          ElevatedButton(onPressed: null, child: Text('Elevated')),
          OutlinedButton(onPressed: null, child: Text('Outlined')),
        ],
      );

- The target must be callable with no arguments — a top-level function, a static
  method, or a constructor.
- `@Preview(group: 'Forms')` groups it; a file holding more than one entry
  derives a group from its own name.
- Two `@Preview`s on one declaration are two entries, which is how variants are
  spelled.
- An optional parameter is a knob you can turn from the panel, the CLI and an
  agent — `Widget buttons({String label = 'Hello'})`. So is
  `context.knobs.string('label', 'Hello')` read from a `BuildContext` inside the
  preview, which needs `package:flutterware/previews.dart`; nothing above it
  does.

`fw run previews new --name='Buttons'` writes that file for you.''';
}

/// The file `new` writes for a preview called [name].
String catalogFileName(String name) {
  var slug = name
      .toLowerCase()
      .replaceAll(RegExp('[^a-z0-9]+'), '_')
      .replaceAll(RegExp(r'^_+|_+$'), '');
  return '${slug.isEmpty ? 'preview' : slug}.dart';
}

/// Dart's reserved words, which cannot be an identifier at all.
///
/// Only the truly reserved ones. Built-in identifiers — `get`, `set`, `late`,
/// `required` and the rest — are legal names for a function, so renaming those
/// would be officious. `await` and `yield` are in for safety: they are reserved
/// only inside async and generator bodies, but a preview named either of them is
/// a coin flip nobody needs to win.
const _dartReservedWords = {
  'assert',
  'await',
  'break',
  'case',
  'catch',
  'class',
  'const',
  'continue',
  'default',
  'do',
  'else',
  'enum',
  'extends',
  'false',
  'final',
  'finally',
  'for',
  'if',
  'in',
  'is',
  'new',
  'null',
  'rethrow',
  'return',
  'super',
  'switch',
  'this',
  'throw',
  'true',
  'try',
  'var',
  'void',
  'while',
  'with',
  'yield',
};

/// The symbol inside it — the file's slug, lowerCamelCased.
///
/// Must be a legal Dart identifier, because the scaffold declares a
/// top-level function with this name and the generated entrypoint imports it by
/// name. Two things a preview's name can do that an identifier cannot: start with
/// a digit (`404 page`), and be a reserved word — and `Switch` is close to the
/// most likely name in a catalog of previews, so this is not a corner. Both are answered
/// the same way, by prefixing `preview`, which reads as a name somebody might have
/// chosen rather than as an escape.
String catalogSymbolName(String name) {
  var words = catalogFileName(name)
      .replaceAll('.dart', '')
      .split('_')
      .where((w) => w.isNotEmpty)
      .toList();
  if (words.isEmpty) return 'preview';
  var symbol = [
    words.first,
    for (var word in words.skip(1)) word[0].toUpperCase() + word.substring(1),
  ].join();
  if (!_dartReservedWords.contains(symbol) &&
      !RegExp(r'^[0-9]').hasMatch(symbol)) {
    return symbol;
  }
  return 'preview${symbol[0].toUpperCase()}${symbol.substring(1)}';
}

/// The file `new` writes: one entry that renders as written, and a second,
/// commented out, showing the knob API.
///
/// It renders green on purpose. Somebody who has never written a preview gets
/// the API in a file that already works, rather than a template to debug.
String catalogScaffold(String name) {
  var symbol = catalogSymbolName(name);
  return '''
import 'package:material_ui/material_ui.dart';
import 'package:flutter/widget_previews.dart';

@Preview(name: '$name')
Widget $symbol() => Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          spacing: 12,
          children: [
            Text('$name', style: const TextStyle(fontSize: 24)),
            const Text('Replace this with the widget you are building.'),
            FilledButton(onPressed: () {}, child: const Text('A button')),
          ],
        ),
      ),
    );

// A knob is whatever the preview asks for while it builds — no registration,
// and the panel, the CLI and an agent all get the same control. An optional
// parameter is one, read straight off the signature:
//
// @Preview(name: '$name, parameterised')
// Widget ${symbol}Knobs({String label = 'A button'}) =>
//     Center(child: FilledButton(onPressed: () {}, child: Text(label)));
//
// So is anything asked for deeper down, which reads a BuildContext and needs
// `package:flutterware/previews.dart` for `context.knobs`:
//
// @Preview(name: '$name, from a context')
// Widget ${symbol}Inner() => Builder(
//       builder: (context) => Text(context.knobs.string('label', 'A button')),
//     );
//
// A *required* parameter is neither, so a preview cannot take the BuildContext
// itself: the target has to be callable with no arguments.
''';
}

/// Why there are no entries, and what to do about it — the sentence above the
/// hint.
///
/// [directory] is package-relative, as the config declares it, and empty for
/// the default whole-package scan; [package] names the declared package when
/// there is more than one, since "no entries" is ambiguous in a monorepo.
String catalogEmptyReason({
  required String directory,
  required bool directoryExists,
  String? package,
}) {
  var named = package == null || package == '.' ? null : package;

  // Nothing to point at and nothing to blame: the scan covered the package, so
  // there is genuinely nothing annotated. The version of this that named a
  // directory was the tool's most misleading sentence — it read as "look
  // elsewhere" to somebody whose previews were sitting in `lib/`.
  if (directory.isEmpty) {
    return named == null
        ? 'No previews in this package yet.'
        : 'No previews in $named yet.';
  }

  var where = named == null ? '$directory/' : '$named/$directory/';
  if (directoryExists) return 'No previews in $where yet.';

  // Only a *declared* directory can be missing now, so this can say plainly
  // whose choice it was. Telling someone who wrote `directory: 'examples'` to
  // try `demo/` instead read as the tool not having noticed what they set.
  return 'No previews: $where does not exist.\n'
      "tool/flutterware.dart declares `directory: '$directory'` for this "
      'package, so that is the only place scanned — the default is to scan the '
      'whole package. Either the path is wrong, or the previews are somewhere '
      'else.';
}
