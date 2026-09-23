import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutterware/previews_guest.dart';
import 'package:flutterware/plugins.dart';
import 'package:flutterware_app/src/address/address_scope.dart';
import 'package:flutterware_app/src/previews/catalog_entry.dart';
import 'package:flutterware_app/src/previews/catalog_session.dart';
import 'package:flutterware_app/src/previews/catalog_view.dart';
import 'package:flutterware_app/src/previews/protocol.dart';
import 'package:flutterware_app/src/ui/aside.dart';

/// What the panel does when a demo stops compiling.
///
/// Reachable without a guest because a broken selection renders the error
/// instead of the texture — which is the behaviour under test.
void main() {
  const alpha = CatalogEntry(
    path: 'demo/a.dart',
    symbol: 'alpha',
    annotation: "Demo(name: 'Alpha')",
    name: 'Alpha',
  );
  const beta = CatalogEntry(
    path: 'demo/b.dart',
    symbol: 'beta',
    annotation: "Demo(name: 'Beta')",
    name: 'Beta',
  );
  const gamma = CatalogEntry(
    path: 'demo/c.dart',
    symbol: 'gamma',
    annotation: "Demo(name: 'Gamma')",
    name: 'Gamma',
  );

  CatalogSession sessionOf(
    List<CatalogEntry> all,
    CatalogEntry broken,
    String error,
  ) {
    return CatalogSession(
        appPackageRoot: '/app',
        flutterSdkRoot: '/sdk',
        projectRoot: '/project',
      )
      ..phase = CatalogSessionPhase.ready
      ..entries = [
        for (var e in all)
          if (e.id != broken.id) e,
      ]
      ..quarantined = [QuarantinedEntry(entry: broken, error: error)]
      ..selected = broken
      ..active = all.first;
  }

  // Every case here keeps one entry broken and selected: that is what renders
  // the error page instead of the guest's texture, which no widget test has.
  CatalogSession sessionWithBroken(CatalogEntry broken, String error) =>
      sessionOf([alpha, beta, gamma], broken, error);

  // Private to the view, so found by type name: it replaced a Material Switch,
  // which was both oversized for a 36-pixel bar and the one control on the row
  // not drawn from the palette.
  final toggles = find.byWidgetPredicate(
    (w) => w.runtimeType.toString() == '_Toggle',
  );

  // The view reads what it is staged as from the address and writes picks back
  // to it, so a test needs one. Exposed so a test can assert on the address
  // rather than on a field, which is the whole point of the change.
  late ValueNotifier<Address> address;

  // The shell's half of the fold, stood in for: the panel reaches the rail
  // through these two and never through a [ShellController], which is what lets
  // one button fold both without the catalog knowing what a shell is.
  late bool railVisible;
  late AsideVisibility aside;

  setUp(() {
    railVisible = true;
    aside = AsideVisibility(
      railVisible: () => railVisible,
      setRailVisible: (value) => railVisible = value,
    );
  });

  Future<void> pump(
    WidgetTester tester,
    CatalogSession session, {
    String? device,
    Map<String, String> axes = const {},
    Map<String, String> knobs = const {},
    // The knobs are a tab now rather than a drawer that is always there, so a
    // test that wants them has to be looking at them — which is the same thing
    // a person has to do.
    //
    // Null leaves the tab alone rather than defaulting it, because a second
    // `pump` in one test means "the panel rebuilt", and a rebuild that flipped
    // you back to another tab would be testing the opposite of what is true.
    InspectTab? tab,
  }) {
    // Opening the tab also opens the panel, which now starts closed: a test
    // that wants a tab has to be looking at it, which is the same thing a
    // person has to do.
    if (tab != null) {
      session
        ..inspectTab = tab
        ..panelCollapsed = false;
    }
    address = ValueNotifier(
      Address(
        worktree: 'test',
        plugin: 'flutterware.previews',
        axes: {
          'device': ?device,
          for (var axis in axes.entries) 'axis.${axis.key}': axis.value,
          for (var knob in knobs.entries) 'knob.${knob.key}': knob.value,
        },
      ),
    );
    return tester.pumpWidget(
      MaterialApp(
        home: AddressRoot(
          address: address,
          onChanged: (next) => address.value = next,
          // The scope the shell puts above every panel. Without it the list
          // cannot be folded at all — which is the honest answer for the
          // exported page, and the wrong one for a test about the panel.
          child: AsideScope(
            aside: aside,
            child: Scaffold(body: CatalogView(session: session)),
          ),
        ),
      ),
    );
  }

  /// [name] as the *tree* shows it.
  ///
  /// The demo's name is in two places now: its row here, and the title above
  /// the stage that says what is on it and carries the way back off it. A bare
  /// `find.text` would be ambiguous for whichever entry is selected, and
  /// ambiguous only sometimes — which is worse than ambiguous always.
  Finder treeText(String name) =>
      find.descendant(of: find.byType(ListView), matching: find.text(name));

  /// A folder's chevron, which is the only thing that folds it now.
  ///
  /// The row itself picks what the pane beside the tree shows, so the two had
  /// to stop being one target: a click that both folded a branch and changed
  /// what was on screen was one gesture with two results and no way to ask for
  /// either alone.
  Finder foldOf(String folder) => find
      .descendant(
        of: find.ancestor(of: treeText(folder), matching: find.byType(Row)),
        matching: find.byType(Icon),
      )
      .first;

  testWidgets('a broken entry keeps its place in the tree', (tester) async {
    var session = sessionWithBroken(beta, 'boom');
    await pump(tester, session);

    // Ordered by where they sit on screen, which is the claim: a demo that
    // stops compiling does not move.
    double y(String name) => tester.getTopLeft(treeText(name)).dy;
    expect(y('Alpha'), lessThan(y('Beta')));
    expect(y('Beta'), lessThan(y('Gamma')));
  });

  testWidgets('a broken entry stays tappable, because that is the retry', (
    tester,
  ) async {
    var session = sessionWithBroken(beta, 'boom');
    await pump(tester, session);

    var row = tester.widget<InkWell>(
      find
          .ancestor(of: find.text('Beta'), matching: find.byType(InkWell))
          .first,
    );
    expect(row.onTap, isNotNull);
  });

  testWidgets('a click shows as selected before anything is compiled', (
    tester,
  ) async {
    // `switchTo` sets `selected` and queues the compile. Without a notify at
    // the moment of asking, the row did not light until the queue reached it —
    // and for a quarantined entry that means waiting out a fresh compile
    // attempt, seconds of it. Nothing moved, so you clicked again, and queued
    // another. It took about five before one landed.
    // *Both* broken, and starting on the other one. A compiling entry sends
    // the canvas to the texture, which a widget test has no guest for — the
    // reason every case in this file keeps its selection on something that
    // does not build.
    var session =
        CatalogSession(
            appPackageRoot: '/app',
            flutterSdkRoot: '/sdk',
            projectRoot: '/project',
          )
          ..phase = CatalogSessionPhase.ready
          ..entries = const [gamma]
          ..quarantined = const [
            QuarantinedEntry(entry: alpha, error: 'boom'),
            QuarantinedEntry(entry: beta, error: 'boom'),
          ]
          ..selected = alpha
          ..active = alpha;
    await pump(tester, session);

    Color? colourOf(String name) => tester
        .widgetList<Container>(
          find.ancestor(of: find.text(name), matching: find.byType(Container)),
        )
        .map((c) => c.color)
        .firstWhere((c) => c != null, orElse: () => null);
    var unselected = colourOf('Beta');

    await tester.tap(find.text('Beta'));
    // One pump, not `pumpAndSettle`: the claim is that it lands on the very
    // next frame rather than at the far end of a queue.
    await tester.pump();

    expect(colourOf('Beta'), isNot(unselected));
  });

  testWidgets('the filter narrows the tree', (tester) async {
    var session = sessionWithBroken(beta, 'boom');
    await pump(tester, session);

    session.browsing.filter = 'alp';
    await tester.pump();

    expect(treeText('Alpha'), findsOneWidget);
    expect(treeText('Beta'), findsNothing);
    expect(treeText('Gamma'), findsNothing);
  });

  testWidgets('a filter that matches nothing says so', (tester) async {
    var session = sessionWithBroken(beta, 'boom');
    await pump(tester, session);

    session.browsing.filter = 'zzz';
    await tester.pump();

    expect(find.text('Nothing matches'), findsOneWidget);
  });

  testWidgets('folders fold', (tester) async {
    const one = CatalogEntry(
      path: 'demo/team/one.dart',
      symbol: 'one',
      annotation: 'Demo()',
      name: 'One',
    );
    const two = CatalogEntry(
      path: 'demo/billing/two.dart',
      symbol: 'two',
      annotation: 'Demo()',
      name: 'Two',
    );
    var session = sessionOf([one, two, beta], beta, 'boom');
    await pump(tester, session);
    expect(find.text('One'), findsOneWidget);

    await tester.tap(foldOf('team'));
    await tester.pump();
    expect(find.text('One'), findsNothing);
    expect(find.text('team'), findsOneWidget, reason: 'the folder remains');
    expect(find.text('Two'), findsOneWidget, reason: 'its neighbour is intact');
  });

  testWidgets('and the folder row itself does not fold them', (tester) async {
    // The row's job is to say what the pane shows. It used to fold as well,
    // from the same click, which meant neither could be asked for on its own.
    const one = CatalogEntry(
      path: 'demo/team/one.dart',
      symbol: 'one',
      annotation: 'Demo()',
      name: 'One',
    );
    var session = sessionOf([one, beta], beta, 'boom');
    await pump(tester, session);
    expect(treeText('One'), findsOneWidget);

    await tester.tap(treeText('team'));
    await tester.pump();

    expect(treeText('One'), findsOneWidget, reason: 'still open');
  });

  group('the folder around the selection', () {
    const inside = CatalogEntry(
      path: 'demo/team/one.dart',
      symbol: 'one',
      annotation: 'Demo()',
      name: 'One',
    );
    const outside = CatalogEntry(
      path: 'demo/billing/two.dart',
      symbol: 'two',
      annotation: 'Demo()',
      name: 'Two',
    );

    testWidgets('folds, like every other folder', (tester) async {
      // It used to be held open for as long as it held the selection: the
      // click landed in the closed set, the row did not move, and the only
      // visible effect anywhere was the collapse-all button changing its mind.
      var session = sessionOf([inside, outside], inside, 'boom');
      await pump(tester, session);
      expect(treeText('One'), findsOneWidget);

      await tester.tap(foldOf('team'));
      await tester.pump();

      expect(treeText('One'), findsNothing);
      expect(session.selected?.id, inside.id, reason: 'and it is still yours');
    });

    testWidgets('and stays folded when you come back to the panel', (
      tester,
    ) async {
      // The mark lives on the session for this: kept in the panel, every
      // return would re-reveal the selection and undo the fold.
      var session = sessionOf([inside, outside], inside, 'boom');
      await pump(tester, session);
      await tester.tap(foldOf('team'));
      await tester.pump();

      await pump(tester, session);
      expect(treeText('One'), findsNothing);
    });

    testWidgets('opens once for a selection that arrives folded away', (
      tester,
    ) async {
      // A selection is not always made in the tree — an address names one, and
      // the daemon can move you off an entry it can no longer build.
      //
      // Both broken, and for the reason every case in this file keeps one
      // broken: a selection that compiles sends the canvas to the texture,
      // which a widget test has no guest for.
      var session =
          CatalogSession(
              appPackageRoot: '/app',
              flutterSdkRoot: '/sdk',
              projectRoot: '/project',
            )
            ..phase = CatalogSessionPhase.ready
            ..quarantined = const [
              QuarantinedEntry(entry: inside, error: 'boom'),
              QuarantinedEntry(entry: outside, error: 'boom'),
            ]
            ..selected = inside;
      await pump(tester, session);
      await tester.tap(foldOf('team'));
      await tester.pump();
      expect(treeText('One'), findsNothing);

      session
        ..selected = outside
        ..notifyListeners();
      await tester.pump();
      session
        ..selected = inside
        ..notifyListeners();
      // Twice: the reveal runs after the frame that noticed the selection, and
      // opening a folder is a notify of its own.
      await tester.pump();
      await tester.pump();

      expect(treeText('One'), findsOneWidget);
    });
  });

  testWidgets('a switch that has to compile says so over the old picture', (
    tester,
  ) async {
    // Only the slow path ever gets here: the guest switches most entries by
    // itself in a frame, and a loader that came and went inside one would be a
    // flash on every click.
    var session = sessionWithBroken(beta, 'boom');
    await pump(tester, session);
    expect(find.text('Beta doesn’t compile'), findsOneWidget);

    session
      ..compilingSwitch = gamma
      ..notifyListeners();
    await tester.pump();

    expect(find.text('Gamma'), findsAtLeastNWidgets(1));
    expect(find.text('Compiling…'), findsOneWidget);
    expect(
      find.byType(CircularProgressIndicator),
      findsOneWidget,
      reason: 'a spinner, because this is the case that takes seconds',
    );
  });

  testWidgets('expanding folds the rail with the list, and leaves the way '
      'back', (tester) async {
    var session = sessionWithBroken(beta, 'boom');
    await pump(tester, session);

    await tester.tap(find.byTooltip('Expand the panel (⌥⌘B)'));
    await tester.pump();
    expect(find.text('Alpha'), findsNothing);
    expect(railVisible, isFalse, reason: 'one verb, both panes');

    await tester.tap(find.byTooltip('Restore the panels (⌥⌘B)'));
    await tester.pump();
    expect(find.text('Alpha'), findsOneWidget);
    expect(railVisible, isTrue);
  });

  testWidgets('restoring gives back a rail that was already hidden — as '
      'hidden', (tester) async {
    var session = sessionWithBroken(beta, 'boom');
    railVisible = false;
    await pump(tester, session);

    await tester.tap(find.byTooltip('Expand the panel (⌥⌘B)'));
    await tester.pump();
    // With the rail already gone the gutter still offers everything back,
    // because everything that is gone is the aside.
    await tester.tap(find.byTooltip('Restore the panels (⌥⌘B)'));
    await tester.pump();

    expect(find.text('Alpha'), findsOneWidget);
    expect(
      railVisible,
      isFalse,
      reason: 'restore undoes expand, not a choice somebody made before it',
    );
  });

  testWidgets('the compiler error is shown where the widget would be', (
    tester,
  ) async {
    var session = sessionWithBroken(
      beta,
      "demo/b.dart:3:7: Error: The method 'Nope' isn't defined.",
    );
    await pump(tester, session);

    expect(find.text('Beta doesn’t compile'), findsOneWidget);
    expect(
      find.text('demo/b.dart · beta'),
      findsOneWidget,
      reason: 'the header says which file to go and fix',
    );
    // The error is selectable, so it is both a Text and the EditableText
    // underneath it — what matters is that the compiler's own words are on
    // screen rather than a summary of them.
    expect(
      find.textContaining("The method 'Nope' isn't defined"),
      findsAtLeastNWidgets(1),
    );
    expect(find.text('Retry'), findsOneWidget);
  });

  testWidgets('the status bar keeps its height when a switch fails', (
    tester,
  ) async {
    var session = sessionWithBroken(beta, 'boom');
    await pump(tester, session);
    var bar = find
        .ancestor(
          of: find.byIcon(Icons.refresh),
          matching: find.byType(Container),
        )
        .last;
    var idle = tester.getSize(bar);
    expect(idle.height, 32);

    // A failure used to add a button to the row, and the button was taller
    // than the text it stood next to.
    session
      ..lastSwitch = SwitchReport(
        entry: beta,
        compile: const Duration(milliseconds: 1234),
        reload: Duration.zero,
        newSourceCount: 0,
        editedCount: 1,
        reloaded: true,
        error: 'boom',
      )
      ..notifyListeners();
    await tester.pump();

    expect(tester.getSize(bar), idle);
  });

  testWidgets('the filter field keeps its height as you type', (tester) async {
    var session = sessionWithBroken(beta, 'boom');
    await pump(tester, session);
    var field = find.byType(TextField);
    var empty = tester.getSize(field);

    // The clear button appears with the first character, and an
    // InputDecorator sizes itself around its icons.
    await tester.enterText(field, 'a');
    await tester.pump();

    expect(tester.getSize(field), empty);
  });

  testWidgets('a filtered row marks what matched', (tester) async {
    var session = sessionWithBroken(beta, 'boom');
    await pump(tester, session);
    session.browsing.filter = 'lph';
    await tester.pump();

    var marked = tester.widget<Text>(
      find
          .ancestor(
            of: find.text('Alpha', findRichText: true),
            matching: find.byType(Text),
          )
          .first,
    );
    var spans = (marked.textSpan! as TextSpan).children!.cast<TextSpan>();
    expect(spans.map((s) => s.text), ['A', 'lph', 'a']);
    expect(
      spans[1].style?.backgroundColor,
      isNotNull,
      reason: 'the matched run is the highlighted one',
    );
    expect(spans[0].style?.backgroundColor, isNull);
  });

  testWidgets('the busy dot waits before it shows itself', (tester) async {
    // Driven directly: what is under test is the timing, and a switch that
    // lands inside the delay must never show anything — a 90ms compile that
    // blinks at you reads as a fault, not as progress.
    Future<void> show(String? busy) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: BusyDot(busy: busy)),
        ),
      );
    }

    double opacity() =>
        tester.widget<AnimatedOpacity>(find.byType(AnimatedOpacity)).opacity;

    await show(null);
    expect(opacity(), 0);

    await show('compiling');
    expect(opacity(), 0);
    await tester.pump(const Duration(milliseconds: 100));
    expect(opacity(), 0, reason: 'a warm switch is over before this');

    await tester.pump(const Duration(milliseconds: 200));
    expect(opacity(), 1);

    await show(null);
    expect(opacity(), 0);
    await tester.pumpAndSettle();
  });

  // A long catalog arrives as a table of contents rather than as a list you
  // are already scrolling. The threshold is a paneful — see `treeRowBudget` —
  // and the three-entry catalog every other test here uses is well under it,
  // which is why they all find their entries on the first pump.
  testWidgets('a catalog too long for the pane opens folded', (tester) async {
    var many = [
      for (var i = 0; i < 16; i++)
        CatalogEntry(
          path: 'demo/left/e$i.dart',
          symbol: 'left$i',
          annotation: 'Demo()',
          name: 'Left $i',
        ),
      for (var i = 0; i < 16; i++)
        CatalogEntry(
          path: 'demo/right/e$i.dart',
          symbol: 'right$i',
          annotation: 'Demo()',
          name: 'Right $i',
        ),
    ];
    // 34 rows with everything open: two folders and thirty-two entries.
    await pump(tester, sessionOf([...many, beta], beta, 'boom'));

    expect(find.text('left'), findsOneWidget);
    expect(find.text('right'), findsOneWidget);
    expect(treeText('Left 0'), findsNothing);
    expect(treeText('Right 0'), findsNothing);
    expect(
      find.byTooltip('Expand all'),
      findsOneWidget,
      reason:
          'the button reads the same set the tree does, so it offers the '
          'direction the fold left open',
    );

    // Folded is not hidden: a folder opens on a click like any other.
    await tester.tap(find.text('left'));
    await tester.pump();
    expect(treeText('Left 0'), findsOneWidget);
    expect(treeText('Right 0'), findsNothing);

    // And the two rules compose. A fresh catalog this long folds, and then
    // opens the branches over whatever is selected: the entry the panel is
    // showing is never one you have to go looking for.
    await pump(tester, sessionOf([...many, beta], many.first, 'boom'));
    await tester.pump();
    expect(treeText('Left 0'), findsOneWidget);
    expect(treeText('Right 0'), findsNothing);
  });

  testWidgets('one button folds everything, then unfolds it', (tester) async {
    const one = CatalogEntry(
      path: 'demo/team/one.dart',
      symbol: 'one',
      annotation: 'Demo()',
      name: 'One',
    );
    var session = sessionOf([one, beta], beta, 'boom');
    await pump(tester, session);
    expect(find.text('One'), findsOneWidget);

    await tester.tap(find.byTooltip('Collapse all'));
    await tester.pump();
    expect(find.text('One'), findsNothing);

    await tester.tap(find.byTooltip('Expand all'));
    await tester.pump();
    expect(find.text('One'), findsOneWidget);
  });

  group('the top bar', () {
    testWidgets('starts on Fit, with nothing to turn or to frame', (
      tester,
    ) async {
      await pump(tester, sessionWithBroken(beta, 'boom'));

      expect(find.text('Fit'), findsOneWidget);
      expect(
        find.byTooltip('Hide the frame'),
        findsNothing,
        reason: 'there is no frame to hide until there is a device',
      );
      // Dim rather than gone, both of them: the capsule keeps its width, so
      // picking a phone does not reflow the bar under the pointer that picked
      // it — and a control that says why it cannot act beats one that vanished.
      expect(find.byTooltip('Fit is drawn without a body'), findsOneWidget);
      expect(find.byTooltip('The panel does not rotate'), findsOneWidget);
    });

    testWidgets('picking a device sizes the guest to its screen', (
      tester,
    ) async {
      var session = sessionWithBroken(beta, 'boom');
      await pump(tester, session);

      await tester.tap(find.text('Fit'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('iPhone 13').last);
      await tester.pumpAndSettle();

      // Into the address, not into a field on the session. That is the fix:
      // one place holds it, and the picture is read back from there.
      expect(address.value.axes['device'], 'iphone-13');
      // The screen in logical pixels, which is the number a layout is written
      // against — not the physical one the guest is actually rendering.
      expect(find.text('390×844'), findsOneWidget);
      expect(find.text('iPhone 13'), findsOneWidget);
    });

    testWidgets('the frame can be taken off once there is one', (tester) async {
      var session = sessionWithBroken(beta, 'boom');
      await pump(tester, session, device: 'iphone-13');

      await tester.tap(find.byTooltip('Hide the frame'));
      await tester.pump();

      expect(session.staging.frameVisible, isFalse);
      expect(find.byTooltip('Show the frame'), findsOneWidget);
    });

    testWidgets('a window has no body, so the switch does not offer one', (
      tester,
    ) async {
      // It used to be live here and change nothing: a desktop size gets no
      // silhouette, so the toggle was switching a picture that is never drawn.
      var session = sessionWithBroken(beta, 'boom');
      await pump(tester, session, device: 'window-wide');

      expect(find.byTooltip('Wide window is drawn without a body'), findsOne);
      await tester.tap(find.byTooltip('Wide window is drawn without a body'));
      await tester.pump();
      expect(session.staging.frameVisible, isTrue, reason: 'untouched');
    });
  });

  group('the device', () {
    // Selected *and* broken, so the canvas renders the compile error rather
    // than a texture — the only way in without a live guest engine. The top
    // bar draws either way, which is what these are about.
    const plain = CatalogEntry(
      path: 'demo/m.dart',
      symbol: 'm',
      annotation: 'Preview()',
      name: 'M',
    );

    testWidgets('comes from the address alone, so no parameter is no frame', (
      tester,
    ) async {
      // An entry used to get a say through `formFactor`, and a phone here was
      // a default computed from the declaration. Nothing declares one now.
      await pump(tester, sessionOf([plain, alpha], plain, 'boom'));

      expect(find.text('iPhone 13'), findsNothing);
      expect(address.value.axes, isEmpty, reason: 'a default is not a choice');
    });

    testWidgets('and a chosen one is shown', (tester) async {
      await pump(
        tester,
        sessionOf([plain, alpha], plain, 'boom'),
        device: 'ipad',
      );

      expect(find.text('iPad'), findsOneWidget);
    });

    testWidgets('and fit reads as the panel', (tester) async {
      await pump(
        tester,
        sessionOf([plain, alpha], plain, 'boom'),
        device: 'fit',
      );

      expect(find.text('Fit'), findsOneWidget);
    });
  });

  group('the knob panel', () {
    KnobReport report(List<KnobDescriptor> knobs) =>
        KnobReport(entryId: beta.id, knobs: knobs);

    testWidgets('says so when the entry declares none, rather than vanishing', (
      tester,
    ) async {
      // The drawer this replaced was *absent* when an entry had no knobs,
      // which meant anybody who had not happened to open a demo with knobs
      // never learned they existed. Empty and explaining itself beats gone.
      await pump(
        tester,
        sessionWithBroken(beta, 'boom'),
        tab: InspectTab.controls,
      );
      expect(find.byType(Slider), findsNothing);
      expect(toggles, findsNothing);
      expect(find.textContaining('declares no knobs'), findsOneWidget);
    });

    testWidgets('is what the panel opens on', (tester) async {
      // Not Elements: the everyday loop is turning a knob and watching the
      // demo, and a panel that opens onto a wall of widget rows has an opinion
      // about what you came here to do. The panel itself starts folded away —
      // see `the panel` in inspect_panel_test — so this is about which tab is
      // there when you open it, not about what is on screen at rest.
      var session = sessionWithBroken(beta, 'boom');
      await pump(tester, session);
      expect(find.text('Controls'), findsOneWidget);
      expect(find.textContaining('declares no knobs'), findsNothing);

      await tester.tap(find.byTooltip('Show the panel'));
      await tester.pump();
      expect(session.inspectTab, InspectTab.controls);
      expect(find.textContaining('declares no knobs'), findsOneWidget);
    });

    testWidgets('renders a control per kind', (tester) async {
      var session = sessionWithBroken(beta, 'boom')
        ..knobs = report(const [
          KnobDescriptor(
            name: 'label',
            kind: KnobKind.string,
            value: 'Hello',
            defaultValue: 'Hello',
          ),
          KnobDescriptor(
            name: 'count',
            kind: KnobKind.integer,
            value: 2,
            defaultValue: 2,
            min: 0,
            max: 9,
          ),
          KnobDescriptor(
            name: 'dense',
            kind: KnobKind.boolean,
            value: false,
            defaultValue: false,
          ),
        ]);
      await pump(tester, session, tab: InspectTab.controls);

      expect(find.text('label'), findsOneWidget);
      expect(find.text('count'), findsOneWidget);
      expect(find.text('dense'), findsOneWidget);
      // Bounded, so it slides; the value reads out beside it.
      expect(find.byType(Slider), findsOneWidget);
      expect(toggles, findsOneWidget);
    });

    testWidgets('a number with no bounds is a field, not a slider', (
      tester,
    ) async {
      var session = sessionWithBroken(beta, 'boom')
        ..knobs = report(const [
          KnobDescriptor(
            name: 'ratio',
            kind: KnobKind.number,
            value: 1.5,
            defaultValue: 1.5,
          ),
        ]);
      await pump(tester, session, tab: InspectTab.controls);

      expect(find.byType(Slider), findsNothing);
      expect(find.text('1.5'), findsOneWidget);
    });

    testWidgets('a knob that has moved is legible against one that has not', (
      tester,
    ) async {
      var session = sessionWithBroken(beta, 'boom')
        ..knobs = report(const [
          KnobDescriptor(
            name: 'moved',
            kind: KnobKind.string,
            value: 'changed',
            defaultValue: 'Hello',
          ),
          KnobDescriptor(
            name: 'resting',
            kind: KnobKind.string,
            value: 'Hello',
            defaultValue: 'Hello',
          ),
        ]);
      // Moved because the *address* says so. The report's own `value` is the
      // demo's confirmation and does not decide what is drawn.
      await pump(
        tester,
        session,
        knobs: const {'moved': 'changed'},
        tab: InspectTab.controls,
      );

      Color colorOf(String name) =>
          tester.widget<Text>(find.text(name)).style!.color!;
      expect(colorOf('moved'), isNot(colorOf('resting')));
    });

    testWidgets('a field keeps what you typed when another knob moves', (
      tester,
    ) async {
      // The panel rebuilds whenever any knob changes — a slider settling, a
      // value read back from the guest — and a field that rebuilt its own
      // controller would throw away the half-typed number sitting in it.
      var session = sessionWithBroken(beta, 'boom')
        ..knobs = report(const [
          KnobDescriptor(
            name: 'ratio',
            kind: KnobKind.number,
            value: 1.5,
            defaultValue: 1.5,
          ),
          KnobDescriptor(
            name: 'dense',
            kind: KnobKind.boolean,
            value: false,
            defaultValue: false,
          ),
        ]);
      await pump(tester, session, tab: InspectTab.controls);

      await tester.enterText(find.widgetWithText(TextField, '1.5'), '12');
      session.knobs = report(const [
        KnobDescriptor(
          name: 'ratio',
          kind: KnobKind.number,
          value: 1.5,
          defaultValue: 1.5,
        ),
        KnobDescriptor(
          name: 'dense',
          kind: KnobKind.boolean,
          value: true,
          defaultValue: false,
        ),
      ]);
      await pump(tester, session);

      expect(find.text('12'), findsOneWidget);
    });
  });

  group('the top bar axes', () {
    AxisReport report(List<KnobDescriptor> axes) =>
        AxisReport(entryId: 'demo/a.dart#a', shellId: 'app', axes: axes);

    const flavor = KnobDescriptor(
      name: 'flavor',
      kind: KnobKind.picker,
      value: 'dev',
      defaultValue: 'dev',
      options: ['dev', 'staging', 'prod'],
    );
    const compact = KnobDescriptor(
      name: 'compact',
      kind: KnobKind.boolean,
      value: false,
      defaultValue: false,
    );

    testWidgets('an entry whose wrapper is not a shell has a bare bar', (
      tester,
    ) async {
      await pump(tester, sessionWithBroken(beta, 'boom'));
      expect(find.text('flavor'), findsNothing);
      expect(toggles, findsNothing);
    });

    testWidgets('each axis is named, and drawn by its kind', (tester) async {
      var session = sessionWithBroken(beta, 'boom')
        ..axes = report(const [flavor, compact]);
      await pump(tester, session);

      // Named unconditionally: up here an axis sits beside a device picker, and
      // an unlabelled control would read as something about the phone.
      expect(find.text('flavor'), findsOneWidget);
      expect(find.text('compact'), findsOneWidget);
      expect(find.text('dev'), findsOneWidget);
      expect(toggles, findsOneWidget);
    });

    testWidgets('an axis off its default is legible against one that is not', (
      tester,
    ) async {
      var session = sessionWithBroken(beta, 'boom')
        ..axes = report(const [
          KnobDescriptor(
            name: 'flavor',
            kind: KnobKind.picker,
            value: 'prod',
            defaultValue: 'dev',
            options: ['dev', 'prod'],
          ),
          compact,
        ]);
      // Off its default because the *address* says so. The report's own
      // `value` is the guest's confirmation and does not decide what is drawn.
      await pump(tester, session, axes: const {'flavor': 'prod'});

      Color colorOf(String name) =>
          tester.widget<Text>(find.text(name)).style!.color!;
      expect(colorOf('flavor'), isNot(colorOf('compact')));
    });

    testWidgets('the toggle writes the address, and draws it at once', (
      tester,
    ) async {
      // Hand-rolled, so the tap path is ours to get right. The value is drawn
      // from what the address now says rather than from an optimistic patch
      // over the report: the guest has not answered, and nothing was mutated
      // to make the control move.
      var session = sessionWithBroken(beta, 'boom')
        ..axes = report(const [compact]);
      await pump(tester, session);

      var onDefault = tester.widget<Text>(find.text('compact')).style!.color;

      await tester.tap(toggles);
      await tester.pump();

      expect(address.value.axes['axis.compact'], 'true');
      expect(
        session.axes.axes.single.value,
        isNot(true),
        reason: 'the report is still exactly what the guest said',
      );
      expect(
        tester.widget<Text>(find.text('compact')).style!.color,
        isNot(onDefault),
        reason: 'and the control has already moved, from the address alone',
      );
    });

    testWidgets('the options are what the guest reported, not the signature', (
      tester,
    ) async {
      // A signature carries `Flavor`; only the guest knows what its values are
      // called, which is why the report is what the picker is built from.
      var session = sessionWithBroken(beta, 'boom')
        ..axes = report(const [flavor]);
      await pump(tester, session);

      await tester.tap(find.text('dev'));
      await tester.pumpAndSettle();
      expect(find.text('staging'), findsOneWidget);
      expect(find.text('prod'), findsOneWidget);
    });
  });

  group('a knob writes the address', () {
    KnobReport report(List<KnobDescriptor> knobs) =>
        KnobReport(entryId: beta.id, knobs: knobs);

    const title = KnobDescriptor(
      name: 'title',
      kind: KnobKind.string,
      value: 'Hello',
      defaultValue: 'Hello',
    );

    testWidgets('and the demo is told because of that, not instead of it', (
      tester,
    ) async {
      var session = sessionWithBroken(beta, 'boom')..knobs = report([title]);
      await pump(tester, session, tab: InspectTab.controls);

      await tester.enterText(find.byType(TextField).last, 'Bonjour');
      // The field debounces, so a burst of typing is one write rather than one
      // per keystroke.
      await tester.pump(const Duration(milliseconds: 350));

      expect(address.value.axes['knob.title'], 'Bonjour');
      expect(
        session.knobs.knobs.single.value,
        'Hello',
        reason: 'the report is still exactly what the demo said',
      );
    });

    testWidgets('and returning it to the default clears the parameter', (
      tester,
    ) async {
      // Silence *is* the default, which is what makes an address name only
      // what somebody chose — and what made the top bar stick when a stale
      // confirmed value was used as the fallback instead.
      var session = sessionWithBroken(beta, 'boom')..knobs = report([title]);
      await pump(
        tester,
        session,
        knobs: const {'title': 'Bonjour'},
        tab: InspectTab.controls,
      );

      await tester.enterText(find.byType(TextField).last, 'Hello');
      await tester.pump(const Duration(milliseconds: 350));

      expect(address.value.axes.containsKey('knob.title'), isFalse);
    });
  });
}
