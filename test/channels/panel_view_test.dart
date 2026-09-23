import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutterware/channels.dart';
import 'package:flutterware/channels_ui.dart';

/// Deliberately bare: no `Scaffold`, no `Material`, no `Card` — only the
/// `Directionality` and theme any host provides. These widgets are embedded in
/// a cockpit pane and in some app's overlay, and neither is obliged to have put
/// a `Material` above them.
Future<void> pumpBare(WidgetTester tester, Widget child, {double width = 900}) {
  return tester.pumpWidget(
    MaterialApp(
      home: SizedBox(width: width, height: 500, child: child),
    ),
  );
}

InspectorEvent event(int id, Map<String, Object?> payload) => InspectorEvent(
  channel: 'p/f',
  id: id,
  time: DateTime.utc(2026, 8, 11, 9, id),
  payload: payload,
  isReplay: false,
);

void main() {
  /// Found by the previews the first time they rendered: `Switch`, `TextField`
  /// and `DropdownButtonFormField` throw without a `Material` ancestor, and a
  /// bare `Text` renders in Flutter's yellow-underlined fallback. Every
  /// exported view now carries a [PanelSurface]; this is what keeps it.
  testWidgets('every view stands on its own Material', (tester) async {
    var views = <String, Widget>{
      'controls': ControlsView(
        knobs: const [
          KnobDescriptor(
            name: 'flag',
            kind: KnobKind.boolean,
            value: true,
            defaultValue: false,
          ),
          KnobDescriptor(
            name: 'url',
            kind: KnobKind.string,
            value: 'x',
            defaultValue: '',
          ),
          KnobDescriptor(
            name: 'env',
            kind: KnobKind.picker,
            value: 'a',
            defaultValue: 'a',
            options: ['a', 'b'],
          ),
        ],
        actions: const [PluginAction('go', 'Go')],
        onKnob: (_, _) {},
        onAction: (_, _) {},
      ),
      'controls empty': const ControlsView(knobs: [], actions: []),
      'feed': FeedView(
        feed: const FeedDescriptor('f', 'F'),
        events: [
          event(1, const {'a': 'b'}),
        ],
      ),
      'feed empty': const FeedView(feed: FeedDescriptor('f', 'F'), events: []),
      'state unread': const StateView(
        state: StateDescriptor('s', 'S'),
        snapshot: null,
      ),
      'state read': const StateView(
        state: StateDescriptor('s', 'S'),
        snapshot: {'k': 'v'},
      ),
      'panel bare': const PanelView(descriptor: PanelDescriptor('p', 'P')),
    };

    for (var entry in views.entries) {
      await pumpBare(tester, entry.value);
      expect(tester.takeException(), isNull, reason: entry.key);
      expect(find.byType(PanelSurface), findsWidgets, reason: entry.key);
    }
  });

  /// Also found by the previews: a feed that declared no fields synthesises one
  /// per payload key, none of them primary, so nothing flexed and a 90
  /// character SQL string overflowed the row by 583 pixels.
  testWidgets('a feed with no primary field still fits', (tester) async {
    await pumpBare(
      tester,
      FeedView(
        feed: const FeedDescriptor('queries', 'Queries'),
        events: [
          event(1, {
            'sql':
                'SELECT * FROM todos WHERE list_id = ? AND completed = 0 '
                'ORDER BY updated_at DESC LIMIT 50',
            'rows': 17,
          }),
        ],
      ),
      width: 420,
    );

    expect(tester.takeException(), isNull);
    expect(find.textContaining('SELECT'), findsOneWidget);
  });

  testWidgets('a tab per feed, per state, and one for the controls', (
    tester,
  ) async {
    await pumpBare(
      tester,
      const PanelView(
        descriptor: PanelDescriptor(
          'net',
          'Network',
          feeds: [FeedDescriptor('requests', 'Requests')],
          states: [StateDescriptor('config', 'Client')],
          actions: [PluginAction('clear', 'Clear')],
        ),
      ),
    );

    expect(find.text('Requests'), findsOneWidget);
    expect(find.text('Client'), findsOneWidget);
    expect(find.text('Controls'), findsOneWidget);
  });

  testWidgets('a knob reports its change and marks itself overridden', (
    tester,
  ) async {
    Object? written;
    await pumpBare(
      tester,
      ControlsView(
        knobs: const [
          KnobDescriptor(
            name: 'newCheckout',
            kind: KnobKind.boolean,
            value: true,
            defaultValue: false,
          ),
        ],
        actions: const [],
        onKnob: (_, value) => written = value,
      ),
    );

    expect(find.text('overridden'), findsOneWidget);
    await tester.tap(find.byType(Switch));
    expect(written, isFalse);
  });

  testWidgets('an action with a required parameter waits for it', (
    tester,
  ) async {
    Map<String, Object?>? ran;
    await pumpBare(
      tester,
      ControlsView(
        knobs: const [],
        actions: const [
          PluginAction(
            'notify',
            'Notify',
            parameters: [ActionParameter('title', 'Title')],
          ),
        ],
        onAction: (_, args) => ran = args,
      ),
    );

    var button = find.widgetWithText(FilledButton, 'Notify');
    expect(tester.widget<FilledButton>(button).onPressed, isNull);

    await tester.enterText(find.byType(TextField), 'Hello');
    await tester.pump();
    await tester.tap(button);

    expect(ran, {'title': 'Hello'});
  });

  test('values are formatted by their declared kind', () {
    String show(FieldKind kind, Object? value) =>
        formatFieldValue(FieldDescriptor('k', 'K', kind: kind), value);

    expect(show(FieldKind.bytes, 1240), '1.2 kB');
    expect(show(FieldKind.duration, 1180.3), '1.18s');
    // One decimal only below 10ms; past that the fraction is noise.
    expect(show(FieldKind.duration, 18.24), '18ms');
    expect(show(FieldKind.duration, 4.27), '4.3ms');
    expect(show(FieldKind.duration, 0.4), '400µs');
    expect(show(FieldKind.text, null), '—');
    // An unknown value under a numeric kind is shown, not swallowed.
    expect(show(FieldKind.bytes, 'huge'), 'huge');
  });
}
