import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutter/widget_previews.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutterware/plugins.dart';
import 'package:flutterware/previews.dart';
import 'package:flutterware/previews_guest.dart'
    show CatalogEntryBuilder, CatalogKnobs;
import 'package:flutterware_app/src/previews/catalog_entry.dart';
import 'package:flutterware_app/src/previews/catalog_session.dart';
import 'package:flutterware_app/src/previews/catalog_view.dart';
import 'package:flutterware_app/src/previews/inline_guest.dart';
import 'package:flutterware_app/src/address/address_scope.dart';
import 'package:flutterware_app/src/ui/aside.dart';

/// The previews panel over a guest drawn **inside** the test — no daemon, no
/// embedder process. The entry is a real widget with a real knob; the stage
/// draws it, the inspector walks it, a point finds a node in it, and a knob
/// set through the address rebuilds it. Every one of those reaches the guest
/// through the same two seams the embedder guest uses — `GuestSurface` for
/// the picture and `GuestChannel` for the extensions — which is what makes a
/// browser, where no process can be spawned, the same panel.
void main() {
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

  CatalogEntryBuilder? entryOf(String id) => switch (id) {
    'demo/a.dart#alpha' => (
      preview: const Preview(name: 'Alpha'),
      builder: () => const _Alpha(),
    ),
    'demo/b.dart#beta' => (
      preview: const Preview(name: 'Beta'),
      builder: () => const Center(child: Text('Beta here')),
    ),
    'demo/d.dart#delta' => (
      preview: const Preview(name: 'Delta'),
      builder: () => const _Delta(),
    ),
    'demo/c.dart#gamma' => (
      preview: Preview(
        name: 'Gamma',
        wrapper: (child) => MaterialApp(home: child),
      ),
      builder: () => const Scaffold(body: Center(child: Text('Gamma app'))),
    ),
    _ => null,
  };

  const delta = CatalogEntry(
    path: 'demo/d.dart',
    symbol: 'delta',
    annotation: "Preview(name: 'Delta')",
    name: 'Delta',
  );

  const gamma = CatalogEntry(
    path: 'demo/c.dart',
    symbol: 'gamma',
    annotation: "Preview(name: 'Gamma')",
    name: 'Gamma',
  );

  late ValueNotifier<Address> address;

  /// Opens [entry] the way a click on the list does. Pumped rather than
  /// awaited: the guest answers a show once a frame has been drawn, and the
  /// frames are this clock's.
  Future<void> open(
    WidgetTester tester,
    CatalogSession session,
    CatalogEntry entry,
  ) async {
    unawaited(session.switchTo(entry));
    for (var i = 0; i < 100 && session.active?.id != entry.id; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(session.active?.id, entry.id, reason: 'the switch should land');
    await tester.pumpAndSettle();
  }

  Future<CatalogSession> pumpInline(
    WidgetTester tester, {
    CatalogEntry first = alpha,
  }) async {
    // Through `start`, the way the panel opens one: the catalog and the
    // guest both come from the two seams, and nothing else is special.
    var inline = InlinePreviewsGuest((
      entries: [alpha, beta, gamma, delta],
      entryOf: entryOf,
    ));
    var session = CatalogSession(
      appPackageRoot: '/app',
      flutterSdkRoot: '/sdk',
      projectRoot: '/project',
      connectToDaemon: inline.connect,
      launchGuest: inline.launch,
    );
    addTearDown(session.dispose);
    // Not awaited: the start ticks its own timers and the inspect client
    // waits between reads, all of it on the clock the pumps below advance.
    unawaited(session.start());
    address = ValueNotifier(
      Address(worktree: 'test', plugin: 'flutterware.previews'),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: AddressRoot(
          address: address,
          onChanged: (next) => address.value = next,
          child: AsideScope(
            aside: AsideVisibility(
              railVisible: () => true,
              setRailVisible: (_) {},
            ),
            child: Scaffold(
              body: Column(
                children: [
                  // Something the studio paints *before* the stage — see the
                  // semantics test below.
                  const Text('Studio rail'),
                  Expanded(child: CatalogView(session: session)),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    for (
      var i = 0;
      i < 100 && session.phase != CatalogSessionPhase.ready;
      i++
    ) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(session.phase, CatalogSessionPhase.ready);
    await open(tester, session, first);
    return session;
  }

  testWidgets('the stage draws the entry', (tester) async {
    await pumpInline(tester);
    expect(find.text('Hello'), findsOneWidget);
  });

  testWidgets('switching shows another entry, in place', (tester) async {
    var session = await pumpInline(tester);
    await open(tester, session, beta);
    expect(find.text('Beta here'), findsOneWidget);
    expect(find.text('Hello'), findsNothing);
    expect(
      session.lastSwitch?.direct,
      isTrue,
      reason: 'an entry compiled in is shown, never compiled',
    );
  });

  testWidgets('the inspector walks the entry in this process', (tester) async {
    var session = await pumpInline(tester);
    await session.readTree();
    await tester.pump();
    var tree = session.treeForSelection;
    expect(tree, isNotNull);
    expect(
      tree!.nodes.map((n) => n.type),
      contains('_Alpha'),
      reason: 'the walk starts at the demo root, not at the studio',
    );
    expect(tree.nodes.map((n) => n.type), isNot(contains('CatalogView')));
  });

  testWidgets('a point finds a node', (tester) async {
    var session = await pumpInline(tester);
    await session.readTree();
    await tester.pump();
    var text = tester.getCenter(find.text('Hello'));
    var picture = tester.getTopLeft(find.byType(InlineGuestPicture));
    var id = await session.nodeUnder(
      text.dx - picture.dx,
      text.dy - picture.dy,
    );
    expect(id, isNotNull);
    expect(session.treeForSelection!.nodeAt(id!)!.type, 'Text');
  });

  testWidgets("an entry with its own app does not swallow the studio's "
      'semantics', (tester) async {
    var semantics = tester.ensureSemantics();
    var session = await pumpInline(tester);
    await open(tester, session, gamma);
    expect(find.text('Gamma app'), findsOneWidget);
    // A MaterialApp's modal barrier blocks the semantics of everything
    // painted before it, up to the nearest boundary. The picture is one.
    expect(tester.getSemantics(find.text('Studio rail')).label, 'Studio rail');
    semantics.dispose();
  });

  testWidgets('picking a knob keeps every knob declared', (tester) async {
    var session = await pumpInline(tester);
    await open(tester, session, delta);
    expect(find.text('main/icon'), findsOneWidget);
    expect(session.knobs.knobs.map((k) => k.name), ['set', 'role']);
    address.value = address.value.copyWith(axes: {'knob.set': 'pro'});
    await tester.pump();
    await tester.pump();
    await tester.pumpAndSettle();
    print(
      'PROBE selections=${session.knobSelections} report=${session.knobs.knobs.map((k) => '${k.name}=${k.value}')} guest=${CatalogKnobs.instance.editable.knobs.keys.toList()} entry=${CatalogKnobs.instance.entryId}',
    );
    expect(find.text('pro/icon'), findsOneWidget);
    expect(session.knobs.knobs.map((k) => k.name), [
      'set',
      'role',
    ], reason: 'a pick rebuilds the demo, which declares both again');
  });

  testWidgets('a knob set through the address rebuilds the entry', (
    tester,
  ) async {
    await pumpInline(tester);
    address.value = address.value.copyWith(axes: {'knob.label': 'Bye'});
    await tester.pump();
    await tester.pump();
    await tester.pumpAndSettle();
    expect(find.text('Bye'), findsOneWidget);
    expect(find.text('Hello'), findsNothing);
  });
}

class _Alpha extends StatelessWidget {
  const _Alpha();

  @override
  Widget build(BuildContext context) {
    var label = context.knobs.string('label', 'Hello');
    return Center(child: Text(label));
  }
}

/// Two pickers built from map literals, read before a [LayoutBuilder] — the
/// shape of the example's app-icon preview.
class _Delta extends StatelessWidget {
  const _Delta();

  @override
  Widget build(BuildContext context) {
    var knobs = context.knobs;
    var set = knobs.picker('set', {
      for (var name in const ['main', 'pro']) name: name,
    }, 'main');
    var role = knobs.picker('role', const {
      'icon': 'icon',
      'foreground': 'foreground',
    }, 'icon');
    return LayoutBuilder(
      builder: (context, constraints) => Center(child: Text('$set/$role')),
    );
  }
}
