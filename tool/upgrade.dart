/// Moves every pub dependency of the workspace to its latest release, as the
/// weekly Upgrade workflow does once `tool/bump_flutter.dart beta` has moved
/// `.fvmrc` to the latest Flutter beta.
///
/// ```
/// fvm dart tool/upgrade.dart [--summary=<file>]
/// ```
///
/// A constraint that excludes a dependency's latest release is widened to it,
/// unless `tool/check_constraints.dart` holds it back with a reason, and one
/// pinned by the Flutter SDK takes the version the SDK running this pins.
/// Then `pubspec.lock` takes the newest version every constraint allows, and
/// `tool/prepare_submit.dart` formats the workspace again, since a new
/// `dart_style` can format it differently. The `environment:` floors are
/// left where they are.
///
/// `--summary` writes what moved against HEAD as markdown, the Upgrade
/// workflow's pull request description. The upgrade breaking something is
/// not this tool failing: CI on the pull request says what broke.
library;

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

import 'check_constraints.dart'
    show
        heldBack,
        hostedDependencies,
        oldestFlutter,
        pinnedBySdk,
        repoRoot,
        workspacePackages;

Future<void> main(List<String> args) async {
  var summary = [
    for (var arg in args)
      if (arg.startsWith('--summary=')) arg.substring('--summary='.length),
  ].lastOrNull;

  Directory.current = repoRoot();
  var sdk = _flutterSdk();
  var pubspecs = _pubspecs();

  var pinned = _pinToSdk(sdk, pubspecs);

  var names =
      {for (var pubspec in pubspecs) ...hostedDependencies(_load(pubspec)).keys}
          .difference({
            ...heldBack.keys,
            ...pinnedBySdk.keys,
            ...workspacePackages(),
          })
          .toList()
        ..sort();

  var flutter = p.join(
    sdk,
    'bin',
    Platform.isWindows ? 'flutter.bat' : 'flutter',
  );
  await _run(flutter, ['pub', 'upgrade', '--major-versions', ...names]);
  await _run(flutter, ['pub', 'upgrade']);
  await _run(Platform.resolvedExecutable, ['tool/prepare_submit.dart']);

  if (summary != null) {
    File(summary).writeAsStringSync(_summary(pubspecs, pinned));
  }
}

/// The workspace's pubspecs: the root's, then each member's.
List<String> _pubspecs() {
  var root = _load('pubspec.yaml');
  return [
    'pubspec.yaml',
    for (var member in root['workspace'] as YamlList? ?? YamlList())
      '$member/pubspec.yaml',
  ];
}

/// Rewrites each dependency in [pinnedBySdk] to the version the SDK's own
/// pubspec pins, wherever a pubspec here names one, and returns those
/// versions.
///
/// Line surgery rather than a YAML round-trip, which would drop the comments
/// that say why a pin is where it is.
Map<String, String> _pinToSdk(String sdk, List<String> pubspecs) {
  var pins = <String, String>{};
  for (var MapEntry(key: name, value: path) in pinnedBySdk.entries) {
    var theirs = hostedDependencies(_load(p.join(sdk, path)))[name];
    if (theirs == null) {
      stderr.writeln('The Flutter SDK at $sdk no longer pins $name in $path.');
      exit(1);
    }
    pins[name] = theirs;
    var line = RegExp(
      '^(  ${RegExp.escape(name)}:)[ \t]+[^ \t#\n][^\n]*\$',
      multiLine: true,
    );
    for (var pubspec in pubspecs) {
      var file = File(pubspec);
      var source = file.readAsStringSync();
      var pinned = source.replaceAllMapped(line, (m) => '${m[1]} $theirs');
      if (pinned != source) {
        file.writeAsStringSync(pinned);
        print('$pubspec: $name $theirs, as $path pins it');
      }
    }
  }
  return pins;
}

String _summary(List<String> pubspecs, Map<String, String> pinned) {
  var out = StringBuffer();

  var pinWas = _pin(_atHead('.fvmrc'));
  var pin = _pin(File('.fvmrc').readAsStringSync());
  if (pinWas != pin) {
    out
      ..writeln(
        '**Flutter** $pinWas → $pin '
        '([what changed](https://github.com/flutter/flutter/compare/'
        '$pinWas...$pin)).',
      )
      ..writeln()
      ..writeln(
        'CI runs on $pin. The `environment:` floors stay where they are: '
        '`tool/check_constraints.dart` checks that they, and a release of '
        'every dependency, still resolve on Flutter $oldestFlutter, the '
        'oldest a project builds with.',
      )
      ..writeln();
  }

  var moved = <String>[];
  for (var pubspec in pubspecs) {
    var was = switch (_atHead(pubspec)) {
      var text? => hostedDependencies(loadYaml(text) as YamlMap),
      null => const <String, String?>{},
    };
    var now = hostedDependencies(_load(pubspec));
    for (var name in {...was.keys, ...now.keys}.toList()..sort()) {
      if (was[name] != now[name]) {
        moved.add(
          _row(['`$pubspec`', name, was[name] ?? 'any', now[name] ?? 'any']),
        );
      }
    }
  }
  _table(out, '**Constraints**', ['Pubspec', 'Package', 'From', 'To'], moved);

  var lockWas = _locked(_atHead('pubspec.lock'));
  var lock = _locked(File('pubspec.lock').readAsStringSync());
  // pubspec.lock says how each package relates to the root alone, so in a
  // workspace a member's own dependency reads as transitive.
  var direct = {
    for (var pubspec in pubspecs)
      for (var section in ['dependencies', 'dev_dependencies'])
        ...?(_load(pubspec)[section] as YamlMap?)?.keys.cast<String>(),
  };
  _table(
    out,
    '**Resolved** (`pubspec.lock`)',
    ['Package', 'From', 'To', 'Dependency'],
    [
      for (var name in {...lockWas.keys, ...lock.keys}.toList()..sort())
        if (lockWas[name] != lock[name])
          _row([
            name,
            lockWas[name] ?? '—',
            lock[name] ?? '—',
            direct.contains(name) ? 'direct' : 'transitive',
          ]),
    ],
  );

  _list(out, '**Pinned by the Flutter SDK**', [
    for (var MapEntry(:key, :value) in pinned.entries)
      '$key $value, as `${pinnedBySdk[key]}` pins it in Flutter $pin',
  ]);
  _list(out, '**Held back** by `tool/check_constraints.dart`', [
    for (var MapEntry(:key, :value) in heldBack.entries) '$key: $value',
  ]);
  _list(
    out,
    '**Overridden**, so the workspace resolves these whatever the '
    'constraints say',
    [
      for (var file in ['pubspec.yaml', 'pubspec_overrides.yaml'])
        if (File(file).existsSync())
          for (var MapEntry(:key, :value)
              in (_load(file)['dependency_overrides'] as YamlMap? ?? YamlMap())
                  .entries)
            '$key ${value is String ? value : jsonEncode(value)}, in `$file`',
    ],
  );

  var formatted = [
    for (var path in _changedFiles())
      if (!const {
        'pubspec.yaml',
        'pubspec.lock',
        '.fvmrc',
      }.contains(p.basename(path)))
        '`$path`',
  ];
  _list(
    out,
    '**Formatted** again by `tool/prepare_submit.dart`, under the new '
    '`dart_style`',
    formatted,
  );

  out
    ..writeln('**Before merging**')
    ..writeln()
    ..writeln(
      "- A red check is this upgrade's breakage: fix it on this branch. "
      'The next weekly run rebuilds the branch from `master`, unless '
      "someone else's commit is on it.",
    );
  return out.toString();
}

void _table(
  StringBuffer out,
  String heading,
  List<String> columns,
  List<String> rows,
) {
  if (rows.isEmpty) return;
  out
    ..writeln(heading)
    ..writeln()
    ..writeln(_row(columns))
    ..writeln(_row([for (var _ in columns) '---']))
    ..writeAll(rows, '\n')
    ..writeln()
    ..writeln();
}

String _row(List<String> cells) => '| ${cells.join(' | ')} |';

void _list(StringBuffer out, String heading, List<String> items) {
  if (items.isEmpty) return;
  out
    ..writeln(heading)
    ..writeln()
    ..writeAll([for (var item in items) '- $item'], '\n')
    ..writeln()
    ..writeln();
}

/// Every package [lock] resolves, with its version.
Map<String, String> _locked(String? lock) {
  if (lock == null) return const {};
  var packages = (loadYaml(lock) as YamlMap)['packages'] as YamlMap;
  return {
    for (var MapEntry(:key, :value) in packages.entries)
      key as String: (value as YamlMap)['version'] as String,
  };
}

YamlMap _load(String path) =>
    loadYaml(File(path).readAsStringSync()) as YamlMap;

String? _pin(String? fvmrc) => fvmrc == null
    ? null
    : (jsonDecode(fvmrc) as Map<String, Object?>)['flutter'] as String?;

/// [path] as HEAD has it; null when HEAD has no such file.
String? _atHead(String path) {
  var result = Process.runSync('git', ['show', 'HEAD:$path']);
  return result.exitCode == 0 ? result.stdout as String : null;
}

/// The tracked files that differ from HEAD.
List<String> _changedFiles() {
  var result = Process.runSync('git', ['diff', '--name-only', 'HEAD']);
  return const LineSplitter().convert(result.stdout as String);
}

/// The Flutter SDK above the Dart running this, so `fvm dart` upgrades with
/// the pinned Flutter.
String _flutterSdk() {
  var dir = p.dirname(Platform.resolvedExecutable);
  while (!File(p.join(dir, 'packages', 'flutter_tools', 'pubspec.yaml'))
      .existsSync()) {
    var parent = p.dirname(dir);
    if (parent == dir) {
      stderr.writeln(
        'This is not running inside a Flutter SDK. Run it with the pinned '
        'one: `fvm dart tool/upgrade.dart`.',
      );
      exit(1);
    }
    dir = parent;
  }
  return dir;
}

/// Runs [executable] with the output on this one's, and exits with its code
/// when it fails.
Future<void> _run(String executable, List<String> arguments) async {
  print('> ${[p.basename(executable), ...arguments].join(' ')}');
  var process = await Process.start(
    executable,
    arguments,
    mode: ProcessStartMode.inheritStdio,
    runInShell: Platform.isWindows,
  );
  var code = await process.exitCode;
  if (code != 0) exit(code);
}
