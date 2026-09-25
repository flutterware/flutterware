/// Times opening a two-person world from a cold worktree.
///
/// The measure the guest experiment's speed clause is decided on
/// (`docs/superpowers/specs/2026-09-25-worlds-guest-experiment-plan.md`,
/// *The rule*): from a worktree where nothing is resolved and nothing is
/// built, how long until every person's first screen is showing. Each
/// candidate takes its fastest path, and the report names the steps, so a
/// path that is fast by skipping something says what it skipped.
///
/// ```sh
/// fvm dart fixtures/world_lab/app/tool/cold_open.dart <worktree> macos
/// fvm dart fixtures/world_lab/app/tool/cold_open.dart <worktree> simulator <udid> <udid>
/// fvm dart fixtures/world_lab/app/tool/cold_open.dart <worktree> guest [seeds | <seed.dill>] [--studio-answers]
/// ```
///
/// `guest` stands this checkout's `app/tool/embedder/run_app.dart` in for the
/// studio, which is already running when somebody opens a world: its own
/// start-up is not counted, and its clock starts where the worktree's work
/// does. `seeds` uses the studio's machine-level seed store — the half of the
/// program under the SDK and the pub cache, left by any checkout that compiled
/// it before (`app/lib/src/embedder/seed_kernel.dart`); a path is a kernel to
/// start from instead. `--studio-answers` is candidate 2: the plugins' own
/// Dart halves, their platform answered by the harness, instead of the lab's
/// fakes.
///
/// The worktree is prepared by the caller (`git worktree add`), because
/// checking out is not part of opening a world. The machine is warm — the pub
/// cache, the SDK's artifacts and, for the simulator, both devices booted — and
/// the report says so rather than pretending otherwise.
///
/// The SDK is the one running this script: `fvm dart` names it, and nothing
/// here reaches for a `flutter` on PATH.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

const _bundleId = 'dev.flutterware.worldlab.worldLabApp';
final _firstFrame = RegExp(r'world_lab: first frame at (\S+),');

final _clock = Stopwatch();
late final DateTime _start;

Future<void> main(List<String> args) async {
  if (args.length < 2 || !{'macos', 'simulator', 'guest'}.contains(args[1])) {
    stderr.writeln(
      'usage: cold_open.dart <worktree> macos\n'
      '       cold_open.dart <worktree> simulator <udid> <udid>\n'
      '       cold_open.dart <worktree> guest [seeds | <seed.dill>] '
      '[--studio-answers]',
    );
    exitCode = 64;
    return;
  }
  var worktree = Directory(args[0]).absolute.path;
  var app = '$worktree/fixtures/world_lab/app';
  if (Directory('$app/build').existsSync() ||
      Directory('$worktree/.dart_tool').existsSync()) {
    stderr.writeln('$worktree is not cold: it has a build or a .dart_tool.');
    exitCode = 1;
    return;
  }
  var answers = args.contains('--studio-answers');
  var devices = args.skip(2).where((a) => a != '--studio-answers').toList();
  if (args[1] == 'simulator') await _prepareSimulators(devices);

  _start = DateTime.now();
  _clock.start();
  await _step('resolve', () => _run(_flutter, ['pub', 'get'], worktree));
  List<DateTime> frames;
  if (args[1] == 'guest') {
    frames = await _guests(
      app,
      seed: devices.firstOrNull,
      studioAnswers: answers,
    );
  } else if (args[1] == 'macos') {
    await _step(
      'build',
      () => _run(_flutter, ['build', 'macos', '--debug'], app),
    );
    var first = '$app/build/macos/Build/Products/Debug/world_lab_app.app';
    var second = '$app/build/macos/Build/Products/Debug/world_lab_app_2.app';
    await _step('give the second person a bundle id', () async {
      await _run('cp', ['-Rc', first, second], app);
      await _run('/usr/libexec/PlistBuddy', [
        '-c',
        'Set :CFBundleIdentifier $_bundleId.person2',
        '$second/Contents/Info.plist',
      ], app);
      await _run('codesign', [
        '--force',
        '--sign',
        '-',
        '--entitlements',
        'macos/Runner/DebugProfile.entitlements',
        second,
      ], app);
    });
    frames = await _step(
      'start both, until both have drawn',
      () => Future.wait([_execToFirstFrame(first), _execToFirstFrame(second)]),
    );
  } else {
    await _step(
      'build',
      () => _run(_flutter, ['build', 'ios', '--simulator', '--debug'], app),
    );
    var built = '$app/build/ios/iphonesimulator/Runner.app';
    frames = await _step(
      'install and start on both, until both have drawn',
      () => Future.wait([
        for (var device in devices) _simulatorToFirstFrame(device, built),
      ]),
    );
  }

  stdout.writeln('');
  for (var (i, frame) in frames.indexed) {
    stdout.writeln(
      'person ${i + 1}: screen showing at '
      '${_seconds(frame.difference(_start))}',
    );
  }
  var last = frames.reduce((a, b) => a.isAfter(b) ? a : b);
  stdout.writeln(
    'world open: ${_seconds(last.difference(_start))} '
    '(${args[1]}${answers ? ', studio answers' : ''}, cold worktree, '
    'warm machine)',
  );
  for (var process in _started) {
    process.kill();
  }
}

/// Both people in embedded guests, by this checkout's harness, answering the
/// moment each guest drew — measured on the harness's clock, which starts when
/// the worktree's work does, and placed on this script's.
Future<List<DateTime>> _guests(
  String app, {
  String? seed,
  bool studioAnswers = false,
}) async {
  var checkout = File.fromUri(Platform.script)
      .parent
      .parent
      .parent
      .parent
      .parent;
  var harness = await Process.start(Platform.resolvedExecutable, [
    'run',
    'tool/embedder/run_app.dart',
    '--package',
    app,
    if (studioAnswers)
      '--studio-answers'
    else ...[
      '--fakes',
      '$app/guest/fakes.dart',
    ],
    '--person',
    'Ana;person=Ana',
    '--person',
    'Leo;person=Leo',
    if (seed == 'seeds') '--seeds' else if (seed != null) ...['--seed', seed],
  ], workingDirectory: '${checkout.path}/app');
  _started.add(harness);
  // Where the resolve left off: the harness's clock is placed here, so its
  // own start-up — which a running studio does not pay — is not counted.
  var resolved = _start.add(_clock.elapsed);
  var drew = <DateTime>[];
  var done = Completer<void>();
  harness.stdout.transform(utf8.decoder).transform(const LineSplitter()).listen(
    (line) {
      if (!line.startsWith('[world]')) return;
      if (RegExp(r'^\[world\]\s+[\d.]+ s  ').hasMatch(line)) {
        stdout.writeln('   (harness) ${line.substring(8).trim()}');
      }
      var at = RegExp(r': drew at ([\d.]+) s').firstMatch(line);
      if (at != null) {
        var seconds = double.parse(at.group(1)!);
        drew.add(resolved.add(Duration(microseconds: (seconds * 1e6).round())));
        if (drew.length == 2) done.complete();
      }
    },
  );
  harness.stderr.transform(utf8.decoder).listen(stderr.write);
  await done.future;
  stdout.writeln("   (the harness's own start-up is not counted)");
  return drew;
}

/// `<sdk>/bin/cache/dart-sdk/bin/dart` → `<sdk>/bin/flutter`.
final _flutter = File(Platform.resolvedExecutable)
    .parent
    .parent
    .parent
    .parent
    .uri
    .resolve('flutter')
    .toFilePath();

final _started = <Process>[];

Future<T> _step<T>(String name, Future<T> Function() body) async {
  var at = _clock.elapsed;
  var result = await body();
  stdout.writeln(
    '${_seconds(_clock.elapsed).padLeft(7)}  $name '
    '(${_seconds(_clock.elapsed - at)})',
  );
  return result;
}

String _seconds(Duration d) =>
    '${(d.inMilliseconds / 1000).toStringAsFixed(1)} s';

Future<void> _run(String executable, List<String> args, String cwd) async {
  var result = await Process.run(executable, args, workingDirectory: cwd);
  if (result.exitCode != 0) {
    throw Exception(
      '$executable ${args.join(' ')} failed (${result.exitCode}):\n'
      '${result.stdout}\n${result.stderr}',
    );
  }
}

/// Starts a built macOS app and answers when it has drawn its first frame.
Future<DateTime> _execToFirstFrame(String bundle) async {
  var process = await Process.start('$bundle/Contents/MacOS/world_lab_app', []);
  _started.add(process);
  return _firstFrameIn(process.stdout);
}

/// Installs and starts the app on a booted simulator, reading its first frame
/// from the device's log — an iOS app's `print` goes there, not to a console.
Future<DateTime> _simulatorToFirstFrame(String device, String app) async {
  var log = await Process.start('xcrun', [
    'simctl',
    'spawn',
    device,
    'log',
    'stream',
    '--style',
    'compact',
    '--predicate',
    'process == "Runner"',
  ]);
  _started.add(log);
  var frame = _firstFrameIn(log.stdout);
  await _run('xcrun', ['simctl', 'install', device, app], '.');
  await _run('xcrun', ['simctl', 'launch', device, _bundleId], '.');
  return frame;
}

Future<DateTime> _firstFrameIn(Stream<List<int>> output) async {
  var line = await output
      .transform(utf8.decoder)
      .transform(const LineSplitter())
      .firstWhere(_firstFrame.hasMatch)
      .timeout(const Duration(minutes: 2));
  return DateTime.parse(_firstFrame.firstMatch(line)!.group(1)!).toLocal();
}

/// Both devices booted, and the app gone from each, so the install is a first
/// install on every run.
Future<void> _prepareSimulators(List<String> devices) async {
  if (devices.length != 2) {
    throw ArgumentError('simulator takes two device ids');
  }
  var list = await Process.run('xcrun', [
    'simctl',
    'list',
    'devices',
    'booted',
    '-j',
  ]);
  var booted = {
    for (var runtime
        in ((jsonDecode(list.stdout as String) as Map)['devices'] as Map)
            .values)
      for (var device in runtime as List) (device as Map)['udid'],
  };
  for (var device in devices) {
    if (!booted.contains(device)) {
      throw StateError('$device is not booted; boot it first.');
    }
    await Process.run('xcrun', ['simctl', 'uninstall', device, _bundleId]);
  }
}
