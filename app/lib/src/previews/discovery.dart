import 'dart:io';

import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:path/path.dart' as p;
import 'package:pubspec_parse/pubspec_parse.dart';

import '../utils/enum_lookup.dart';
import '../utils/list_files.dart';
import '../utils/parameter_knobs.dart';
import 'authoring.dart';
import 'catalog_entry.dart';

/// One file's contribution to a scan, held so the next scan need not re-read
/// it.
class _FileScan {
  _FileScan({required this.modified});

  /// When the file was last written, in microseconds. This is the entire cache
  /// invalidation: a file whose mtime has not moved cannot have changed what it
  /// declares.
  final int modified;

  final entries = <CatalogEntry>[];
  final diagnostics = <ScanDiagnostic>[];
  final multiPreviews = <String, String>{};
}

/// How a scan went: what it found, and what it noticed but did not act on.
class ScanResult {
  ScanResult({
    required this.entries,
    required this.diagnostics,
    this.changed = true,
  });

  final List<CatalogEntry> entries;

  final List<ScanDiagnostic> diagnostics;

  /// Whether any file was read this time.
  ///
  /// False means this is what the previous [CatalogScanner.scan] returned, file
  /// for file, and a caller holding that result has nothing to do — which is
  /// all the fingerprint this replaced was for. Fingerprinting listed and
  /// statted the roots to decide whether a scan was worth it, which was a good
  /// trade while a scan meant reading and parsing everything. It is not one now
  /// that a scan re-reads only what moved: the two cost the same (45ms against
  /// 47ms at this repository's root), so asking first and then scanning paid
  /// for the walk twice on exactly the reloads that had work to do.
  final bool changed;

  /// A scan with an error is not a usable catalog: an entry would be missing or
  /// unreachable, which is worse than refusing.
  bool get ok => diagnostics.every((d) => !d.isError);
}

class ScanDiagnostic {
  ScanDiagnostic.error(this.message, {this.location}) : isError = true;
  ScanDiagnostic.warning(this.message, {this.location}) : isError = false;

  final String message;
  final String? location;
  final bool isError;

  @override
  String toString() => location == null ? message : '$location: $message';
}

/// Finds catalog entries by **parsing** the project, never by resolving or
/// compiling it.
///
/// Resolution costs 17.3s for a single unit on a real project against 478ms to
/// parse the whole package, and buys nothing here: nobody — not us, not
/// Flutter's own previewer — interprets a preview annotation statically. The
/// annotation's source text is carried through to the guest and evaluated as
/// Dart there.
class CatalogScanner {
  CatalogScanner({
    required this.projectRoot,
    this.roots = const [defaultCatalogRoot],
    this.previewAnnotations = defaultPreviewAnnotations,
  });

  /// Entry paths are recorded relative to this, so a generated file is the same
  /// on every machine.
  final String projectRoot;

  /// Directories to scan, relative to [projectRoot]. The empty string is the
  /// package root, and is the default.
  final List<String> roots;

  /// Recognition is by **registration**, not by inference. The class-hierarchy
  /// closure that would let a project's own `Tablet extends Preview` be detected
  /// automatically was cut: name-filtering already discards the noise it was
  /// meant to filter, and an unregistered annotation shows up immediately as a
  /// missing entry.
  final List<String> previewAnnotations;

  /// What each file yielded last time it was read, keyed by absolute path.
  ///
  /// What makes a rescan proportional to the edit rather than to the
  /// package. The scan root is the whole package now, so any `.dart` file
  /// being touched brings us here — `lib/main.dart` included, which you edit
  /// constantly — and a rescan sits at the head of `select`, on the hot-reload
  /// path. Re-reading and re-parsing everything there cost 57ms for this app
  /// package and 134ms for the repository root, to answer a question that the
  /// edited file alone decides.
  final _scanned = <String, _FileScan>{};

  /// Which directories below [projectRoot] belong to a package of their own.
  ///
  /// Rebuilt each scan rather than kept: a nested package can be created while
  /// the catalog is open, and a memo that never expires would go on serving its
  /// previews as this package's.
  final _nested = <String, bool>{};

  /// Rebuilt per scan for the same reason [_nested] is: it caches parses, and a
  /// file that changed between scans must not answer from the old one.
  EnumLookup _lookup = EnumLookup();

  /// This package's name, so a demo importing its own `package:` URI resolves
  /// without reading anything. The rest of the checkout resolves too, off the
  /// `package_config.json` [EnumLookup] finds from this root — a demo whose
  /// enum lives in a shared package is the same shape as an entry point whose
  /// knob does.
  late final String? _packageName = () {
    try {
      return Pubspec.parse(
        File(p.join(projectRoot, 'pubspec.yaml')).readAsStringSync(),
      ).name;
    } on Object {
      return null;
    }
  }();

  ScanResult scan() {
    _nested.clear();
    _lookup = EnumLookup(
      selfPackage: _packageName,
      selfPackageRoot: projectRoot,
    );
    var changed = false;
    var live = <String>{};
    for (var file in _dartFiles()) {
      var read = _read(file);
      // Listed a moment ago and unreadable now — a checkout or a build landing
      // mid-scan. Left out of [live], so it is treated as gone and picked up
      // again whenever it comes back.
      if (read == null) continue;
      live.add(file.path);
      if (identical(_scanned[file.path], read)) continue;
      _scanned[file.path] = read;
      changed = true;
    }
    // A file that is gone takes its entries with it — including one that became
    // gitignored, or that a new nested pubspec just handed to another package,
    // which are the same thing from here.
    var held = _scanned.length;
    _scanned.removeWhere((path, _) => !live.contains(path));
    changed |= _scanned.length != held;
    // Assembly below is a pure function of [_scanned], so when nothing moved
    // there is nothing to redo — only the flag differs.
    if (_last case var last? when !changed) {
      return ScanResult(
        entries: last.entries,
        diagnostics: last.diagnostics,
        changed: false,
      );
    }

    var entries = <CatalogEntry>[];
    var diagnostics = <ScanDiagnostic>[];
    var multiPreviews = <String, String>{};
    // In path order, so the diagnostics a reader sees do not depend on which
    // files happened to be re-read this time.
    for (var path in _scanned.keys.toList()..sort()) {
      var scan = _scanned[path]!;
      entries.addAll(scan.entries);
      diagnostics.addAll(scan.diagnostics);
      multiPreviews.addAll(scan.multiPreviews);
    }

    // The cross-file half, which no per-file cache can hold and which is cheap
    // enough not to: both are one pass over the entries already in hand.
    _rejectDuplicateIds(entries, diagnostics);
    _reportMultiPreviews(multiPreviews, diagnostics);
    entries.sort((a, b) => a.id.compareTo(b.id));
    return _last = ScanResult(entries: entries, diagnostics: diagnostics);
  }

  /// The last assembled result, to answer an unchanged scan with.
  ScanResult? _last;

  /// What [file] contributes, re-read only when it has moved since last time —
  /// otherwise the very object the last scan returned, which is how the caller
  /// tells that nothing happened.
  ///
  /// Null when it cannot be read at all. A rescan sits at the head of every
  /// `select`, so a file the walk listed and something deleted a moment later
  /// has to be a file this stops caring about, not an exception on the reload
  /// path.
  _FileScan? _read(File file) {
    int modified;
    String source;
    try {
      modified = file.statSync().modified.microsecondsSinceEpoch;
      if (_scanned[file.path] case var cached?
          when cached.modified == modified) {
        return cached;
      }
      source = file.readAsStringSync();
    } on FileSystemException {
      return null;
    }

    // A substring prefilter before parsing: 20ms across 180 files, against
    // 478ms to parse them. `MultiPreview` joins the annotations rather than
    // riding along with them, because the class that extends it is routinely
    // declared in a file that holds no entries of its own.
    if (!previewAnnotations.any((a) => source.contains('@$a')) &&
        !source.contains('MultiPreview')) {
      // Cached all the same: a file with no annotations is most of a package,
      // and not recording it is re-reading it on every rescan for ever.
      return _FileScan(modified: modified);
    }

    var result = _FileScan(modified: modified);
    _scanFile(
      file,
      source,
      result.entries,
      result.diagnostics,
      result.multiPreviews,
    );
    // Per file by definition — a group is derived from the file's own name when
    // the file holds more than one entry — so it belongs on this side of the
    // cache rather than in the assembly above.
    _deriveGroups(result.entries);
    return result;
  }

  /// Listed the way git lists, because the default root is now the package
  /// itself and a raw recursive walk from there is a trap.
  ///
  /// `Directory.listSync(recursive: true)` follows symlinks by default, so
  /// pointing it at a package with a `.fvm/flutter_sdk` link read the entire
  /// Flutter SDK — 17,163 `.dart` files against this repository's own 1,127.
  /// Ignores are honoured from the enclosing repository down, so a workspace
  /// member with no `.gitignore` of its own still skips what the repository
  /// ignores.
  Iterable<File> _dartFiles() sync* {
    for (var root in roots) {
      var directory = p.join(projectRoot, root);
      if (!Directory(directory).existsSync()) continue;
      for (var file in listFilesInDirectory(directory)) {
        if (!file.path.endsWith('.dart')) continue;
        if (_inNestedPackage(p.dirname(file.path))) continue;
        yield file;
      }
    }
  }

  /// Whether [directory] belongs to a package nested inside this one — a
  /// plugin's `example/`, a `packages/*` member of a workspace.
  ///
  /// A package boundary is where this scan stops, which the widening to the
  /// whole package made a question worth asking: a nested package is a project
  /// in its own right, with its own configuration and its own previews, and a
  /// wrapper generated here would import its file by a path — a second copy of
  /// a library the other package reaches as `package:…`, resolved against a
  /// package config that need not even contain what it imports.
  bool _inNestedPackage(String directory) {
    if (_nested[directory] case var known?) return known;
    bool result;
    if (p.equals(directory, projectRoot) ||
        !p.isWithin(projectRoot, directory)) {
      result = false;
    } else if (File(p.join(directory, 'pubspec.yaml')).existsSync()) {
      result = true;
    } else {
      result = _inNestedPackage(p.dirname(directory));
    }
    return _nested[directory] = result;
  }

  void _scanFile(
    File file,
    String source,
    List<CatalogEntry> entries,
    List<ScanDiagnostic> diagnostics,
    Map<String, String> multiPreviews,
  ) {
    var parsed = parseString(content: source, throwIfDiagnostics: false);
    var unit = parsed.unit;
    var path = p.split(p.relative(file.path, from: projectRoot)).join('/');
    // From the first annotation to the closing brace, so an edit to the
    // annotation and an edit to the body both land inside it. Not from the
    // node's own offset, which is its doc comment when it has one — a
    // rewritten sentence above an entry is not an edit to the entry.
    (int, int) spanOf(AnnotatedNode node) => (
      parsed.lineInfo
          .getLocation(node.metadata.firstOrNull?.offset ?? node.offset)
          .lineNumber,
      parsed.lineInfo.getLocation(node.end).lineNumber,
    );

    for (var declaration in unit.declarations) {
      if (declaration is ClassDeclaration &&
          declaration.extendsClause?.superclass.name.lexeme == 'MultiPreview') {
        multiPreviews[declaration.namePart.typeName.lexeme] = path;
      }
      switch (declaration) {
        case FunctionDeclaration():
          var annotations = _annotationsOn(declaration.metadata);
          if (annotations.isEmpty) continue;
          if (!_returnsWidget(declaration.returnType)) {
            diagnostics.add(
              ScanDiagnostic.warning(
                '${declaration.name.lexeme} is annotated but does not return '
                'Widget or WidgetBuilder',
                location: path,
              ),
            );
          }
          for (var (ordinal, annotation) in annotations.indexed) {
            _add(
              entries,
              diagnostics,
              path,
              declaration.name.lexeme,
              annotation,
              declaration.functionExpression.parameters,
              ordinal,
              spanOf(declaration),
            );
          }

        case ClassDeclaration():
          for (var member in declaration.body.members) {
            var annotations = _annotationsOn(member.metadata);
            if (annotations.isEmpty) continue;
            var className = declaration.namePart.typeName.lexeme;
            switch (member) {
              // `Foo` names the type; `Foo.new` is the tear-off, which is what
              // the generated wrapper needs.
              case ConstructorDeclaration(:var name, :var parameters):
                for (var (ordinal, annotation) in annotations.indexed) {
                  _add(
                    entries,
                    diagnostics,
                    path,
                    '$className.${name?.lexeme ?? 'new'}',
                    annotation,
                    parameters,
                    ordinal,
                    spanOf(member),
                  );
                }
              case MethodDeclaration(
                isStatic: true,
                :var name,
                :var parameters,
              ):
                for (var (ordinal, annotation) in annotations.indexed) {
                  _add(
                    entries,
                    diagnostics,
                    path,
                    '$className.${name.lexeme}',
                    annotation,
                    parameters,
                    ordinal,
                    spanOf(member),
                  );
                }
              default:
                diagnostics.add(
                  ScanDiagnostic.warning(
                    'an annotation on a non-static member of $className is not '
                    'a catalog entry',
                    location: path,
                  ),
                );
            }
          }

        default:
          break;
      }
    }
  }

  void _add(
    List<CatalogEntry> entries,
    List<ScanDiagnostic> diagnostics,
    String path,
    String symbol,
    Annotation annotation,
    FormalParameterList? parameters,
    int ordinal,
    (int, int) span,
  ) {
    // `@Preview`'s own rule: the target must be callable with no arguments.
    var required =
        parameters?.parameters.where((p) => p.isRequired) ?? const [];
    if (required.isNotEmpty) {
      diagnostics.add(
        ScanDiagnostic.error(
          '$symbol has required parameters, so it cannot be a catalog entry',
          location: path,
        ),
      );
      return;
    }

    // The signature *is* the declaration, implemented once for demos and entry
    // points alike. Costs a parse of this file's direct imports, and only for a
    // parameter whose type is not a built-in one.
    var declared = knobsFromParameters(
      parameters,
      file: p.join(projectRoot, path),
      lookup: _lookup,
      onSkipped: (parameter, reason) => diagnostics.add(
        ScanDiagnostic.warning(
          '$symbol offers no control for `$parameter`: $reason',
          location: path,
        ),
      ),
    );

    entries.add(
      CatalogEntry(
        path: path,
        symbol: symbol,
        knobs: [for (var knob in declared) knob.knob],
        // Verbatim, `@` stripped. Never interpreted here.
        annotation: annotation.toSource().substring(1),
        name: _literalString(annotation, 'name') ?? symbol,
        declaredId: _literalString(annotation, 'id'),
        group: _literalString(annotation, 'group'),
        ordinal: ordinal,
        line: span.$1,
        endLine: span.$2,
      ),
    );
  }

  /// A file holding more than one entry gives its entries a group, so variants
  /// get a parent without anyone declaring one. `group:` overrides it.
  ///
  /// The file's name as written, never prettified. This used to sentence-case
  /// it — `avatar_tile.dart` became `Avatar tile` — which made one row in the
  /// tree follow a rule none of the others did: a directory folder, a declared
  /// `group:` and an entry's name are all shown exactly as their source spells
  /// them. Two spellings in one column is the whole of what it bought, and the
  /// capital letter is one line away for anyone who wants it: `group: 'Avatar
  /// tile'` is the deliberate act, and it beats this.
  void _deriveGroups(List<CatalogEntry> entries) {
    var byFile = <String, List<CatalogEntry>>{};
    for (var entry in entries) {
      byFile.putIfAbsent(entry.path, () => []).add(entry);
    }
    for (var MapEntry(key: path, value: fileEntries) in byFile.entries) {
      if (fileEntries.length < 2) continue;
      var derived = p.basenameWithoutExtension(path);
      for (var i = 0; i < entries.length; i++) {
        var entry = entries[i];
        if (entry.path != path || entry.group != null) continue;
        entries[i] = entry.withGroup(derived);
      }
    }
  }

  /// Two entries resolving to one id means one of them is unreachable. That is
  /// a broken tree, not something to note and carry on from — the one place
  /// this design escalates from reporting to refusing.
  ///
  /// Only a *declared* `id:` can do this now. Stacked annotations used to
  /// collide here, which made an `id:` mandatory precisely where variants are
  /// spelled; they take an ordinal instead.
  void _rejectDuplicateIds(
    List<CatalogEntry> entries,
    List<ScanDiagnostic> diagnostics,
  ) {
    var byId = <String, List<CatalogEntry>>{};
    for (var entry in entries) {
      byId.putIfAbsent(entry.id, () => []).add(entry);
    }
    for (var MapEntry(key: id, value: clashing) in byId.entries) {
      if (clashing.length < 2) continue;
      diagnostics.add(
        ScanDiagnostic.error(
          '${clashing.length} entries resolve to the same id "$id" '
          '(${clashing.map((e) => e.name).join(', ')}). '
          'Give all but one an explicit id.',
          location: clashing.first.path,
        ),
      );
    }
  }

  /// `MultiPreview` is Flutter's one-annotation-many-previews base class, and
  /// nothing here can serve it: it hands back its previews from a `previews`
  /// getter, evaluated as Dart, while every entry the catalog knows about is
  /// resolved from the source before anything runs.
  ///
  /// Registered ones only, which is all this can answer for.
  /// Registered, a `MultiPreview` reaches the generated wrapper as
  /// `Preview get fwPreview => BrightnessPreview()` and fails to compile, pointing
  /// at generated code rather than at the declaration that caused it — so
  /// refusing here, by name, is strictly better than the same failure later.
  ///
  /// Unregistered, an annotation naming one is never seen and its previews are
  /// missing with no mention of why. That is worth saying and is *not said
  /// here*: knowing the name is used would mean parsing files the prefilter
  /// skips, which is the 20ms-against-478ms property the scan is built on.
  /// Warning off the declaration alone would fire on a subclass serving
  /// Flutter's own previewer perfectly well — this scanner volunteering an
  /// opinion about a file it has no stake in, from a bare-name match.
  void _reportMultiPreviews(
    Map<String, String> multiPreviews,
    List<ScanDiagnostic> diagnostics,
  ) {
    for (var MapEntry(key: name, value: path) in multiPreviews.entries) {
      if (!previewAnnotations.contains(name)) continue;
      diagnostics.add(
        ScanDiagnostic.error(
          '$name extends MultiPreview, which declares its previews at run '
          'time. Previews are found by reading the source, so flutterware '
          'cannot know what one expands to. Remove it from previewAnnotations '
          'and write one @Preview per entry.',
          location: path,
        ),
      );
    }
  }

  /// Every registered annotation on a declaration, not just the first.
  ///
  /// Stacking is one of the two supported ways to spell variants, so two
  /// `@Preview`s are two entries, told apart by their position on the
  /// declaration.
  List<Annotation> _annotationsOn(List<Annotation> metadata) => [
    for (var annotation in metadata)
      if (previewAnnotations.contains(annotation.name.name)) annotation,
  ];

  static bool _returnsWidget(TypeAnnotation? type) {
    if (type == null) return true; // Inferred; the compiler will judge it.
    var name = type is NamedType ? type.name.lexeme : type.toSource();
    return name == 'Widget' || name == 'WidgetBuilder';
  }

  /// Literal arguments are read here; anything else is left for the guest to
  /// evaluate, which is why `size: kSomething` costs nothing.
  static String? _literalString(Annotation annotation, String parameter) {
    for (var argument
        in annotation.arguments?.arguments ?? const <Argument>[]) {
      if (argument is! NamedArgument) continue;
      if (argument.name.lexeme != parameter) continue;
      var value = argument.argumentExpression;
      if (value is SimpleStringLiteral) return value.value;
    }
    return null;
  }
}
