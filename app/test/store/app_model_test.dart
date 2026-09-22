import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutterware/plugins.dart';
// ignore: implementation_imports
import 'package:flutterware/src/log_client.dart';
import 'package:flutterware/store_report.dart';
import 'package:flutterware_app/src/context.dart';
import 'package:flutterware_app/src/plugins/native/store_core.dart';
import 'package:flutterware_app/src/plugins/plugin_host.dart';
import 'package:flutterware_app/src/shell/workspace.dart';
import 'package:flutterware_app/src/shell/worktree.dart';
import 'package:flutterware_app/src/utils/flutter_sdk.dart';
import 'package:path/path.dart' as p;

/// An app is the unit, and a package can carry several.
///
/// The property under all of it: **two apps never share a path.** They may
/// share a package, a scenario file, a listing shape and every locale in it,
/// and the only thing keeping their trees, their manifests and their build
/// directories apart is the name. So the name has to be resolved in one place
/// and appear in all three.
void main() {
  late Directory root;

  setUp(() {
    root = Directory.systemTemp.createTempSync('store-apps');
    File(p.join(root.path, 'pubspec.yaml')).writeAsStringSync('name: shop\n');
  });

  tearDown(() => root.deleteSync(recursive: true));

  StoreCore coreFor(List<Map<String, Object?>> apps) {
    var worktree = Worktree(path: root.path);
    return StoreCore(
      PluginHost(
        id: storePluginId,
        label: 'Store',
        worktree: worktree,
        workspace: Workspace(
          root: worktree.path,
          declared: [const Pkg('.')],
          discovered: const ['.'],
          appContext: AppContext(logger: LogClient.print()),
          flutterSdk: FlutterSdkPath('/tmp/flutter'),
        ),
        config: {'apps': apps},
      ),
    );
  }

  Map<String, Object?> declared({String? name, String? output}) =>
      StoreShotsApp(
        const Pkg('.'),
        name: name,
        output: output,
        listings: const [
          Listing.appStore(locales: {'en': 'en-US'}),
        ],
      ).toJson();

  group('what an app is called', () {
    // The ordinary project says nothing, and gets a real name rather than an
    // invented one.
    test('the package pubspec, when the declaration is silent', () {
      var core = coreFor([declared()]);
      expect(core.nameOf(core.apps.single), 'shop');
    });

    test('the declaration, when it says', () {
      var core = coreFor([declared(name: 'shop-pro')]);
      expect(core.nameOf(core.apps.single), 'shop-pro');
    });

    // `Pkg('.').name` is `.`, which is not a directory anybody wants to see in
    // a path — and a tree is exactly where this ends up.
    test('never a bare dot', () {
      File(p.join(root.path, 'pubspec.yaml')).deleteSync();
      var core = coreFor([declared()]);
      expect(core.nameOf(core.apps.single), 'app');
    });
  });

  group('two apps, one package', () {
    late StoreCore core;

    setUp(() {
      core = coreFor([declared(name: 'shop'), declared(name: 'shop-pro')]);
    });

    test('both are declared', () {
      expect(core.apps.map(core.nameOf), ['shop', 'shop-pro']);
    });

    test('their trees do not collide', () {
      var outputs = core.apps.map(core.outputOf).toSet();
      expect(outputs, hasLength(2));
      expect(outputs.every((o) => p.isWithin(root.path, o)), isTrue);
    });

    // Two apps on one package are two scenario files and therefore two dills,
    // and a shared build directory is a tear rather than a wrong path.
    test('their roots are the same, their leaves are not', () {
      var roots = core.apps.map(core.rootOf).toSet();
      expect(roots, hasLength(1));
      expect(core.apps.map((a) => p.basename(core.outputOf(a))), [
        'shop',
        'shop-pro',
      ]);
    });
  });

  group('the app is always the last segment', () {
    // Including for a project with one app. A tree whose depth depends on how
    // many things are in it is a tree every consumer has to branch on.
    test('with one app declared', () {
      var core = coreFor([declared()]);
      expect(
        core.outputOf(core.apps.single),
        p.join(root.path, 'build', 'flutterware', 'store', 'shop'),
      );
    });

    test('under a declared output', () {
      var core = coreFor([declared(output: 'fastlane/metadata')]);
      expect(
        core.outputOf(core.apps.single),
        p.join(root.path, 'fastlane', 'metadata', 'shop'),
      );
    });
  });

  group('the rail', () {
    // Including for one app: the panel is titled by the entry it is on, and
    // a project with one app is the one that most needs telling whose
    // listing this is.
    test('one app is one entry', () {
      var core = coreFor([declared()]);
      expect(core.report.children.map((c) => (c.id, c.label)), [
        ('shop', 'shop'),
      ]);
    });

    // The id is what `--app` takes, so an address and a flag agree.
    test('two apps on one package are two entries, by name', () {
      var core = coreFor([declared(name: 'shop'), declared(name: 'shop-pro')]);
      expect(core.report.children.map((c) => c.id), ['shop', 'shop-pro']);
    });
  });

  group('narrowing to one app', () {
    test('a name nobody declared is refused, and the refusal lists them', () {
      var core = coreFor([declared(name: 'shop'), declared(name: 'shop-pro')]);
      expect(
        () => core.invoke('open', arguments: {'app': 'nope'}),
        throwsA(
          isA<ArgumentError>().having(
            (e) => '${e.message}',
            'message',
            allOf(contains('shop'), contains('shop-pro')),
          ),
        ),
      );
    });
  });

  group('the manifest', () {
    // One manifest per app, under that app's own root — so two apps cannot
    // write over each other's, and a script reading one gets one app.
    test('lands under the app, and its sets say which app they are', () {
      var core = coreFor([declared(name: 'shop')]);
      var app = core.apps.single;
      var set = StoreShotsSet(
        app: core.nameOf(app),
        store: 'app-store',
        deviceClass: 'iphone-6-9',
        appLocale: 'en',
        storeLocale: 'en-US',
        output: core.outputOf(app),
        directory: p.join('ios', 'en-US'),
        images: const ['iphone-6-9-01-menu.png'],
        exportedAt: DateTime(2026, 8, 27),
      );
      var file = File(
        p.join(
          core.outputOf(app),
          StoreShotsReport.directory,
          StoreShotsReport.fileName,
        ),
      );
      StoreShotsReport(sets: [set]).writeTo(file);

      var read = core.manifestOf(app);
      expect(read.sets.single.app, 'shop');
      expect(read['shop/app-store/iphone-6-9/en'], isNotNull);
      expect(
        read.sets.single.pathOf('iphone-6-9-01-menu.png'),
        p.join(core.outputOf(app), 'ios', 'en-US', 'iphone-6-9-01-menu.png'),
      );
    });
  });
}
