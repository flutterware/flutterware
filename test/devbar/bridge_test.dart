import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutterware/channels.dart';
import 'package:flutterware/devbar.dart';

/// A descriptor-mode plugin: it implements [DevbarPanelSource], and that is the
/// whole of how it declares its mode.
class _FlagsPlugin implements DevbarPlugin, DevbarPanelSource {
  var enabled = false;
  Panel? panel;
  var disposed = false;

  @override
  String get panelId => 'flags';

  @override
  String get panelLabel => 'Feature flags';

  @override
  void describePanel(Panel panel) {
    this.panel = panel;
    panel.feed('changes', 'Changes');
    panel.knob(
      const KnobDescriptor(
        name: 'newCheckout',
        kind: KnobKind.boolean,
        value: false,
        defaultValue: false,
      ),
      read: () => enabled,
      write: (value) => enabled = value == true,
    );
    panel.action(const PluginAction('reset', 'Reset'), (_) => {'ok': true});
  }

  @override
  void dispose() => disposed = true;
}

/// Widget mode: no [DevbarPanelSource], so nothing outside the app sees it.
class _WidgetOnlyPlugin implements DevbarPlugin {
  @override
  void dispose() {}
}

void main() {
  setUp(() {
    // The bridge only mirrors when flutterware is watching; `install()` is
    // what the run guest does before `runApp`, and it is idempotent.
    GuestChannels.install();
    for (var panel in GuestChannels.panels.descriptors) {
      GuestChannels.panels.remove(panel.id);
    }
  });

  Future<void> pumpDevbar(
    WidgetTester tester, {
    required List<DevbarPluginFactory> plugins,
    bool mounted = true,
  }) async {
    await tester.pumpWidget(
      mounted
          ? Devbar(plugins: plugins, headless: true, child: const SizedBox())
          : const SizedBox(),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('a descriptor-mode plugin becomes a panel; a widget-mode one '
      'does not', (tester) async {
    await pumpDevbar(
      tester,
      plugins: [(_) => _FlagsPlugin(), (_) => _WidgetOnlyPlugin()],
    );

    var panels = GuestChannels.panels.descriptors;
    expect(panels.map((p) => p.id), ['flags']);
    expect(panels.single.label, 'Feature flags');
    expect(panels.single.knobs.single.name, 'newCheckout');
    expect(panels.single.feeds.single.id, 'changes');
    expect(panels.single.actions.single.id, 'reset');
  });

  testWidgets('unmounting gives the panels back', (tester) async {
    await pumpDevbar(tester, plugins: [(_) => _FlagsPlugin()]);
    expect(GuestChannels.panels.descriptors, hasLength(1));

    await pumpDevbar(tester, plugins: const [], mounted: false);

    expect(GuestChannels.panels.descriptors, isEmpty);
    expect(GuestChannels.core.channels, isNot(contains('flags')));
  });

  testWidgets('a hot restart — dispose then mount — leaves one panel, live', (
    tester,
  ) async {
    var first = _FlagsPlugin();
    await pumpDevbar(tester, plugins: [(_) => first]);
    await pumpDevbar(tester, plugins: const [], mounted: false);

    var second = _FlagsPlugin();
    await pumpDevbar(tester, plugins: [(_) => second]);

    expect(first.disposed, isTrue);
    expect(GuestChannels.panels.descriptors.map((p) => p.id), ['flags']);
    // The surviving panel is the new plugin's, not a corpse of the old one.
    second.enabled = true;
    expect(GuestChannels.panels.descriptors.single.knobs.single.value, isTrue);
  });

  testWidgets('two devbars at once do not shadow each other', (tester) async {
    await tester.pumpWidget(
      Column(
        textDirection: TextDirection.ltr,
        children: [
          Devbar(
            plugins: [(_) => _FlagsPlugin()],
            headless: true,
            child: const SizedBox(),
          ),
          Devbar(
            plugins: [(_) => _FlagsPlugin()],
            headless: true,
            child: const SizedBox(),
          ),
        ],
      ),
    );
    await tester.pumpAndSettle();

    // The ordinary app's id is untouched; the second instance is suffixed, so
    // an agent reading `flags` in a one-devbar app reads what the plugin
    // declared.
    expect(GuestChannels.panels.descriptors.map((p) => p.id), [
      'flags',
      'flags#2',
    ]);
  });

  testWidgets('a knob written over the wire reaches the plugin', (
    tester,
  ) async {
    var plugin = _FlagsPlugin();
    await pumpDevbar(tester, plugins: [(_) => plugin]);

    var peer = _Peer();
    GuestChannels.core.handleFrame(peer, {
      'ch': 'flags',
      't': 'req',
      'id': 1,
      'm': panelSetKnobMethod,
      'p': {'id': 'newCheckout', 'value': true},
    });
    await tester.pumpAndSettle();

    expect(plugin.enabled, isTrue);
  });

  testWidgets('a plugin emits on its panel after mounting', (tester) async {
    var plugin = _FlagsPlugin();
    await pumpDevbar(tester, plugins: [(_) => plugin]);

    plugin.panel!.emit('changes', {'flag': 'newCheckout'});

    var peer = _Peer();
    GuestChannels.core.attach(peer, 1);
    expect(peer.frames.where((f) => f['ch'] == 'flags/changes'), hasLength(1));
  });
}

class _Peer implements InspectorPeer {
  final frames = <Map<String, Object?>>[];

  @override
  void send(Map<String, Object?> frame) => frames.add(frame);

  @override
  void close() {}
}
