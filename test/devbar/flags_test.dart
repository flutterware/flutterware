import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutterware/channels.dart';
import 'package:flutterware/devbar.dart';
import 'package:flutterware/devbar_plugins/variables.dart';

/// Feature flags, from the widget that declares one to the wire a cockpit
/// reads — the app half of Decision 4.
void main() {
  setUp(() {
    GuestChannels.install();
    for (var panel in GuestChannels.panels.descriptors) {
      GuestChannels.panels.remove(panel.id);
    }
  });

  PanelDescriptor flags() =>
      GuestChannels.panels.descriptors.singleWhere((p) => p.id == 'flags');

  Future<Object?> call(
    WidgetTester tester,
    String method, [
    Map<String, Object?> params = const {},
  ]) async {
    var peer = _Peer();
    GuestChannels.core.handleFrame(peer, {
      'ch': 'flags',
      't': 'req',
      'id': 1,
      'm': method,
      'p': params,
    });
    await tester.pumpAndSettle();
    var frame = peer.frames.single;
    if (frame['t'] == 'err') {
      throw StateError('${(frame['p']! as Map)['message']}');
    }
    return frame['p'];
  }

  Future<void> pump(
    WidgetTester tester, {
    required List<FeatureFlagValue> declared,
    Widget child = const SizedBox(),
  }) async {
    await tester.pumpWidget(
      Devbar(
        plugins: [VariablesPlugin.init()],
        headless: true,
        flags: declared,
        child: child,
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('a declared flag arrives as a knob with its live value', (
    tester,
  ) async {
    var newCheckout = FeatureFlag<bool>(
      'newCheckout',
      false,
      description: 'The rewritten checkout',
    );
    await pump(tester, declared: [newCheckout.withValue(true)]);

    var knob = flags().knobs.singleWhere((k) => k.name == 'newCheckout');
    expect(knob.kind, KnobKind.boolean);
    expect(knob.value, isTrue);
    expect(knob.defaultValue, isFalse);
    expect(knob.description, 'The rewritten checkout');
  });

  testWidgets('the cockpit turns a flag on, and the app holds it', (
    tester,
  ) async {
    var flag = FeatureFlag<bool>('newCheckout', false);
    bool? seenByTheApp;
    await pump(
      tester,
      declared: [flag.withDefaultValue],
      child: Builder(
        builder: (context) {
          seenByTheApp = flag.dependsOnValue(context);
          return const SizedBox();
        },
      ),
    );
    expect(seenByTheApp, isFalse);

    var reply =
        (await call(tester, panelSetKnobMethod, {
              'id': 'newCheckout',
              'value': true,
            }))!
            as Map;

    // The widget that reads the flag rebuilt — the point of the whole bridge.
    expect(seenByTheApp, isTrue);
    var knob = (reply['knobs']! as List).single as Map;
    expect(knob['value'], isTrue);
  });

  testWidgets('every kind a devbar variable can be survives the trip', (
    tester,
  ) async {
    await pump(
      tester,
      declared: [
        FeatureFlag<String>('apiBaseUrl', 'https://api').withDefaultValue,
        FeatureFlag.slider<int>(
          'retries',
          3,
          min: 0,
          max: 10,
          step: 1,
        ).withDefaultValue,
        FeatureFlag.slider<double>(
          'jitter',
          0.5,
          min: 0,
          max: 1,
          step: 0.1,
        ).withDefaultValue,
        FeatureFlag.picker<String>(
          'environment',
          'prod',
          options: {'prod': 'Production', 'stg': 'Staging'},
        ).withDefaultValue,
      ],
    );

    var byName = {for (var knob in flags().knobs) knob.name: knob};
    expect(byName['apiBaseUrl']!.kind, KnobKind.string);
    expect(byName['retries']!.kind, KnobKind.integer);
    expect(byName['retries']!.min, 0);
    expect(byName['retries']!.step, 1);
    expect(byName['jitter']!.kind, KnobKind.number);
    // Only the labels cross; the app keeps the values behind them.
    expect(byName['environment']!.kind, KnobKind.picker);
    expect(byName['environment']!.options, ['Production', 'Staging']);
    expect(byName['environment']!.value, 'Production');
  });

  testWidgets('a picker is set by its label, and a stale label is refused', (
    tester,
  ) async {
    var flag = FeatureFlag.picker<String>(
      'environment',
      'prod',
      options: {'prod': 'Production', 'stg': 'Staging'},
    );
    await pump(tester, declared: [flag.withDefaultValue]);

    await call(tester, panelSetKnobMethod, {
      'id': 'environment',
      'value': 'Staging',
    });
    expect(flags().knobs.single.value, 'Staging');

    await call(tester, panelSetKnobMethod, {
      'id': 'environment',
      'value': 'Nowhere',
    });
    expect(
      flags().knobs.single.value,
      'Staging',
      reason: 'an unknown label leaves the value alone rather than clearing it',
    );
  });

  /// The wish map's app half: the cockpit names a value for a flag nothing has
  /// declared yet, and it applies the instant something does.
  testWidgets('a pre-set value waits for the flag that has not appeared', (
    tester,
  ) async {
    await pump(tester, declared: const []);

    var reply =
        (await call(tester, 'preset', {'name': 'newCheckout', 'value': true}))!
            as Map;
    expect(reply['declared'], isFalse, reason: 'nothing has declared it yet');
    expect(flags().knobs, isEmpty);

    // Now the screen that declares it gets built.
    var flag = FeatureFlag<bool>('newCheckout', false);
    await pump(tester, declared: [flag.withDefaultValue]);

    expect(
      flags().knobs.single.value,
      isTrue,
      reason: 'the wish applied on the way in',
    );
  });

  testWidgets('a flag that goes away stops being a knob', (tester) async {
    var flag = FeatureFlag<bool>('newCheckout', false);
    await pump(tester, declared: [flag.withDefaultValue]);
    expect(flags().knobs, hasLength(1));

    await pump(tester, declared: const []);

    expect(flags().knobs, isEmpty);
  });
}

class _Peer implements InspectorPeer {
  final frames = <Map<String, Object?>>[];

  @override
  void send(Map<String, Object?> frame) => frames.add(frame);

  @override
  void close() {}
}
