// Running the generator over one scene group.
//
// Load order, and the reason this is its own step: declarations come before
// scene files. A scene file spells `const DrinkBadgeArgs(size: 140)`, whose
// class is written from the group's declaration of that widget, and
// `tokens.brand`, whose field is written from the libraries the group lists
// — so the declaration and the libraries are read, the classes are written,
// and only then does anything parse a scene.
import 'dart:io';

import 'package:flutterware/scene_authoring.dart';
import 'package:path/path.dart' as p;

import 'args_codegen.dart';
import 'discovery.dart';
import 'externals_file.dart';
import 'group_file.dart';
import 'scene_file.dart';
import 'tokens_file.dart';

/// One library as a group sees it: where it is, what it is called, and
/// what it declares.
class GroupLibrary {
  GroupLibrary(this.entry, this.tokens);

  final SceneLibraryEntry entry;
  final List<SceneTokenDecl> tokens;
}

/// What a group's declaration and its libraries add up to — the vocabulary
/// every scene of the group is parsed against, and the generator's input.
class GroupVocabulary {
  GroupVocabulary({
    required this.widgets,
    required this.exports,
    required this.libraries,
    required this.imports,
  });

  final List<ExternalWidgetDecl> widgets;
  final List<SceneTokenDecl> exports;
  final List<GroupLibrary> libraries;

  /// The declaration's imports, for the opaque types the generated class
  /// spells.
  final List<String> imports;

  /// Every token a scene may name: the libraries' in order, then the
  /// exports. Read [tokenRefusals] before trusting the union.
  List<SceneTokenDecl> get tokens => [
    for (var l in libraries) ...l.tokens,
    ...exports,
  ];

  Map<String, Set<String>> get declaredArgs => {
    for (var w in widgets) w.entry: {for (var a in w.args) a.name},
  };

  static final empty = GroupVocabulary(
    widgets: const [],
    exports: const [],
    libraries: const [],
    imports: const [],
  );
}

/// What a generation run had to say.
class SceneArgsResult {
  SceneArgsResult({
    required this.path,
    required this.wrote,
    this.refusals = const [],
    this.source,
    GroupVocabulary? vocabulary,
  }) : vocabulary = vocabulary ?? GroupVocabulary.empty;

  /// The generated file, or null when there was nothing to generate.
  final String? path;

  /// Whether the file changed. A run that writes nothing is the common one:
  /// the generator is called on every scan, and a scan usually finds what
  /// the last one did.
  final bool wrote;

  /// Why the declarations could not be read. The generated file is left
  /// exactly as it was — half a vocabulary is worse than a stale one.
  final List<SceneRefusal> refusals;

  /// What the generator produced, whether or not it was written.
  final String? source;

  /// What the group declares, as read — empty when it was refused.
  final GroupVocabulary vocabulary;
}

/// Reads a group's declaration and its libraries — nothing generated yet.
/// Refusals carry the file they came from in their message when it is not
/// the declaration itself.
({GroupVocabulary? vocabulary, List<SceneRefusal> refusals}) readGroup(
  SceneGroupEntry group,
  ScenePackageScan scan,
) {
  var declaration = File(group.declarationPath);
  if (!declaration.existsSync()) {
    return (
      vocabulary: null,
      refusals: [
        SceneRefusal(
          0,
          1,
          'no declaration',
          '${group.declarationPath} is gone: the folder is no longer a group',
        ),
      ],
    );
  }
  var parsed = parseGroupFile(
    declaration.readAsStringSync(),
    resolveImport: importResolverFor(group.declarationPath),
    librarySymbolAt: scan.librarySymbolAt,
  );
  if (!parsed.ok) return (vocabulary: null, refusals: parsed.refusals);

  var libraries = <GroupLibrary>[];
  var refusals = <SceneRefusal>[];
  var seen = <String, String>{};
  for (var ref in parsed.libraries) {
    var entry = scan.libraryAt(ref.path!)!;
    var tokens = parseTokensFile(
      File(entry.path).readAsStringSync(),
      symbol: entry.symbol,
    );
    for (var r in tokens.refusals) {
      refusals.add(
        SceneRefusal(
          r.offset,
          r.line,
          r.construct,
          '${entry.fileName}: ${r.message}',
        ),
      );
    }
    libraries.add(GroupLibrary(entry, tokens.tokens));
    for (var t in tokens.tokens) {
      var other = seen[t.name];
      if (other != null) {
        refusals.add(
          SceneRefusal(
            0,
            1,
            'duplicate token',
            '"${t.name}" is declared by both $other and ${entry.fileName}',
          ),
        );
      }
      seen[t.name] = entry.fileName;
    }
  }
  for (var t in parsed.exports) {
    var other = seen[t.name];
    if (other != null) {
      refusals.add(
        SceneRefusal(
          0,
          1,
          'duplicate token',
          '"${t.name}" is exported here and declared by $other',
        ),
      );
    }
  }
  if (refusals.isNotEmpty) return (vocabulary: null, refusals: refusals);
  return (
    vocabulary: GroupVocabulary(
      widgets: parsed.widgets,
      exports: parsed.exports,
      libraries: libraries,
      imports: parsed.imports,
    ),
    refusals: const [],
  );
}

/// Writes `scene_args.dart` for [group].
///
/// Three things are read: the group's declaration — the widgets, the
/// exports, the libraries it lists — the libraries themselves, and every
/// scene class's own parameters, which need no declaration because a scene
/// already says what it takes in its header.
SceneArgsResult generateSceneArgsFor(
  SceneGroupEntry group,
  ScenePackageScan scan, {
  bool write = true,
}) {
  var read = readGroup(group, scan);
  var vocabulary = read.vocabulary;
  if (vocabulary == null) {
    return SceneArgsResult(path: null, wrote: false, refusals: read.refusals);
  }
  var tokens = vocabulary.tokens;

  var scenes = <SceneClassDecl>[];
  for (var entry in group.scenes) {
    var parsed = parseSceneFile(
      File(entry.path).readAsStringSync(),
      tokens: tokens,
    );
    // A scene that does not parse is the panel's problem to report with line
    // numbers; here it simply contributes no arguments class, and the one it
    // had last time stays until it parses again.
    if (parsed.doc == null) continue;
    scenes.add(
      SceneClassDecl(
        entry.className,
        parsed.doc!.params.toList(),
        p.url.joinAll(p.split(p.relative(entry.path, from: group.directory))),
        tokensFormal: parsed.doc!.tokensFormal,
      ),
    );
  }
  scenes.sort((a, b) => a.className.compareTo(b.className));

  var target = File(group.argsPath);
  var source = emitSceneArgs(
    externals: vocabulary.widgets,
    scenes: scenes,
    tokens: tokens,
    declarationImports: vocabulary.imports,
  );
  if (target.existsSync() && target.readAsStringSync() == source) {
    return SceneArgsResult(
      path: target.path,
      wrote: false,
      source: source,
      vocabulary: vocabulary,
    );
  }
  if (write) target.writeAsStringSync(source);
  return SceneArgsResult(
    path: target.path,
    wrote: write,
    source: source,
    vocabulary: vocabulary,
  );
}

/// Every group under [scope], generated. What a scan does before it lists
/// anything: a scene file names classes this writes.
Map<String, SceneArgsResult> generateSceneArgsIn(
  String scope, {
  bool write = true,
  ScenePackageScan? scan,
}) {
  var found = scan ?? discoverPackage(scope);
  return {
    for (var group in found.groups)
      group.directory: generateSceneArgsFor(group, found, write: write),
  };
}
