import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutterware/plugins.dart';
import 'package:flutterware_app/src/address/address_scope.dart';
import 'package:flutterware_app/src/previews/catalog_entry.dart';
import 'package:flutterware_app/src/previews/catalog_session.dart';
import 'package:flutterware_app/src/previews/catalog_view.dart';
import 'package:flutterware_app/src/previews/protocol.dart';

/// The canvas the panel opens on, when one package holds two form factors.
///
/// The declaration is per subtree, so moving between a phone screen and a
/// desktop dashboard has to move the canvas with it — a device held on the
/// session could not do that, and a package-wide one framed half the catalog
/// on the wrong screen. Reached through a quarantined selection because that
/// is what renders without a guest: the bar is the same bar either way.
void main() {
  const phone = CatalogEntry(
    path: 'demo/mobile/tile.dart',
    symbol: 'tile',
    annotation: "Preview(name: 'Tile')",
    name: 'Tile',
  );
  const desktop = CatalogEntry(
    path: 'demo/desktop/bar.dart',
    symbol: 'bar',
    annotation: "Preview(name: 'Bar')",
    name: 'Bar',
  );
  const loose = CatalogEntry(
    path: 'demo/shared/spacer.dart',
    symbol: 'spacer',
    annotation: "Preview(name: 'Spacer')",
    name: 'Spacer',
  );

  const canvases = [
    PreviewCanvas('demo/mobile', devices: [Devices.iphone16, Devices.iphoneSe]),
    PreviewCanvas('demo/desktop', devices: [Devices.wideWindow]),
  ];

  CatalogSession sessionOn(CatalogEntry selected) =>
      CatalogSession(
          appPackageRoot: '/app',
          flutterSdkRoot: '/sdk',
          projectRoot: '/project',
          canvases: canvases,
        )
        ..phase = CatalogSessionPhase.ready
        ..quarantined = [
          QuarantinedEntry(entry: selected, error: 'not compiled here'),
        ]
        ..selected = selected;

  Future<void> pump(
    WidgetTester tester,
    CatalogSession session, {
    String? device,
  }) {
    var address = ValueNotifier(
      Address(
        worktree: 'test',
        plugin: 'flutterware.previews',
        axes: {'device': ?device},
      ),
    );
    return tester.pumpWidget(
      MaterialApp(
        home: AddressRoot(
          address: address,
          onChanged: (next) => address.value = next,
          child: Scaffold(body: CatalogView(session: session)),
        ),
      ),
    );
  }

  testWidgets('the bar opens on the canvas the entry is under', (tester) async {
    await pump(tester, sessionOn(phone));
    expect(find.text('iPhone 16'), findsOneWidget);
  });

  testWidgets('a declared window is offered, not staged', (tester) async {
    // A phone's screen is the constraint the layout has to survive; a desktop
    // window has no true size, because the person using it drags the corner.
    // So a desktop subtree opens on the resizable rectangle — and staging a
    // 1600-wide window in a pane a third that wide would show it at 30%, which
    // is a thumbnail rather than a preview.
    await pump(tester, sessionOn(desktop));

    expect(find.text('Fit'), findsOneWidget);
    expect(find.text('Wide window'), findsNothing);

    // Offered, though: it is one tap away, in the declared group.
    await tester.tap(find.text('Fit'));
    await tester.pumpAndSettle();
    expect(find.text('DECLARED'), findsOneWidget);
    expect(find.text('Wide window'), findsAtLeastNWidgets(1));
  });

  testWidgets('an entry under no canvas opens on the plain rectangle', (
    tester,
  ) async {
    await pump(tester, sessionOn(loose));

    expect(find.text('Fit'), findsOneWidget);
  });

  testWidgets('a device on the address still wins over the declaration', (
    tester,
  ) async {
    // The declaration is where a picture starts, never where it is stuck: the
    // address is what a person picking a device writes, and what a captured
    // link carries.
    await pump(tester, sessionOn(phone), device: 'ipad');

    expect(find.text('iPad'), findsOneWidget);
    expect(find.text('iPhone 16'), findsNothing);
  });

  testWidgets('the picker offers the whole declared list, not just the head', (
    tester,
  ) async {
    // The other half of "the list is the offered set". A card with a breakpoint
    // in it is meant to survive both phones, and which one broke is the
    // question — so both are one tap away rather than somewhere in a table of
    // every phone there is.
    await pump(tester, sessionOn(phone));
    await tester.tap(find.text('iPhone 16'));
    await tester.pumpAndSettle();

    // Uppercased by the popover, like every group heading beside it.
    expect(find.text('DECLARED'), findsOneWidget);

    // Both of them, and above the table they also appear in — which is the
    // whole of the affordance: the project already said which two matter.
    var standingGroup = tester.getTopLeft(find.text('IOS')).dy;
    expect(
      tester.getTopLeft(find.text('DECLARED')).dy,
      lessThan(standingGroup),
    );
    for (var declared in ['iPhone 16', 'iPhone SE']) {
      expect(
        tester.getTopLeft(find.text(declared).first).dy,
        lessThan(standingGroup),
        reason: '$declared is not in the declared group',
      );
    }
  });

  testWidgets('a package that declares none offers no such group', (
    tester,
  ) async {
    var session =
        CatalogSession(
            appPackageRoot: '/app',
            flutterSdkRoot: '/sdk',
            projectRoot: '/project',
          )
          ..phase = CatalogSessionPhase.ready
          ..quarantined = [
            const QuarantinedEntry(entry: phone, error: 'not compiled here'),
          ]
          ..selected = phone;

    await pump(tester, session);
    await tester.tap(find.text('Fit'));
    await tester.pumpAndSettle();

    // The popover did open — the standing groups are there, and only the
    // declared one is absent.
    expect(find.text('IOS'), findsOneWidget);
    expect(find.text('DECLARED'), findsNothing);
  });
}
