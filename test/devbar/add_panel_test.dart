import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutterware/channels.dart';
import 'package:flutterware/devbar.dart';

/// A panel scoped to something the app opens and closes — a session's
/// database is the case this was built for.
class _SessionPanel implements DevbarPanelSource {
  _SessionPanel(this.environment);

  final String environment;
  var described = 0;

  @override
  String get panelId => 'db:main';

  @override
  String get panelLabel => 'Database';

  @override
  void describePanel(Panel panel) {
    described++;
    panel.action(
      const PluginAction('query', 'Run a query'),
      (_) => {'environment': environment},
    );
  }
}

void main() {
  setUp(() {
    GuestChannels.install();
    for (var panel in GuestChannels.panels.descriptors) {
      GuestChannels.panels.remove(panel.id);
    }
  });

  List<String> panelIds() => [
    for (var panel in GuestChannels.panels.descriptors) panel.id,
  ];

  testWidgets('a panel arrives with the widget and leaves with it', (
    tester,
  ) async {
    var source = _SessionPanel('prod');

    await tester.pumpWidget(
      Devbar(
        plugins: const [],
        headless: true,
        child: AddDevbarPanel(source: source, child: const Text('signed in')),
      ),
    );
    await tester.pumpAndSettle();

    expect(panelIds(), ['db:main']);
    expect(source.described, 1);
    expect(await GuestChannels.panels['db:main']!.run('query'), {
      'environment': 'prod',
    });

    // Signing out: the subtree goes, and the panel goes with it.
    await tester.pumpWidget(
      Devbar(
        plugins: const [],
        headless: true,
        child: const Text('signed out'),
      ),
    );
    await tester.pumpAndSettle();

    expect(panelIds(), isEmpty);
    expect(GuestChannels.core.channels, isNot(contains('db:main')));
  });

  testWidgets('a rebuild handing back the same source re-declares nothing', (
    tester,
  ) async {
    var source = _SessionPanel('prod');
    Future<void> pump(String label) => tester.pumpWidget(
      Devbar(
        plugins: const [],
        headless: true,
        child: AddDevbarPanel(source: source, child: Text(label)),
      ),
    );

    await pump('one');
    await pump('two');
    await tester.pumpAndSettle();

    // Re-describing means tearing the channels down and announcing a changed
    // list — a per-frame cost for a panel nothing asked to change.
    expect(source.described, 1);
    expect(panelIds(), ['db:main']);
    expect(find.text('two'), findsOneWidget);
  });

  testWidgets('switching environment: a new source is a new panel', (
    tester,
  ) async {
    var staging = _SessionPanel('staging');
    Future<void> pump(_SessionPanel source) => tester.pumpWidget(
      Devbar(
        plugins: const [],
        headless: true,
        child: AddDevbarPanel(source: source, child: const SizedBox()),
      ),
    );

    await pump(staging);
    await tester.pumpAndSettle();
    var prod = _SessionPanel('prod');
    await pump(prod);
    await tester.pumpAndSettle();

    // One panel, under the id the source asked for — the old one was given
    // back before the new one claimed it, so nothing was pushed to `db:main#2`.
    expect(panelIds(), ['db:main']);
    expect(prod.described, 1);
    expect(await GuestChannels.panels['db:main']!.run('query'), {
      'environment': 'prod',
    });
  });

  testWidgets('the child is rendered where it would have been anyway', (
    tester,
  ) async {
    await tester.pumpWidget(
      Devbar(
        plugins: const [],
        headless: true,
        child: const Align(
          alignment: Alignment.topLeft,
          child: SizedBox(width: 120, height: 40, child: Text('signed in')),
        ),
      ),
    );
    await tester.pumpAndSettle();
    var bare = tester.getRect(find.text('signed in'));

    await tester.pumpWidget(
      Devbar(
        plugins: const [],
        headless: true,
        child: AddDevbarPanel(
          source: _SessionPanel('prod'),
          child: const Align(
            alignment: Alignment.topLeft,
            child: SizedBox(width: 120, height: 40, child: Text('signed in')),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(tester.getRect(find.text('signed in')), bare);
  });

  group('served from code, for a scope that is not a subtree', () {
    test('a session opens and closes it, with no widget in sight', () {
      var source = _SessionPanel('prod');

      var panel = DevbarPanels.add(source);
      expect(panel.id, 'db:main');
      expect(panelIds(), ['db:main']);

      panel.remove();
      expect(panelIds(), isEmpty);
      expect(GuestChannels.core.channels, isNot(contains('db:main')));
    });

    test('removing twice is a no-op, so it can sit next to a close()', () {
      var panel = DevbarPanels.add(_SessionPanel('prod'));
      panel.remove();
      var other = DevbarPanels.add(_SessionPanel('staging'));

      // The second remove must not take the panel somebody else has since
      // claimed under the same name.
      panel.remove();
      expect(panelIds(), ['db:main']);
      expect(other.id, 'db:main');
    });

    test('the handle says which id it actually got', () {
      var first = DevbarPanels.add(_SessionPanel('prod'));
      var second = DevbarPanels.add(_SessionPanel('staging'));

      // Forgetting the first `remove` is what this looks like from outside:
      // the panel that wanted `db:main` did not get it.
      expect(first.id, 'db:main');
      expect(second.id, 'db:main#2');
      first.remove();
      second.remove();
    });
  });
}
