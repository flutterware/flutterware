import 'dart:convert';
import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutterware/plugins.dart' show Address;
// ignore: implementation_imports
import 'package:flutterware/src/log_client.dart';
import 'package:flutterware_app/src/address/address_scope.dart';
import 'package:flutterware_app/src/context.dart';
import 'package:flutterware_app/src/dependencies/detail.dart';
import 'package:flutterware_app/src/dependencies/model/pub_dev_api.dart';
import 'package:flutterware_app/src/dependencies/model/service.dart';
import 'package:flutterware_app/src/package_ref.dart';
import 'package:flutterware_app/src/ui/theme.dart';
import 'package:flutterware_app/src/utils/flutter_sdk.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// The detail page against the real workspace, with both network sources faked.
///
/// Same fake-time discipline as `list_screen_test.dart`: `pub deps` is answered
/// from the fixture, and the load is driven **before** `pumpWidget` so no future
/// is started under fake time and then awaited from real time.
void main() {
  var fixture = File('test/dependencies/fixtures/pub_deps.json')
      .readAsStringSync();

  late Directory cache;

  setUp(() async {
    cache = await Directory.systemTemp.createTemp('fw_detail');
  });

  tearDown(() => cache.deleteSync(recursive: true));

  String scoreJson() => jsonEncode({
    'grantedPoints': 150,
    'maxPoints': 160,
    'likeCount': 1234,
    'downloadCount30Days': 5000000,
    'tags': [
      'publisher:dart.dev',
      'sdk:dart',
      'platform:android',
      'platform:ios',
      'is:wasm-ready',
      'license:bsd-3-clause',
    ],
  });

  String packageJson(String name) => jsonEncode({
    'name': name,
    'latest': {
      'version': '99.0.0',
      'published': '2026-01-05T00:00:00.000Z',
      'pubspec': {
        'name': name,
        'repository': 'https://github.com/dart-lang/$name',
        'topics': ['networking'],
      },
    },
    'versions': [
      {'version': '99.0.0', 'published': '2026-01-05T00:00:00.000Z'},
    ],
  });

  Future<void> pumpDetail(
    WidgetTester tester,
    String packageName, {
    http.Client? client,
  }) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    var service = DependenciesService(
      PackageRef(
        AppContext(logger: LogClient.print()),
        '../fixtures/probe_app',
        FlutterSdkPath('/tmp/flutter'),
      ),
      runProcess: (executable, arguments, {workingDirectory}) async =>
          ProcessResult(0, 0, fixture, ''),
      pubDevApi: PubDevApi(
        cacheDirectory: cache,
        client:
            client ??
            MockClient((request) async {
              if (request.url.path.endsWith('/score')) {
                return http.Response(scoreJson(), 200);
              }
              return http.Response(packageJson(packageName), 200);
            }),
      ),
    );
    addTearDown(service.dispose);

    var address = ValueNotifier(
      Address(worktree: 'wt', plugin: 'flutterware.dependencies'),
    );
    addTearDown(address.dispose);

    await tester.runAsync(() => service.dependencies.refresh());
    await tester.runAsync(() => service.pubDevFor(packageName).refresh());
    // Otherwise every Usage section renders "Scanning…" and asserts nothing.
    await tester.runAsync(() => service.packageImports.refresh());

    await tester.pumpWidget(
      MaterialApp(
        theme: appTheme,
        home: Scaffold(
          body: AddressRoot(
            address: address,
            onChanged: (next) => address.value = next,
            child: DependencyDetailScreen(service, packageName),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  testWidgets('shows the package, its version and its kind', (tester) async {
    await pumpDetail(tester, 'path_provider');

    expect(tester.takeException(), isNull);
    expect(find.text('path_provider'), findsWidgets);
    expect(find.text('Direct'), findsOneWidget);
    expect(find.text('Versions'), findsOneWidget);
    expect(find.text('Why is this here?'), findsOneWidget);
    expect(find.text('Usage'), findsOneWidget);
  });

  testWidgets('pub.dev numbers reach the stat tiles', (tester) async {
    await pumpDetail(tester, 'path_provider');

    expect(find.text('Downloads / 30d'), findsOneWidget);
    expect(find.text('5M'), findsOneWidget);
    expect(find.text('Pub points'), findsOneWidget);
    expect(find.text('150 / 160'), findsOneWidget);
    expect(find.text('dart.dev'), findsOneWidget);
  });

  testWidgets('a newer version on pub.dev is flagged', (tester) async {
    await pumpDetail(tester, 'path_provider');

    expect(find.text('Latest on pub.dev'), findsOneWidget);
    expect(find.text('99.0.0'), findsOneWidget);
    expect(find.text('Update available'), findsOneWidget);
  });

  testWidgets('compatibility is built from the pub.dev tags', (tester) async {
    await pumpDetail(tester, 'path_provider');

    // Scrolled to first, unlike the sections above it. The page is a `ListView`,
    // so a child below the fold has no element at all — and `find` searches the
    // element tree, not the widget list it was built from. This is the sixth
    // section down, which is why it is the only one that needed this.
    await tester.scrollUntilVisible(find.text('Compatibility'), 200);

    expect(find.text('Compatibility'), findsOneWidget);
    expect(find.text('bsd-3-clause'), findsOneWidget);
    expect(find.text('android'), findsOneWidget);
    expect(find.text('Ready'), findsOneWidget, reason: 'wasm');
  });

  testWidgets('a dev dependency says so', (tester) async {
    await pumpDetail(tester, 'flutter_test');
    expect(find.text('Dev dependency'), findsOneWidget);
  });

  testWidgets('an SDK package shows its origin, not version 0.0.0', (
    tester,
  ) async {
    await pumpDetail(tester, 'flutter_test');

    // Resolving as `0.0.0` is an artefact of shipping with the SDK, and
    // printing it would read as a real version.
    expect(find.text('0.0.0'), findsNothing);
    expect(find.textContaining('Flutter SDK'), findsWidgets);
  });

  testWidgets('a workspace sibling reports where it really is', (tester) async {
    await pumpDetail(tester, 'flutterware');
    expect(find.text('A member of this workspace'), findsOneWidget);
  });

  testWidgets('the page survives a package that is not on pub.dev', (
    tester,
  ) async {
    await pumpDetail(
      tester,
      'flutterware',
      client: MockClient((_) async => http.Response('{}', 404)),
    );

    // Everything on the page that comes from disk is still true, so the page
    // renders; only the pub.dev sections are absent.
    expect(tester.takeException(), isNull);
    expect(find.text('Versions'), findsOneWidget);
    expect(find.text('Compatibility'), findsNothing);
    expect(find.text('Downloads / 30d'), findsNothing);
  });

  testWidgets('the page survives being offline', (tester) async {
    await pumpDetail(
      tester,
      'path_provider',
      client: MockClient((_) async => throw const SocketException('offline')),
    );

    expect(tester.takeException(), isNull);
    expect(find.text('path_provider'), findsWidgets);
    expect(find.text('Versions'), findsOneWidget);
  });

  testWidgets('a declared package nothing references says so, carefully', (
    tester,
  ) async {
    // `auto_size_text` is declared by fixtures/probe_app and never imported —
    // the real case, not a synthetic one.
    await pumpDetail(tester, 'auto_size_text');

    expect(find.textContaining('No Dart file imports it'), findsOneWidget);
    // The claim covers assets now, so the copy has to as well.
    expect(
      find.textContaining('no asset declaration names it'),
      findsOneWidget,
    );
    // The word "unused" appears only inside the disclaimer, never as a verdict.
    expect(
      find.textContaining('does not always mean it is unused'),
      findsOneWidget,
    );
  });

  testWidgets('a package outside this member is reported, not blank', (
    tester,
  ) async {
    // `file_picker` belongs to flutterware_app. Landing here from a stale
    // address used to render an ErrorWidget.
    await pumpDetail(tester, 'file_picker');

    expect(find.textContaining('is not in this package'), findsOneWidget);
    expect(find.text('All dependencies'), findsOneWidget);
  });

  /// Walks the page down until [text] is built — the sections live in a
  /// ListView, so the ones below the fold do not exist yet.
  Future<void> scrollTo(WidgetTester tester, String text) async {
    for (var i = 0; i < 12 && find.text(text).evaluate().isEmpty; i++) {
      await tester.drag(find.byType(ListView), const Offset(0, -300));
      await tester.pump();
    }
  }

  testWidgets('the document sections are all present', (tester) async {
    await pumpDetail(tester, 'path_provider');

    // Three of them, where there were two tabs — and a license section that did
    // not exist at all.
    await scrollTo(tester, 'Readme');
    expect(find.text('Readme'), findsOneWidget);
    await scrollTo(tester, 'Changelog');
    expect(find.text('Changelog'), findsOneWidget);
    await scrollTo(tester, 'License text');
    expect(find.text('License text'), findsOneWidget);
  });

  testWidgets('the licence text starts collapsed, the readme does not', (
    tester,
  ) async {
    await pumpDetail(tester, 'path_provider');

    await scrollTo(tester, 'Readme');
    expect(
      find.descendant(
        of: find.ancestor(of: find.text('Readme'), matching: find.byType(Card)),
        matching: find.text('Hide'),
      ),
      findsOneWidget,
      reason: 'the readme is the point of the page',
    );

    await scrollTo(tester, 'License text');
    expect(
      find.descendant(
        of: find.ancestor(
          of: find.text('License text'),
          matching: find.byType(Card),
        ),
        matching: find.text('Show'),
      ),
      findsOneWidget,
      reason: 'a licence is long and rarely what you came for',
    );
  });
}
