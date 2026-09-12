import 'dart:convert';
import 'dart:io';

// ignore: implementation_imports
import 'package:flutterware/src/clock.dart';
import 'package:flutterware/server.dart';
import 'package:flutterware_app/src/demo/recording_paths.dart';
import 'package:flutterware_app/src/launcher_icon/model/scan.dart';
import 'package:flutterware_app/src/scenarios/axes.dart';
import 'package:flutterware_app/src/scenarios/discovery.dart';
import 'package:flutterware_app/src/scenarios/runner.dart';
import 'package:flutterware_app/src/utils/flutter_sdk.dart';
import 'package:path/path.dart' as p;

import 'server_traffic.dart';

/// Writes the recording the studio's demos open: `app/demo/fixture/`.
///
/// Runs the real readers on a real project and keeps what they produced, with
/// every file they name copied in beside it. Nothing here is written by hand,
/// so the recording is only ever an output of the shipped formats and cannot
/// drift from the code that reads it — a recording that stops loading is a
/// format change, found at the right time.
///
/// ```sh
/// cd app && fvm dart run tool/demo/record.dart [project-dir]
/// ```
///
/// The project defaults to `examples/brewline`, the demo app, recorded **as
/// if it were the root of its own repository**: its package path in the
/// recording is `.`.
/// That is what a reader's project usually looks like, and it keeps the
/// recorded project's workspace to one package nothing on disk has to
/// confirm.
///
/// `--only=launcher-icon`, `--only=scenarios` or `--only=server` records one
/// part. The launcher-icon and server parts are byte-identical on every
/// machine, which CI checks; the scenario part spawns the harness and keeps
/// its pixels, which are not, and is recorded from one machine on purpose.
///
/// The server part runs no server: a real [ServerInspector] is started in
/// this process, `tool/demo/server_traffic.dart` reports into it the way a
/// server's adapters do, and the recorder attaches over the real protocol
/// and keeps what came back — so the recording is the wire's own shapes.
Future<void> main(List<String> arguments) async {
  var appRoot = p.dirname(p.dirname(p.dirname(p.fromUri(Platform.script))));
  String? only;
  String? projectArg;
  for (var argument in arguments) {
    if (argument.startsWith('--only=')) {
      only = argument.substring('--only='.length);
      if (!const {'launcher-icon', 'scenarios', 'server'}.contains(only)) {
        stderr.writeln(
          'usage: record.dart [project] '
          '[--only=launcher-icon|scenarios|server]',
        );
        exit(64);
      }
    } else {
      projectArg = argument;
    }
  }
  var project = projectArg == null
      ? p.join(p.dirname(appRoot), 'examples', 'brewline')
      : p.normalize(p.absolute(projectArg));
  var out = p.join(appRoot, 'demo', 'fixture');

  if (!File(p.join(project, 'pubspec.yaml')).existsSync()) {
    stderr.writeln('Not a package: $project');
    exit(1);
  }

  var written = <String>[
    if (only == null || only == 'launcher-icon')
      _recordLauncherIcons(project: project, out: out),
    if (only == null || only == 'scenarios')
      await _recordScenarios(
        project: project,
        out: out,
        scratch: p.join(appRoot, 'build', 'demo_record'),
      ),
    if (only == null || only == 'server') await _recordServer(out: out),
  ];
  print(
    'Recorded ${p.relative(project, from: p.dirname(appRoot))} into '
    '${p.relative(out, from: appRoot)}:\n  ${written.join('\n  ')}',
  );
}

/// Which scenario files of the demo app are recorded: the coffee shop's
/// walks, on a phone and in a window. Enough to show a flow, a device frame
/// of each kind and a step page, without the whole suite's pictures in git.
const recordedScenarioFiles = [
  'test/scenarios/mobile/shop_test.dart',
  'test/scenarios/desktop/shop_window_test.dart',
];

/// The scan, the harness's listing, and a run of [recordedScenarioFiles] with
/// every artifact copied in. The harness is the real one, spawned the way the
/// panel spawns it; what is kept is its report, verbatim but for the paths.
Future<String> _recordScenarios({
  required String project,
  required String out,
  required String scratch,
}) async {
  const packagePath = '.';
  var dir = Directory(p.join(out, 'scenarios'));
  if (dir.existsSync()) dir.deleteSync(recursive: true);
  if (Directory(scratch).existsSync()) {
    Directory(scratch).deleteSync(recursive: true);
  }
  var sdk = await FlutterSdkPath.findSdk();
  if (sdk == null) {
    stderr.writeln("Run this through a Flutter SDK's dart: fvm dart run …");
    exit(1);
  }

  void write(String path, Map<String, Object?> json) => File(p.join(out, path))
    ..parent.createSync(recursive: true)
    ..writeAsStringSync(
      '${const JsonEncoder.withIndent('  ').convert(json)}\n',
    );

  // The scan, as the core takes it: the default root, since the recorded
  // manifest declares no directory.
  // The scan, as the core takes it, narrowed to the files that are run
  // below: the recorded project *has* those scenarios and no others, so
  // its list offers nothing a click cannot open.
  var scanned = ScenarioScanner(
    packageRoot: project,
    directory: defaultScenariosScanRoot,
  ).scan();
  var scan = ScenarioScanResult(
    scenarios: [
      for (var ref in scanned.scenarios)
        if (recordedScenarioFiles.contains(ref.file)) ref,
    ],
    diagnostics: scanned.diagnostics,
    unnamed: scanned.unnamed,
    configFolders: scanned.configFolders,
  );
  write(recordedScenarioScanPath(packagePath), scan.toJson());

  // The banner icon the flow page shows, found the way the page finds it.
  if (representativeIconPath(packageRoot: project) case var icon?) {
    File(icon).copySync(
      (File(
        p.join(out, recordedScenarioAppIconPath(packagePath)),
      )..parent.createSync(recursive: true)).path,
    );
  }

  var runner = ScenarioRunner(
    packageRoot: project,
    directory: defaultScenariosScanRoot,
    flutterSdkRoot: sdk.root,
    onLog: (line) => stderr.writeln('  [harness] $line'),
  );
  var copied = 0;
  var bytes = 0;
  var scenarios = 0;
  var steps = 0;
  try {
    var listed = await runner.list();
    write(recordedScenarioListingsPath(packagePath), {
      'scenarios': [
        for (var listing in listed)
          if (recordedScenarioFiles.contains(listing.file)) listing.toJson(),
      ],
    });

    for (var (i, file) in recordedScenarioFiles.indexed) {
      var report = await runner.run(
        outDir: p.join(scratch, '$i'),
        file: file,
        unspecifiedDevice: defaultScenarioDeviceId,
      );
      for (var entry in (report['scenarios']! as List)) {
        var outcome = (entry as Map).cast<String, Object?>();
        scenarios++;
        var into = recordedScenarioArtifactDir(
          packagePath,
          file,
          outcome['name']! as String,
        );
        for (var step in (outcome['steps'] as List? ?? const [])) {
          steps++;
          var fields = (step as Map).cast<String, Object?>();
          for (var key in _stepPathFields) {
            if (fields[key] case String source when source.isNotEmpty) {
              var destination = '$into/${p.basename(source)}';
              var target = File(p.join(out, destination))
                ..parent.createSync(recursive: true);
              if (source.endsWith('.json')) {
                // A tree names each widget's source file by absolute path,
                // which is this machine's. Re-rooted so the recorded project
                // is where it says it is, and nothing of the laptop that
                // recorded it ships.
                target.writeAsStringSync(
                  _reroot(File(source).readAsStringSync(), project),
                );
              } else {
                File(source).copySync(target.path);
              }
              copied++;
              bytes += target.lengthSync();
              fields[key] = destination;
            }
          }
        }
      }
      write(
        recordedScenarioRunPath(packagePath, file),
        (jsonDecode(_reroot(jsonEncode(report), project)) as Map)
            .cast<String, Object?>(),
      );
    }
    write(recordedScenarioRunsIndexPath(packagePath), {
      'files': recordedScenarioFiles,
    });
  } finally {
    await runner.dispose();
  }
  return '${scanned.scenarios.length} scenarios scanned, '
      '${scan.scenarios.length} kept, '
      '${recordedScenarioFiles.length} files run ($scenarios scenarios, '
      '$steps steps), $copied artifacts, '
      '${(bytes / 1024).toStringAsFixed(0)} KB';
}

/// [text] with every absolute path under [project] spelled under the
/// recorded project's root instead — the workspace above it too, for the
/// paths that reach into it.
String _reroot(String text, String project) => text
    .replaceAll(project, recordedProjectRoot)
    .replaceAll(p.dirname(p.dirname(project)), '$recordedProjectRoot/..');

/// The step fields that name a file — the ones `ScenarioRunStep.locate`
/// rewrites, and the ones `RecordedScenarioRunner` puts back under the
/// recorded root.
const _stepPathFields = [
  'image',
  'tree',
  'file',
  'keys',
  'semantics',
  'events',
  'frames',
];

/// The default scan and one per flavor, with the files copied flat.
String _recordLauncherIcons({required String project, required String out}) {
  const packagePath = '.';
  var dir = Directory(p.join(out, 'launcher_icon'));
  // Generated wholesale: a flavor that no longer exists would otherwise leave
  // its scan behind, and the recording would claim it.
  if (dir.existsSync()) dir.deleteSync(recursive: true);

  var flavors = <String?>[
    null,
    for (var flavor in discoverIconFlavors(project)) flavor.name,
  ];
  var copied = <String, int>{};
  for (var flavor in flavors) {
    var scan = scanIcons(
      packageRoot: project,
      packagePath: packagePath,
      flavor: flavor,
    );
    var json = scan.toJson();
    for (var role in json['roles']! as List) {
      for (var file in ((role as Map)['files'] as List? ?? const [])) {
        var entry = file as Map;
        var source = File(entry['absolutePath']! as String);
        var destination = recordedIconFilePath(
          packagePath,
          entry['path']! as String,
        );
        if (!copied.containsKey(destination)) {
          var target = File(p.join(out, destination))
            ..parent.createSync(recursive: true);
          source.copySync(target.path);
          copied[destination] = source.lengthSync();
        }
        entry['absolutePath'] = destination;
        // A recording carries no clock. The file's mtime is whatever the last
        // checkout set it to, which would make the same project record
        // differently on every machine — and CI checks that re-recording
        // changes nothing. The panel never draws it; the inventory action
        // reports it, and reports the pinned instant everything else renders
        // at.
        entry['modified'] = pinnedClockOrigin.toIso8601String();
      }
    }
    File(p.join(out, recordedIconScanPath(packagePath, flavor: flavor)))
      ..parent.createSync(recursive: true)
      ..writeAsStringSync(
        '${const JsonEncoder.withIndent('  ').convert(json)}\n',
      );
  }

  var bytes = copied.values.fold(0, (sum, length) => sum + length);
  return '${flavors.length} launcher icon scans '
      '(${flavors.skip(1).join(', ')}), ${copied.length} files, '
      '${(bytes / 1024).toStringAsFixed(0)} KB';
}

/// The orders server's ring, as an attachment received it.
///
/// A real inspector in a temp run dir, the scripted traffic reported into
/// it, one attachment over the real socket — then everything the attachment
/// holds is written down: hello, events, the details behind each event, and
/// the answers to the two SQL commands. Times are re-rooted to
/// [pinnedClockOrigin] and spaced evenly, and the identity is the recorded
/// project's, so the file is the same on every machine.
Future<String> _recordServer({required String out}) async {
  const packagePath = '.';
  const name = 'orders';
  var dir = Directory(p.join(out, 'server'));
  if (dir.existsSync()) dir.deleteSync(recursive: true);

  // Short paths on purpose: a unix socket path is capped at 104 bytes, and
  // the macOS temp directory alone spends most of that.
  var scratch = Directory('/tmp').existsSync()
      ? Directory('/tmp')
      : Directory.systemTemp;
  var runDir = scratch.createTempSync('fwrec-run-');
  var projectRoot = scratch.createTempSync('fwrec-srv-');
  var inspector = ServerInspector.start(
    runDir: runDir.path,
    projectRoot: projectRoot.path,
    name: name,
    pid: 4242,
  );
  // The recorder stands where a test does: one inspector, attached by hand.
  // ignore: invalid_use_of_visible_for_testing_member
  FlutterwareServer.debugAttachInspector(inspector);
  try {
    await inspector.published;
    playOrdersServer();
    var handle = scanServerHandles(runDir.path).single;
    var client = await ServerAttachClient.connect(handle);
    try {
      var deadline = DateTime.now().add(const Duration(seconds: 5));
      while (!client.replayComplete && DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      var events = client.received;
      var details = <String, Map<String, Object?>>{};
      for (var event in events) {
        var fetched = await client.details(event.id);
        if (fetched != null) details['${event.id}'] = fetched;
      }
      var answers = <String, Map<String, Object?>>{
        for (var method in ['explain', 'requery'])
          'sql/$method': await client.request('sql', method, {
            'query': ordersByCustomerQuery,
            'params': [7],
          }),
      };
      var startedAt = pinnedClockOrigin.subtract(const Duration(minutes: 3));
      var json = {
        'handle': {
          'projectRoot': recordedProjectRoot,
          'name': name,
          'socketPath': '$recordedProjectRoot/.dart_tool/$name.sock',
          'pid': handle.pid,
          'startedAt': startedAt.toIso8601String(),
          'baseUrl': handle.baseUrl,
          'environment': handle.environment,
        },
        'hello': {
          'name': client.hello.name,
          'pid': client.hello.pid,
          'projectRoot': recordedProjectRoot,
          'startedAt': startedAt.toIso8601String(),
          'channels': client.hello.channels,
          'eventCount': client.hello.eventCount,
        },
        'events': [
          for (var (i, event) in events.indexed)
            {
              'id': event.id,
              'channel': event.channel,
              'time': pinnedClockOrigin
                  .add(Duration(milliseconds: 350 * i))
                  .toIso8601String(),
              if (event.rid != null) 'rid': event.rid,
              'payload': event.payload,
            },
        ],
        'details': details,
        'answers': answers,
      };
      File(p.join(out, recordedServerPath(packagePath, name)))
        ..parent.createSync(recursive: true)
        ..writeAsStringSync(
          '${const JsonEncoder.withIndent('  ').convert(json)}\n',
        );
      File(p.join(out, recordedServerIndexPath(packagePath))).writeAsStringSync(
        '${const JsonEncoder.withIndent('  ').convert({
          'servers': [name],
        })}\n',
      );
      return '1 server ($name): ${events.length} events, '
          '${details.length} with details, ${answers.length} answers';
    } finally {
      await client.close();
    }
  } finally {
    await inspector.stop();
    // ignore: invalid_use_of_visible_for_testing_member
    await FlutterwareServer.reset();
    for (var d in [runDir, projectRoot]) {
      if (d.existsSync()) d.deleteSync(recursive: true);
    }
  }
}
