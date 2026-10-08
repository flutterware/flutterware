// A token library as a document: the editor's own, the way a scene file is.
//
// A library is a `*.tokens.dart` the editor writes — values it holds,
// draws and compares against — shared by every scene of every group that
// lists it. This is the object those scenes share: one per file, with its
// own journal (an edit to a token is undone here, never in a scene), its
// own dirty flag and save door, and the same disk discipline as a scene
// file: it re-parses what it emits before writing, writes nothing when the
// bytes are already there, and adopts a version that arrived on disk as one
// undoable step.
//
// Pure Dart: `fw`, a codemod and the panel edit a library through the same
// door.
import 'package:clock/clock.dart';
import 'package:dart_style/dart_style.dart';
import 'package:flutterware/scene_authoring.dart';
import 'package:path/path.dart' as p;

import 'import/variables.dart';
import 'scene_file.dart';
import 'tokens_file.dart';
import 'workspace.dart';

/// The result of opening a library: the document, or why there is none.
class TokensLibraryOpen {
  TokensLibraryOpen._(this.library, this.refusals);

  final TokensLibrary? library;
  final List<SceneRefusal> refusals;

  bool get ok => library != null;
}

/// What the last import into a library did — kept in the file, as comment
/// lines under the header the reader recognises, so the pane can show it
/// after a restart and after an import the CLI ran. Written by [merge].
class ImportNote {
  const ImportNote({
    required this.from,
    required this.when,
    required this.added,
    required this.updated,
    required this.unchanged,
    this.kept = const [],
    this.notImported = const [],
  });

  /// The design file, as named to the import — a file name.
  final String from;

  /// When, to the minute, as written: `2026-09-07 14:02`.
  final String when;

  final int added;
  final int updated;
  final int unchanged;

  /// Library tokens the design file does not know, left alone.
  final List<String> kept;

  /// What did not become a token, each `what — reason`: the design file's
  /// refusals, and the library's — a name already taken by another kind.
  final List<String> notImported;

  String get summary =>
      '$added added · $updated updated · $unchanged unchanged · '
      '${kept.length} kept';

  /// The comment block, one line each; what [parse] reads back.
  String emit() {
    var out = StringBuffer()
      ..writeln('// Imported from $from on $when — $summary.');
    if (notImported.isNotEmpty) {
      out.writeln('// Not imported:');
      for (var line in notImported) {
        out.writeln('//   $line');
      }
    }
    if (kept.isNotEmpty) {
      out.writeln('// Kept, not in the design file: ${kept.join(', ')}');
    }
    return '$out';
  }

  static final _head = RegExp(
    r'^// Imported from (.+) on (\S+ \S+) — (\d+) added · (\d+) updated · '
    r'(\d+) unchanged · (\d+) kept\.$',
  );

  /// The note in [source], or null when it carries none.
  static ImportNote? parse(String source) {
    var lines = source.split('\n');
    for (var (i, line) in lines.indexed) {
      var m = _head.firstMatch(line);
      if (m == null) continue;
      var notImported = <String>[];
      var kept = <String>[];
      var j = i + 1;
      if (j < lines.length && lines[j] == '// Not imported:') {
        j++;
        while (j < lines.length && lines[j].startsWith('//   ')) {
          notImported.add(lines[j].substring(5));
          j++;
        }
      }
      const keptHead = '// Kept, not in the design file: ';
      if (j < lines.length && lines[j].startsWith(keptHead)) {
        kept = lines[j].substring(keptHead.length).split(', ');
      }
      return ImportNote(
        from: m[1]!,
        when: m[2]!,
        added: int.parse(m[3]!),
        updated: int.parse(m[4]!),
        unchanged: int.parse(m[5]!),
        kept: kept,
        notImported: notImported,
      );
    }
    return null;
  }
}

class TokensLibrary extends SceneListenable implements SceneSavable {
  TokensLibrary({
    required this.path,
    List<SceneTokenDecl> tokens = const [],
    String? source,
    this.importNote,
  }) : tokens = [...tokens],
       _disk = source;

  /// The last import into this file, or null — see [ImportNote].
  ImportNote? importNote;

  /// Read a file through the parse door — its list symbol derived from its
  /// name, the way discovery derives it.
  static TokensLibraryOpen open(String path, String source) {
    var parsed = parseTokensFile(source, symbol: tokensSymbolFor(path));
    if (!parsed.ok) return TokensLibraryOpen._(null, parsed.refusals);
    return TokensLibraryOpen._(
      TokensLibrary(
        path: path,
        tokens: parsed.tokens,
        source: source,
        importNote: ImportNote.parse(source),
      ),
      const [],
    );
  }

  /// Where it lives — the identity a workspace dedupes on.
  @override
  final String path;

  String get symbol => tokensSymbolFor(path);

  String get fileName => p.basename(path);

  /// The declarations, in the file's order. Mutated only through the doors
  /// below, so every change is journaled and announced.
  final List<SceneTokenDecl> tokens;

  String? _disk;

  /// Whether [source] is the text this library last read or wrote.
  @override
  bool matchesDisk(String source) => source == _disk;

  var _revision = 0;
  var _savedRevision = 0;

  /// Bumped by every edit — what an autosave arms on.
  int get revision => _revision;

  @override
  bool get isDirty => _revision != _savedRevision;

  // --- Queries -------------------------------------------------------------

  SceneTokenDecl? named(String name) {
    for (var t in tokens) {
      if (t.name == name) return t;
    }
    return null;
  }

  /// Why [wanted] cannot be a token's name here, or null when it can.
  /// [taken] names what the group's other libraries and exports already
  /// use — a scene reads one `tokens.name`, whichever file declares it.
  String? nameProblem(
    String wanted, {
    String? renaming,
    Set<String> taken = const {},
  }) {
    if (!isValidNodeName(wanted)) {
      return '"$wanted" is not a valid name. A name is a Dart identifier: '
          'letters, digits and underscores, not starting with a digit';
    }
    if (wanted == renaming) return null;
    if (named(wanted) != null) return '"$wanted" is already in $fileName';
    if (taken.contains(wanted)) {
      return '"$wanted" is already declared elsewhere in the group';
    }
    return null;
  }

  /// A free name off [base]: `brand`, `brand2`, `brand3`…
  String freeName(String base, {Set<String> taken = const {}}) {
    if (!isValidNodeName(base)) base = 'token';
    if (nameProblem(base, taken: taken) == null) return base;
    for (var i = 2; ; i++) {
      if (nameProblem('$base$i', taken: taken) == null) return '$base$i';
    }
  }

  // --- Journal -------------------------------------------------------------

  static const _journalCap = 100;
  final _undo = <(String, List<SceneTokenDecl>, ImportNote?)>[];
  final _redo = <(String, List<SceneTokenDecl>, ImportNote?)>[];
  String? _openMerge;

  bool get canUndo => _undo.isNotEmpty;
  bool get canRedo => _redo.isNotEmpty;
  String? get undoLabel => _undo.isEmpty ? null : _undo.last.$1;

  /// One journaled edit. A [mergeKey] folds a run of edits — a drag, a
  /// keystroke sequence — into one entry, until [endMerge].
  void perform(String label, void Function() mutate, {String? mergeKey}) {
    var merge =
        mergeKey != null &&
        _redo.isEmpty &&
        _undo.isNotEmpty &&
        _openMerge == mergeKey;
    _openMerge = mergeKey;
    if (!merge) {
      _undo.add((label, List.of(tokens), importNote));
      if (_undo.length > _journalCap) _undo.removeAt(0);
      _redo.clear();
    }
    mutate();
    _revision++;
    notifyListeners();
  }

  void endMerge() => _openMerge = null;

  void undo() {
    if (_undo.isEmpty) return;
    var (label, before, note) = _undo.removeLast();
    _redo.add((label, List.of(tokens), importNote));
    tokens
      ..clear()
      ..addAll(before);
    importNote = note;
    _openMerge = null;
    _revision++;
    notifyListeners();
  }

  void redo() {
    if (_redo.isEmpty) return;
    var (label, after, note) = _redo.removeLast();
    _undo.add((label, List.of(tokens), importNote));
    tokens
      ..clear()
      ..addAll(after);
    importNote = note;
    _revision++;
    notifyListeners();
  }

  // --- Doors ---------------------------------------------------------------

  /// Declares a value token — a colour or a number, the two a design system
  /// holds beside its styles. With no [value] the kind's zero.
  void add(
    String name,
    SceneParamKind kind, {
    Object? value,
    Set<String> taken = const {},
  }) {
    if (!libraryTokenKinds.contains(kind)) {
      throw ArgumentError(notADesignValue(paramKindTypeName(kind)));
    }
    if (nameProblem(name, taken: taken) case var problem?) {
      throw ArgumentError(problem);
    }
    var v = value ?? _zeroOf(kind);
    if (!_holds(kind, v)) {
      throw ArgumentError('a ${kind.name} token does not hold a $v');
    }
    perform('Add token $name', () {
      tokens.add(SceneTokenDecl(name, kind, v));
    });
  }

  /// Declares a text style — the text subset of the table, shared whole.
  void addStyle(
    String name, {
    SceneTextStyle style = const SceneTextStyle(fontSize: 16),
    Set<String> taken = const {},
  }) {
    if (nameProblem(name, taken: taken) case var problem?) {
      throw ArgumentError(problem);
    }
    perform('Add style $name', () {
      tokens.add(SceneTokenDecl.style(name, style));
    });
  }

  /// Renames a token. The scenes reading it are the caller's to follow —
  /// a library does not know its readers.
  void rename(String name, String wanted, {Set<String> taken = const {}}) {
    wanted = wanted.trim();
    if (wanted == name) return;
    var i = tokens.indexWhere((t) => t.name == name);
    if (i < 0) throw ArgumentError('no token "$name"');
    if (nameProblem(wanted, renaming: name, taken: taken) case var problem?) {
      throw ArgumentError(problem);
    }
    perform('Rename token $name', () {
      tokens[i] = _renamed(tokens[i], wanted);
    });
  }

  /// Sets a value token's value.
  void setValue(String name, Object value, {String? mergeKey}) {
    var i = tokens.indexWhere((t) => t.name == name);
    if (i < 0) throw ArgumentError('no token "$name"');
    var t = tokens[i];
    var kind = t.kind;
    if (kind == null || !t.hasValue) {
      throw ArgumentError('"$name" holds no value to set');
    }
    if (!_holds(kind, value)) {
      throw ArgumentError('"$name" is a ${t.typeName}: a $value is not one');
    }
    perform('Edit token $name', mergeKey: mergeKey, () {
      tokens[i] = SceneTokenDecl(name, kind, value);
    });
  }

  /// Replaces a style token's fields.
  void setStyle(String name, SceneTextStyle style, {String? mergeKey}) {
    var i = tokens.indexWhere((t) => t.name == name);
    if (i < 0) throw ArgumentError('no token "$name"');
    var t = tokens[i];
    if (!t.isStyle || !t.hasValue) {
      throw ArgumentError('"$name" is not a style');
    }
    perform('Edit style $name', mergeKey: mergeKey, () {
      tokens[i] = SceneTokenDecl.style(name, style);
    });
  }

  /// Deletes a token. Whether anything reads it is the caller's to check —
  /// across every scene of every group that lists this file.
  void delete(String name) {
    var i = tokens.indexWhere((t) => t.name == name);
    if (i < 0) throw ArgumentError('no token "$name"');
    perform('Delete token $name', () => tokens.removeAt(i));
  }

  // --- Import --------------------------------------------------------------

  /// Merges a design file's variables in, by name, as one undoable step —
  /// the library is the user's, the design file a source it draws from. A
  /// token the file knows takes the file's value; one it does not know is
  /// added; one the file does not have is kept and listed. A name the
  /// library holds as another kind — a style, a string where the file has a
  /// colour — is refused by name rather than replaced. The report is also
  /// written into the file as the [importNote].
  ImportNote merge(VariablesImport import, {required String from}) {
    var when = clock.now();
    String two(int n) => n.toString().padLeft(2, '0');
    var stamp =
        '${when.year}-${two(when.month)}-${two(when.day)} '
        '${two(when.hour)}:${two(when.minute)}';
    var added = 0, updated = 0, unchanged = 0;
    var notImported = [for (var r in import.refusals) '$r'];
    var seen = <String>{};
    var next = List.of(tokens);
    for (var t in import.tokens) {
      seen.add(t.name);
      var i = next.indexWhere((x) => x.name == t.name);
      if (i < 0) {
        next.add(t.decl);
        added++;
        continue;
      }
      var have = next[i];
      if (have.isExport || have.isStyle || have.kind != t.kind) {
        var what = have.isStyle ? 'a style' : 'a ${have.kind?.name}';
        notImported.add(
          '${t.source}: "${t.name}" is $what here, the file has a '
          '${t.kind.name}',
        );
        continue;
      }
      if (t.value == have.value) {
        unchanged++;
      } else {
        next[i] = t.decl;
        updated++;
      }
    }
    var kept = [
      for (var t in tokens)
        if (!seen.contains(t.name)) t.name,
    ];
    var note = ImportNote(
      from: from,
      when: stamp,
      added: added,
      updated: updated,
      unchanged: unchanged,
      kept: kept,
      notImported: notImported,
    );
    perform('Import from $from', () {
      tokens
        ..clear()
        ..addAll(next);
      importNote = note;
    });
    return note;
  }

  // --- File ----------------------------------------------------------------

  String emit() => emitTokensLibrary(tokens, symbol: symbol, note: importNote);

  /// Emit, refuse to write anything the parser would reject, and hand the
  /// text to [write]. Returns the refusals — empty on success.
  @override
  List<SceneRefusal> save(void Function(String path, String source) write) {
    var source = emit();
    var check = parseTokensFile(source, symbol: symbol);
    if (!check.ok) return check.refusals;
    if (source != _disk) {
      write(path, source);
      _disk = source;
    }
    _savedRevision = _revision;
    return const [];
  }

  /// Takes the version [source] on disk, as one undoable step.
  List<SceneRefusal> adopt(String source) {
    var parsed = parseTokensFile(source, symbol: symbol);
    if (!parsed.ok) return parsed.refusals;
    perform('Reload from disk', () {
      tokens
        ..clear()
        ..addAll(parsed.tokens);
      importNote = ImportNote.parse(source);
    });
    _disk = source;
    _savedRevision = _revision;
    return const [];
  }

  static SceneTokenDecl _renamed(SceneTokenDecl t, String name) =>
      t.style != null
      ? SceneTokenDecl.style(name, t.style!)
      : SceneTokenDecl(name, t.kind!, t.value!);

  static Object _zeroOf(SceneParamKind kind) => switch (kind) {
    SceneParamKind.string => '',
    SceneParamKind.number => 0.0,
    SceneParamKind.color => const SceneColor(0xFF000000),
    SceneParamKind.bool => false,
    SceneParamKind.list => const <Object?>[],
  };

  static bool _holds(SceneParamKind kind, Object value) => switch (kind) {
    SceneParamKind.string => value is String,
    SceneParamKind.number => value is double,
    SceneParamKind.color => value is SceneColor,
    SceneParamKind.bool => value is bool,
    SceneParamKind.list => value is List,
  };
}

/// The header every library file carries: the marker, then what the file
/// is — for the reader who opens it in an IDE rather than in the editor.
/// The marker, and nothing else.
///
/// A one-token library used to be five lines of explanation over one line of
/// content. The explanation belongs where somebody who has not opened the
/// file can read it; what stays is the line discovery needs.
const tokensLibraryHeader = '$sceneTokensFileMarker\n';

/// The order a library is written and drawn in: the value kinds as the
/// sheet lays them out, then the styles, and within a kind the order the
/// file had.
///
/// Decided 2026-09-09, with the library's page: a library reads as a design
/// system when its colours are together and its type ramp is together, and
/// a page that groups over a file that does not would be two orders to keep
/// in your head. So the file takes the page's. The cost is a one-time
/// reordering diff the first time an old library is written.
List<SceneTokenDecl> tokensByKind(List<SceneTokenDecl> tokens) => [
  for (var kind in libraryTokenOrder)
    for (var t in tokens)
      if (!t.isStyle && t.kind == kind) t,
  for (var t in tokens)
    if (t.isStyle) t,
  // Nothing a library holds lands here — a token is a value or a style.
  // Total anyway, because an order that drops a declaration is a shredder.
  for (var t in tokens)
    if (!t.isStyle && t.kind == null) t,
];

/// A library's whole text: the header, the authoring import, and one
/// `Token<…>` per declaration under [symbol]. What [parseTokensFile] reads
/// back, so the round trip is the test.
String emitTokensLibrary(
  List<SceneTokenDecl> tokens, {
  required String symbol,
  ImportNote? note,
}) {
  tokens = tokensByKind(tokens);
  var out = StringBuffer(tokensLibraryHeader);
  if (note != null) out.write(note.emit());
  out
    ..writeln("import 'package:flutterware/scene_authoring.dart';")
    ..writeln();
  if (tokens.isEmpty) {
    out.writeln('final $symbol = <Token<Object>>[];');
  } else {
    out.writeln('final $symbol = [');
    for (var t in tokens) {
      out.writeln('  ${_tokenLiteral(t)},');
    }
    out.writeln('];');
  }
  return _formatter.format(out.toString());
}

String _tokenLiteral(SceneTokenDecl t) {
  if (t.style case var style?) {
    return "const Token<SceneTextStyle>('${t.name}', "
        '${sceneStyleLiteral(style)})';
  }
  return "const Token<${t.typeName}>('${t.name}', "
      '${_valueLiteral(t.value!)})';
}

String _valueLiteral(Object value) => switch (value) {
  SceneColor c =>
    'SceneColor(0x${c.argb.toRadixString(16).toUpperCase().padLeft(8, '0')})',
  String s => sceneStringLiteral(s),
  double d => d == d.roundToDouble() && d.abs() < 1e15 ? '${d.round()}' : '$d',
  var v => '$v',
};

final _formatter = DartFormatter(
  languageVersion: DartFormatter.latestLanguageVersion,
);
