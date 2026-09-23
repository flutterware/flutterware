import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutterware_app/src/address/address_scope.dart';
import 'package:flutterware/plugins.dart';
import 'package:flutterware_app/src/previews/catalog_entry.dart';
import 'package:flutterware_app/src/previews/catalog_session.dart';
import 'package:flutterware_app/src/previews/catalog_view.dart';
import 'package:flutterware_app/src/previews/preview_sheet.dart';
import 'package:flutterware_app/src/previews/protocol.dart';
import 'package:flutterware_app/src/previews/thumbnails.dart';

/// What the stage draws in the gap between a click and the guest's next frame.
///
/// The guest paints one texture and switches which demo is inside it, so for
/// the ~35–70ms a warm switch takes, that texture still holds the demo that was
/// there before. Off the catalog that is a demo nobody asked for, arriving and
/// being replaced — a flash of the wrong thing on every click.
void main() {
  const alpha = CatalogEntry(
    path: 'demo/team.dart',
    symbol: 'alpha',
    annotation: "Preview(name: 'Alpha')",
    name: 'Alpha',
    group: 'Team',
  );
  const beta = CatalogEntry(
    path: 'demo/team.dart',
    symbol: 'beta',
    annotation: "Preview(name: 'Beta')",
    name: 'Beta',
    group: 'Team',
  );

  late CatalogSession session;
  late PreviewThumbnails store;

  setUp(() {
    session =
        CatalogSession(
            appPackageRoot: '/app',
            flutterSdkRoot: '/sdk',
            projectRoot: '/project',
          )
          ..phase = CatalogSessionPhase.ready
          ..entries = [alpha, beta];
    store = PreviewThumbnails(
      packageRoot: '/project',
      render: (entryId, outDir, {required sync}) async => null,
    );
  });

  Future<void> pump(WidgetTester tester) {
    var address = ValueNotifier<Address>(
      Address(worktree: 'test', plugin: 'flutterware.previews'),
    );
    addTearDown(address.dispose);
    return tester.pumpWidget(
      MaterialApp(
        home: AddressRoot(
          address: address,
          onChanged: (next) => address.value = next,
          child: Scaffold(
            body: CatalogView(session: session, thumbnails: store),
          ),
        ),
      ),
    );
  }

  Future<void> unmount(WidgetTester tester) async {
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpWidget(const SizedBox.shrink());
    session.dispose();
    store.dispose();
  }

  testWidgets('the catalog holds while the guest is still on the old demo', (
    tester,
  ) async {
    // Picked from the catalog, so the stage was showing tiles and the guest is
    // holding whatever it warmed on. There is no engine on this session at all,
    // which is the sharp end of the assertion: reaching the texture branch here
    // would throw on `engine!` rather than quietly draw the wrong demo.
    session
      ..selected = beta
      ..active = alpha;
    await pump(tester);

    expect(find.byType(PreviewSheet), findsOneWidget);

    await unmount(tester);
  });

  testWidgets('and the tile that was clicked is marked while it waits', (
    tester,
  ) async {
    // Or the click is silent for as long as the wait lasts, which on a switch
    // that has to compile is seconds rather than frames.
    session
      ..selected = beta
      ..active = alpha;
    await pump(tester);

    var sheet = tester.widget<PreviewSheet>(find.byType(PreviewSheet));
    expect(sheet.selectedId, beta.id);

    await unmount(tester);
  });

  testWidgets('a compile error is not something to wait for', (tester) async {
    // An entry that will not build has no frame coming. Holding the catalog up
    // in front of the compiler's complaint would hide the one thing worth
    // reading.
    session
      ..quarantined = [QuarantinedEntry(entry: beta, error: 'boom at line 3')]
      ..selected = beta
      ..active = alpha;
    await pump(tester);

    expect(find.byType(PreviewSheet), findsNothing);
    expect(find.textContaining('boom at line 3'), findsOneWidget);

    await unmount(tester);
  });
}
