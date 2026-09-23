import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutterware/channels.dart';
import 'package:flutterware/devbar.dart';

class _SessionPlugin implements DevbarPlugin, DevbarPanelSource {
  @override
  String get panelId => 'db:main';

  @override
  String get panelLabel => 'Database';

  @override
  void describePanel(Panel panel) =>
      panel.action(const PluginAction('query', 'Run a query'), (_) => {});

  @override
  void dispose() {}
}

/// A devbar is not always the app's outermost widget. One scoped to
/// something that opens and closes — a session, an environment — is mounted
/// long after `runApp`, and everything [Devbar] does on the way up was written
/// for the other case.
void main() {
  setUp(() {
    GuestChannels.install();
    for (var panel in GuestChannels.panels.descriptors) {
      GuestChannels.panels.remove(panel.id);
    }
  });

  Widget host(Widget child) =>
      Directionality(textDirection: TextDirection.ltr, child: child);

  testWidgets('while its plugins load it paints nothing at all', (
    tester,
  ) async {
    await tester.pumpWidget(host(const Text('signed out')));

    var loading = Completer<DevbarPlugin>();
    await tester.pumpWidget(
      host(
        Devbar(
          plugins: [(_) => loading.future],
          headless: true,
          child: const Text('signed in'),
        ),
      ),
    );

    // The frame the devbar first builds in. Its child cannot be built yet — a
    // descendant may reach for a plugin on the way up — so *something* stands
    // in, and for a devbar mounted this late that something is painted:
    // `deferFirstFrame` does nothing once a frame has gone to the engine.
    // It used to be a full-bleed red `Container`, which is what an app
    // scoping a devbar to a session saw at every login.
    expect(find.text('signed in'), findsNothing);
    expect(
      find.descendant(
        of: find.byType(Devbar),
        matching: find.byType(ColoredBox),
      ),
      findsNothing,
    );

    loading.complete(_SessionPlugin());
    await tester.pumpAndSettle();
    expect(find.text('signed in'), findsOneWidget);
  });

  testWidgets('its panels arrive when it mounts and go when it unmounts', (
    tester,
  ) async {
    await tester.pumpWidget(host(const Text('signed out')));
    expect(GuestChannels.panels.descriptors, isEmpty);

    await tester.pumpWidget(
      host(
        Devbar(
          plugins: [(_) => _SessionPlugin()],
          headless: true,
          child: const Text('signed in'),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(GuestChannels.panels.descriptors.map((p) => p.id), ['db:main']);

    await tester.pumpWidget(host(const Text('signed out')));
    await tester.pumpAndSettle();
    expect(GuestChannels.panels.descriptors, isEmpty);
  });
}
