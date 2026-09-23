import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutterware/src/drive/resolve.dart';
import 'package:flutterware/src/scenarios/target.dart';

/// The shared actionability ladder in its live flavor — no `s.` prefix, no
/// `s.tester` escape hatch, and a [TargetFailure] kind on every refusal so a
/// live driver can decide what is transient. The scenario flavor of the same
/// ladder is covered by test/scenarios/actionability_test.dart.
void main() {
  testWidgets('a covered target is refused with the covered kind', (
    tester,
  ) async {
    await tester.pumpWidget(_covered());
    var resolver = TargetResolver(tester);

    var error = await _refusal(() => resolver.resolve('Buy', 'tap'));

    expect(error.failure, TargetFailure.covered);
    expect('$error', contains('`tap` at its center'));
    expect('$error', isNot(contains('s.')));
    expect('$error', isNot(contains('tester')));
  });

  testWidgets('a covered refusal names what the pointer lands on', (
    tester,
  ) async {
    // The consumer case behind this: neither of the generic sentence's two
    // causes was true — nothing covered the target and nothing absorbed the
    // pointer, an `OverflowBox` had simply pushed its centre over a
    // neighbour. The hit test already knows what the pointer reaches; the
    // refusal says it.
    await tester.pumpWidget(
      MaterialApp(
        home: Stack(
          children: [
            Center(
              child: TextButton(onPressed: () {}, child: const Text('Buy')),
            ),
            Positioned.fill(
              child: Material(
                child: InkWell(
                  onTap: () {},
                  child: const Center(child: Text('Blocking sheet')),
                ),
              ),
            ),
          ],
        ),
      ),
    );
    var resolver = TargetResolver(tester);

    var error = await _refusal(() => resolver.resolve('Buy', 'tap'));

    expect(error.failure, TargetFailure.covered);
    expect('$error', contains('lands on "Blocking sheet"'));
    // The two-guess sentence is the fallback for a nameless hit, not a
    // preamble to this one.
    expect('$error', isNot(contains('IgnorePointer')));
  });

  testWidgets('nothing matching is refused with the notFound kind and the '
      'screen description when one is wired', (tester) async {
    await tester.pumpWidget(_covered());
    var resolver = TargetResolver(
      tester,
      describeScreen: () => visibleTextsOf(tester).join(', '),
    );

    var error = await _refusal(() => resolver.resolve('Pay', 'tap'));

    expect(error.failure, TargetFailure.notFound);
    expect('$error', contains('nothing matches "Pay"'));
    // Nothing on this screen scrolls, so the refusal must not send the
    // reader hunting scroll positions.
    expect('$error', contains('Nothing on this screen scrolls'));
    expect('$error', isNot(contains('scrollTo')));
    expect('$error', contains('Visible text: Buy'));
  });

  testWidgets('a screen with no text at all gets the blank hint instead of '
      'the lazy-list guess', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: SizedBox.shrink()));
    var resolver = TargetResolver(
      tester,
      messages: const TargetMessages(blankScreenHint: 'Nothing has rendered.'),
    );

    var error = await _refusal(() => resolver.resolve('Pay', 'tap'));

    expect(error.failure, TargetFailure.notFound);
    expect('$error', contains('Nothing has rendered.'));
    expect('$error', isNot(contains('lazy list')));
  });

  testWidgets('a screen that has content keeps the guess instead of the '
      'blank hint', (tester) async {
    await tester.pumpWidget(_covered());
    var resolver = TargetResolver(
      tester,
      messages: const TargetMessages(blankScreenHint: 'Nothing has rendered.'),
    );

    var error = await _refusal(() => resolver.resolve('Pay', 'tap'));

    expect('$error', contains('never built'));
    expect('$error', isNot(contains('Nothing has rendered.')));
  });

  testWidgets('several matches are refused with the multiple kind, and the '
      'refusal says where each one is', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Row(
          children: [
            for (var i = 0; i < 2; i++)
              SizedBox(width: 100, height: 40, child: const Text('Buy')),
          ],
        ),
      ),
    );
    var resolver = TargetResolver(tester);

    var error = await _refusal(() => resolver.resolve('Buy', 'tap'));

    expect(error.failure, TargetFailure.multiple);
    expect('$error', contains('2 widgets match "Buy"'));
    // Numbered as `nth` indexes them, so the caller picks one from this
    // refusal rather than going back for another look.
    expect('$error', contains('  0 at 0,280 100×40'));
    expect('$error', contains('  1 at 100,280 100×40'));
  });

  testWidgets('a target matching everything lists ten and counts the rest', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Wrap(
          children: [
            for (var i = 0; i < 14; i++)
              const SizedBox(width: 100, height: 40, child: Text('Buy')),
          ],
        ),
      ),
    );
    var resolver = TargetResolver(tester);

    var error = await _refusal(() => resolver.resolve('Buy', 'tap'));

    expect('$error', contains('14 widgets match'));
    expect('$error', contains('  9 at'));
    expect('$error', isNot(contains('  10 at')));
    expect('$error', contains('… and 4 more'));
  });

  testWidgets('an essay-length text is capped with an ellipsis, and still '
      'resolves via containing', (tester) async {
    var essay = 'log line ${'x' * visibleTextCap}';
    await tester.pumpWidget(
      MaterialApp(home: ListView(children: [const Text('Buy'), Text(essay)])),
    );

    var texts = visibleTextsOf(tester);

    expect(texts, contains('Buy'));
    var capped = texts.singleWhere((t) => t.startsWith('log line'));
    expect(capped.length, visibleTextCap + 1);
    expect(capped, endsWith('…'));

    var resolver = TargetResolver(tester);
    var finder = await resolver.resolve(Target.containing('log line'), 'tap');
    expect(finder.evaluate(), hasLength(1));
  });

  /// Reported by a consumer driving a login screen. The screenshot in the
  /// same reply rendered bullets and the `texts` beside it carried the
  /// password in clear — into the agent's transcript, into any log that
  /// transcript reaches, and onto disk in the run's journal and in a
  /// scenario's captured step, all of which archive this projection whole.
  testWidgets('an obscured field reports what it draws, not what it holds', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              TextField(
                obscureText: true,
                controller: TextEditingController(text: 'hunter2!'),
              ),
              TextField(controller: TextEditingController(text: 'ada@dev.io')),
            ],
          ),
        ),
      ),
    );

    var texts = visibleTextsOf(tester);

    expect(texts, isNot(contains('hunter2!')));
    expect(texts, contains('••••••••'), reason: 'the length still shows');
    expect(
      texts,
      contains('ada@dev.io'),
      reason: 'an ordinary field is untouched',
    );
  });

  /// The mask is the field's own [EditableText.obscuringCharacter], so the
  /// projection keeps matching the pixels for an app that picked another one.
  testWidgets('the mask is the character the field actually draws', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TextField(
            obscureText: true,
            obscuringCharacter: '*',
            controller: TextEditingController(text: 'abc'),
          ),
        ),
      ),
    );

    expect(visibleTextsOf(tester), contains('***'));
  });

  testWidgets('an nth index past the end is refused with the count, not a '
      'RangeError', (tester) async {
    await tester.pumpWidget(_covered());
    var resolver = TargetResolver(tester);

    var error = await _refusal(
      () => resolver.resolve(const Target.nth('Buy', 4), 'tap'),
    );

    // notFound rather than a raw RangeError is what puts it back on the retry
    // ladder: mid-transition, the match it wanted may be one frame away.
    expect(error.failure, TargetFailure.notFound);
    expect('$error', contains('"Buy" matches 1 widget'));
    expect('$error', contains('`nth` index 4 is out of range'));
    expect('$error', contains('the only index is 0'));
  });

  testWidgets('an nth index past several matches names the valid range', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Row(children: [Text('Buy'), Text('Buy'), Text('Buy')]),
      ),
    );
    var resolver = TargetResolver(tester);

    var error = await _refusal(
      () => resolver.resolve(const Target.nth('Buy', 7), 'tap'),
    );

    expect('$error', contains('"Buy" matches 3 widgets'));
    expect('$error', contains('valid indices are 0–2'));
  });

  testWidgets('an nth over a target matching nothing says the index is not '
      'the problem', (tester) async {
    await tester.pumpWidget(_covered());
    var resolver = TargetResolver(
      tester,
      describeScreen: () => visibleTextsOf(tester).join(', '),
    );

    var error = await _refusal(
      () => resolver.resolve(const Target.nth('Moderate', 1), 'drag'),
    );

    expect(error.failure, TargetFailure.notFound);
    expect('$error', contains('`nth` has nothing to index'));
    expect('$error', contains('"Moderate" matches nothing'));
    // The miss underneath still gets its usual treatment.
    expect('$error', contains('Visible text: Buy'));
    expect('$error', isNot(contains('out of range')));
  });

  testWidgets('a nested nth reports the level that actually ran out', (
    tester,
  ) async {
    await tester.pumpWidget(_covered());
    var resolver = TargetResolver(tester);

    var error = await _refusal(
      () => resolver.resolve(const Target.nth(Target.nth('Buy', 6), 0), 'tap'),
    );

    expect('$error', contains('"Buy" matches 1 widget'));
    expect('$error', contains('`nth` index 6 is out of range'));
  });

  testWidgets('a miss on a string that differs by an invisible character '
      'names the character', (tester) async {
    // The two strings below are not the same string: the rendered one holds a
    // literal U+202F before `PM`, the target a plain U+0020 — what modern ICU
    // emits against what anybody types. Said here because the source shows the
    // difference exactly as well as the screen does, which is not at all.
    await tester.pumpWidget(const MaterialApp(home: Text('Aug 17, 2:58 PM')));
    var resolver = TargetResolver(tester);

    var error = await _refusal(
      () => resolver.resolve('Aug 17, 2:58 PM', 'tap'),
    );

    expect(error.failure, TargetFailure.notFound);
    expect('$error', contains('differs from yours at character 12'));
    expect('$error', contains('yours has U+0020 SPACE'));
    expect('$error', contains('U+202F NARROW NO-BREAK SPACE'));
    expect('$error', contains(r'{"containing": "Aug 17, 2:58"}'));
    // The guess it replaces would have sent the reader scrolling.
    expect('$error', isNot(contains('lazy list')));
  });

  testWidgets('a miss on a string the screen only contains offers containing', (
    tester,
  ) async {
    await tester.pumpWidget(const MaterialApp(home: Text('Save changes')));
    var resolver = TargetResolver(tester);

    var error = await _refusal(() => resolver.resolve('Save', 'tap'));

    expect('$error', contains('"Save changes" is on screen'));
    expect('$error', contains('yours ends and the rendered one continues'));
    expect('$error', contains(r'{"containing": "Save"}'));
  });

  testWidgets('a numbered item further down a list is not a near miss', (
    tester,
  ) async {
    // "Item 40" shares six characters with "Item 4" and means nothing by it.
    // Reporting a divergence here would suppress the one hint that is right,
    // which is what `scrollTo` is for.
    await tester.pumpWidget(
      MaterialApp(
        home: ListView(children: [for (var i = 0; i < 8; i++) Text('Item $i')]),
      ),
    );
    var resolver = TargetResolver(tester);

    var error = await _refusal(() => resolver.resolve('Item 40', 'tap'));

    expect('$error', isNot(contains('differs from yours')));
    expect('$error', contains('`scrollTo` walks to it'));
  });

  testWidgets('a scrollable screen names the empty-list cause beside the '
      'lazy-list one', (tester) async {
    // The other reason "nothing matches" on a list screen: the list is empty
    // — a seeding bug, an unpinned clock — and no amount of scrolling will
    // build the row. The visible text beside the guess is what says which.
    await tester.pumpWidget(
      MaterialApp(
        home: Column(
          children: [
            const Text('Bookings'),
            Expanded(child: ListView(children: const [])),
          ],
        ),
      ),
    );
    var resolver = TargetResolver(
      tester,
      describeScreen: () => visibleTextsOf(tester).join(', '),
    );

    var error = await _refusal(
      () => resolver.resolve('Visit Dr. Aubrey', 'tap'),
    );

    expect('$error', contains('`scrollTo` walks to it'));
    expect('$error', contains('or the list that would hold it is empty'));
    expect('$error', contains('Visible text: Bookings'));
  });

  testWidgets('a trailing invisible character is still a near miss', (
    tester,
  ) async {
    await tester.pumpWidget(const MaterialApp(home: Text('Checkout')));
    var resolver = TargetResolver(tester);

    var error = await _refusal(() => resolver.resolve('Checkout ', 'tap'));

    expect('$error', contains('yours has U+0020 SPACE'));
    expect('$error', contains('nothing — it ends there'));
  });

  testWidgets('two unrelated words are not reported as a near miss', (
    tester,
  ) async {
    await tester.pumpWidget(const MaterialApp(home: Text('Buy')));
    var resolver = TargetResolver(tester);

    var error = await _refusal(() => resolver.resolve('Back', 'tap'));

    expect('$error', isNot(contains('differs from yours')));
    expect('$error', contains('Nothing on this screen scrolls'));
  });

  testWidgets('a miss on words the semantics tree carries names label', (
    tester,
  ) async {
    // A `Slider.label` is what `screen` reports as the control's words, and
    // it is not a rendered `Text` at rest — the trap this refusal exists for.
    await tester.pumpWidget(
      MaterialApp(
        home: Material(
          child: Slider(
            value: 5,
            max: 10,
            divisions: 10,
            label: '5 — Moderate',
            onChanged: (_) {},
          ),
        ),
      ),
    );
    var resolver = TargetResolver(tester);

    var error = await _refusal(() => resolver.resolve('5 — Moderate', 'drag'));

    expect(error.failure, TargetFailure.notFound);
    expect('$error', contains('No *rendered* text matches'));
    expect('$error', contains('1 semantics label does'));
    expect('$error', contains(r'{"label": …}'));
    expect('$error', isNot(contains('lazy list')));
    // And the target it names does resolve.
    var finder = await resolver.resolve(
      const Target.label('5 — Moderate'),
      'drag',
    );
    expect(finder.evaluate(), hasLength(1));
  });

  testWidgets('a miss on words only a tooltip carries names tooltip', (
    tester,
  ) async {
    // The other half of the same trap, and the one the live GUI actually
    // produced: `screen` falls back to the tooltip for a control with no
    // label and no text, so its `w` is unreachable as bare text too.
    await tester.pumpWidget(
      const MaterialApp(
        home: Material(
          child: Tooltip(message: 'Reload (⌘R)', child: Icon(Icons.refresh)),
        ),
      ),
    );
    var resolver = TargetResolver(tester);

    var error = await _refusal(() => resolver.resolve('Reload (⌘R)', 'tap'));

    expect('$error', contains('1 tooltip does'));
    expect('$error', contains(r'{"tooltip": …}'));

    var finder = await resolver.resolve(
      const Target.tooltip('Reload (⌘R)'),
      'tap',
    );
    expect(finder.evaluate(), isNotEmpty);
  });

  testWidgets('the semantics probe stays quiet when semantics is off', (
    tester,
  ) async {
    await tester.pumpWidget(const MaterialApp(home: Text('Buy')));
    var resolver = TargetResolver(tester);

    var error = await _refusal(() => resolver.resolve('Add to cart', 'tap'));

    expect('$error', isNot(contains('semantics label')));
    expect('$error', contains('Nothing on this screen scrolls'));
  }, semanticsEnabled: false);

  testWidgets('below the fold resolves after the ladder scrolls to it', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: Column(
              children: [
                const SizedBox(height: 2000),
                TextButton(onPressed: () {}, child: const Text('Buy')),
              ],
            ),
          ),
        ),
      ),
    );
    var resolver = TargetResolver(tester);

    var finder = await resolver.resolve('Buy', 'tap');

    await tester.tap(finder, warnIfMissed: true);
  });

  /// Reported by a consumer driving a form. `item:` is documented as the
  /// way to reach a control with no words, a field whose label floats above
  /// it is exactly that, and `enterText` on one refused with "contains 0 text
  /// fields" — about a field the reply's own screen had just listed.
  testWidgets('a point inside a field finds the editable above it', (
    tester,
  ) async {
    await tester.pumpWidget(_form());
    var box = tester.getRect(find.byType(TextField));
    var resolver = TargetResolver(tester);

    var finder = await resolver.resolve(
      Target.at(box.center.dx, box.center.dy),
      'enterText',
    );

    // The point itself resolves below the editable — that is the bug — so it
    // is the walk up that has to produce exactly one field.
    expect(
      find
          .descendant(
            of: finder,
            matching: find.byType(EditableText),
            matchRoot: true,
          )
          .evaluate(),
      isEmpty,
    );
    expect(editableWithin(finder).evaluate(), hasLength(1));
  });

  testWidgets('a target above the editable still finds it downwards', (
    tester,
  ) async {
    await tester.pumpWidget(_form());

    expect(editableWithin(find.byType(TextField)).evaluate(), hasLength(1));
  });

  testWidgets('nothing enclosing a target that is no field', (tester) async {
    await tester.pumpWidget(_form());

    expect(editableWithin(find.text('Sign in')).evaluate(), isEmpty);
  });

  /// Reported alongside the one above. A `labelText` is a visible string,
  /// so the bare target matches it, and the generic covered sentence sent the
  /// reader looking for whatever was on top of the field they were aiming at.
  testWidgets("a field label is refused with the field's own centre", (
    tester,
  ) async {
    await tester.pumpWidget(_form());
    var resolver = TargetResolver(tester);

    var error = await _refusal(
      () => resolver.resolve('Phone number', 'enterText'),
    );

    expect(error.failure, TargetFailure.covered);
    expect(
      '$error',
      contains('"Phone number" belongs to a text field\'s decoration'),
    );
    var box = tester.getRect(find.byType(InputDecorator));
    expect(
      '$error',
      contains(
        '{"x": ${box.center.dx.round()}, "y": ${box.center.dy.round()}}',
      ),
    );
    // And the address it hands back is one that works.
    var finder = await resolver.resolve(
      Target.at(box.center.dx, box.center.dy),
      'enterText',
    );
    expect(editableWithin(finder).evaluate(), hasLength(1));
  });

  testWidgets('the label form is offered once it can be checked', (
    tester,
  ) async {
    var semantics = tester.ensureSemantics();
    await tester.pumpWidget(_form());
    var resolver = TargetResolver(tester);

    var error = await _refusal(
      () => resolver.resolve('Phone number', 'enterText'),
    );

    expect('$error', contains('`{"label": "Phone number"}`'));
    // Checked by resolving it, which is what the refusal claims of it.
    var finder = await resolver.resolve(
      const Target.label('Phone number'),
      'enterText',
    );
    expect(editableWithin(finder).evaluate(), hasLength(1));
    semantics.dispose();
  });

  /// The live GUI disproved the first version of this message, which
  /// offered `{"label": …}` for whatever it read off the decoration: on the
  /// studio's own filter field the offered label found nothing, because a
  /// word had just been typed into it. So the string is resolved before it is
  /// offered, and a field the semantics tree does not carry gets the point
  /// alone.
  testWidgets('a label the semantics tree does not carry is not offered', (
    tester,
  ) async {
    var semantics = tester.ensureSemantics();
    await tester.pumpWidget(_form(excludeSemantics: true));
    var resolver = TargetResolver(tester);

    var error = await _refusal(
      () => resolver.resolve('Phone number', 'enterText'),
    );

    expect('$error', contains("belongs to a text field's decoration"));
    expect('$error', isNot(contains('"label"')));
    semantics.dispose();
  });

  testWidgets('a decoration with neither offers only the point', (
    tester,
  ) async {
    var semantics = tester.ensureSemantics();
    await tester.pumpWidget(_form(label: null, prefix: '+32'));
    var resolver = TargetResolver(tester);

    var error = await _refusal(() => resolver.resolve('+32', 'enterText'));

    expect('$error', contains("belongs to a text field's decoration"));
    expect('$error', isNot(contains('"label"')));
    expect('$error', contains('its centre'));
    semantics.dispose();
  });

  testWidgets('an ordinary covering keeps the ordinary sentence', (
    tester,
  ) async {
    await tester.pumpWidget(_covered());
    var resolver = TargetResolver(tester);

    var error = await _refusal(() => resolver.resolve('Buy', 'tap'));

    expect('$error', contains('another widget covers it'));
    expect('$error', isNot(contains('decoration')));
  });
}

/// A field whose only words are its decoration's — the shape both consumer
/// reports were made on.
Widget _form({
  String? label = 'Phone number',
  String? hint,
  String? prefix,
  bool excludeSemantics = false,
}) {
  Widget field = TextField(
    decoration: InputDecoration(
      labelText: label,
      hintText: hint,
      prefixText: prefix,
    ),
  );
  if (excludeSemantics) field = ExcludeSemantics(child: field);
  return MaterialApp(
    home: Scaffold(body: Column(children: [const Text('Sign in'), field])),
  );
}

Widget _covered() => MaterialApp(
  home: Stack(
    children: [
      Center(
        child: TextButton(onPressed: () {}, child: const Text('Buy')),
      ),
      Positioned.fill(
        child: GestureDetector(behavior: HitTestBehavior.opaque, onTap: () {}),
      ),
    ],
  ),
);

Future<TargetError> _refusal(Future<Object?> Function() act) async {
  try {
    await act();
  } on TargetError catch (error) {
    return error;
  }
  fail('expected a TargetError');
}
