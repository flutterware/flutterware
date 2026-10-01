import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutterware/flutter_test.dart';
import 'package:flutterware/src/scenarios/run_listener.dart';

/// The verbs a desktop needs and a finger does not have: the mouse — `hover`,
/// `unhover`, `secondaryTap`, the wheel — and the keyboard's `key`, beside
/// `doubleTap`.
///
/// They are the live drive's verbs, ported with their targets and their
/// semantics. The difference is the clock: a hover's hold and a double tap's
/// gap are fake time here, so what they wait for — a tooltip's timer, the
/// recognizer's window — happens exactly, every run.
void main() {
  var captures = <ScenarioStepCapture>[];
  setUp(() {
    captures = [];
    scenarioRunListener = captures.add;
  });
  tearDown(() => scenarioRunListener = null);

  group('hover', () {
    // The reason the hold exists. `waitDuration` is a `Timer`, which schedules
    // no frame until it fires, so a hover that only settled would see a quiet
    // screen and capture it without the tooltip.
    scenario('holds long enough for a tooltip to show', (s) async {
      await s.pumpWidget(
        _app(
          const Tooltip(
            message: 'Saves the document',
            waitDuration: Duration(milliseconds: 400),
            child: Text('Save'),
          ),
        ),
      );

      await s.hover('Save');

      expect(find.text('Saves the document'), findsOneWidget);
    });
    tearDown(() {
      var step = captures.last;
      expect(step.verb, 'hover');
      expect(step.target, '"Save"');
      // A tooltip is an overlay entry, so it is in the step's words like any
      // other widget: "does this control explain itself" has an answer.
      expect(step.texts, contains('Saves the document'));
    });
  });

  scenario('a hold shorter than the wait shows no tooltip', (s) async {
    await s.pumpWidget(
      _app(
        const Tooltip(
          message: 'Saves the document',
          waitDuration: Duration(milliseconds: 400),
          child: Text('Save'),
        ),
      ),
    );

    await s.hover('Save', hold: const Duration(milliseconds: 100));

    expect(find.text('Saves the document'), findsNothing);
  });

  // A mouse does not leave because the step ended: the thing to tap may only
  // be there while it is hovered.
  scenario('the mouse stays where it is put', (s) async {
    var regions = _Regions();
    await s.pumpWidget(_app(regions.build(['A', 'B'])));

    await s.hover('A');
    await s.screen('Still hovered');
    expect(regions.on, {'A'});

    // One mouse, moved — not a second one arriving, which would leave two
    // things hovered at once.
    await s.hover('B');
    expect(regions.on, {'B'});
  });

  group('unhover', () {
    scenario('takes the mouse away, and the tooltip with it', (s) async {
      await s.pumpWidget(
        _app(
          const Tooltip(
            message: 'Saves the document',
            waitDuration: Duration(milliseconds: 400),
            child: Text('Save'),
          ),
        ),
      );
      await s.hover('Save');
      expect(find.text('Saves the document'), findsOneWidget);

      await s.unhover();

      expect(find.text('Saves the document'), findsNothing);
      expect(RendererBinding.instance.mouseTracker.mouseIsConnected, isFalse);
    });
    tearDown(() {
      // Named after what it released, so the flow reads `unhover "Save"`.
      expect(captures.last.verb, 'unhover');
      expect(captures.last.target, '"Save"');
    });
  });

  group('unhover with no mouse on the screen', () {
    scenario('moves nothing and takes no picture', (s) async {
      await s.pumpWidget(_app(const Text('Nothing hovered')));

      await s.unhover();
    });
    tearDown(() {
      expect([for (var c in captures) c.verb], isNot(contains('unhover')));
    });
  });

  scenario('a hover over nothing is refused, with the screen it looked at', (
    s,
  ) async {
    await s.pumpWidget(_app(const Text('Only this')));

    await expectLater(
      () => s.hover('Not here'),
      throwsA(
        isA<ScenarioTargetError>().having(
          (e) => e.message,
          'message',
          allOf(contains('Not here'), contains('Only this')),
        ),
      ),
    );
    expect(RendererBinding.instance.mouseTracker.mouseIsConnected, isFalse);
  });

  group('doubleTap', () {
    scenario('fires onDoubleTap once', (s) async {
      var doubles = 0;
      var singles = 0;
      await s.pumpWidget(
        _app(
          GestureDetector(
            onTap: () => singles++,
            onDoubleTap: () => doubles++,
            child: const Text('Zoom'),
          ),
        ),
      );

      await s.doubleTap('Zoom');

      expect(doubles, 1);
      expect(singles, 0, reason: 'one gesture, not two taps');
    });
    tearDown(() {
      expect(captures.last.verb, 'doubleTap');
      expect(captures.last.target, '"Zoom"');
    });
  });

  // The gap is not a nicety. Inside `kDoubleTapMinTime` the recognizer reads
  // the second tap as the first one restarting, and fires nothing.
  scenario('a double tap with no gap does nothing', (s) async {
    var doubles = 0;
    await s.pumpWidget(
      _app(
        GestureDetector(
          onDoubleTap: () => doubles++,
          child: const Text('Zoom'),
        ),
      ),
    );

    await s.doubleTap('Zoom', gap: Duration.zero);

    expect(doubles, 0);
  });

  group('secondaryTap', () {
    scenario('opens the context menu a right-click asks for', (s) async {
      await s.pumpWidget(
        _app(
          Builder(
            builder: (context) => GestureDetector(
              onSecondaryTapUp: (details) => showMenu<void>(
                context: context,
                position: RelativeRect.fromLTRB(
                  details.globalPosition.dx,
                  details.globalPosition.dy,
                  details.globalPosition.dx,
                  details.globalPosition.dy,
                ),
                items: const [PopupMenuItem(child: Text('Rename'))],
              ),
              child: const Text('Row'),
            ),
          ),
        ),
      );

      await s.secondaryTap('Row');

      expect(find.text('Rename'), findsOneWidget);
      // It is the hover's mouse, and it stays where it clicked — over the
      // menu's barrier now, which is what a real one would be over.
      expect(RendererBinding.instance.mouseTracker.mouseIsConnected, isTrue);
    });
    tearDown(() {
      expect(captures.last.verb, 'secondaryTap');
      expect(captures.last.texts, contains('Rename'));
    });
  });

  scenario('a primary tap does not answer a right-click', (s) async {
    var primary = 0;
    var secondary = 0;
    await s.pumpWidget(
      _app(
        GestureDetector(
          onTap: () => primary++,
          onSecondaryTap: () => secondary++,
          child: const Text('Row'),
        ),
      ),
    );

    await s.secondaryTap('Row');
    await s.secondaryTap('Row');

    // Twice, on purpose: every press is a pointer of its own, as an engine
    // numbers them, so the second finds nothing of the first still open.
    expect(secondary, 2);
    expect(primary, 0);
  });

  group('scroll', () {
    var left = ScrollController();
    var right = ScrollController();
    tearDown(() {
      left.dispose();
      right.dispose();
      left = ScrollController();
      right = ScrollController();
    });

    // Two panes side by side, which is the whole point of a wheel: it moves
    // the one under the mouse, where `scrollTo` would pick one and walk it.
    scenario('moves the pane under the mouse, and only that one', (s) async {
      await s.pumpWidget(_TwoLists(left, right));

      await s.scroll(const Key('right'), const Offset(0, 300));

      // A wheel's sign: positive moves *down* the list.
      expect(right.offset, 300);
      expect(left.offset, 0);
    });
    tearDown(() {
      expect(captures.last.verb, 'scroll');
      expect(captures.last.target, contains('right'));
    });
  });

  group('key', () {
    scenario('presses a chord a Shortcuts binding answers', (s) async {
      var fired = 0;
      await s.pumpWidget(
        _app(
          CallbackShortcuts(
            bindings: {
              const SingleActivator(LogicalKeyboardKey.keyK, meta: true): () =>
                  fired++,
            },
            child: const Focus(autofocus: true, child: Text('Palette')),
          ),
        ),
      );

      await s.key('meta+k');

      expect(fired, 1);
      expect(HardwareKeyboard.instance.logicalKeysPressed, isEmpty);
    });
    tearDown(() {
      expect(captures.last.verb, 'key');
      expect(captures.last.target, 'meta+k');
      // A keystroke has no point on the screen, and the step claims none.
      expect(captures.last.aim, isNull);
    });
  });

  // The one way the verb could silently do nothing. Without a `MaterialApp`,
  // because a `Navigator`'s route takes focus on its own; an app with nothing
  // focusable leaves the keystroke at the root scope, above every binding.
  scenario('a key that went nowhere, with nothing focused, is refused', (
    s,
  ) async {
    var fired = 0;
    await s.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: CallbackShortcuts(
          bindings: {
            const SingleActivator(LogicalKeyboardKey.escape): () => fired++,
          },
          child: const Text('Unfocused'),
        ),
      ),
    );

    await expectLater(
      () => s.key('escape'),
      throwsA(
        isA<ScenarioTargetError>().having(
          (e) => e.message,
          'message',
          allOf(
            contains('s.key("escape")'),
            contains('holds focus'),
            contains('autofocus'),
          ),
        ),
      ),
    );
    expect(fired, 0);
    expect(HardwareKeyboard.instance.physicalKeysPressed, isEmpty);
  });

  scenario('a name that is not a key is refused', (s) async {
    await s.pumpWidget(_app(const Focus(autofocus: true, child: Text('A'))));

    await expectLater(
      () => s.key('banana'),
      throwsA(
        isA<ScenarioTargetError>().having(
          (e) => e.message,
          'message',
          allOf(contains('"banana"'), contains('arrowDown')),
        ),
      ),
    );
  });

  // Every branch replays from a fresh app, and a fresh app has no mouse on it:
  // one the first branch left parked would hover whatever the next builds.
  scenario('a split branch starts with no mouse on the screen', (s) async {
    var regions = _Regions();
    await s.pumpWidget(_app(regions.build(['A'])));
    expect(RendererBinding.instance.mouseTracker.mouseIsConnected, isFalse);

    await s.split({
      'hovers': () async {
        await s.hover('A');
        expect(regions.on, {'A'});
      },
      'does not': () async {
        expect(regions.on, isEmpty);
      },
    });
  });
}

Widget _app(Widget child) => MaterialApp(
  home: Scaffold(body: Center(child: child)),
);

/// Which of its regions the mouse is over.
class _Regions {
  final on = <String>{};

  Widget region(String label, Widget child) => MouseRegion(
    onEnter: (_) => on.add(label),
    onExit: (_) => on.remove(label),
    child: child,
  );

  Widget build(List<String> labels) => Column(
    mainAxisSize: MainAxisSize.min,
    children: [for (var label in labels) region(label, Text(label))],
  );
}

class _TwoLists extends StatelessWidget {
  const _TwoLists(this.left, this.right);

  final ScrollController left;
  final ScrollController right;

  @override
  Widget build(BuildContext context) => MaterialApp(
    home: Scaffold(
      body: Row(
        children: [
          for (var (name, controller) in [('left', left), ('right', right)])
            Expanded(
              child: ListView.builder(
                key: Key(name),
                controller: controller,
                itemCount: 100,
                itemBuilder: (_, i) =>
                    SizedBox(height: 50, child: Text('$name $i')),
              ),
            ),
        ],
      ),
    ),
  );
}
