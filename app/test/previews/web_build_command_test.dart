import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:flutterware/plugins.dart';
// ignore: implementation_imports
import 'package:flutterware/src/log_client.dart';
import 'package:flutterware_app/src/previews/catalog_entry.dart';
import 'package:flutterware_app/src/previews/web_build.dart';
import 'package:flutterware_app/src/previews/web_build_dialog.dart';
import 'package:flutterware_app/src/context.dart';
import 'package:flutterware_app/src/plugins/native/previews_core.dart';
import 'package:flutterware_app/src/plugins/plugin_host.dart';
import 'package:flutterware_app/src/shell/workspace.dart';
import 'package:flutterware_app/src/shell/worktree.dart';
import 'package:flutterware_app/src/utils/flutter_sdk.dart';
import 'package:flutterware_app/src/session/job.dart';

/// The command the build dialog shows.
///
/// It is an instruction to a user, so the thing worth testing is not its
/// wording but whether it would *work*: the flags have to be the ones the
/// action declares, and the defaults it leaves out have to be the ones the
/// action actually defaults to.
void main() {
  String command({
    String package = '.',
    bool nameThePackage = false,
    String output = '',
    String baseHref = '',
  }) => webBuildCommand(
    pluginId: uiCatalogPluginId,
    package: package,
    nameThePackage: nameThePackage,
    output: output,
    baseHref: baseHref,
  );

  test('the bare form names the plugin the way the CLI resolves it', () {
    // `fw` matches on the last dotted segment, not the full id.
    expect(command(), 'dart run flutterware run previews build-web');
  });

  test('the default output is left off', () {
    // Spelling out a value that changes nothing teaches the flag rather than
    // the command.
    expect(
      command(output: WebCatalogBuilder.defaultOutput),
      isNot(contains('--output')),
    );
    expect(command(output: 'docs/catalog'), contains('--output=docs/catalog'));
  });

  test('the package is named only where the action needs it', () {
    expect(command(package: 'packages/ui'), isNot(contains('--package')));
    expect(
      command(package: 'packages/ui', nameThePackage: true),
      contains('--package=packages/ui'),
    );
  });

  test('a base href appears as written', () {
    expect(command(baseHref: '/catalog/'), endsWith('--base-href=/catalog/'));
  });

  test('a path with a space is quoted', () {
    // Unquoted this is two arguments and the command silently builds somewhere
    // else.
    expect(
      command(output: 'my builds/web'),
      contains("--output='my builds/web'"),
    );
  });

  group('cancellation', () {
    late Directory root;

    setUp(() {
      root = Directory.systemTemp.createTempSync('fw_web_cancel_test');
      Directory(p.join(root.path, 'web')).createSync(recursive: true);
      var demo = Directory(p.join(root.path, 'demo'))
        ..createSync(recursive: true);
      File(p.join(demo.path, 'a.dart')).writeAsStringSync('''
import 'package:material_ui/material_ui.dart';

Widget a() => const Placeholder();
''');
    });

    tearDown(() => root.deleteSync(recursive: true));

    const entry = CatalogEntry(
      path: 'demo/a.dart',
      symbol: 'a',
      name: 'A',
      annotation: 'Demo()',
    );

    test('a cancelled build says so rather than looking broken', () async {
      // A stand-in for the compile: a child that ignores the build arguments
      // and does not finish on its own, so the only way this call returns is
      // the kill. `exec` so the signal reaches the sleep rather than a shell
      // holding it.
      var fake = File(p.join(root.path, 'fake_flutter'))
        ..writeAsStringSync('#!/bin/sh\nexec sleep 30\n');
      Process.runSync('chmod', ['+x', fake.path]);

      var builder = WebCatalogBuilder(
        flutterExecutable: fake.path,
        packageRoot: root.path,
        title: 'Example',
      );
      var building = builder.build(entries: const [entry]);

      // After the process is up, so there is something to signal.
      await Future<void>.delayed(const Duration(milliseconds: 200));
      await builder.cancel();

      // Not "exit 143": a build stopped on purpose is not a build that broke,
      // and before this the child was never signalled at all — it outlived the
      // app, kept writing into the project, and had its generated sources
      // deleted under it by the next build.
      await expectLater(
        building,
        throwsA(
          isA<ActionRefusal>().having(
            (e) => e.message,
            'message',
            contains('cancelled'),
          ),
        ),
      );
    });
  });

  group('against the action it claims to run', () {
    late Directory root;

    PreviewsCore core() {
      var worktree = Worktree(path: root.path);
      return PreviewsCore(
        PluginHost(
          id: uiCatalogPluginId,
          label: 'Previews',
          worktree: worktree,
          workspace: Workspace(
            root: worktree.path,
            declared: [Pkg('.')],
            discovered: const ['.'],
            appContext: AppContext(logger: LogClient.print()),
            flutterSdk: FlutterSdkPath('/tmp/flutter'),
          ),
          config: const {
            'packages': [
              {'path': '.'},
            ],
          },
        ),
      );
    }

    setUp(() {
      root = Directory.systemTemp.createTempSync('fw_web_command_test');
    });

    tearDown(() => root.deleteSync(recursive: true));

    test('every flag it prints is one the action declares', () {
      var action = core().report.actions.firstWhere(
        (a) => a.id == webBuildActionId,
      );
      var declared = {for (var p in action.parameters) p.id};

      var printed = command(
        package: 'packages/ui',
        nameThePackage: true,
        output: 'docs/catalog',
        baseHref: '/catalog/',
      );
      var flags = RegExp(r'--([a-z-]+)=')
          .allMatches(printed)
          .map((m) => m.group(1)!)
          .toSet();

      expect(flags, isNotEmpty);
      // A flag renamed on the action and not here is a command that fails the
      // moment somebody copies it.
      expect(declared, containsAll(flags));
    });

    test('the action it names exists', () {
      expect(
        core().report.actions.map((a) => a.id),
        contains(webBuildActionId),
      );
    });
  });
}
