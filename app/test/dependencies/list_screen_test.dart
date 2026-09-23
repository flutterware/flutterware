import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutterware/plugins.dart' show Address;
// ignore: implementation_imports
import 'package:flutterware/src/log_client.dart';
import 'package:flutterware_app/src/address/address_scope.dart';
import 'package:flutterware_app/src/context.dart';
import 'package:flutterware_app/src/dependencies/list.dart';
import 'package:flutterware_app/src/dependencies/model/service.dart';
import 'package:flutterware_app/src/package_ref.dart';
import 'package:flutterware_app/src/ui/table.dart';
import 'package:flutterware_app/src/ui/theme.dart';
import 'package:flutterware_app/src/utils/flutter_sdk.dart';

/// Mounts the real screen and checks that it lays out.
///
/// The point is the layout. The screen used to be a `ListView` wrapping a
/// `DataTable` inside a `SizedBox` whose height was `rowCount * rowHeight`; it
/// is now a bounded `Column` so the table can virtualize. That swap is exactly
/// the kind that renders at zero height or overflows without anyone noticing
/// until they open the app, and a widget test fails loudly on both.
///
/// `pub deps` is answered from the captured fixture rather than by spawning
/// the real thing: a widget test drives fake time, so a subprocess never
/// completes inside one and `pumpAndSettle` waits forever. That injection seam
/// is why `DependenciesService` takes a `runProcess`.
void main() {
  var fixture = File('test/dependencies/fixtures/pub_deps.json')
      .readAsStringSync();

  Future<void> pumpScreen(
    WidgetTester tester, {
    Size size = const Size(1200, 800),
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    var service = DependenciesService(
      PackageRef(
        AppContext(logger: LogClient.print()),
        '../fixtures/probe_app',
        // Never invoked: the injected runProcess answers instead.
        FlutterSdkPath('/tmp/flutter'),
      ),
      runProcess: (executable, arguments, {workingDirectory}) async =>
          ProcessResult(0, 0, fixture, ''),
    );
    addTearDown(service.dispose);

    var address = ValueNotifier(
      Address(worktree: 'wt', plugin: 'flutterware.dependencies'),
    );
    addTearDown(address.dispose);

    // **Before** the pump, not after. The lockfile and the package config are
    // real files, so the load only progresses in real time — and a load started
    // by the widget's own subscription begins under fake time, which nothing in
    // `runAsync` can then drive to completion. Loading first leaves the
    // AsyncValue already initialised, so mounting subscribes to a cached value
    // and starts nothing.
    await tester.runAsync(() => service.dependencies.refresh());

    await tester.pumpWidget(
      MaterialApp(
        theme: appTheme,
        home: Scaffold(
          body: AddressRoot(
            address: address,
            onChanged: (next) => address.value = next,
            child: DependenciesScreen(service, package: 'fixtures/probe_app'),
          ),
        ),
      ),
    );

    // Not pumpAndSettle: the pub_scores loader is left unresolved on purpose
    // (nothing here needs scores) and its spinner would never settle.
    await tester.pump();
  }

  testWidgets('lays out and lists the declared dependencies', (tester) async {
    await pumpScreen(tester);

    expect(tester.takeException(), isNull);
    expect(find.byType(FwTable<Dependency>), findsOneWidget);

    // The table got real height rather than collapsing to nothing.
    expect(
      tester.getSize(find.byType(FwTable<Dependency>)).height,
      greaterThan(200),
    );

    // Direct + dev are on by default, transitive is not.
    expect(find.text('flutterware'), findsOneWidget);
    expect(find.text('path_provider'), findsOneWidget);
    expect(find.text('async'), findsNothing);
  });

  testWidgets('the columns Stage B added are on screen', (tester) async {
    await pumpScreen(tester);

    for (var column in [
      'PACKAGE',
      'TYPE',
      'ORIGIN',
      'CONSTRAINT',
      'RESOLVED',
      'PUB',
      'GITHUB',
    ]) {
      expect(find.text(column), findsOneWidget, reason: 'missing $column');
    }
  });

  testWidgets('origin is shown per package, not left blank', (tester) async {
    await pumpScreen(tester);

    // A workspace sibling and the SDK packages are the two kinds that used to
    // render as an empty cell for every member of a workspace.
    expect(find.text('workspace'), findsWidgets);
    expect(find.text('Flutter SDK'), findsWidgets);
    expect(find.text('pub.dev'), findsWidgets);
  });

  testWidgets('filtering by kind narrows the table', (tester) async {
    await pumpScreen(tester);
    expect(find.text('flutterware'), findsOneWidget);

    // The chip carries its count, which is also what tells it apart from the
    // fourteen "Direct" badges in the rows below.
    await tester.tap(find.text('Direct 14'));
    await tester.pump();

    expect(find.text('flutterware'), findsNothing);
    expect(find.text('flutter_test'), findsOneWidget);
  });

  testWidgets('search narrows what the kind filter left', (tester) async {
    await pumpScreen(tester);

    await tester.enterText(find.byType(TextFormField), 'provider');
    await tester.pump();

    expect(find.text('path_provider'), findsOneWidget);
    expect(find.text('flutterware'), findsNothing);
  });

  testWidgets('a narrow viewport scrolls rather than overflowing', (
    tester,
  ) async {
    // Every column declares a minWidth, so at 700px they outgrow the viewport
    // and the table must scroll horizontally instead of painting over its edge.
    await pumpScreen(tester, size: const Size(700, 600));
    expect(tester.takeException(), isNull);
    expect(find.byType(FwTable<Dependency>), findsOneWidget);
  });
}
