import 'dart:io';

import 'package:analyzer/dart/analysis/results.dart';
import 'package:analyzer/dart/constant/value.dart';
import 'package:analyzer/dart/element/element.dart';
import 'package:analyzer/dart/element/type.dart';
// Implementation imports, on purpose: `byteStore` is the whole point of this
// spike and the public `AnalysisContextCollection` constructor does not expose
// it.
import 'package:analyzer/src/dart/analysis/analysis_context_collection.dart';
import 'package:analyzer/src/dart/analysis/byte_store.dart';
import 'package:analyzer/src/dart/analysis/file_byte_store.dart';
import 'package:flutterware_app/src/previews/discovery.dart';
import 'package:path/path.dart' as p;

/// Measures what resolved analysis costs when it is allowed to keep a cache,
/// and what it buys — specifically whether `@CatalogShell` and the regex import
/// carrying in `entrypoint_generator.dart` can both be deleted.
///
/// The baseline it argues against: 17.3s for the first resolved unit, ~26ms for
/// each one after. That number was measured with the default `MemoryByteStore`,
/// so it is the cost of linking a closure *from nothing*, every time. The
/// question here is what the same work costs when the linked summaries survive
/// the process.
///
/// ```sh
/// cd app && dart run tool/catalog/resolve_spike.dart ../fixtures/probe_app
/// dart run tool/catalog/resolve_spike.dart . tool/catalog/demos --store file
/// ```
Future<void> main(List<String> args) async {
  var positional = <String>[];
  var store = 'file';
  var clear = false;
  var edit = false;
  String? editPath;
  String? sdkPath;
  for (var i = 0; i < args.length; i++) {
    switch (args[i]) {
      case '--store':
        store = args[++i];
      case '--clear':
        clear = true;
      case '--edit':
        edit = true;
        if (i + 1 < args.length && !args[i + 1].startsWith('--')) {
          editPath = args[++i];
        }
      case '--sdk':
        sdkPath = args[++i];
      default:
        positional.add(args[i]);
    }
  }
  if (positional.isEmpty) {
    stderr.writeln(
      'usage: resolve_spike.dart <projectRoot> [scanRoot] '
      '[--store memory|file|dartserver] [--clear] [--sdk <dart-sdk>]',
    );
    exit(64);
  }

  var projectRoot = p.canonicalize(positional.first);
  var scanRoot = positional.length > 1 ? positional[1] : 'demo';
  sdkPath ??= _findDartSdk();

  var cachePath = switch (store) {
    'memory' => null,
    'dartserver' => p.join(
      Platform.environment['HOME']!,
      '.dartServer',
      '.analysis-driver',
    ),
    _ => p.join(
      Platform.environment['HOME']!,
      '.flutterware',
      'analysis-cache',
      _shortHash(projectRoot),
    ),
  };
  if (clear && cachePath != null && store != 'dartserver') {
    var directory = Directory(cachePath);
    if (directory.existsSync()) directory.deleteSync(recursive: true);
  }
  // `FileByteStore` does not create its own directory: it writes a temp file
  // straight into it and swallows the failure, so a missing directory makes the
  // store a silent no-op that looks exactly like a cache that never helps.
  if (cachePath != null) Directory(cachePath).createSync(recursive: true);

  _rule('setup');
  print('project    $projectRoot');
  print('scan root  $scanRoot');
  print('sdk        $sdkPath');
  print('store      $store${cachePath == null ? '' : '  $cachePath'}');
  if (cachePath != null) {
    print('cache size ${_directorySize(cachePath)}');
  }

  // ---------------------------------------------------------------- listing --
  // Unchanged from what ships: the tree has to be on screen before any of the
  // below has started, so this stays syntactic.
  _rule('listing (syntactic — what ships today)');
  var watch = Stopwatch()..start();
  var scan = CatalogScanner(projectRoot: projectRoot, roots: [scanRoot]).scan();
  var listingMs = watch.elapsedMilliseconds;
  print('parse scan          ${listingMs}ms');
  print('entries             ${scan.entries.length}');
  for (var diagnostic in scan.diagnostics) {
    print('  ${diagnostic.isError ? 'error' : 'warn '} $diagnostic');
  }

  var files = <String>{
    for (var entry in scan.entries) p.join(projectRoot, entry.path),
  };
  if (files.isEmpty) {
    // No annotated files: still worth measuring the closure, so resolve
    // whatever is in the root.
    files.addAll(
      Directory(p.join(projectRoot, scanRoot))
          .listSync(recursive: true)
          .whereType<File>()
          .where((f) => f.path.endsWith('.dart'))
          .map((f) => f.path)
          .take(40),
    );
    print('no annotated files — resolving ${files.length} for timing only');
  }

  // ------------------------------------------------------------- resolution --
  _rule('resolution');
  watch.reset();
  var collection = AnalysisContextCollectionImpl(
    includedPaths: [projectRoot],
    sdkPath: sdkPath,
    byteStore: switch (store) {
      'memory' => MemoryByteStore(),
      // Never evicting, because this one is the IDE's: the question is only
      // whether our keys hit entries the analysis server already linked, and
      // running a 2GB eviction pass over someone else's cache to find out is
      // not a fair trade.
      'dartserver' => FileByteStore(cachePath!),
      // 2GB: the analysis server's own order of magnitude. A store too small
      // evicts the closure between runs, and every run is a cold run — which
      // looks exactly like a cache that does not work.
      _ => EvictingFileByteStore(cachePath!, 2 * 1024 * 1024 * 1024),
    },
  );
  print('collection setup    ${watch.elapsedMilliseconds}ms');

  var sorted = files.toList()..sort();
  var pass = await _pass(collection, sorted, projectRoot);
  print('first unit element  ${pass.firstMs}ms');
  print(
    'remaining ${sorted.length - 1} units  ${pass.restMs}ms '
    '(${sorted.length > 1 ? (pass.restMs / (sorted.length - 1)).round() : 0}ms each)',
  );
  print('TOTAL resolution    ${pass.firstMs + pass.restMs}ms');
  print('extraction          ${pass.extractMs}ms');
  for (var problem in pass.unreachable) {
    print('  unreachable  $problem');
  }
  if (cachePath != null) {
    print('cache size after    ${_directorySize(cachePath)}');
  }

  // ------------------------------------------------------------- extraction --
  _rule('extraction (resolved)');
  var entries = pass.entries;
  var shells = pass.shells;
  for (var entry in entries) {
    print('');
    print('${entry.path}#${entry.symbol}');
    print('  annotation   ${entry.annotationType}');
    print('  name         ${entry.name}');
    print('  id           ${entry.declaredId ?? '(derived)'}');
    print('  figma        ${entry.figma ?? '-'}');
    var shell = entry.wrapper == null ? null : shells[entry.wrapper];
    if (shell == null) {
      print('  shell        (none)');
      continue;
    }
    print('  shell        ${shell.symbol}  <- ${shell.libraryUri}');
    for (var axis in shell.axes) {
      print(
        '    axis ${axis.name}: ${axis.typeName} '
        '= ${axis.defaultName} ${axis.values}',
      );
    }
    for (var problem in shell.problems) {
      print('    ! $problem');
    }
  }

  _rule('shells, none of them declared');
  print('resolved shells: ${shells.length}');
  for (var shell in shells.values) {
    var axes = shell.axes.map((a) => a.name).join(', ');
    print('  ${shell.symbol}  axes: ${axes.isEmpty ? '(none)' : axes}');
  }

  // ---------------------------------------------------------------- codegen --
  var sample = entries.where((e) => e.wrapper != null).firstOrNull;
  if (sample != null) {
    _rule('generated wrapper (element-derived imports, no regex carrying)');
    print(_wrapperSource(sample, shells[sample.wrapper]!, projectRoot));
  }

  // ------------------------------------------------------------ incremental --
  // The number the design actually runs on. A daemon resolves once at session
  // start; every question after that is "the user just saved a demo — how long
  // until it can run again". Cold and warm cost say nothing about that.
  //
  // The whole loop is measured, not just the re-resolve: elements do not
  // survive a file change (holding one across an edit throws `Missing
  // library`), so every pass has to re-fetch *and* re-extract. That is the
  // constraint that decides the shape of the real thing.
  if (edit && sorted.isNotEmpty) {
    _rule('incremental (same process, one file really edited)');
    var target = editPath == null
        ? sorted.first
        : p.join(projectRoot, editPath);
    print('editing ${p.relative(target, from: projectRoot)}');
    var file = File(target);
    var original = file.readAsStringSync();
    try {
      for (var round = 1; round <= 3; round++) {
        // A real declaration, not a comment: a stale cache answering instantly
        // would look identical to a fast one if the edit changed nothing
        // observable.
        file.writeAsStringSync('$original\nvoid fwSpikeMarker$round() {}\n');
        var context = collection.contextFor(target);
        context.changeFile(target);
        watch.reset();
        await context.applyPendingFileChanges();
        var applied = watch.elapsedMilliseconds;

        var again = await _pass(collection, sorted, projectRoot);
        var sees = again.markers.contains('fwSpikeMarker$round');
        print(
          'round $round  applyChanges ${applied}ms  '
          'resolve ${again.firstMs + again.restMs}ms  '
          'extract ${again.extractMs}ms  '
          '=> ${applied + again.firstMs + again.restMs + again.extractMs}ms  '
          '${again.entries.length} entries, ${again.shells.length} shells, '
          'sees edit: $sees',
        );
      }
    } finally {
      file.writeAsStringSync(original);
      var context = collection.contextFor(target);
      context.changeFile(target);
      await context.applyPendingFileChanges();
    }
    print('(${p.relative(target, from: projectRoot)} restored)');
  }

  if (cachePath != null) {
    _rule('cache flush');
    // `FileByteStore.putGet` schedules its write and returns; nothing awaits it.
    // A daemon outlives that, but a spike that exits immediately would leave an
    // empty cache and conclude, wrongly, that caching does not work.
    var flushed = await _awaitFlush(cachePath);
    print('settled after       ${flushed}ms');
    print('cache size          ${_directorySize(cachePath)}');
  }
}

/// Waits until the store stops growing and has no `-temp-` files left.
Future<int> _awaitFlush(String path) async {
  var watch = Stopwatch()..start();
  var previous = -1;
  while (watch.elapsedMilliseconds < 60000) {
    await Future<void>.delayed(const Duration(milliseconds: 250));
    var directory = Directory(path);
    if (!directory.existsSync()) continue;
    var entities = directory.listSync(recursive: true);
    var pending = entities.where((e) => e.path.contains('-temp-')).length;
    var total = entities.whereType<File>().length;
    if (pending == 0 && total == previous && total > 0) break;
    previous = total;
  }
  return watch.elapsedMilliseconds;
}

// ---------------------------------------------------------------------------
// Extraction
// ---------------------------------------------------------------------------

/// One resolve-then-extract sweep over [sorted].
///
/// Both halves together, always. An element belongs to the analysis session
/// that produced it, and a file change discards that session — reading a
/// `LibraryElement` captured before an edit throws `Missing library`. So the
/// resolved model has to be turned into plain data inside the same sweep that
/// produced it, which is why this returns descriptions and not elements.
class _Pass {
  _Pass({
    required this.entries,
    required this.shells,
    required this.firstMs,
    required this.restMs,
    required this.extractMs,
    required this.unreachable,
    required this.markers,
  });

  final List<_ResolvedEntry> entries;
  final Map<ExecutableElement, _ResolvedShell> shells;
  final int firstMs;
  final int restMs;
  final int extractMs;
  final List<String> unreachable;

  /// Spike-edit markers seen in this sweep, so a round can prove it is looking
  /// at the edit rather than at a cached answer.
  final Set<String> markers;
}

Future<_Pass> _pass(
  AnalysisContextCollectionImpl collection,
  List<String> sorted,
  String projectRoot,
) async {
  var watch = Stopwatch()..start();
  var libraries = <String, LibraryElement>{};
  var unreachable = <String>[];
  var firstMs = 0;
  var restMs = 0;

  for (var (index, path) in sorted.indexed) {
    watch.reset();
    SomeUnitElementResult result;
    try {
      result = await collection
          .contextFor(path)
          .currentSession
          .getUnitElement(path);
    } on StateError catch (error) {
      // A file `analysis_options.yaml` excludes belongs to no context at all,
      // so there is nothing to ask. Reported rather than fatal: the syntactic
      // scan lists such a file happily, so the two passes disagree about what
      // exists, and that disagreement has to be designed for.
      unreachable.add(
        '${p.relative(path, from: projectRoot)}: ${error.message}',
      );
      continue;
    }
    var elapsed = watch.elapsedMilliseconds;
    if (index == 0) {
      firstMs = elapsed;
    } else {
      restMs += elapsed;
    }
    if (result is! UnitElementResult) {
      unreachable.add('${p.relative(path, from: projectRoot)}: $result');
      continue;
    }
    libraries[path] = result.fragment.element;
  }

  watch.reset();
  var entries = <_ResolvedEntry>[];
  var markers = <String>{};
  for (var MapEntry(key: path, value: library) in libraries.entries) {
    _collectEntries(library, path, projectRoot, entries);
    for (var function in library.topLevelFunctions) {
      var name = function.name;
      if (name != null && name.startsWith('fwSpikeMarker')) markers.add(name);
    }
  }

  // Shells are not declared. They are whatever a `wrapper:` points at, and
  // their axes are the optional named parameters of that function. Nothing
  // here reads `@CatalogShell`.
  var shells = <ExecutableElement, _ResolvedShell>{};
  for (var entry in entries) {
    var wrapper = entry.wrapper;
    if (wrapper == null) continue;
    shells.putIfAbsent(wrapper, () => _shellOf(wrapper));
  }

  return _Pass(
    entries: entries,
    shells: shells,
    firstMs: firstMs,
    restMs: restMs,
    extractMs: watch.elapsedMilliseconds,
    unreachable: unreachable,
    markers: markers,
  );
}

class _ResolvedEntry {
  _ResolvedEntry({
    required this.path,
    required this.symbol,
    required this.annotationType,
    required this.name,
    required this.declaredId,
    required this.figma,
    required this.wrapper,
    required this.target,
  });

  final String path;
  final String symbol;
  final String annotationType;
  final String name;
  final String? declaredId;
  final String? figma;

  /// The function `wrapper:` names — recovered as an element even though the
  /// field's static type is `Widget Function(Widget)`, which erases it. This is
  /// the single fact the syntactic scan cannot get, and the reason
  /// `@CatalogShell` exists today.
  final ExecutableElement? wrapper;
  final ExecutableElement target;
}

class _ResolvedShell {
  _ResolvedShell({
    required this.symbol,
    required this.libraryUri,
    required this.element,
    required this.axes,
    required this.problems,
  });

  final String symbol;
  final Uri libraryUri;
  final ExecutableElement element;
  final List<_ResolvedAxis> axes;
  final List<String> problems;
}

class _ResolvedAxis {
  _ResolvedAxis({
    required this.name,
    required this.typeName,
    required this.libraryUri,
    required this.values,
    required this.defaultName,
    required this.isBoolean,
  });

  final String name;
  final String typeName;
  final Uri? libraryUri;

  /// The options themselves, read off the enum's element. Today these are
  /// unknown until the guest has compiled and reported them back.
  final List<String> values;
  final String defaultName;
  final bool isBoolean;
}

void _collectEntries(
  LibraryElement library,
  String path,
  String projectRoot,
  List<_ResolvedEntry> into,
) {
  var relative = p.split(p.relative(path, from: projectRoot)).join('/');

  void consider(ExecutableElement element, String symbol) {
    for (var annotation in element.metadata.annotations) {
      var value = annotation.computeConstantValue();
      var type = value?.type;
      if (value == null || type is! InterfaceType) continue;
      // Recognition by the element's own hierarchy, not by the annotation's
      // spelling. A project's `base class Tablet extends Preview` is found
      // here with no registration list and no name matching.
      if (!_isPreview(type.element)) continue;
      into.add(
        _ResolvedEntry(
          path: relative,
          symbol: symbol,
          annotationType: type.element.name ?? '?',
          name: _field(value, 'name')?.toStringValue() ?? symbol,
          declaredId: _field(value, 'id')?.toStringValue(),
          figma: _field(value, 'figma')?.toStringValue(),
          wrapper: _field(value, 'wrapper')?.toFunctionValue(),
          target: element,
        ),
      );
    }
  }

  for (var function in library.topLevelFunctions) {
    consider(function, function.name ?? '?');
  }
  for (var type in library.classes) {
    for (var method in type.methods.where((m) => m.isStatic)) {
      consider(method, '${type.name}.${method.name}');
    }
    for (var constructor in type.constructors) {
      var name = constructor.name;
      consider(
        constructor,
        '${type.name}.${name == null || name.isEmpty ? 'new' : name}',
      );
    }
  }
}

/// Whether [element] is `Preview` or descends from it.
bool _isPreview(InterfaceElement element) {
  InterfaceElement? current = element;
  var guard = 0;
  while (current != null && guard++ < 32) {
    if (current.name == 'Preview' &&
        '${current.library.uri}'.startsWith('package:flutter/')) {
      return true;
    }
    current = current.supertype?.element;
  }
  return false;
}

/// A field of a const object, following the superclass chain.
///
/// The chain matters: every field this reads — `name`, `wrapper`, `group` —
/// is declared on `Preview` while a project's own subclass declares the rest,
/// and a `DartObject` keeps inherited fields under the synthetic `(super)` key
/// rather than flattening them.
DartObject? _field(DartObject object, String name) {
  DartObject? current = object;
  var guard = 0;
  while (current != null && guard++ < 32) {
    var value = current.getField(name);
    if (value != null && !value.isNull) return value;
    current = current.getField('(super)');
  }
  return null;
}

/// A shell read entirely from a function's signature.
_ResolvedShell _shellOf(ExecutableElement element) {
  var axes = <_ResolvedAxis>[];
  var problems = <String>[];

  var positional = element.formalParameters.where((f) => !f.isNamed).toList();
  if (positional.length != 1 || !positional.single.isRequiredPositional) {
    problems.add(
      'must take exactly one required positional parameter (the child)',
    );
  }

  for (var parameter in element.formalParameters) {
    if (!parameter.isNamed) continue;
    var name = parameter.name ?? '?';
    if (!parameter.isOptionalNamed) {
      problems.add('axis "$name" is required, so defaults cannot be used');
      continue;
    }
    if (!parameter.hasDefaultValue) {
      problems.add('axis "$name" has no default');
      continue;
    }

    var type = parameter.type;
    var constant = parameter.computeConstantValue();
    if (type.isDartCoreBool) {
      axes.add(
        _ResolvedAxis(
          name: name,
          typeName: 'bool',
          libraryUri: null,
          values: const ['false', 'true'],
          defaultName: '${constant?.toBoolValue()}',
          isBoolean: true,
        ),
      );
      continue;
    }
    var typeElement = type is InterfaceType ? type.element : null;
    if (typeElement is! EnumElement) {
      // Not a diagnostic guessed from a name: the type is known, so this says
      // what it actually is.
      problems.add(
        'axis "$name" is ${type.getDisplayString()}, which is neither an enum '
        'nor a bool, so it has no closed set of values',
      );
      continue;
    }
    axes.add(
      _ResolvedAxis(
        name: name,
        typeName: typeElement.name ?? '?',
        libraryUri: typeElement.library.uri,
        values: [
          for (var constant in typeElement.constants) constant.name ?? '?',
        ],
        defaultName: constant?.variable?.name ?? '?',
        isBoolean: false,
      ),
    );
  }

  var enclosing = element.enclosingElement;
  var symbol = enclosing is InterfaceElement
      ? '${enclosing.name}.${element.name}'
      : element.name ?? '?';
  return _ResolvedShell(
    symbol: symbol,
    libraryUri: element.library.uri,
    element: element,
    axes: axes,
    problems: problems,
  );
}

// ---------------------------------------------------------------------------
// Codegen
// ---------------------------------------------------------------------------

/// A wrapper file whose every reference is qualified by a prefix this function
/// minted, from a library URI an element reported.
///
/// Nothing is copied from the demo's source. There is no import list to carry,
/// no relative URI to rebase, no prefix to collide, and the annotation is
/// rebuilt from its constant rather than pasted as text — so a `@Demo` whose
/// arguments name private or prefixed constants generates the same as any
/// other.
String _wrapperSource(
  _ResolvedEntry entry,
  _ResolvedShell shell,
  String projectRoot,
) {
  var prefixes = <String, String>{};
  String prefixFor(Uri uri) =>
      prefixes.putIfAbsent('$uri', () => 'p${prefixes.length}');

  var demoUri = entry.target.library.uri;
  var demoPrefix = prefixFor(demoUri);
  var shellPrefix = prefixFor(shell.libraryUri);
  var axisPrefixes = {
    for (var axis in shell.axes)
      if (axis.libraryUri != null) axis.name: prefixFor(axis.libraryUri!),
  };

  String argumentFor(_ResolvedAxis axis) {
    if (axis.isBoolean) {
      return "  ${axis.name}: CatalogAxes.instance.flag('${axis.name}', "
          '${axis.defaultName}),';
    }
    var type = '${axisPrefixes[axis.name]}.${axis.typeName}';
    return "  ${axis.name}: CatalogAxes.instance.pick('${axis.name}', "
        '$type.values, $type.${axis.defaultName}),';
  }

  var arguments = [for (var axis in shell.axes) argumentFor(axis)];

  var imports = [
    for (var MapEntry(key: uri, value: prefix) in prefixes.entries)
      "import '${_importable(uri, projectRoot)}' as $prefix;",
  ];

  return '''
// GENERATED — do not edit.
import 'package:flutter/widgets.dart';
import 'package:flutterware/ui_catalog.dart';
${imports.join('\n')}

Widget Function() get fwBuilder => $demoPrefix.${entry.symbol};

Widget _fwWrapInShell(Widget child) => $shellPrefix.${shell.symbol}(
  child,
${arguments.join('\n')}
);

Widget Function(Widget)? get fwShellWrap => _fwWrapInShell;

// Axes and their options, known here rather than reported by the guest:
${shell.axes.map((a) => '// ${a.name}: ${a.values} (default ${a.defaultName})').join('\n')}
''';
}

String _importable(String uri, String projectRoot) {
  if (!uri.startsWith('file:')) return uri;
  return p.split(p.relative(p.fromUri(uri), from: projectRoot)).join('/');
}

// ---------------------------------------------------------------------------

void _rule(String title) {
  print('');
  print('── $title ${'─' * (68 - title.length).clamp(0, 68)}');
}

String _directorySize(String path) {
  var directory = Directory(path);
  if (!directory.existsSync()) return '(absent)';
  var bytes = 0;
  var count = 0;
  for (var entity in directory.listSync(recursive: true)) {
    if (entity is! File) continue;
    bytes += entity.lengthSync();
    count++;
  }
  return '${(bytes / 1024 / 1024).toStringAsFixed(1)}MB in $count files';
}

String _shortHash(String value) {
  var hash = 0;
  for (var unit in value.codeUnits) {
    hash = (hash * 31 + unit) & 0x7fffffff;
  }
  return hash.toRadixString(16);
}

String? _findDartSdk() {
  var directory = File(Platform.resolvedExecutable).parent;
  while (true) {
    var candidate = Directory(p.join(directory.path, 'dart-sdk'));
    if (candidate.existsSync()) return candidate.path;
    var parent = directory.parent;
    if (parent.path == directory.path) return null;
    directory = parent;
  }
}
