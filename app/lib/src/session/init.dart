import 'dart:convert';
import 'dart:io';

import 'package:dart_style/dart_style.dart';
import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

import '../identity/face_guess.dart';
import '../shell/repo_layout.dart';
import '../utils/run_git.dart';

/// Where an agent looks for the servers a project offers.
///
/// Committed rather than ignored, unlike everything else `init` writes: it says
/// what this project *is*, not what one machine happens to have, and a
/// checkout that arrives already knowing its own tools is the entire point.
const mcpConfigFileName = '.mcp.json';

/// Writes the two files a project needs to be usable by a human and an agent:
/// its config, and its MCP registration.
///
/// It records nothing about this machine, and that is the change from what it
/// used to be. It wrote `.flutterware/sdk`, a link naming whichever SDK ran
/// it, so that a globally installed `fw` could find a project and the SDK to
/// run it with. There is no such binary now — flutterware is reached through
/// `dart run flutterware`, so the SDK is whatever the caller's own `dart` is,
/// answered fresh on every invocation rather than recorded once and left to go
/// stale.
///
/// What is left is derived and disposable: delete either file and running again
/// writes it back.
class ProjectInit {
  ProjectInit({
    required this.root,
    required this.out,
    required this.err,
    Future<ProcessResult> Function(
      String,
      List<String>, {
      String? workingDirectory,
    })?
    runProcess,
  }) : _run = runProcess ?? runGitTool;

  /// The repo root, as [findRepoRoot] resolves it — so `fw` from a
  /// subdirectory and `fw` from the top initialize the same place.
  final String root;

  final StringSink out;
  final StringSink err;
  final Future<ProcessResult> Function(
    String,
    List<String>, {
    String? workingDirectory,
  })
  _run;

  Future<int> run({bool quiet = false}) async {
    var scaffolded = _scaffoldConfig();
    var registered = _registerMcpServer();
    var pinned = registered ? _pinnedSdkHint() : null;

    if (!quiet && (scaffolded || registered)) {
      out.writeln('Initialized $root');
      if (scaffolded) out.writeln('  wrote $configFileName');
      if (registered) {
        out.writeln('  registered flutterware in $mcpConfigFileName');
        // A repo that ignores every dotfile — `.*`, which is common and is
        // what this one does — has just had the file written and hidden. It
        // still works for whoever ran this, so it is not worth refusing to
        // write; it is worth not implying the rest of the team got it.
        if (await _isIgnoredByGit(p.join(root, mcpConfigFileName))) {
          out.writeln('    .gitignore hides it, so it stays on this machine');
        }
        if (pinned != null) out.writeln('    $pinned');
      }
    } else if (pinned != null) {
      // The one line a quiet run says, and to stderr: it runs before every
      // command, `fw mcp` and `--json` among them, whose stdout is not ours.
      err.writeln('fw: $pinned');
    }
    return 0;
  }

  /// A line for a project that pins its SDK with a version manager, or null.
  ///
  /// The entry [_registerMcpServer] writes is plain `dart`, and stays that way
  /// — see there. But `init` runs quietly before whatever command came first,
  /// so the entry appears without anyone having read it, and a `dart` on
  /// `PATH` older than the pin fails only later: at the client's handshake, in
  /// a log nobody is watching. So the moment it is written, a project that
  /// says it pins its SDK is told so once.
  ///
  /// Read from the pin files rather than by comparing the `dart` that launched
  /// this with the one on `PATH`, which would be the sharper test. Finding that
  /// one means resolving `dart` off `PATH`, which nothing here does — see
  /// `test/ambient_sdk_test.dart` — and Flutter's `bin/dart` is a wrapper whose
  /// path never equals the SDK binary it runs, so the comparison would fire
  /// for everyone. A pin file this does not recognise costs only the line.
  String? _pinnedSdkHint() {
    for (var (name, command) in _pinFiles) {
      String text;
      try {
        text = File(p.join(root, name)).readAsStringSync();
      } on FileSystemException {
        continue;
      }
      // `.tool-versions` and mise's files pin anything — node, java — and
      // only a Flutter or Dart line is about the `dart` in question.
      if (name != '.fvmrc' && !_sdkLine.hasMatch(text)) continue;
      var fix = command == null
          ? 'run it through your version manager'
          : 'change it to `$command run flutterware mcp`';
      return "$name pins this project's SDK, but the flutterware entry in "
          '$mcpConfigFileName runs `dart` from PATH. If that is a different '
          'SDK, $fix.';
    }
    return null;
  }

  /// Whether git already ignores [path].
  ///
  /// Asked of git rather than read off `.gitignore`, because a repo may cover a
  /// path through a broad pattern — this one ignores every dotfile with `.*` —
  /// or through a global excludes file this cannot see at all.
  ///
  /// No git means no, which is the answer this caller wants: nothing is hiding
  /// `.mcp.json`.
  Future<bool> _isIgnoredByGit(String path) async {
    try {
      var result = await _run('git', [
        'check-ignore',
        '-q',
        path,
      ], workingDirectory: root);
      return result.exitCode == 0;
    } on ProcessException {
      return false;
    }
  }

  /// Adds `flutterware` to the project's `.mcp.json`, so an agent opening this
  /// repo finds the tools without anyone having wired them up.
  ///
  /// Answers the question the other two surfaces never had: the GUI is a window
  /// you can see and `fw` is a command you can type, but an MCP server nobody
  /// has configured is indistinguishable from one that does not exist.
  ///
  /// The entry is the command a user would type, and it names no version
  /// manager. `dart run flutterware mcp` resolves through whatever `dart` the
  /// client's environment provides, at spawn time — so upgrading an SDK keeps
  /// it correct, and flutterware never has to know whether this project is
  /// managed by fvm, mise, asdf or nothing at all. Guessing that from a
  /// `.fvmrc` and writing the guess into a file would be the staleness this
  /// design exists to avoid, one layer down.
  ///
  /// A user whose `dart` is not the one this project wants edits the entry to
  /// say so — `fvm dart run flutterware mcp`, and so on. It is their file and
  /// their choice, and a project with a pin file is told it may need making —
  /// see [_pinnedSdkHint]. The one thing worth knowing before making it is
  /// that a version manager which auto-installs an SDK may narrate that onto
  /// stdout, which is where the protocol lives.
  ///
  /// Merges; never rewrites. This is the one file `init` touches that
  /// flutterware does not own — other servers live in it, it is normally
  /// committed, and an entry someone has edited is an entry they meant. So a
  /// `flutterware` key that is already there is left exactly as it is, and a
  /// file that does not parse is left alone entirely rather than replaced with
  /// a valid one that has lost whatever it said.
  ///
  /// The exception is [_deadEntry] — the `fw mcp` spelling this used to write,
  /// naming a binary that no longer exists. That one is ours, it is broken, and
  /// leaving it would mean an agent finding a server that cannot start.
  ///
  /// And the entry is *spliced in as text*, not re-encoded from the parsed map:
  /// see [_spliceServer].
  bool _registerMcpServer() {
    var file = File(p.join(root, mcpConfigFileName));

    var entry = <String, Object?>{
      'command': 'dart',
      'args': ['run', 'flutterware', 'mcp'],
    };

    if (!file.existsSync()) {
      file.writeAsStringSync(
        '${const JsonEncoder.withIndent('  ').convert({
          'mcpServers': {'flutterware': entry},
        })}\n',
      );
      return true;
    }

    var source = file.readAsStringSync();
    Map<String, Object?> config;
    try {
      config = jsonDecode(source) as Map<String, Object?>;
    } on Object {
      return false;
    }

    var declared = config['mcpServers'];
    // Present but not an object: someone else's schema, or a typo. Either way
    // it is not ours to correct.
    if (declared != null && declared is! Map<String, Object?>) return false;
    var servers = declared as Map<String, Object?>?;
    var existing = servers?['flutterware'];
    if (existing != null && !_isDeadEntry(existing)) return false;

    var spliced = existing == null
        ? _spliceServer(source, entry)
        : _replaceServer(source, entry);
    if (spliced != null) {
      file.writeAsStringSync(spliced);
      return true;
    }

    // The text was not the shape the parsed value promised — a comment, or
    // something else no scanner here knows about. Getting the entry in still
    // beats preserving the layout of a file we could not read closely.
    config['mcpServers'] = {...?servers, 'flutterware': entry};
    file.writeAsStringSync(
      '${const JsonEncoder.withIndent('  ').convert(config)}\n',
    );
    return true;
  }

  /// Inserts `flutterware` into [source] as *text*, leaving every byte outside
  /// the insertion exactly where it was.
  ///
  /// Re-encoding the parsed map is one line shorter and rewrites the whole
  /// file: two spaces where the project used four, keys in a different order,
  /// a trailing newline appearing or leaving. The result is a diff touching
  /// every line of a file `init` does not own, to add one entry — and whoever
  /// reads that commit has to check by hand that nothing else moved.
  ///
  /// Returns null when the text is not the shape the parsed value promised, so
  /// the caller can fall back to re-encoding rather than skip the entry.
  static String? _spliceServer(String source, Map<String, Object?> entry) {
    var root = _skipWhitespace(source, 0);
    if (root >= source.length || source[root] != '{') return null;

    var servers = _memberValue(source, root + 1, 'mcpServers');
    if (servers == null) {
      return _insertMember(source, root, 'mcpServers', {'flutterware': entry});
    }
    if (source[servers] != '{') return null;
    return _insertMember(source, servers, 'flutterware', entry);
  }

  /// The entry `init` used to write: `fw mcp`, run through a globally installed
  /// binary that no longer exists.
  ///
  /// Matched exactly, and only this shape. Anyone who edited theirs — a
  /// different command, an `env`, an added argument — meant it, and a tool that
  /// overwrites an edit because it recognises the key is worse than one that
  /// leaves a broken entry behind.
  static bool _isDeadEntry(Object? value) {
    if (value is! Map) return false;
    if (value.length != 2 || value['command'] != 'fw') return false;
    var args = value['args'];
    return args is List && args.length == 1 && args.single == 'mcp';
  }

  /// Replaces the `flutterware` entry's *value*, leaving every byte outside it
  /// where it was — the same discipline as [_insertMember], for the one entry
  /// this is allowed to overwrite.
  static String? _replaceServer(String source, Map<String, Object?> entry) {
    var root = _skipWhitespace(source, 0);
    if (root >= source.length || source[root] != '{') return null;

    var servers = _memberValue(source, root + 1, 'mcpServers');
    if (servers == null || source[servers] != '{') return null;
    var value = _memberValue(source, servers + 1, 'flutterware');
    if (value == null) return null;

    // The value's first line continues the line the key is on, so it carries no
    // indent of its own; every line below it is laid out under that key.
    var indent = _indentOfLineAt(source, value);
    var lines = const LineSplitter().convert(
      const JsonEncoder.withIndent('  ').convert(entry),
    );
    return source.replaceRange(
      value,
      _skipValue(source, value),
      [lines.first, for (var line in lines.skip(1)) '$indent$line'].join('\n'),
    );
  }

  /// Splices `"name": value` into the object whose `{` is at [open], after the
  /// members already there — where every other tool that edits JSON in place
  /// puts a new key, and where anyone rereading the file looks for the thing
  /// that was added last.
  ///
  /// Laid out the way the file already lays itself out: the indent unit is read
  /// off the first member rather than assumed, because a project writing four
  /// spaces would otherwise get one two-space entry it did not ask for, and an
  /// object written on one line stays on one line.
  ///
  /// Returns null when the text does not walk the way valid JSON should.
  static String? _insertMember(
    String source,
    int open,
    String name,
    Object? value,
  ) {
    var close = _skipValue(source, open) - 1;
    var first = _skipWhitespace(source, open + 1);
    var isEmpty = first == close;
    // An empty object says nothing about how the file is written, so it
    // borrows the answer from whether anything else in the file has a line
    // break at all.
    var multiline = isEmpty
        ? source.contains('\n')
        : source.lastIndexOf('\n', close) > open;

    // Where the comma goes, and everything before it stays byte-identical.
    int? end;
    if (!isEmpty) {
      end = _lastMemberEnd(source, open + 1);
      if (end == null) return null;
    }

    if (!multiline) {
      var member = '${jsonEncode(name)}: ${jsonEncode(value)}';
      if (isEmpty) {
        return '${source.substring(0, open + 1)}$member'
            '${source.substring(close)}';
      }
      return '${source.substring(0, end!)}, $member${source.substring(end)}';
    }

    var parentIndent = _indentOfLineAt(source, open);
    var memberIndent = _indentOfLineAt(source, first);
    // Usable only if the first member actually starts its own line below the
    // brace, and sits further in than the object it belongs to.
    if (source.lastIndexOf('\n', first) <= open ||
        !memberIndent.startsWith(parentIndent) ||
        memberIndent.length <= parentIndent.length) {
      memberIndent = '$parentIndent  ';
    }

    var encoded = const LineSplitter().convert(
      JsonEncoder.withIndent(memberIndent.substring(parentIndent.length))
          .convert({name: value}),
    );
    var member = encoded
        .sublist(1, encoded.length - 1)
        .map((line) => '$parentIndent$line')
        .join('\n');

    // An empty object has to grow lines around the entry; a populated one only
    // needs a comma on the line that used to be last.
    if (isEmpty) {
      return '${source.substring(0, open + 1)}\n$member\n$parentIndent'
          '${source.substring(close)}';
    }
    return '${source.substring(0, end!)},\n$member${source.substring(end)}';
  }

  /// Writes a starter `tool/flutterware.dart` when the project has none.
  ///
  /// A project with one package and the default plugins has nothing to say
  /// here, so this file is not required to work — but writing it is how anyone
  /// finds out that configuration exists at all, which an empty default never
  /// teaches.
  bool _scaffoldConfig() {
    var file = File(p.join(root, configFileName));
    if (file.existsSync()) return false;

    // A declared monorepo scaffolds as one: the root pubspec's `workspace:`
    // list is right there and machine-readable, and a single-package config
    // written into it hands every tool the workspace shell — a package with
    // no lib, no tests and no previews — while the real ones go unserved.
    // Only the declared list, deliberately: promoting whatever a
    // directory scan turned up would write claims nobody made.
    var members = workspaceMembers(root);
    var consts = {'app': '.'};
    var widgetConsts = ['app'];
    if (members != null && members.isNotEmpty) {
      var pubspecs = {
        for (var member in members) member: _readMember(root, member),
      };
      consts = _memberConsts({
        for (var member in members) member: pubspecs[member]?.name,
      });
      // Previews and Scenarios render widgets, and a package that does not
      // depend on Flutter has none: handed one anyway, each reports "no
      // entries" for it on every `fw status`, for good. Dependencies has
      // something to say about every package. A pubspec this cannot read is
      // kept rather than judged.
      widgetConsts = [
        for (var MapEntry(key: name, value: path) in consts.entries)
          if (pubspecs[path]?.flutter ?? true) name,
      ];
    }
    var declarations = [
      for (var entry in consts.entries)
        "const ${entry.key} = Pkg('${entry.value}');",
    ].join('\n');
    String uses(Iterable<String> names) =>
        names.map((name) => '.new($name)').join(', ');
    var perPackage = members == null || members.isEmpty
        ? '; the default is the single\n// package here'
        : ", listed from the root\n// pubspec's `workspace:` members";
    var widgetTools = widgetConsts.isEmpty
        ? '''
  // Previews and Scenarios are for Flutter packages, and no member here
  // depends on Flutter.
'''
        : '''
  // Renders the widgets you have annotated with `@Preview`, found anywhere in
  // the package — add `directory: 'demo'` to bound the scan.
  // `fw run previews new --name="Buttons"` writes your first one.
  fw.use(Previews(packages: [${uses(widgetConsts)}]));

  // Widget tests that screenshot every step, found anywhere under `test/`.
  // `fw run scenarios new --name="Onboarding"` writes your first one.
  fw.use(Scenarios(packages: [${uses(widgetConsts)}]));
''';
    if (widgetConsts.isNotEmpty && widgetConsts.length < consts.length) {
      widgetTools = '''
  // Previews and Scenarios get only the members that depend on Flutter: the
  // others have no widgets to show.

$widgetTools''';
    }

    var source =
        '''
import 'package:flutterware/plugins.dart';

// Which tools this project gets, and what they work on.
//
// Run `fw status` to see what they say, and `fw actions` for what they can do.
// Every tool listed here is available from the GUI, the CLI and MCP.

// One Pkg per package you want a tool to work on$perPackage. Hand each tool the ones it applies to.
$declarations

void main() => Flutterware.configure((fw) {
${_identityLine(root, consts)}
  fw.use(Dependencies(packages: [${uses(consts.keys)}]));

$widgetTools});
''';
    // Formatted, because the lists above are built on one line, and a
    // workspace of two dozen members made each `fw.use(...)` 700 characters
    // long — in a file whose whole job is to be read and edited. `init` runs
    // before every command, so a source the formatter refuses is still
    // written as it is rather than failing all of them.
    try {
      source = DartFormatter(
        languageVersion: DartFormatter.latestLanguageVersion,
      ).format(source);
    } on FormatterException {
      // Left as built; the analyzer will say what is wrong with it.
    }

    file.parent.createSync(recursive: true);
    file.writeAsStringSync(source);
    return true;
  }
}

/// What the scaffold reads from a workspace member's pubspec: its name, and
/// whether it depends on Flutter. Null when there is none or it will not
/// parse.
({String? name, bool flutter})? _readMember(String root, String member) {
  try {
    var text = File(p.join(root, member, 'pubspec.yaml')).readAsStringSync();
    if (loadYaml(text) case YamlMap pubspec) {
      var name = pubspec['name'];
      return (
        name: name is String ? name : null,
        flutter: switch (pubspec['dependencies']) {
          {'flutter': {'sdk': 'flutter'}} => true,
          _ => false,
        },
      );
    }
  } on FileSystemException {
    // A member the workspace lists and nobody has created yet.
  } on YamlException {
    // The project's problem, and `pub get` reports it.
  }
  return null;
}

/// A Dart identifier per workspace member, keyed name → path, from each
/// member's path and the `name:` its pubspec declares.
///
/// The pubspec name, camelCased — `design_system` as `designSystem`. It is
/// the name the package already goes by, and pub keeps it unique across a
/// workspace. The directory was the source once, first come first served,
/// and on a 24-package workspace the short names went to whatever was listed
/// first — `example`, for one package's example app — while the app the
/// repository exists for was pushed out to its whole path. A member whose
/// pubspec does not say falls back to its directory, then to its whole path,
/// then to a counter.
///
/// A name Dart reserves, or one the file already uses, gets `Pkg` on the end:
/// a `main` beside `void main()` does not compile, and a const named `fw`
/// would be shadowed, silently, by the closure's own `fw`.
Map<String, String> _memberConsts(Map<String, String?> members) {
  String camel(String path) {
    var parts = path
        .split(RegExp(r'[^A-Za-z0-9]+'))
        .where((part) => part.isNotEmpty)
        .toList();
    if (parts.isEmpty) return 'pkg';
    var name = [
      parts.first.toLowerCase(),
      for (var part in parts.skip(1)) part[0].toUpperCase() + part.substring(1),
    ].join();
    if (RegExp(r'^[0-9]').hasMatch(name)) return 'pkg$name';
    return _unavailableNames.contains(name) ? '${name}Pkg' : name;
  }

  var consts = <String, String>{};
  for (var MapEntry(key: member, value: pubspecName) in members.entries) {
    var name = camel(pubspecName ?? p.basename(member));
    if (consts.containsKey(name)) name = camel(member);
    var base = name;
    for (var n = 2; consts.containsKey(name); n++) {
      name = '$base$n';
    }
    consts[name] = member;
  }
  return consts;
}

/// What a scaffolded const cannot be called: the words Dart reserves, and the
/// names the file itself declares or is handed.
const _unavailableNames = {
  'main',
  'fw',
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

/// The `fw.identity(...)` the scaffold writes, with a guess already filled in.
///
/// The guess belongs here and nowhere else. Which package represents a
/// repository is a claim only its author can make — a monorepo holds several
/// real apps and no obvious answer — so inferring it at every launch would be
/// an invisible rule. Written into the config once, it is a starting point to
/// read and correct.
///
/// A repository where nothing has a real icon yet gets the line commented out:
/// there is nothing true to put in it, and an empty default would not even
/// show that the setting exists.
///
/// The comment says what each field does because the call alone reads as
/// though naming the package were the declaration and the icon a detail. It
/// is the other way round: the picture is the point, and the package is only
/// where to find it.
String _identityLine(String root, Map<String, String> consts) {
  const preamble =
      '  // The picture that stands for this repository in the window and the\n'
      '  // Dock, so several checkouts open at once can be told apart. Both\n'
      '  // fields are needed: `icon` is the picture, and `package` is the\n'
      '  // directory its path is relative to.\n'
      '  //\n';
  var guessed = guessFace(root);
  if (guessed == null) {
    return '$preamble'
        '  // Nothing here has an icon of its own yet, so this is left for you to\n'
        '  // fill in.\n'
        '  // fw.identity(const ProjectIdentity(\n'
        "  //   package: Pkg('.'),\n"
        "  //   icon: 'assets/logo.png',\n"
        '  // ));\n';
  }
  // The member's const when it has one, so a rename moves one line.
  var package = consts.entries
      .where((entry) => entry.value == guessed.package)
      .map((entry) => entry.key)
      .firstOrNull;
  return '$preamble'
      '  // Guessed from the icons found here: change either if that is the wrong\n'
      '  // app, or point `icon` at the source art your icon generator reads.\n'
      '  fw.identity(const ProjectIdentity(\n'
      "    package: ${package ?? "Pkg('${guessed.package}')"},\n"
      "    icon: '${guessed.icon}',\n"
      '  ));\n';
}

/// The leading whitespace of the line [offset] sits on.
String _indentOfLineAt(String source, int offset) {
  var start = source.lastIndexOf('\n', offset) + 1;
  var end = start;
  while (end < offset && (source[end] == ' ' || source[end] == '\t')) {
    end++;
  }
  return source.substring(start, end);
}

int _skipWhitespace(String source, int offset) {
  while (offset < source.length && ' \t\r\n'.contains(source[offset])) {
    offset++;
  }
  return offset;
}

/// Offset just past the string literal starting at [offset].
int _skipString(String source, int offset) {
  offset++;
  while (offset < source.length) {
    if (source[offset] == r'\') {
      offset += 2;
      continue;
    }
    if (source[offset] == '"') return offset + 1;
    offset++;
  }
  return offset;
}

/// Offset just past the value starting at [offset].
///
/// Only has to be right about already-valid JSON — whatever this walks has
/// been through [jsonDecode] — so it counts brackets rather than parsing, and
/// only strings need real handling because they can contain them.
int _skipValue(String source, int offset) {
  if (source[offset] == '"') return _skipString(source, offset);
  if (source[offset] != '{' && source[offset] != '[') {
    while (offset < source.length && !',}] \t\r\n'.contains(source[offset])) {
      offset++;
    }
    return offset;
  }

  var depth = 0;
  while (offset < source.length) {
    var char = source[offset];
    if (char == '"') {
      offset = _skipString(source, offset);
      continue;
    }
    if (char == '{' || char == '[') {
      depth++;
    } else if (char == '}' || char == ']') {
      depth--;
      if (depth == 0) return offset + 1;
    }
    offset++;
  }
  return offset;
}

/// Offset just past the value of the last member of the object whose body
/// starts at [body] — where a new member's comma goes.
///
/// Deliberately not the offset of the `}`: the whitespace between the two is
/// the file's own, and a new member belongs before it, not in place of it.
int? _lastMemberEnd(String source, int body) {
  int? end;
  var offset = _skipWhitespace(source, body);
  while (offset < source.length && source[offset] != '}') {
    if (source[offset] != '"') return null;
    offset = _skipWhitespace(source, _skipString(source, offset));
    if (offset >= source.length || source[offset] != ':') return null;

    end = _skipValue(source, _skipWhitespace(source, offset + 1));
    offset = _skipWhitespace(source, end);
    if (offset < source.length && source[offset] == ',') {
      offset = _skipWhitespace(source, offset + 1);
    }
  }
  return end;
}

/// Offset of the value of [key] in the object whose body starts at [body], or
/// null when the key is not there.
int? _memberValue(String source, int body, String key) {
  var offset = _skipWhitespace(source, body);
  while (offset < source.length && source[offset] != '}') {
    if (source[offset] != '"') return null;
    var nameEnd = _skipString(source, offset);
    var name = jsonDecode(source.substring(offset, nameEnd)) as String;

    offset = _skipWhitespace(source, nameEnd);
    if (offset >= source.length || source[offset] != ':') return null;
    offset = _skipWhitespace(source, offset + 1);
    if (name == key) return offset;

    offset = _skipWhitespace(source, _skipValue(source, offset));
    if (offset < source.length && source[offset] == ',') {
      offset = _skipWhitespace(source, offset + 1);
    }
  }
  return null;
}

/// The files a version manager pins a project's SDK in, each with the command
/// that runs `dart` through it — null where the file is shared by several
/// managers and naming one would be a guess.
const _pinFiles = [
  ('.fvmrc', 'fvm dart'),
  ('.mise.toml', 'mise exec -- dart'),
  ('mise.toml', 'mise exec -- dart'),
  // asdf's, and mise reads it too.
  ('.tool-versions', null),
];

/// A line pinning Flutter or Dart, in `.tool-versions` (`flutter 3.x`) or a
/// mise file (`flutter = "3.x"`).
final _sdkLine = RegExp(r'^\s*"?(flutter|dart)\b', multiLine: true);
