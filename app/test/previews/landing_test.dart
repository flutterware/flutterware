import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutterware/plugins.dart';
import 'package:flutterware_app/src/address/address_scope.dart';
import 'package:flutterware_app/src/previews/catalog_entry.dart';
import 'package:flutterware_app/src/previews/catalog_session.dart';
import 'package:flutterware_app/src/previews/catalog_view.dart';
import 'package:flutterware_app/src/previews/protocol.dart';
import 'package:flutterware_app/src/previews/staged_device.dart';
import 'package:flutterware_app/src/ui/aside.dart';

/// What the panel looks like before a demo has been picked.
///
/// Opening Previews used to pick one: whichever entry sorted first by id, which
/// it compiled, revealed the folder around and wrote into the address. Two
/// things were wrong with it. The pick was arbitrary — entries sort by id and
/// the tree sorts folders first and then by label, so the demo that opened was
/// routinely not even the row at the top — and it made a link to the panel into
/// a link to a demo.
///
/// It is not the compile that was wrong. The guest still warms on the first
/// entry, because the cost is all in the boot: measured on this repo, a cold
/// start is ~12.5s and a switch on the warm guest is ~49ms. What was wrong is
/// calling that warm-up a selection.
void main() {
  const alpha = CatalogEntry(
    path: 'demo/a.dart',
    symbol: 'alpha',
    annotation: "Demo(name: 'Alpha')",
    name: 'Alpha',
  );
  const beta = CatalogEntry(
    path: 'demo/b.dart',
    symbol: 'beta',
    annotation: "Demo(name: 'Beta')",
    name: 'Beta',
  );

  CatalogSession session({List<CatalogEntry> scanned = const []}) =>
      CatalogSession(
        appPackageRoot: '/app',
        flutterSdkRoot: '/sdk',
        projectRoot: '/project',
        scannedEntries: scanned,
      );

  late AsideVisibility aside;
  setUp(() {
    var railVisible = true;
    aside = AsideVisibility(
      railVisible: () => railVisible,
      setRailVisible: (value) => railVisible = value,
    );
  });

  Future<void> pump(WidgetTester tester, CatalogSession s) => tester.pumpWidget(
    MaterialApp(
      home: AddressRoot(
        address: ValueNotifier(
          Address(worktree: 'test', plugin: 'flutterware.previews'),
        ),
        onChanged: (_) {},
        child: AsideScope(
          aside: aside,
          child: Scaffold(body: CatalogView(session: s)),
        ),
      ),
    ),
  );

  group('the listing does not wait for the daemon', () {
    test('it answers from the scan until one has reported', () {
      // The panel is only built once the plugin's scan has found entries — that
      // is the gate on starting a session at all — so this list is known before
      // the first frame while the daemon is a handshake away. Measured on this
      // repo's example package that gap is 8 seconds, and the list spent all of
      // it saying there were none.
      var s = session(scanned: const [alpha, beta]);
      expect(s.allEntries, [alpha, beta]);

      s.dispose();
    });

    test('and from the daemon the moment it does, marks and all', () {
      var s = session(scanned: const [alpha, beta])
        ..entries = const [alpha]
        ..quarantined = const [
          QuarantinedEntry(entry: beta, error: 'expected an identifier'),
        ];

      // The same two rows, not four: the seed is replaced rather than merged.
      expect(s.allEntries, [alpha, beta]);
      expect(s.compileErrorFor(beta), 'expected an identifier');

      s.dispose();
    });

    test('including when every entry it found turns out to be broken', () {
      // `entries` is then empty, so a flag keyed on it having content would
      // leave the seed in place and the quarantine marks off the rows.
      var s = session(scanned: const [alpha])
        ..quarantined = const [QuarantinedEntry(entry: alpha, error: 'boom')];

      expect(s.compileErrorFor(alpha), 'boom');

      s.dispose();
    });
  });

  group('an address naming no entry', () {
    test('leaves the selection alone rather than clearing it', () {
      // This is what returns you to the demo you were on after a trip through
      // another plugin: the panel unmounts, the session does not, and the
      // address it is remounted at names no entry.
      var s = session()
        ..entries = const [alpha, beta]
        ..phase = CatalogSessionPhase.ready
        ..selected = beta;

      s.wantedEntryId = null;

      expect(s.selected, beta);
      expect(s.missingEntryId, isNull);

      s.dispose();
    });
  });

  testWidgets('with nothing selected the stage says what to do', (
    tester,
  ) async {
    var s = session(scanned: const [alpha, beta]);
    addTearDown(s.dispose);
    await pump(tester, s);

    expect(find.text('Pick a demo'), findsOneWidget);
    // And the list is already there to pick from, which is the other half of
    // the landing: an empty stage beside an empty list would just be a panel
    // that had not loaded.
    expect(find.text('Alpha'), findsOneWidget);
    expect(find.text('Beta'), findsOneWidget);
  });

  group('a warm guest is not a selection', () {
    // The guest goes on holding the last entry it loaded after you leave it:
    // letting go would make the next click a cold start again. Anything that
    // treats that as "what is on screen" turns the catalog into a demo.
    CatalogSession warm() => session()
      ..entries = const [alpha, beta]
      ..phase = CatalogSessionPhase.ready
      ..active = beta;

    test('so a check for edits on a catalog page selects nothing', () {
      // Fired from the panel's own mount and from the window regaining focus —
      // so leaving the plugin and coming back, or merely alt-tabbing, landed
      // you on the demo you had just left.
      var s = warm();

      unawaited(s.reloadIfChanged());

      expect(s.selected, isNull);
      s.dispose();
    });

    test('and neither does a reload', () {
      var s = warm();

      unawaited(s.reload());

      expect(
        s.selected,
        isNull,
        reason: 'there is nothing on the stage for a reload to rebuild',
      );
      s.dispose();
    });

    test('while a demo on the stage still reloads', () {
      var s = warm()..selected = beta;

      unawaited(s.reloadIfChanged());

      expect(s.selected, beta);
      s.dispose();
    });
  });

  group('a click that beats the guest', () {
    test('still counts as the ask, so the row lights', () {
      // The list is live seconds before the guest now, off the scan. A row you
      // can read but not click — with nothing saying why — is worse than no
      // row, so a click during the boot is recorded as a request.
      var s = session(scanned: const [alpha, beta]);
      expect(s.phase, CatalogSessionPhase.starting);

      s.wantedEntryId = beta.id;

      expect(s.selected, beta);

      s.dispose();
    });

    testWidgets('and the stage stops inviting one and says what it is doing', (
      tester,
    ) async {
      var s = session(scanned: const [alpha, beta]);
      addTearDown(s.dispose);
      await pump(tester, s);
      expect(find.text('Pick a demo'), findsOneWidget);

      s.wantedEntryId = beta.id;
      await tester.pump();

      expect(find.text('Pick a demo'), findsNothing);
      expect(find.textContaining('Compiling Beta'), findsOneWidget);
    });
  });

  testWidgets('and nothing is offered to inspect until there is a demo', (
    tester,
  ) async {
    // The dock reads the *live guest*, so on the catalog it went on showing the
    // tree, the knobs and the console of whichever demo was visited last — an
    // inspector attached to something that is not on the screen.
    var s = session(scanned: const [alpha, beta]);
    addTearDown(s.dispose);
    await pump(tester, s);

    expect(find.text('Elements'), findsNothing);
    expect(find.text('Semantics'), findsNothing);

    s.wantedEntryId = beta.id;
    await tester.pump();

    expect(find.text('Elements'), findsOneWidget);
  });

  testWidgets('and the bar over the stage comes and goes with it', (
    tester,
  ) async {
    // Same rule, other end of the pane: a device picker, the axes the entry on
    // screen declared, a zoom for the stage and a button that photographs the
    // live frame are all about a demo, and on the catalog they were all the
    // last one's.
    var s = session(scanned: const [alpha, beta]);
    addTearDown(s.dispose);
    await pump(tester, s);

    expect(find.byType(StagedDevice), findsNothing);

    s.wantedEntryId = beta.id;
    await tester.pump();

    expect(find.byType(StagedDevice), findsOneWidget);
  });

  testWidgets('and no folder is opened for a selection nobody made', (
    tester,
  ) async {
    // The tree is given "arrive folded" on purpose. Revealing the ancestors of
    // an entry the panel picked for itself undid that on every cold open, for
    // one arbitrary branch.
    var s = session(scanned: const [alpha, beta]);
    addTearDown(s.dispose);
    await pump(tester, s);
    await tester.pump();

    expect(s.browsing.needsReveal(null), isFalse);
  });
}
