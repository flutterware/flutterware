import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutterware_app/src/plugins/native/run_results.dart';
import 'package:flutterware_app/src/run/handle.dart';
import 'package:flutterware_app/src/run/knobs_tab.dart';
import 'package:flutterware_app/src/ui/picker.dart';

/// The editor that makes the 262ms reachable: the launch form lives on the New
/// run page, and the only other way back to it is Stop — which is a rebuild.
void main() {
  RunHandle handleWith(Map<String, String> knobs) => RunHandle(
    worktree: '/w',
    worktreeName: 'wt',
    device: 'macos',
    entrypoint: 'lib/main.dart',
    entrypointName: 'App',
    package: 'app',
    launcherPid: 1,
    knobs: knobs,
    startedAt: DateTime(2026),
  );

  var knobs = [
    RunKnobEntry(name: 'apiHost', kind: 'string', defaultValue: 'localhost'),
    RunKnobEntry(
      name: 'backend',
      kind: 'picker',
      defaultValue: 'dev',
      options: const ['dev', 'staging', 'prod'],
    ),
  ];

  Future<List<Map<String, String>>> pump(
    WidgetTester tester, {
    RunHandle? handle,
    List<RunKnobEntry>? offered,
    String? unknown,
    String? Function(String)? interfaceOf,
    Map<String, String> Function(Map<String, String> values)? running,
  }) async {
    var applied = <Map<String, String>>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: KnobsTab(
            handle: handle ?? handleWith(const {}),
            knobs: offered ?? knobs,
            unknown: unknown,
            interfaceOf: interfaceOf,
            // Answers with what the app is now running, as `applyKnobs` does.
            // [running] stands in for a source refilling a knob the caller left
            // out, which is the case where the answer differs from the ask.
            onApply: (values) async {
              applied.add(values);
              return running?.call(values) ?? values;
            },
          ),
        ),
      ),
    );
    return applied;
  }

  testWidgets('draws each knob for the kind its parameter declares', (
    tester,
  ) async {
    await pump(tester);

    expect(find.text('apiHost'), findsOneWidget);
    expect(find.byType(TextFormField), findsOneWidget);
    // An enum is a dropdown of its own constants rather than a field somebody
    // can misspell into.
    expect(find.byType(FwPicker<String>), findsOneWidget);
  });

  testWidgets('will not restart until something has actually changed', (
    tester,
  ) async {
    await pump(tester);

    var button = tester.widget<FilledButton>(find.byType(FilledButton));
    expect(button.onPressed, isNull);
    // The cost is stated only once there is something to pay it for.
    expect(find.textContaining('starts from its first screen'), findsNothing);
  });

  testWidgets('an edit enables the button and says what a restart costs', (
    tester,
  ) async {
    var applied = await pump(tester);

    await tester.enterText(find.byType(TextFormField), 'staging.example.com');
    await tester.pump();

    expect(find.textContaining('starts from its first screen'), findsOneWidget);
    expect(applied, isEmpty, reason: 'not applied until the button is pressed');

    await tester.tap(find.byType(FilledButton));
    await tester.pump();

    expect(applied.single, {'apiHost': 'staging.example.com'});
  });

  testWidgets('starts from what the run is actually holding', (tester) async {
    // A knob whose current value the tool had forgotten would be a field you
    // can only overwrite blind.
    await pump(tester, handle: handleWith({'apiHost': 'already.set'}));

    expect(find.text('already.set'), findsOneWidget);
    expect(
      tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
      isNull,
    );
  });

  testWidgets('an entry point taking none says so rather than sitting blank', (
    tester,
  ) async {
    await pump(tester, offered: const []);

    expect(find.textContaining('takes no knobs'), findsOneWidget);
    // And teaches the one thing that would make it non-empty.
    expect(find.textContaining('optional named parameters'), findsOneWidget);
  });

  testWidgets('a text knob offers its options, and a tap fills the field', (
    tester,
  ) async {
    // `Knob('apiHost', from: ValueSource.hostAddresses)` is a String parameter,
    // so a text field — and the whole reason it exists is the list underneath.
    // Rendering options only for pickers made this feature invisible to a
    // human while `entrypoints` still reported it to an agent.
    var applied = await pump(
      tester,
      offered: [
        RunKnobEntry(
          name: 'apiHost',
          kind: 'string',
          defaultValue: 'localhost',
          options: const ['192.168.1.24', '10.0.0.3'],
        ),
      ],
      interfaceOf: (address) => address.startsWith('192.') ? 'en0' : null,
    );

    // Once: the chip. The field is empty, because a default is a hint and an
    // offered value is not a choice until it is picked.
    expect(find.text('192.168.1.24'), findsOneWidget);
    // Five bare IPv4s say nothing about which one the phone can reach.
    expect(find.text('en0'), findsOneWidget);

    await tester.tap(find.text('192.168.1.24'));
    await tester.pump();

    // The field shows it, not just the form state behind it: `initialValue` is
    // read once, so a chip tap used to change the value and leave the box.
    expect(
      tester.widget<TextFormField>(find.byType(TextFormField)).controller?.text,
      '192.168.1.24',
    );

    await tester.tap(find.byType(FilledButton));
    await tester.pump();
    expect(applied.single, {'apiHost': '192.168.1.24'});
  });

  testWidgets('a picker does not repeat its own constants as chips', (
    tester,
  ) async {
    await pump(tester);

    // The dropdown already is the list; a second copy below it would be the
    // same facts twice. `dev` is on screen because it is selected; the other
    // two constants exist only inside the menu, which is not open.
    expect(find.text('dev'), findsOneWidget);
    expect(find.text('staging'), findsNothing);
    expect(find.text('prod'), findsNothing);
  });

  testWidgets('a knob that has been set can be put back', (tester) async {
    // The only way to say "stop overriding this". A text field can be emptied,
    // but a switch and a dropdown have no empty — without this a picker moved
    // off its default could never go back.
    var applied = await pump(tester, handle: handleWith({'backend': 'prod'}));

    expect(find.text('Reset'), findsOneWidget);
    await tester.tap(find.text('Reset'));
    await tester.pump();

    await tester.tap(find.byType(FilledButton));
    await tester.pump();
    expect(applied.single, isEmpty);
  });

  testWidgets('a line with nothing to set draws no control', (tester) async {
    // Two kinds of line have no parameter behind them — a config knob naming
    // one that is not there, and a `required` parameter that cannot be a knob.
    // Both carry a problem saying exactly that, and a text field beside it
    // would be the control-that-does-nothing the problem complains about.
    await pump(
      tester,
      offered: [
        RunKnobEntry(name: 'apiHost', problem: 'main requires this, so …'),
      ],
    );

    expect(find.text('apiHost'), findsOneWidget);
    expect(find.textContaining('main requires this'), findsOneWidget);
    expect(find.byType(TextFormField), findsNothing);
    expect(find.byType(Switch), findsNothing);
    expect(find.byType(FwPicker<String>), findsNothing);
  });

  testWidgets('a required knob says so, loudest while nothing answers it', (
    tester,
  ) async {
    // The word that separates a knob nobody has touched from one the launch is
    // waiting on. A required knob is reported *without* the parameter's own
    // default — that placeholder is exactly what the flag says not to trust —
    // so "no default" here is the state Start is greyed out in.
    await pump(
      tester,
      offered: [
        RunKnobEntry(name: 'apiToken', kind: 'string', required: true),
        RunKnobEntry(
          name: 'flutterSdkRoot',
          kind: 'string',
          required: true,
          // A source worked this one out, which is what satisfies the flag: the
          // point is that a value was chosen for this launch, not that a human
          // typed it.
          defaultValue: '/opt/flutter',
        ),
      ],
    );

    expect(find.text('required'), findsNWidgets(2));
    var amber = tester
        .widgetList<Text>(find.text('required'))
        .map((text) => text.style?.color)
        .toSet();
    expect(amber.length, 2, reason: 'the answered one is not shouting');
  });

  testWidgets('an apply that changes nothing still settles the form', (
    tester,
  ) async {
    // The stuck-dirty case. Resetting a knob whose source recomputes the same
    // value means the apply lands and `handle.knobs` does not move — so
    // `didUpdateWidget`, which only reacts to a change, cannot settle this. The
    // form used to keep claiming a pending edit it could never finish: button
    // live, field on its hint, every press restarting the app again.
    await pump(
      tester,
      offered: [
        RunKnobEntry(name: 'serverPort', kind: 'integer', defaultValue: '8086'),
      ],
      handle: handleWith({'serverPort': '8186'}),
      running: (_) => {'serverPort': '8186'},
    );

    await tester.tap(find.text('Reset'));
    await tester.pump();
    expect(
      tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
      isNotNull,
    );

    await tester.tap(find.byType(FilledButton));
    await tester.pumpAndSettle();

    expect(
      tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
      isNull,
      reason: 'the edit is done, so there is nothing left to apply',
    );
    // And the field shows what the run is holding rather than an empty box.
    expect(
      tester.widget<TextFormField>(find.byType(TextFormField)).controller?.text,
      '8186',
    );
  });

  testWidgets('a picker whose value is not among its options still draws', (
    tester,
  ) async {
    // A script source can compute a value for an enum knob that is not one of
    // its constants. A Material dropdown asked to show a value it has no item
    // for asserts, which would take the whole tab down; the house picker
    // degrades to an unfilled trigger.
    await pump(
      tester,
      offered: [
        RunKnobEntry(
          name: 'backend',
          kind: 'picker',
          defaultValue: 'whatever-the-script-said',
          options: const ['dev', 'prod'],
        ),
      ],
    );

    expect(find.byType(FwPicker<String>), findsOneWidget);
    expect(find.text('Choose…'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a run it cannot read says why, not "takes no knobs"', (
    tester,
  ) async {
    // Another checkout of the same repo has the same package paths and the
    // same entry point names, so every lookup succeeds — against source that
    // may be on a different branch. Claiming the app takes none would be a
    // statement about somebody else's code.
    await pump(
      tester,
      offered: const [],
      unknown: 'This run belongs to feature-x.',
    );

    expect(find.text('This run belongs to feature-x.'), findsOneWidget);
    expect(find.textContaining('takes no knobs'), findsNothing);
    // Nothing to edit, so nothing that looks editable.
    expect(find.byType(FilledButton), findsNothing);
  });

  test('a copy keeps the knobs, or a launch forgets them seconds later', () {
    // `refreshFromLog` rewrites the handle the moment the launcher reports a VM
    // service — a few seconds after every launch. A copy that dropped `knobs`
    // left the field empty in the cockpit while the app was plainly running
    // with values, which is exactly what the end-to-end showed.
    var handle = RunHandle(
      worktree: '/w',
      worktreeName: 'wt',
      device: 'macos',
      entrypoint: 'lib/main.dart',
      launcherPid: 1,
      defines: const {'FW_MARKER': 'x'},
      knobs: const {'apiHost': 'set.example.com'},
      startedAt: DateTime(2026),
    );

    var refreshed = handle.withService(vmService: 'ws://127.0.0.1:1/ws');

    expect(refreshed.knobs, {'apiHost': 'set.example.com'});
    expect(refreshed.defines, {'FW_MARKER': 'x'});
    expect(handle.withKnobs(const {'apiHost': 'other'}).defines, {
      'FW_MARKER': 'x',
    });
  });
}
