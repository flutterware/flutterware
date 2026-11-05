@Timeout(Duration(minutes: 3))
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutterware_app/src/embedder/build_directory.dart';
import 'package:flutterware_app/src/embedder/flutter_cache.dart';
import 'package:flutterware_app/src/embedder/tester_host.dart';
import 'package:flutterware_app/src/utils/run_dir.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory temp;
  late String root;
  late String cache;
  late File source;
  late List<String> lines;
  late List<TesterHost> hosts;
  var sdk = FlutterCache.fromRunningSdk().flutterRoot;

  TesterHost host({String lane = 'first', void Function(String)? log}) {
    var result = TesterHost(
      packageRoot: root,
      flutterSdkRoot: sdk,
      program: _Program(source.path),
      lane: BuildLane(
        root,
        preferred: '$sessionBuildRoot/$lane',
        program: 'probe',
      ),
      onLog: (line) {
        lines.add(line);
        log?.call(line);
      },
    );
    hosts.add(result);
    return result;
  }

  List<File> seeds() => Directory(cache).existsSync()
      ? Directory(cache)
            .listSync(recursive: true)
            .whereType<File>()
            .where((f) => f.path.endsWith('.dill'))
            .toList()
      : [];

  Future<void> expectValue(TesterHost h, String value) async {
    var reply = await h.exclusive(() async {
      await h.ensureGuest();
      return h.vm.requireExtension('ext.flutterware.probe');
    });
    expect(reply?['value'], value);
  }

  setUp(() {
    temp = Directory.systemTemp.createTempSync('tester-host-');
    root = p.join(temp.path, 'project');
    cache = p.join(temp.path, 'cache');
    flutterwareDirOverride = cache;
    lines = [];
    hosts = [];
    Directory(root).createSync();
    File(p.join(root, 'pubspec.yaml')).writeAsStringSync('''
name: host_probe
environment:
  sdk: ^3.13.0-0
dependencies:
  flutter:
    sdk: flutter
''');
    var configFile = File(
      p.join(
        Directory.current.parent.path,
        '.dart_tool',
        'package_config.json',
      ),
    );
    var config =
        jsonDecode(configFile.readAsStringSync()) as Map<String, dynamic>;
    for (var package in (config['packages'] as List).cast<Map>()) {
      package['rootUri'] = configFile.uri
          .resolve(package['rootUri'] as String)
          .toString();
    }
    (config['packages'] as List).add({
      'name': 'host_probe',
      'rootUri': Uri.directory(root).toString(),
      'packageUri': 'lib/',
      'languageVersion': '3.13',
    });
    File(p.join(root, '.dart_tool', 'package_config.json'))
      ..parent.createSync(recursive: true)
      ..writeAsStringSync(jsonEncode(config));
    var graphFile = File(
      p.join(Directory.current.parent.path, '.dart_tool', 'package_graph.json'),
    );
    var graph =
        jsonDecode(graphFile.readAsStringSync()) as Map<String, dynamic>;
    graph['roots'] = ['host_probe'];
    (graph['packages'] as List).add({
      'name': 'host_probe',
      'version': '1.0.0',
      'dependencies': ['flutter'],
      'devDependencies': <String>[],
    });
    File(p.join(root, '.dart_tool', 'package_graph.json'))
        .writeAsStringSync(jsonEncode(graph));
    source = File(p.join(root, 'main.dart'))
      ..writeAsStringSync(_source('first'));
  });

  tearDown(() async {
    try {
      for (var h in hosts.reversed) {
        await h.dispose();
      }
    } finally {
      flutterwareDirOverride = null;
      temp.deleteSync(recursive: true);
    }
  });

  test('first result precedes seed publication; disposal restores a reusable kernel', () async {
    var h = host();
    await expectValue(h, 'first');
    expect(seeds(), isEmpty);
    source.writeAsStringSync(_source('edited'));
    await h.refresh();
    await expectValue(h, 'edited');
    expect(seeds(), isEmpty, reason: 'requests must not pay for publication');

    var entered = Completer<void>();
    var release = Completer<void>();
    var turn = h.exclusive(() async {
      entered.complete();
      await release.future;
    });
    await entered.future;
    var queued = expectLater(
      h.exclusive(() async {
        fail('a queued request ran after disposal');
      }),
      throwsStateError,
    );
    var disposed = h.dispose();
    expect(identical(disposed, h.dispose()), isTrue);
    await Future<void>.delayed(Duration.zero);
    expect(seeds(), isEmpty, reason: 'publication waits for the compiler turn');
    await expectLater(h.exclusive(() async {}), throwsStateError);
    release.complete();
    await turn;
    await queued;
    await disposed;
    expect(seeds(), hasLength(1));
    expect(lines.where((line) => line.contains('seeded ')), hasLength(1));
    await expectLater(h.start(), throwsStateError);

    // A new compiler must load the full edited program, not the seed's empty
    // main. A different lane must also be able to use the published seed.
    await expectValue(host(), 'edited');
    await expectValue(host(lane: 'second'), 'edited');
    expect(lines, contains(contains('starting from a seed')));
  });

  test(
    'asset failure drains the concurrent compile, and a fixed start retries',
    () async {
      var h = host();
      var blocked = File(p.join(root, h.buildDirectory, 'probe_assets'))
        ..parent.createSync(recursive: true)
        ..writeAsStringSync('a file blocks the asset directory');
      await expectLater(h.start(), throwsA(anything));
      expect(
        lines,
        contains(contains('compiled the harness in')),
        reason:
            'asset failure must wait for the independently started compiler',
      );
      expect(seeds(), isEmpty);
      blocked.deleteSync();
      await expectValue(h, 'first');
    },
  );

  test('compile failure is reported and does not publish a seed', () async {
    source.writeAsStringSync('this is not Dart');
    var h = host();
    await expectLater(h.start(), throwsA(isA<TesterCompileException>()));
    expect(seeds(), isEmpty);
    source.writeAsStringSync(_source('fixed'));
    await expectValue(h, 'fixed');
  });

  test(
    'dispose during compilation drains startup without spawning a guest',
    () async {
      Future<void>? disposing;
      late TesterHost h;
      h = host(
        log: (line) {
          if (line.contains('compiling the harness')) disposing = h.dispose();
        },
      );
      await expectLater(h.start(), throwsStateError);
      await disposing;
      expect(seeds(), isEmpty);
      expect(File(h.logPath).existsSync(), isFalse);
      await expectValue(host(), 'first');
    },
  );

  test(
    'publication failure restores the full program and reports the failure',
    () async {
      var failed = false;
      var h = host(
        log: (line) {
          if (!failed && line.contains('seeded ')) {
            failed = true;
            throw StateError('publication callback failed');
          }
        },
      );
      await expectValue(h, 'first');
      await h.dispose();
      expect(failed, isTrue);
      expect(
        lines,
        contains(
          contains('no seed written: Bad state: publication callback failed'),
        ),
      );
      await expectValue(host(), 'first');
    },
  );

  test(
    'a failed kernel restoration fails disposal and discards the unsafe output',
    () async {
      late TesterHost h;
      var blocked = false;
      h = host(
        log: (line) {
          if (!blocked && line.contains('seeded ')) {
            blocked = true;
            // A directory at the output path makes the return emit fail.
            File(h.dillPath).deleteSync();
            Directory(h.dillPath).createSync();
          }
        },
      );
      await expectValue(h, 'first');
      var disposing = h.dispose();
      await expectLater(disposing, throwsA(anything));
      expect(blocked, isTrue);
      expect(
        File(p.join(root, h.buildDirectory, 'probe.dill')).existsSync(),
        isFalse,
      );
      expect(identical(disposing, h.dispose()), isTrue);
      hosts.remove(h); // The expected failure is retained by dispose.
      Directory(h.dillPath).deleteSync();
      await expectValue(host(), 'first');
    },
  );

  test(
    'an unwritable seed store is reported and leaves the full kernel usable',
    () async {
      var h = host();
      await expectValue(h, 'first');
      File(p.join(cache, 'kernels'))
        ..parent.createSync(recursive: true)
        ..writeAsStringSync('a file blocks the cache directory');
      await h.dispose();
      expect(lines, contains(contains('could not write a seed root')));
      await expectValue(host(), 'first');
    },
  );
}

class _Program extends TesterProgram {
  _Program(this.entrypoint);
  final String entrypoint;
  @override
  String get name => 'probe';
  @override
  String get readyLine => 'probe ready';
  @override
  List<String> sources() => [entrypoint];
  @override
  String writeEntrypoint(List<String> sources) => entrypoint;
}

String _source(String value) =>
    '''
import 'dart:developer';
import 'package:flutter/widgets.dart';
String value() => '$value';
void main() {
  WidgetsFlutterBinding.ensureInitialized();
  registerExtension('ext.flutterware.probe', (_, __) async =>
    ServiceExtensionResponse.result('{"value":"\${value()}"}'));
  print('probe ready');
}
''';
