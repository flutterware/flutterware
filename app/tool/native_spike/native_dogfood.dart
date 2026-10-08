// Dogfood driver for the native fallback layer.
//
// The stack an agent actually uses — a real Session, the run plugin's own
// act/observe actions — against an app already running on a device, driving
// both layers in one story: the Flutter layer for what Flutter draws, the
// native layer for what it does not, and the journal reconciling the two.
//
//   cd app && fvm dart run tool/native_spike/native_dogfood.dart <device> [outDir]
import 'dart:convert';
import 'dart:io';

import 'package:flutterware/plugins.dart';
// ignore: implementation_imports
import 'package:flutterware/src/log_client.dart';
import 'package:flutterware_app/src/session/job.dart';
import 'package:flutterware_app/src/session/session.dart';
import 'package:path/path.dart' as p;

late Session session;
late Directory outDir;
late String device;

Future<Map<String, Object?>> run(
  String action,
  Map<String, Object?> args,
) async {
  Job job;
  try {
    job = session.invoke('run', action, arguments: args);
  } on SessionException catch (e) {
    return {'error': '$e'};
  }
  var result = await job.done;
  if (!result.ok) return {'error': describeJobError(result.error!)};
  return switch (result.value) {
    PluginResult value => value.toJson(),
    var other => {'value': '$other'},
  };
}

Future<Map<String, Object?>> act(
  String label,
  Map<String, Object?> args,
) async {
  var started = DateTime.now();
  var reply = await run('act', {'device': device, ...args});
  var ms = DateTime.now().difference(started).inMilliseconds;
  stderr.writeln(
    '>> $label [${args['layer'] ?? 'flutter'}] ${args['verb']} '
    '${args['target'] ?? ''}',
  );
  stderr.writeln(
    '   ok=${reply['ok']} ${ms}ms nodes=${reply['nodes']} '
    'space=${reply['coordinateSpace'] ?? '-'} '
    'scale=${reply['screenshotScale'] ?? '-'} '
    'reconciled=${reply['reconciled'] ?? 0}',
  );
  if (reply['error'] case String error) {
    stderr.writeln('   ! ${error.replaceAll('\n', '\n     ')}');
  }
  if (reply['screenshot'] case String path) {
    File(path).copySync(p.join(outDir.path, '$label.png'));
  }
  return reply;
}

Future<void> main(List<String> args) async {
  device = args.isNotEmpty ? args[0] : 'emulator-5554';
  outDir = Directory(args.length > 1 ? args[1] : '/tmp/fw-native')
    ..createSync(recursive: true);
  var repoRoot = p.dirname(Directory.current.absolute.path);
  session = await Session.open(
    Directory(repoRoot),
    logger: LogClient.writeTo(stderr),
  );
  var report = <String, Object?>{};
  try {
    report['flutter-observe'] = await act('1-flutter-observe', {
      'verb': 'observe',
    });

    var native = await act('2-native-observe', {
      'verb': 'observe',
      'layer': 'native',
    });
    report['native-observe'] = {
      'texts': (native['texts'] as List?)?.take(25).toList(),
      'note': native['note'],
    };

    // The whole point of the layer: tap through it, and prove it landed by
    // asking the *other* layer what happened.
    report['native-tap'] = await act('3-native-tap', {
      'verb': 'tap',
      'layer': 'native',
      'target': 'Increment',
    });
    report['after-tap'] = await act('4-flutter-observe', {'verb': 'observe'});

    // Refusals are the teaching surface: a target that exists on neither
    // layer, on each layer.
    report['flutter-miss'] = await act('5-flutter-miss', {
      'verb': 'tap',
      'target': 'NoSuchThing',
    });
    report['native-miss'] = await act('6-native-miss', {
      'verb': 'tap',
      'layer': 'native',
      'target': 'NoSuchThing',
    });
    report['native-unsupported'] = await act('7-native-key', {
      'verb': 'tap',
      'layer': 'native',
      'target': jsonEncode({'key': 'whatever'}),
    });
    report['native-drag'] = await act('8-native-drag', {
      'verb': 'drag',
      'layer': 'native',
      'target': 'Increment',
    });
  } finally {
    File(p.join(outDir.path, 'report.json'))
        .writeAsStringSync(const JsonEncoder.withIndent('  ').convert(report));
    stderr.writeln('\nartifacts in ${outDir.path}');
    session.dispose();
    exit(0);
  }
}
