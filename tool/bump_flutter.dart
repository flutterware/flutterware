/// Moves the two Flutter numbers this repo keeps, which are deliberately not
/// one number.
///
/// `.fvmrc` is the SDK development happens on: fvm installs exactly it, CI
/// runs exactly it. It moves whenever there is a newer beta worth having,
/// which is often.
///
/// The `environment:` floors in the shipping pubspecs are a *promise* — the
/// oldest Flutter this package claims to work on. They move only when
/// something below them actually breaks. Left to track the pin they promise
/// the beta of the week, which is exactly how `flutter: '>=3.47.0-0'` came to
/// sit in a package whose last published floor was `>=3.21.0`: a floor naming
/// an unreleased beta is a package nobody on stable can install.
///
/// Keeping them apart is what lets stable catch up on its own. The floor stays
/// put, stable rises past it, and the package becomes installable there with
/// nobody republishing anything.
///
/// ```
/// fvm dart tool/bump_flutter.dart beta        # or stable, or 3.48.0-0.1.pre
/// fvm dart tool/bump_flutter.dart --floor     # promise the pin, after a break
/// fvm dart tool/bump_flutter.dart --check     # what CI runs; offline
/// ```
///
/// A bump writes the pin only. Run `fvm install` afterwards to fetch it.
library;

import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:pub_semver/pub_semver.dart';
import 'package:yaml/yaml.dart';

/// The same index fvm installs from, so this cannot name a version that would
/// then fail to install.
const _releaseIndex =
    'https://storage.googleapis.com/flutter_infra_release/releases/releases_macos.json';

/// Only the pubspecs that reach a user carry the promise.
///
/// `fixtures/probe_app` is excluded on purpose: `.pubignore` keeps `fixtures/`
/// out of the archive, so its floor is nobody's promise, and it records a real
/// requirement of its own (dot shorthands, Dart 3.10) that a workspace-wide
/// rewrite would flatten. [_check] still holds it to being satisfiable, and
/// `examples/brewline` with it: the demo's floor is a stranger's, not ours.
const _shipping = ['pubspec.yaml', 'app/pubspec.yaml'];

Future<void> main(List<String> args) async {
  var root = _repoRoot();
  var check = args.contains('--check');
  var floor = args.contains('--floor');
  var rest = args.where((a) => !a.startsWith('--')).toList();

  if (check) {
    exit(_check(root));
  }
  if (rest.length > 1 || (!floor && rest.isEmpty)) {
    stderr.writeln(
      'usage: bump_flutter.dart <version|beta|stable>'
      ' | --floor [<version>] | --check',
    );
    exit(64);
  }

  // `--floor` with no version promises what we already develop on, which is
  // the common case after a break: you found the breakage by running the pin.
  var target = rest.isEmpty
      ? _Release.ofPin(root)
      : await _resolve(rest.single);

  // One or the other, never both: a command that moved the pin *and* the floor
  // is the drift this tool exists to stop, however deliberate it looked when
  // typed.
  if (floor) {
    for (var relative in _shipping) {
      _rewriteEnvironment(File(p.join(root.path, relative)), target);
      print(
        'floor: $relative -> flutter ${target.flutterFloor},'
        ' sdk ${target.sdkFloor}',
      );
    }
    print(
      '\nThe pin did not move. Analyze and test before committing this:'
      '\na floor is a claim, and nothing below it has been run.',
    );
  } else {
    // The version alone, so the file keeps the layout fvm gave it and a bump
    // is one changed line.
    var fvmrc = File(p.join(root.path, '.fvmrc'));
    var source = fvmrc.readAsStringSync();
    var version = RegExp(r'("flutter"\s*:\s*")[^"]*"');
    fvmrc.writeAsStringSync(
      version.hasMatch(source)
          ? source.replaceFirstMapped(
              version,
              (m) => '${m[1]}${target.flutter}"',
            )
          : '{\n  "flutter": "${target.flutter}"\n}',
    );
    print('pin: .fvmrc -> ${target.flutter} (Dart ${target.dart})');
    print(
      '\nThe floor did not move. Run --floor only when something below it'
      ' broke;\nuntil then it is what lets stable catch up on its own.',
    );
  }
}

/// Fails loudly rather than in a resolve nobody reads.
///
/// Everything here is offline: the pin's own Dart version comes from the
/// `flutter.version.json` of the SDK running this, which is the pinned one on
/// a laptop and in CI alike.
int _check(Directory root) {
  var release = _Release.ofPin(root);
  var problems = <String>[];

  for (var relative in [
    ..._shipping,
    'fixtures/probe_app/pubspec.yaml',
    'examples/brewline/pubspec.yaml',
  ]) {
    var file = File(p.join(root.path, relative));
    var environment =
        (loadYaml(file.readAsStringSync()) as YamlMap)['environment']
            as YamlMap;

    for (var entry in {
      'sdk': release.dart,
      'flutter': release.flutter,
    }.entries) {
      var text = environment[entry.key] as String?;
      if (text == null) continue;
      var constraint = VersionConstraint.parse(text);
      if (!constraint.allows(entry.value)) {
        problems.add(
          '$relative: ${entry.key}: $text does not allow ${entry.value},'
          ' which .fvmrc pins',
        );
      }
    }
  }

  if (problems.isEmpty) {
    print(
      '.fvmrc pins ${release.flutter} (Dart ${release.dart}), which'
      ' satisfies every floor.',
    );
    return 0;
  }
  stderr.writeln('The pin and the floors disagree:\n');
  for (var problem in problems) {
    stderr.writeln('  $problem');
  }
  stderr.writeln(
    '\nA floor above the pin is the drift this check exists to catch: the'
    '\nrepo would no longer build on the SDK it says it develops on. Either'
    '\nbump the pin, or lower the floor by hand — `--floor` only raises it.',
  );
  return 1;
}

/// A Flutter version and the Dart it ships, which are never guessed apart:
/// both come from one release-index entry, or one `flutter.version.json`.
class _Release {
  final Version flutter;
  final Version dart;

  _Release(this.flutter, this.dart);

  /// The pinned version, described by **the SDK running this script**.
  ///
  /// Reading the running SDK rather than a version manager's cache keeps
  /// [_check] offline, and means this works wherever it is invoked from: under
  /// `fvm dart` on a laptop, and in CI where the pin was installed by a setup
  /// action that has never heard of fvm. Looking in `~/fvm` would have been a
  /// guess about the machine, which is the habit this repo has just finished
  /// removing everywhere else.
  ///
  /// The running SDK **has to be the pinned one**, and saying so is half the
  /// value: a check run under the wrong SDK compares the floors against a Dart
  /// version nobody pinned and passes or fails for the wrong reason.
  factory _Release.ofPin(Directory root) {
    var pin = readPin(root);
    var sdk = _runningSdk();
    if (sdk == null) {
      stderr.writeln(
        'this is not running inside a Flutter SDK, so it cannot read the pin'
        "'s\nDart version. Run it with the pinned SDK: "
        '`fvm dart tool/bump_flutter.dart --check`.',
      );
      exit(1);
    }

    var json = jsonDecode(
      File(p.join(sdk, 'bin', 'cache', 'flutter.version.json'))
          .readAsStringSync(),
    ) as Map<String, dynamic>;
    var running = json['frameworkVersion'] as String;
    if (running != pin) {
      stderr.writeln(
        '.fvmrc pins $pin but this is running under $running.'
        '\nRun it with the pinned SDK: `fvm dart tool/bump_flutter.dart '
        '--check`,\nafter `fvm install`.',
      );
      exit(1);
    }

    return _Release(
      Version.parse(pin),
      // "3.13.0 (build 3.13.0-282.1.beta)" — the build is the precise one.
      _dartVersion(json['dartSdkVersion'] as String),
    );
  }

  /// The Flutter SDK above [Platform.resolvedExecutable], or null.
  ///
  /// `<flutter>/bin/cache/dart-sdk/bin/dart` is four levels down, but the walk
  /// is written as a search rather than a count so it survives a layout change.
  static String? _runningSdk() {
    var dir = p.dirname(Platform.resolvedExecutable);
    while (true) {
      if (File(p.join(dir, 'bin', 'flutter')).existsSync() &&
          File(p.join(dir, 'bin', 'cache', 'flutter.version.json'))
              .existsSync()) {
        return dir;
      }
      var parent = p.dirname(dir);
      if (parent == dir) return null;
      dir = parent;
    }
  }

  /// `>=3.48.0-0` for a prerelease, `>=3.44.9` for a stable.
  ///
  /// The `-0` matters: without it a constraint naming `3.48.0` excludes every
  /// `3.48.0-x.y.pre`, so a beta floor would reject the very betas it means.
  String get flutterFloor => flutter.isPreRelease
      ? '>=${flutter.major}.${flutter.minor}.0-0'
      : '>=$flutter';

  String get sdkFloor => dart.isPreRelease
      ? '^${dart.major}.${dart.minor}.0-0'
      : '^${dart.major}.${dart.minor}.0';
}

/// The build number, not the marketing one: `flutter.version.json` says
/// `3.13.0 (build 3.13.0-282.1.beta)`, and only the parenthesised half sorts
/// correctly against a `^3.13.0-0` floor.
Version _dartVersion(String raw) {
  var build = RegExp(r'\(build ([^)]+)\)').firstMatch(raw);
  return Version.parse(build?.group(1) ?? raw.split(' ').first);
}

/// A version, or a channel name resolved to whatever it points at today.
Future<_Release> _resolve(String nameOrChannel) async {
  var response = await http.get(Uri.parse(_releaseIndex));
  if (response.statusCode != 200) {
    stderr.writeln('the release index answered ${response.statusCode}');
    exit(1);
  }
  var index = jsonDecode(response.body) as Map<String, dynamic>;
  var releases = (index['releases'] as List).cast<Map<String, dynamic>>();
  var current = index['current_release'] as Map<String, dynamic>;

  // One architecture only: the same entry is published per `dart_sdk_arch`,
  // and taking the first match of a bare version would pick by list order.
  var matches = releases.where(
    (r) =>
        r['dart_sdk_arch'] == 'arm64' &&
        (r['version'] == nameOrChannel ||
            (nameOrChannel == r['channel'] &&
                current[nameOrChannel] == r['hash'])),
  );
  if (matches.isEmpty) {
    stderr.writeln(
      '"$nameOrChannel" is not a version or channel in the release index.'
      '\nfvm installs from that index, so a name it does not carry'
      '\nis one it could not fetch.',
    );
    exit(1);
  }
  var release = matches.first;
  return _Release(
    Version.parse(release['version'] as String),
    _dartVersion(release['dart_sdk_version'] as String),
  );
}

/// Rewrites the `sdk:` and `flutter:` lines in place.
///
/// Line surgery rather than a YAML round-trip: these blocks carry comments
/// explaining *why* a floor is where it is, and a round-trip drops them.
void _rewriteEnvironment(File pubspec, _Release release) {
  var source = pubspec.readAsStringSync();
  var inEnvironment = false;
  var out = <String>[];

  for (var line in const LineSplitter().convert(source)) {
    if (!line.startsWith(' ') && line.isNotEmpty) {
      inEnvironment = line.startsWith('environment:');
    }
    // Only lines that already exist: a member without a `flutter:` floor is
    // one that never promised anything, and inventing one is not a bump.
    if (inEnvironment && RegExp(r'^  sdk:\s').hasMatch(line)) {
      out.add('  sdk: ${release.sdkFloor}');
    } else if (inEnvironment && RegExp(r'^  flutter:\s').hasMatch(line)) {
      out.add("  flutter: '${release.flutterFloor}'");
    } else {
      out.add(line);
    }
  }
  // Down to the final newline the file did or did not have: a bump should show
  // up as two changed constraints, not as two constraints and a whitespace
  // diff nobody asked for.
  pubspec.writeAsStringSync(
    out.join('\n') + (source.endsWith('\n') ? '\n' : ''),
  );
}

/// Anchored on this script, not on cwd — the same reason
/// `tool/prepare_submit.dart` is.
Directory _repoRoot() {
  var dir = File.fromUri(Platform.script).parent;
  while (true) {
    if (File('${dir.path}/.fvmrc').existsSync()) return dir;
    var parent = dir.parent;
    if (parent.path == dir.path) {
      throw StateError('no .fvmrc above ${Platform.script}');
    }
    dir = parent;
  }
}

/// The version `.fvmrc` names — fvm's own format, a JSON object with a
/// `flutter` key.
String readPin(Directory root) {
  var file = File(p.join(root.path, '.fvmrc'));
  if (jsonDecode(file.readAsStringSync()) case {'flutter': String pinned}
      when pinned.isNotEmpty) {
    return pinned;
  }
  stderr.writeln('${file.path} does not name a Flutter version.');
  exit(1);
}
