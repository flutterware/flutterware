import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutterware/plugins.dart';
import 'package:flutterware/src/log_client.dart';
import 'package:flutterware_app/src/context.dart';
import 'package:flutterware_app/src/plugins/native/scenarios_core.dart';
import 'package:flutterware_app/src/plugins/plugin_host.dart';
import 'package:flutterware_app/src/shell/workspace.dart';
import 'package:flutterware_app/src/shell/worktree.dart';
import 'package:flutterware_app/src/utils/flutter_sdk.dart';
import 'package:path/path.dart' as p;

/// A package declared twice — a fake-time folder and a real-time one — is two
/// entries on every surface, addressed apart, built apart, rooted together.
void main() {
  late Directory root;

  setUp(() {
    root = Directory.systemTemp.createTempSync('fw-folders');
    for (var dir in ['app/test/scenarios', 'app/test/integration']) {
      Directory(p.join(root.path, dir)).createSync(recursive: true);
    }
  });

  tearDown(() => root.deleteSync(recursive: true));

  ScenariosCore core(List<Map<String, Object?>> declared) {
    var worktree = Worktree(path: root.path);
    return ScenariosCore(
      PluginHost(
        id: scenariosPluginId,
        label: 'Scenarios',
        worktree: worktree,
        workspace: Workspace(
          root: worktree.path,
          declared: [Pkg('app')],
          discovered: ['app'],
          appContext: AppContext(logger: LogClient.print()),
          flutterSdk: FlutterSdkPath('/tmp/flutter'),
        ),
        config: {'packages': declared},
      ),
    );
  }

  test('a package declared once is addressed by its path', () {
    var subject = core([
      {'path': 'app', 'directory': 'test/scenarios'},
    ]);
    expect(subject.packages, ['app']);
    expect(subject.packagePathFor('app'), 'app');
    expect(subject.scanRootFor('app'), 'test/scenarios');
    expect(subject.buildDirectoryFor('app'), 'build/flutterware');
    expect(subject.timeFor('app'), isNull);
  });

  test('a second folder of the same package is addressed by its directory', () {
    var subject = core([
      {
        'path': 'app',
        'directory': 'test/scenarios',
        'languages': ['en'],
      },
      {
        'path': 'app',
        'directory': 'test/integration',
        'time': 'real',
        'animations': 0.5,
      },
    ]);
    expect(subject.packages, ['app', 'app/test/integration']);

    // Same package under both, and everything else its own.
    expect(subject.packagePathFor('app/test/integration'), 'app');
    expect(
      subject.packageRootFor('app/test/integration'),
      subject.packageRootFor('app'),
    );
    expect(subject.scanRootFor('app/test/integration'), 'test/integration');
    expect(
      subject.buildDirectoryFor('app/test/integration'),
      'build/flutterware/folders/test/integration',
    );
    expect(subject.languagesFor('app/test/integration'), isEmpty);
    expect(subject.timeFor('app/test/integration')?.isReal, isTrue);
    expect(subject.timeFor('app/test/integration')?.animations, 0.5);

    // A comparison runs the fake-time folder and never the live one.
    expect(subject.comparablePackages, ['app']);

    // The first folder is untouched by the second.
    expect(subject.scanRootFor('app'), 'test/scenarios');
    expect(subject.buildDirectoryFor('app'), 'build/flutterware');
    expect(subject.timeFor('app'), isNull);
    expect(subject.languagesFor('app'), ['en']);
  });

  test('a key nobody declares reads as a bare package, never a throw', () {
    // A page keyed by a folder the config dropped, between a reload and its
    // rebuild: defaults under a build, and the refusal stays with actions.
    var subject = core([
      {'path': 'app', 'directory': 'test/scenarios'},
    ]);
    expect(
      subject.packagePathFor('app/test/integration'),
      'app/test/integration',
    );
    expect(subject.scanRootFor('app/test/integration'), 'test');
    expect(subject.timeFor('app/test/integration'), isNull);
    expect(subject.languagesFor('app/test/integration'), isEmpty);
  });
}
