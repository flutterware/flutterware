/// The run part of the recording: a real session of the demo app on an iOS
/// simulator, driven by the shipped `fw run` actions, and the run's own files
/// copied out of the run dir.
///
/// Nothing here writes a run by hand. The launcher writes the handle and the
/// log, every `act` writes a journal line and its pictures, and the App tab's
/// answers are what the app said over the real channel. What the recorder
/// does to them is pin what differs between machines — the simulator's id,
/// pids, the VM service address, home paths and the clock — so a recording
/// says nothing about the machine that made it.
///
/// A pixels part: the screenshots are a simulator's, and the launcher's log
/// narrates a `pub get` that tracks pub.dev. Recorded from one machine and
/// never re-recorded by CI.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutterware/channels.dart';
// ignore: implementation_imports
import 'package:flutterware/src/clock.dart';
import 'package:flutterware_app/src/demo/recorded_config.dart';
import 'package:flutterware_app/src/demo/recording_paths.dart';
import 'package:flutterware_app/src/run/channel_client.dart';
import 'package:flutterware_app/src/run/connection.dart';
import 'package:flutterware_app/src/run/handle.dart';
import 'package:flutterware_app/src/shell/worktree.dart';
import 'package:flutterware_app/src/utils/run_dir.dart';
import 'package:path/path.dart' as p;

/// The simulator the session runs on — the device the demo app's previews
/// open on, so the recording and the previews show the same phone.
const recordedSimulatorName = 'iPhone 16';

/// The id the recorded device carries instead of this machine's simulator
/// udid, in every file.
const recordedDeviceId = 'iphone-16';

/// What the session does to the app, in order: the welcome screen, the menu,
/// a drink, a size, the cart, a name on the cup and the order.
const _steps = <Map<String, String>>[
  {'verb': 'observe'},
  {'verb': 'tap', 'target': 'Get started'},
  {'verb': 'tap', 'target': 'Cappuccino'},
  {'verb': 'tap', 'target': 'Large'},
  {'verb': 'tap', 'target': '{"containing":"Add to cart"}'},
  {'verb': 'enterText', 'target': '{"label":"Name on the cup"}', 'text': 'Ada'},
  {'verb': 'tap', 'target': 'Place order'},
];

/// Asked of every step: a step archives its picture at the size the caller
/// wanted, and one nobody wanted is kept small. The Screen tab shows it at
/// the size of a phone.
const _picture = ['--screenshot=true', '--maxSide=1000'];

/// The notification the session pushes once the order is placed, through the
/// devbar plugin, so the App tab's inbox has an entry and the last step shows
/// what the app did with it.
const _push = {
  'title': 'Your order is ready',
  'body': 'A large cappuccino for Ada, at the counter.',
  'link': '/order',
};

Future<String> recordRunSession({
  required String project,
  required String out,
  required String appRoot,
}) async {
  for (var stale in [
    Directory(p.join(out, 'run')),
    Directory(p.join(out, 'run.channels')),
  ]) {
    if (stale.existsSync()) stale.deleteSync(recursive: true);
  }

  var udid = await _bootSimulator();
  Future<Map<String, Object?>> fw(List<String> arguments) =>
      _fw(appRoot: appRoot, project: project, arguments: arguments);

  // The cache the desk reads, with the simulator in it — and what the
  // launch names the device by.
  await fw(['run', 'run', 'devices', '--refresh=true']);
  var launched = await fw([
    'run',
    'run',
    'launch',
    '--device=$udid',
    '--entrypoint=${recordedRunEntrypoint.path}',
    '--wait=true',
  ]);
  var app = (launched['app']! as Map).cast<String, Object?>();
  if (app['app'] != true) {
    throw StateError('the app did not come up: ${jsonEncode(app)}');
  }
  var run = app['run']! as String;
  var vmService = app['vmService']! as String;

  try {
    for (var step in _steps) {
      await fw([
        'run',
        'run',
        'act',
        '--device=$udid',
        ..._picture,
        for (var MapEntry(:key, :value) in step.entries) '--$key=$value',
      ]);
    }
    var channels = await _recordChannels(vmService);
    // What the app did with the notification, as a step of its own.
    await fw([
      'run',
      'run',
      'act',
      '--device=$udid',
      ..._picture,
      '--verb=observe',
    ]);

    var runDir = flutterwareRunDir();
    var written = _copyRun(
      runDir: runDir,
      run: run,
      udid: udid,
      out: out,
      home: Platform.environment['HOME'] ?? '',
      repoRoot: p.dirname(appRoot),
    );
    var key = written.key;
    File(p.join(out, recordedRunChannelsPath(key)))
      ..parent.createSync(recursive: true)
      ..writeAsStringSync(
        '${const JsonEncoder.withIndent('  ').convert(channels)}\n',
      );
    return '1 run ($key): ${written.steps} steps, ${written.files} files, '
        '${(written.bytes / 1024).round()} KB; '
        '${(channels['answers']! as Map).length} channel answers, '
        '${(channels['received']! as List).length} events';
  } finally {
    await fw(['run', 'run', 'stop', '--device=$udid']);
  }
}

/// Boots [recordedSimulatorName] on the newest runtime that has one, and
/// answers its udid.
Future<String> _bootSimulator() async {
  var listed = await Process.run('xcrun', [
    'simctl',
    'list',
    'devices',
    'available',
    '-j',
  ]);
  if (listed.exitCode != 0) {
    throw StateError(
      'The run part records on an iOS simulator, and `xcrun simctl` is not '
      'answering: ${listed.stderr}',
    );
  }
  var byRuntime = (jsonDecode('${listed.stdout}') as Map)['devices'] as Map;
  var runtimes = byRuntime.keys.cast<String>().toList()..sort();
  for (var runtime in runtimes.reversed) {
    for (var device in (byRuntime[runtime] as List).cast<Map>()) {
      if (device['name'] != recordedSimulatorName) continue;
      var udid = device['udid'] as String;
      if (device['state'] != 'Booted') {
        await Process.run('xcrun', ['simctl', 'boot', udid]);
      }
      await Process.run('xcrun', ['simctl', 'bootstatus', udid, '-b']);
      return udid;
    }
  }
  throw StateError(
    'No "$recordedSimulatorName" simulator on this machine. Create one in '
    'Xcode ▸ Settings ▸ Components, or with `xcrun simctl create`.',
  );
}

/// One `fw` call from the project, answering its result.
Future<Map<String, Object?>> _fw({
  required String appRoot,
  required String project,
  required List<String> arguments,
}) async {
  var result = await Process.run(Platform.resolvedExecutable, [
    'run',
    p.join(appRoot, 'bin', 'fw.dart'),
    ...arguments,
  ], workingDirectory: project);
  var stdout = '${result.stdout}';
  var start = stdout.indexOf('{');
  if (result.exitCode != 0 || start < 0) {
    throw StateError(
      'fw ${arguments.join(' ')} failed (${result.exitCode}):\n'
      '$stdout\n${result.stderr}',
    );
  }
  var json = (jsonDecode(stdout.substring(start)) as Map)
      .cast<String, Object?>();
  var answer = (json['result'] as Map?)?.cast<String, Object?>() ?? json;
  if (answer['ok'] == false) {
    throw StateError('fw ${arguments.join(' ')} refused: ${answer['error']}');
  }
  return answer;
}

/// Attaches to the app's channels the way the App tab does, pushes the
/// notification, and keeps every reply the tab would ask for.
Future<Map<String, Object?>> _recordChannels(String vmService) async {
  var connection = await RunConnection.connect(vmService);
  var client = await RunChannelClient.attach(connection, peer: 'recorder');
  try {
    var answers = <String, Object?>{};
    Future<Map<String, Object?>> ask(
      String channel,
      String method, [
      Map<String, Object?> params = const {},
    ]) async {
      var reply = await client.request(channel, method, params);
      answers[recordedChannelRequestKey(channel, method, params)] = reply;
      return reply;
    }

    var listed = await client.request(panelsChannel, panelsList);
    var panels = [
      for (var panel in listed['panels'] as List? ?? const [])
        PanelDescriptor.fromJson((panel as Map).cast<String, Object?>()),
    ];
    var push = panels.firstWhere((panel) => panel.id == 'push');
    await client.request(push.id, panelSetKnobMethod, {
      'id': 'permission',
      'value': 'Granted',
    });
    await client.request(push.id, 'send', _push);
    // The feed's event travels after the reply to `send`.
    await Future<void>.delayed(const Duration(milliseconds: 500));

    await ask(panelsChannel, panelsList);
    for (var panel in panels) {
      await ask(panel.id, panelKnobsMethod);
      for (var state in panel.states) {
        await ask(panel.id, panelStateMethod, {'id': state.id});
      }
    }
    var feedChannels = {
      for (var panel in panels)
        for (var feed in panel.feeds) panel.feedChannel(feed.id),
    };
    // Delivered just after the order, a minute before the pinned now — the
    // clock the session's own steps are moved to.
    var deliveredAt = pinnedClockOrigin.subtract(const Duration(seconds: 55));
    var received = [
      for (var event in client.received)
        if (feedChannels.contains(event.channel))
          {
            'channel': event.channel,
            'id': event.id,
            'time': deliveredAt.toIso8601String(),
            if (event.rid != null) 'rid': event.rid,
            'payload': {
              ...event.payload,
              if (event.payload.containsKey('receivedAt'))
                'receivedAt': deliveredAt.millisecondsSinceEpoch,
            },
          },
    ];
    return {'received': received, 'answers': answers};
  } finally {
    await client.close();
  }
}

/// Copies one run's handle, log, journal and pictures into the recording,
/// under [recordedRunDir] and with everything machine-shaped pinned.
({String key, int steps, int files, int bytes}) _copyRun({
  required String runDir,
  required String run,
  required String udid,
  required String out,
  required String home,
  required String repoRoot,
}) {
  var handlePath = p.join(runDir, '$run.json');
  var handle = RunHandle.tryRead(File(handlePath));
  if (handle == null) throw StateError('no handle at $handlePath');

  const pid = 1;
  const vmService = 'ws://127.0.0.1:0/recording=/ws';
  // The address without its scheme: the log spells it as `ws://` and as
  // `http://`, and both are this machine's port and token.
  var service = Uri.parse(handle.vmService ?? 'ws://none/');
  var serviceBase = '${service.authority}${p.posix.dirname(service.path)}';
  var worktreeName = const Worktree(
    path: recordedProjectRoot,
    isMain: true,
  ).name;
  var oldKey = handle.key;
  var key = runHandleKey(
    recordedProjectRoot,
    recordedDeviceId,
    handle.entrypoint,
  );
  var stem = '$key-$pid';

  var journal = File(p.join(runDir, '$run.journal.jsonl'))
      .readAsLinesSync()
      .where((line) => line.trim().isNotEmpty)
      .map((line) => (jsonDecode(line) as Map).cast<String, Object?>())
      .toList();
  if (journal.isEmpty) throw StateError('the session journaled nothing');

  // The clock: the last step lands a minute before the studio's pinned now,
  // and everything keeps its real distance from it. Written as local times,
  // like the pinned clock itself, so an age reads the same in every zone.
  var last = DateTime.parse(journal.last['at']! as String);
  var shift = pinnedClockOrigin
      .subtract(const Duration(minutes: 1))
      .difference(last);
  String moved(String at) =>
      DateTime.parse(at).add(shift).toLocal().toIso8601String();

  // The simulator and the host's own targets are the recording's. Any other
  // device — a phone plugged into the recording machine — is that person's
  // phone, named after them, and has no place in a fixture.
  var devicesFile = File(p.join(runDir, 'devices.json'));
  var cachedDevices = devicesFile.existsSync()
      ? ((jsonDecode(devicesFile.readAsStringSync()) as Map)['devices']
                    as List? ??
                const [])
            .cast<Map>()
      : const <Map>[];
  bool isRecorded(Map device) =>
      device['id'] == udid ||
      device['category'] == 'desktop' ||
      device['category'] == 'web';
  var private = {
    for (var device in cachedDevices)
      if (!isRecorded(device)) ...[
        '${device['id']}',
        if (device['name'] case String name) name,
      ],
  };
  String withoutPrivate(String text) => const LineSplitter()
      .convert(text)
      .where((line) => !private.any(line.contains))
      .map((line) => '$line\n')
      .join();

  var artifactsDir = p.join(runDir, 'journal', run);
  var newArtifactsDir = p.join(recordedRunDir, 'journal', stem);
  String text(String value) => value
      .replaceAll(artifactsDir, newArtifactsDir)
      .replaceAll(runDir, recordedRunDir)
      .replaceAll(p.join(repoRoot, 'examples', 'brewline'), recordedProjectRoot)
      .replaceAll(repoRoot, recordedProjectRoot)
      .replaceAll(home.isEmpty ? '\u0000' : home, '~')
      .replaceAll(udid, recordedDeviceId)
      .replaceAll(serviceBase, '127.0.0.1:0/recording=')
      .replaceAll('/${handle.worktreeName}/', '/$worktreeName/')
      .replaceAll(oldKey, key);

  var files = <String, List<int>>{};
  var logName = '$key.log';
  files[logName] = utf8.encode(
    text(withoutPrivate(File(handle.logPath!).readAsStringSync())),
  );
  var recorded = RunHandle(
    worktree: recordedProjectRoot,
    worktreeName: worktreeName,
    device: recordedDeviceId,
    deviceName: handle.deviceName,
    entrypoint: handle.entrypoint,
    entrypointName: handle.entrypointName,
    package: '.',
    flavor: handle.flavor,
    launcherPid: pid,
    vmService: vmService,
    appId: handle.appId,
    logPath: p.join(recordedRunDir, logName),
    startedAt: DateTime.parse(
      moved(handle.startedAt.toUtc().toIso8601String()),
    ),
  );
  files['$stem.json'] = utf8.encode(
    '${const JsonEncoder.withIndent('  ').convert({
      ...recorded.toJson(),
      // `toJson` spells it in UTC; see [moved] for why this one is local.
      'startedAt': moved(handle.startedAt.toIso8601String()),
    })}\n',
  );
  files['$stem.journal.jsonl'] = utf8.encode(
    '${[
      for (var entry in journal) jsonEncode({for (var MapEntry(:key, :value) in entry.entries) key: switch (value) {
            String() when key == 'at' => moved(value),
            String() => text(value),
            _ => value,
          }}),
    ].join('\n')}\n',
  );
  for (var file in Directory(artifactsDir).listSync().whereType<File>()) {
    var name = p.basename(file.path);
    var bytes = file.readAsBytesSync();
    files[p.join('journal', stem, name)] = name.endsWith('.png')
        ? bytes
        : utf8.encode(text(utf8.decode(bytes)));
  }
  if (devicesFile.existsSync()) {
    var cache = (jsonDecode(devicesFile.readAsStringSync()) as Map)
        .cast<String, Object?>();
    if (cache['updatedAt'] case String at) cache['updatedAt'] = moved(at);
    cache['devices'] = [
      for (var device in cachedDevices)
        if (isRecorded(device)) jsonDecode(text(jsonEncode(device))),
    ];
    files['devices.json'] = utf8.encode(
      '${const JsonEncoder.withIndent('  ').convert(cache)}\n',
    );
  }

  var bytes = 0;
  for (var MapEntry(key: relative, value: content) in files.entries) {
    File(p.join(out, recordedRunFilePath(relative)))
      ..parent.createSync(recursive: true)
      ..writeAsBytesSync(content);
    bytes += content.length;
  }
  File(p.join(out, recordedRunIndexPath)).writeAsStringSync(
    '${const JsonEncoder.withIndent('  ').convert({'files': files.keys.toList()..sort()})}\n',
  );
  return (key: key, steps: journal.length, files: files.length, bytes: bytes);
}
