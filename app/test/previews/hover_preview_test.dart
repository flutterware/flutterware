import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/gestures.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutterware/plugins.dart';
import 'package:flutterware_app/src/address/address_scope.dart';
import 'package:flutterware_app/src/previews/catalog_entry.dart';
import 'package:flutterware_app/src/previews/catalog_session.dart';
import 'package:flutterware_app/src/previews/catalog_view.dart';
import 'package:flutterware_app/src/previews/preview_popover.dart';
import 'package:flutterware_app/src/previews/protocol.dart';
import 'package:flutterware_app/src/previews/test_runner.dart';
import 'package:flutterware_app/src/previews/thumbnails.dart';
import 'package:path/path.dart' as p;

const alpha = CatalogEntry(
  path: 'demo/a.dart',
  symbol: 'alpha',
  annotation: "Preview(name: 'Alpha')",
  name: 'Alpha',
);
const beta = CatalogEntry(
  path: 'demo/b.dart',
  symbol: 'beta',
  annotation: "Preview(name: 'Beta')",
  name: 'Beta',
);
const gamma = CatalogEntry(
  path: 'demo/c.dart',
  symbol: 'gamma',
  annotation: "Preview(name: 'Gamma')",
  name: 'Gamma',
);
const delta = CatalogEntry(
  path: 'demo/d.dart',
  symbol: 'delta',
  annotation: "Preview(name: 'Delta')",
  name: 'Delta',
);

void main() {
  group('the pointer resting on a row', () {
    late CatalogBrowsing browsing;

    setUp(() => browsing = CatalogBrowsing());
    tearDown(() => browsing.dispose());

    Future<void> settle() => Future<void>.delayed(
      CatalogBrowsing.hoverDelay + const Duration(milliseconds: 40),
    );

    test('is what it is resting on, once it has stopped', () async {
      browsing.hover(beta, at: const Rect.fromLTWH(0, 40, 260, 26));
      expect(browsing.hovering, isNull, reason: 'not yet — it has to rest');
      await settle();
      expect(browsing.hovering, beta);
      expect(browsing.hoveringAt, const Rect.fromLTWH(0, 40, 260, 26));
    });

    test('sweeping past rows lands on none of them', () async {
      // The whole reason there is a delay: a pointer crossing a list produces
      // an enter per row, and a picture asked for per row is forty renders for
      // a gesture that wanted nothing.
      browsing
        ..hover(beta)
        ..hover(gamma)
        ..hover(alpha)
        ..hover(null);
      await settle();
      expect(browsing.hovering, isNull);
    });

    test('leaving puts it back to nothing', () async {
      browsing.hover(beta);
      await settle();
      browsing.hover(null);
      await settle();
      expect(browsing.hovering, isNull);
    });

    test('a click ends it at once, with no delay to wait out', () async {
      browsing.hover(beta);
      await settle();
      expect(browsing.hovering, beta);

      browsing.endHover();
      expect(browsing.hovering, isNull, reason: 'this frame, not in 90ms');
    });

    test('the switch off ends what is showing', () async {
      browsing.hover(beta);
      await settle();
      expect(browsing.hovering, beta);

      browsing.previewOnHover = false;
      await settle();
      expect(browsing.hovering, isNull);

      browsing.hover(gamma);
      await settle();
      expect(browsing.hovering, isNull, reason: 'and starts nothing new');
    });
  });

  group('the store', () {
    late Directory package;

    setUp(() {
      package = Directory.systemTemp.createTempSync('fw_thumb_test');
      for (var entry in [alpha, beta]) {
        File(p.join(package.path, entry.path))
          ..parent.createSync(recursive: true)
          ..writeAsStringSync('// $entry');
      }
    });
    tearDown(() => package.deleteSync(recursive: true));

    /// A store whose renders are counted and answered with a 2×2 frame.
    (PreviewThumbnails, List<({String id, bool sync})>) storeOf() {
      var asked = <({String id, bool sync})>[];
      var store = PreviewThumbnails(
        packageRoot: package.path,
        render: (entryId, outDir, {required sync}) async {
          asked.add((id: entryId, sync: sync));
          var file = File(p.join(outDir, 'frame.raw'))
            ..parent.createSync(recursive: true)
            ..writeAsBytesSync(Uint8List(2 * 2 * 4));
          return PreviewCaptureRow(
            id: entryId,
            image: file.path,
            width: 2,
            height: 2,
          );
        },
      );
      addTearDown(store.dispose);
      return (store, asked);
    }

    Future<void> until(bool Function() done) async {
      for (var i = 0; i < 200; i++) {
        if (done()) return;
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      fail('never arrived');
    }

    test('renders once and keeps the picture', () async {
      var (store, asked) = storeOf();
      store.want(alpha);
      expect(store.of(alpha), isA<ThumbnailPending>());
      await until(() => store.of(alpha) is ThumbnailReady);

      store.want(alpha);
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(asked.length, 1, reason: 'the second ask is the cache');
    });

    test('the first render syncs and the rest do not', () async {
      var (store, asked) = storeOf();
      store.want(alpha);
      await until(() => store.of(alpha) is ThumbnailReady);
      store.want(beta);
      await until(() => store.of(beta) is ThumbnailReady);

      // The cold one is paying for a compile anyway, so a disk sweep on top is
      // free; a warm one would be two seconds behind a pointer.
      expect(asked.map((a) => a.sync), [true, false]);
    });

    /// Moves [entry]'s file on, the way an editor saving it would.
    void touch(CatalogEntry entry) => File(p.join(package.path, entry.path))
        .setLastModifiedSync(DateTime.now().add(const Duration(seconds: 5)));

    test('a picture is stale once its own file moves', () async {
      var (store, asked) = storeOf();
      store.want(alpha);
      await until(() => store.of(alpha) is ThumbnailReady);

      touch(alpha);
      expect(store.of(alpha), isNull, reason: 'and asking again re-renders');

      store.want(alpha);
      await until(() => store.of(alpha) is ThumbnailReady);
      expect(asked.length, 2);
      // The whole point of re-rendering. Without this the harness answers out
      // of the code it compiled at bring-up, hands back the picture that was
      // already there, and the store files it under the *new* stamp — an entry
      // that is now permanently wrong and has no way left to say so.
      expect(asked.last.sync, isTrue);
    });

    test('an edit is synced once, not once per hover', () async {
      var (store, asked) = storeOf();
      store.want(alpha);
      await until(() => store.of(alpha) is ThumbnailReady);

      touch(alpha);
      store.want(alpha);
      await until(() => store.of(alpha) is ThumbnailReady);
      store.want(beta);
      await until(() => store.of(beta) is ThumbnailReady);

      expect(asked.map((a) => a.sync), [true, true, false]);
    });

    test('a neighbour moving is the harness being behind, too', () async {
      var (store, asked) = storeOf();
      store.want(alpha);
      await until(() => store.of(alpha) is ThumbnailReady);
      store.want(beta);
      await until(() => store.of(beta) is ThumbnailReady);

      // Beta's own file never moves. It is alpha's that does — and the picture
      // of beta may well be drawn by something alpha edited.
      touch(alpha);
      store.want(beta);
      await until(() => asked.length == 3);
      expect(asked.last, (id: beta.id, sync: true));
      expect(
        store.of(alpha),
        isNull,
        reason: 'and the sync moved the harness past alpha as well',
      );
    });

    test('a rescan makes the next render sync', () async {
      var (store, asked) = storeOf();
      store.want(alpha);
      await until(() => store.of(alpha) is ThumbnailReady);

      // What the plugin calls when the catalog scan changed under it — an edit
      // to a file no entry is declared in, which no stamp here can see.
      store.invalidate();
      store.want(alpha);
      await until(() => store.of(alpha) is ThumbnailReady);
      expect(asked.map((a) => a.sync), [true, true]);
    });

    test('a harness that throws is the answer, not a crash', () async {
      var store = PreviewThumbnails(
        packageRoot: package.path,
        render: (entryId, outDir, {required sync}) async =>
            throw StateError('the tester would not start'),
      );
      addTearDown(store.dispose);

      store.want(alpha);
      await until(() => store.of(alpha) is ThumbnailFailed);
      expect(
        (store.of(alpha)! as ThumbnailFailed).reason,
        contains('would not start'),
      );
    });

    test(
      'an entry that would not compile shows what the compiler said',
      () async {
        var store = PreviewThumbnails(
          packageRoot: package.path,
          render: (entryId, outDir, {required sync}) async =>
              PreviewCaptureRow(id: entryId, compileError: 'boom at line 3'),
        );
        addTearDown(store.dispose);

        store.want(alpha);
        await until(() => store.of(alpha) is ThumbnailFailed);
        expect((store.of(alpha)! as ThumbnailFailed).reason, 'boom at line 3');
      },
    );
  });

  testWidgets('the row opens the popover, pointing at itself', (tester) async {
    var session =
        CatalogSession(
            appPackageRoot: '/app',
            flutterSdkRoot: '/sdk',
            projectRoot: '/project',
          )
          ..phase = CatalogSessionPhase.ready
          ..entries = [alpha, gamma]
          // The selection is the broken one, which draws the compiler's page
          // where the guest's texture would be — the only way a panel with no
          // engine behind it mounts at all.
          ..quarantined = [QuarantinedEntry(entry: beta, error: 'boom')]
          ..selected = beta
          ..active = alpha;
    var store = PreviewThumbnails(
      packageRoot: '/project',
      render: (entryId, outDir, {required sync}) async => null,
    );
    var address = ValueNotifier<Address>(
      Address(worktree: 'test', plugin: 'flutterware.previews'),
    );
    addTearDown(address.dispose);

    await tester.pumpWidget(
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
    expect(find.byType(PreviewPopover), findsNothing);

    var row = find.text('Gamma');
    var pointer = TestPointer(1, PointerDeviceKind.mouse);
    await tester.sendEventToBinding(pointer.hover(tester.getCenter(row)));
    await tester.pump(CatalogBrowsing.hoverDelay);
    await tester.pumpAndSettle();

    expect(find.byType(PreviewPopover), findsOneWidget);
    var popover = tester.widget<PreviewPopover>(find.byType(PreviewPopover));
    expect(popover.entry, gamma);
    // The row it belongs to, in the coordinates the overlay draws in — this is
    // what the arrow is aimed with.
    expect(popover.anchor.center.dy, tester.getCenter(row).dy);
    // And the file, which is what the tooltip used to say and no longer does.
    expect(find.text('${gamma.path} · ${gamma.symbol}'), findsOneWidget);

    await tester.pump(const Duration(seconds: 1));
    await tester.pumpWidget(const SizedBox.shrink());
    session.dispose();
    store.dispose();
  });

  testWidgets('the selected row shows nothing, and closes what did', (
    tester,
  ) async {
    var (session, store) = _panel();
    await _pump(tester, session, store);

    var pointer = TestPointer(1, PointerDeviceKind.mouse);
    // `Beta` is the selection. Its picture is the canvas already, a few
    // hundred pixels away and full size.
    //
    // Named in the tree, not by `find.text`: the selection's name is also
    // above the stage now, on the title that says what is showing and carries
    // the way back off it.
    await tester.sendEventToBinding(
      pointer.hover(
        tester.getCenter(
          find.descendant(
            of: find.byType(ListView),
            matching: find.text('Beta'),
          ),
        ),
      ),
    );
    await tester.pump(CatalogBrowsing.hoverDelay);
    await tester.pumpAndSettle();
    expect(find.byType(PreviewPopover), findsNothing);

    await tester.sendEventToBinding(
      pointer.hover(tester.getCenter(find.text('Gamma'))),
    );
    await tester.pump(CatalogBrowsing.hoverDelay);
    await tester.pumpAndSettle();
    expect(find.byType(PreviewPopover), findsOneWidget);

    // Arriving on the selection from a row that had one has to close it, not
    // strand it: the pointer left, and only this row knows that.
    await tester.sendEventToBinding(
      pointer.hover(
        tester.getCenter(
          find.descendant(
            of: find.byType(ListView),
            matching: find.text('Beta'),
          ),
        ),
      ),
    );
    await tester.pump(CatalogBrowsing.hoverDelay);
    await tester.pumpAndSettle();
    expect(find.byType(PreviewPopover), findsNothing);

    await _unmount(tester, session, store);
  });

  testWidgets('clicking a row takes its popover with it', (tester) async {
    var (session, store) = _panel();
    await _pump(tester, session, store);

    var pointer = TestPointer(1, PointerDeviceKind.mouse);
    await tester.sendEventToBinding(
      pointer.hover(tester.getCenter(find.text('Delta'))),
    );
    await tester.pump(CatalogBrowsing.hoverDelay);
    await tester.pumpAndSettle();
    expect(find.byType(PreviewPopover), findsOneWidget);

    await tester.tap(find.text('Delta'));
    // One pump: the card has to be gone in the frame the click lands in, not
    // at the end of the leave delay — nothing else moves the pointer, so a
    // card that waited would sit over the canvas it was answering.
    await tester.pump();
    expect(find.byType(PreviewPopover), findsNothing);
    expect(session.selected, delta);

    await _unmount(tester, session, store);
  });
}

/// A panel that mounts without an engine: the *selection* is the broken entry,
/// which draws the compiler's page where the guest's texture would be.
(CatalogSession, PreviewThumbnails) _panel() {
  var session =
      CatalogSession(
          appPackageRoot: '/app',
          flutterSdkRoot: '/sdk',
          projectRoot: '/project',
        )
        ..phase = CatalogSessionPhase.ready
        ..entries = [alpha, gamma]
        // Two broken ones, because the panel only mounts while the selection
        // is broken — so the row a test clicks has to be broken as well, or
        // the click lands on a canvas with no engine behind it.
        ..quarantined = [
          QuarantinedEntry(entry: beta, error: 'boom'),
          QuarantinedEntry(entry: delta, error: 'boom'),
        ]
        ..selected = beta
        ..active = alpha;
  return (
    session,
    PreviewThumbnails(
      packageRoot: '/project',
      render: (entryId, outDir, {required sync}) async => null,
    ),
  );
}

Future<void> _pump(
  WidgetTester tester,
  CatalogSession session,
  PreviewThumbnails store,
) {
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

/// The row's tooltip arms a timer when the pointer lands and the binding fails
/// a test that leaves one pending, so it is run out before the tree goes.
Future<void> _unmount(
  WidgetTester tester,
  CatalogSession session,
  PreviewThumbnails store,
) async {
  await tester.pump(const Duration(seconds: 1));
  await tester.pumpWidget(const SizedBox.shrink());
  session.dispose();
  store.dispose();
}
