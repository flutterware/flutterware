import 'package:flutter/gestures.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutterware/plugins.dart';
import 'package:flutterware/previews_guest.dart';
import 'package:flutterware_app/src/address/address_scope.dart';
import 'package:flutterware_app/src/previews/catalog_entry.dart';
import 'package:flutterware_app/src/previews/catalog_session.dart';
import 'package:flutterware_app/src/previews/catalog_view.dart';
import 'package:flutterware_app/src/previews/inspect_panel.dart';
import 'package:flutterware_app/src/previews/protocol.dart';

/// The inspection panel, against a tree handed to it rather than read from a
/// guest.
///
/// The session keeps a broken entry selected throughout — that is what puts the
/// compiler error where the texture would be, which is the only way a widget
/// test gets to see the panel at all.
void main() {
  const beta = CatalogEntry(
    path: 'demo/b.dart',
    symbol: 'beta',
    annotation: "Demo(name: 'Beta')",
    name: 'Beta',
  );

  InspectNode node(
    String id,
    String type, {
    List<InspectNode> children = const [],
    InspectLayout? layout,
    String? description,
    InspectSource? source,
    bool local = true,
    bool offstage = false,
    Map<String, String> properties = const {},
  }) => InspectNode(
    id: id,
    type: type,
    description: description,
    source: source,
    createdByLocalProject: local,
    offstage: offstage,
    properties: properties,
    layout: layout,
    children: children,
  );

  // Column > [Padding > Text, SizedBox]. Small, and shaped like the thing it
  // stands in for: a couple of boxes, one node that lays nothing out.
  var tree = InspectTree(
    entryId: beta.id,
    root: node(
      '',
      'Column',
      layout: const InspectLayout(
        x: 0,
        y: 0,
        width: 320,
        height: 200,
        constraints: InspectConstraints(
          minWidth: 0,
          maxWidth: 320,
          minHeight: 0,
          maxHeight: double.infinity,
        ),
        flex: InspectFlex(direction: 'vertical', mainAxisAlignment: 'start'),
      ),
      children: [
        node(
          '0',
          'Padding',
          layout: const InspectLayout(x: 8, y: 8, width: 304, height: 48),
          properties: const {'padding': 'EdgeInsets.all(8.0)'},
          source: const InspectSource(
            file: 'file:///project/demo/b.dart',
            line: 12,
            column: 5,
          ),
          children: [
            node(
              '0/0',
              'Text',
              description: 'Text("Save")',
              layout: const InspectLayout(x: 8, y: 8, width: 40, height: 16),
            ),
          ],
        ),
        // No layout at all: a builder. Kept because "it has no box" and "its
        // box is empty" are different answers and the pane must not conflate
        // them.
        node('1', 'Builder'),
      ],
    ),
  );

  late ValueNotifier<Address> address;

  CatalogSession sessionOf({InspectTree? withTree}) =>
      CatalogSession(
          appPackageRoot: '/app',
          flutterSdkRoot: '/sdk',
          projectRoot: '/project',
        )
        ..phase = CatalogSessionPhase.ready
        ..entries = const []
        ..quarantined = [const QuarantinedEntry(entry: beta, error: 'boom')]
        ..selected = beta
        ..active = beta
        // These are the Elements tab's tests; the panel itself opens closed and
        // on Controls, which `the panel` group below asserts.
        ..inspectTab = InspectTab.elements
        ..panelCollapsed = false
        ..tree = withTree;

  Future<void> pump(
    WidgetTester tester,
    CatalogSession session, {
    Map<String, String> params = const {},
  }) {
    address = ValueNotifier(
      Address(
        worktree: 'test',
        plugin: 'flutterware.previews',
        axes: {...params},
      ),
    );
    return tester.pumpWidget(
      MaterialApp(
        home: AddressRoot(
          address: address,
          onChanged: (next) => address.value = next,
          child: Scaffold(body: CatalogView(session: session)),
        ),
      ),
    );
  }

  group('the tree', () {
    testWidgets('draws what the guest reported', (tester) async {
      await pump(tester, sessionOf(withTree: tree));

      expect(find.text('Column'), findsOneWidget);
      expect(find.text('Padding'), findsOneWidget);
      expect(find.text('Text'), findsOneWidget);
      expect(
        find.text('Text("Save")'),
        findsOneWidget,
        reason: 'the words it puts on screen, beside the type',
      );
    });

    testWidgets('says it is reading when nothing has arrived', (tester) async {
      await pump(tester, sessionOf());
      expect(find.text('Reading the tree…'), findsOneWidget);
    });

    testWidgets('refuses a tree that names another entry', (tester) async {
      // Not an empty read — a read from before the switch. Drawing it under a
      // selection it does not belong to is how you end up wondering why your
      // edit did nothing.
      await pump(
        tester,
        sessionOf(
          withTree: InspectTree(
            entryId: 'demo/other.dart#other',
            root: node('', 'Column'),
          ),
        ),
      );
      expect(find.text('Column'), findsNothing);
      expect(find.text('Reading the tree…'), findsOneWidget);
    });

    testWidgets('folds a node away, and its children with it', (tester) async {
      await pump(tester, sessionOf(withTree: tree));
      expect(find.text('Text'), findsOneWidget);

      // Rows in order are Column, Padding, Text, Builder; only the first two
      // have children, so the second chevron is Padding's.
      await tester.tap(find.byIcon(Icons.arrow_drop_down).at(1));
      await tester.pump();

      expect(find.text('Padding'), findsOneWidget, reason: 'the row remains');
      expect(find.text('Text'), findsNothing);
    });
  });

  group('offstage', () {
    // The shape a push leaves behind: the covered route beside the current
    // one, its whole subtree flagged by the walk.
    var pushed = InspectTree(
      entryId: beta.id,
      root: node(
        '',
        'App',
        children: [
          node(
            '0',
            'MenuScreen',
            offstage: true,
            layout: const InspectLayout(x: 0, y: 0, width: 320, height: 200),
            children: [node('0/0', 'Card', offstage: true)],
          ),
          node('1', 'DrinkScreen'),
        ],
      ),
    );

    testWidgets('a hidden subtree starts folded, and says why', (tester) async {
      await pump(tester, sessionOf(withTree: pushed));

      expect(find.text('MenuScreen'), findsOneWidget);
      expect(find.text('offstage'), findsOneWidget);
      expect(find.text('Card'), findsNothing, reason: 'folded by default');
      expect(find.text('DrinkScreen'), findsOneWidget);
    });

    testWidgets('one click unfolds the whole of it', (tester) async {
      await pump(tester, sessionOf(withTree: pushed));

      // Chevrons in row order: App's, then MenuScreen's closed one.
      await tester.tap(find.byIcon(Icons.arrow_right).first);
      await tester.pump();

      expect(
        find.text('Card'),
        findsOneWidget,
        reason:
            'inside the subtree the default flips back to open — '
            'expanding the top must not reveal a pile of still-folded rows',
      );
    });

    testWidgets('a selection inside it is revealed, not answered into a fold', (
      tester,
    ) async {
      await pump(tester, sessionOf(withTree: pushed));
      expect(find.text('Card'), findsNothing);

      address.value = Address(
        worktree: address.value.worktree,
        plugin: address.value.plugin,
        axes: {...address.value.axes, 'inspect.node': '0/0'},
      );
      await tester.pump();

      // Twice: the unfolded row, and the detail pane's headline for it.
      expect(find.text('Card'), findsAtLeastNWidgets(1));
    });

    testWidgets('the detail pane states it over the stale rect', (
      tester,
    ) async {
      await pump(
        tester,
        sessionOf(withTree: pushed),
        params: const {'inspect.node': '0'},
      );
      expect(
        find.textContaining('offstage — in the tree, not on the screen'),
        findsOneWidget,
      );
    });
  });

  group('the semantics tab', () {
    Map<String, Object?> aTree() => {
      'rect': {'x': 0, 'y': 0, 'width': 320, 'height': 200},
      'children': [
        {
          'rect': {'x': 8, 'y': 8, 'width': 100, 'height': 40},
          'label': 'Add to cart',
          'flags': ['isButton'],
          'actions': ['tap'],
        },
      ],
    };

    testWidgets('shows what a screen reader gets, roles badged', (
      tester,
    ) async {
      var session = sessionOf(withTree: tree)
        ..inspectTab = InspectTab.semantics
        ..semantics = InspectSemantics(entryId: beta.id, root: aTree());
      await pump(tester, session);

      // Opens on the script lens — the reading itself, nothing structural.
      expect(find.text('“Add to cart”'), findsOneWidget);

      // The tree lens is the structural half: roles badged, actions listed,
      // a detail pane waiting for a selection.
      await tester.tap(find.text('Tree'));
      await tester.pump();
      expect(find.text('"Add to cart"'), findsOneWidget);
      expect(find.text('button'), findsOneWidget);
      expect(find.text('tap'), findsOneWidget);
      expect(find.text('Select a node'), findsOneWidget);
    });

    testWidgets('a click fills the detail with the full reading', (
      tester,
    ) async {
      var session = sessionOf(withTree: tree)
        ..inspectTab = InspectTab.semantics
        ..semantics = InspectSemantics(entryId: beta.id, root: aTree());
      await pump(tester, session);

      await tester.tap(find.text('Tree'));
      await tester.pump();
      await tester.tap(find.text('"Add to cart"'));
      await tester.pump();

      // The row elides; the detail states everything — flags by name, the
      // rect, the words again selectable.
      expect(find.text('isButton'), findsOneWidget);
      expect(find.text('8, 8 — 100 × 40'), findsOneWidget);
      expect(find.text('Add to cart'), findsOneWidget);
    });

    testWidgets('says it is reading until the guest reports', (tester) async {
      var session = sessionOf(withTree: tree)
        ..inspectTab = InspectTab.semantics;
      await pump(tester, session);
      expect(find.text('Reading what a screen reader gets…'), findsOneWidget);
    });

    testWidgets('refuses a read that names another entry', (tester) async {
      // A read from before the switch, exactly as the tree tab treats it.
      var session = sessionOf(withTree: tree)
        ..inspectTab = InspectTab.semantics
        ..semantics = InspectSemantics(
          entryId: 'demo/other.dart#other',
          root: aTree(),
        );
      await pump(tester, session);

      expect(find.text('"Add to cart"'), findsNothing);
      expect(find.text('Reading what a screen reader gets…'), findsOneWidget);
    });
  });

  group('selection', () {
    testWidgets('a click writes the node onto the address', (tester) async {
      await pump(tester, sessionOf(withTree: tree));

      await tester.tap(find.text('Padding'));
      await tester.pump();

      expect(address.value.axes['inspect.node'], '0');
    });

    testWidgets('the detail pane reads the address, not a field', (
      tester,
    ) async {
      await pump(
        tester,
        sessionOf(withTree: tree),
        params: const {'inspect.node': '0'},
      );

      expect(
        find.textContaining('demo/b.dart:12:5'),
        findsAtLeastNWidgets(1),
        reason: 'the file:line is what an agent or a person goes and edits',
      );
      expect(find.textContaining('304 × 48'), findsAtLeastNWidgets(1));
      expect(
        find.text('EdgeInsets.all(8.0)'),
        findsOneWidget,
        reason: 'what the widget says about itself, under the layout block',
      );
    });

    testWidgets('a node that lays nothing out says so, rather than zeroes', (
      tester,
    ) async {
      await pump(
        tester,
        sessionOf(withTree: tree),
        params: const {'inspect.node': '1'},
      );
      expect(find.textContaining('Lays nothing out'), findsOneWidget);
      expect(find.textContaining('0 × 0'), findsNothing);
    });

    testWidgets('an id the tree no longer has is said, not shown as empty', (
      tester,
    ) async {
      await pump(
        tester,
        sessionOf(withTree: tree),
        params: const {'inspect.node': '9/9'},
      );
      expect(find.textContaining('no longer has 9/9'), findsOneWidget);
    });

    testWidgets('the constraints it was given are shown beside its size', (
      tester,
    ) async {
      await pump(
        tester,
        sessionOf(withTree: tree),
        params: const {'inspect.node': ''},
      );
      // Half of every layout question: a box that is 0 wide because it was
      // given `maxWidth: 0` is a different bug from one that chose to be.
      // Whole pixels without the `.0`, like the size two lines above it.
      expect(find.textContaining('w 0..320'), findsAtLeastNWidgets(1));
      expect(find.textContaining('h 0..∞'), findsAtLeastNWidgets(1));
    });
  });

  group('hovering a row', () {
    // Mounted directly rather than through [CatalogView], because the point of
    // the test is the notifier the two halves share and the view keeps its own
    // private.
    Future<ValueNotifier<String?>> pumpPanel(WidgetTester tester) async {
      var highlight = ValueNotifier<String?>(null);
      var session = sessionOf(withTree: tree);
      await tester.pumpWidget(
        MaterialApp(
          home: AddressRoot(
            address: ValueNotifier(
              Address(worktree: 't', plugin: 'flutterware.previews'),
            ),
            onChanged: (_) {},
            child: Scaffold(
              body: AddressScope(
                namespace: 'inspect',
                child: InspectPanel(
                  session: session,
                  available: 600,
                  highlight: highlight,
                  semanticsHighlight: ValueNotifier(null),
                  picking: ValueNotifier(false),
                  controls: (_) => const SizedBox(),
                ),
              ),
            ),
          ),
        ),
      );
      return highlight;
    }

    testWidgets('lights the row itself, not only the preview', (tester) async {
      // Following the pointer with a rectangle somewhere else and nothing under
      // it leaves you guessing which row you are actually on.
      var highlight = await pumpPanel(tester);
      // Every colour above the row, because the row's own container is one of
      // several and picking it by position would break the moment the widget
      // gained a wrapper. What matters is that something above this text
      // changed and nothing did for its neighbour.
      List<Color?> coloursAround(String text) => tester
          .widgetList<Container>(
            find.ancestor(
              of: find.text(text),
              matching: find.byType(Container),
            ),
          )
          .map((c) => c.color)
          .toList();

      var restingPadding = coloursAround('Padding');
      var restingColumn = coloursAround('Column');

      highlight.value = '0';
      await tester.pump();

      expect(coloursAround('Padding'), isNot(restingPadding));
      expect(
        coloursAround('Column'),
        restingColumn,
        reason: 'and only the row under the pointer',
      );
    });

    testWidgets('follows the picker too, not only the mouse in the tree', (
      tester,
    ) async {
      // Same notifier from both ends: sweeping the demo runs the light down
      // the tree, which is the courtesy in reverse.
      var highlight = await pumpPanel(tester);
      highlight.value = '0/0';
      await tester.pump();
      expect(find.text('Text'), findsOneWidget);
    });

    testWidgets('lights that node on the preview', (tester) async {
      var highlight = await pumpPanel(tester);
      var gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await gesture.addPointer(location: Offset.zero);
      addTearDown(gesture.removePointer);

      await gesture.moveTo(tester.getCenter(find.text('Padding')));
      await tester.pump();
      expect(highlight.value, '0');
    });

    testWidgets('and hands over to the next row rather than going dark', (
      tester,
    ) async {
      // The pointer is already inside the next row by the time the last one is
      // told it was left, so a naive clear would put out the light that row
      // just turned on.
      var highlight = await pumpPanel(tester);
      var gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await gesture.addPointer(location: Offset.zero);
      addTearDown(gesture.removePointer);

      await gesture.moveTo(tester.getCenter(find.text('Padding')));
      await tester.pump();
      await gesture.moveTo(tester.getCenter(find.text('Text')));
      await tester.pump();
      expect(highlight.value, '0/0');
    });
  });

  group('revealing a picked node', () {
    testWidgets('unfolds whatever was hiding it', (tester) async {
      var session = sessionOf(withTree: tree);
      await pump(tester, session);

      // Fold Padding away, so Text is not on screen at all.
      await tester.tap(find.byIcon(Icons.arrow_drop_down).at(1));
      await tester.pump();
      expect(find.text('Text'), findsNothing);
      expect(find.byIcon(Icons.arrow_right), findsOneWidget);

      // Which is where the picker can land: it hit-tests the *demo*, and knows
      // nothing about what the tree happens to have folded. Selecting a row
      // nobody can see is answering into the void.
      await pump(tester, session, params: const {'inspect.node': '0/0'});
      await tester.pump();
      // The chevron rather than the row's text: selecting `0/0` also puts
      // `Text` in the detail pane, so counting the words would pass on a tree
      // that stayed folded.
      expect(find.byIcon(Icons.arrow_right), findsNothing);
    });
  });

  group('problems', () {
    // Mounted directly rather than through [CatalogView]: every case here needs
    // an entry that *compiles*, and a compiling entry sends the view to the
    // texture — which a widget test has no guest for. The panel alone is
    // enough, since the pane reads the session and nothing else.
    Future<CatalogSession> pumpProblems(
      WidgetTester tester, {
      InspectErrors? report,
      String? compileError,
      InspectTab tab = InspectTab.problems,
    }) async {
      var session =
          CatalogSession(
              appPackageRoot: '/app',
              flutterSdkRoot: '/sdk',
              projectRoot: '/project',
            )
            ..phase = CatalogSessionPhase.ready
            ..entries = const [beta]
            ..quarantined = compileError == null
                ? const []
                : [QuarantinedEntry(entry: beta, error: compileError)]
            ..selected = beta
            ..active = beta
            ..inspectTab = tab
            // These are the tab's own tests, and the panel opens closed.
            ..panelCollapsed = false
            ..renderErrors = report;
      await tester.pumpWidget(
        MaterialApp(
          home: AddressRoot(
            address: ValueNotifier(
              Address(worktree: 't', plugin: 'flutterware.previews'),
            ),
            onChanged: (_) {},
            child: Scaffold(
              body: AddressScope(
                namespace: 'inspect',
                child: InspectPanel(
                  session: session,
                  available: 600,
                  highlight: ValueNotifier(null),
                  semanticsHighlight: ValueNotifier(null),
                  picking: ValueNotifier(false),
                  controls: (_) => const SizedBox(),
                ),
              ),
            ),
          ),
        ),
      );
      return session;
    }

    InspectErrors reported(List<InspectError> errors) =>
        InspectErrors(entryId: beta.id, errors: errors);

    testWidgets('lists what the framework reported', (tester) async {
      await pumpProblems(
        tester,
        report: reported(const [
          InspectError(
            exception: 'A RenderFlex overflowed by 430 pixels on the right.',
            library: 'rendering library',
            context: 'during layout',
          ),
        ]),
      );

      expect(find.textContaining('overflowed by 430'), findsAtLeastNWidgets(1));
      expect(
        find.textContaining('rendering library'),
        findsOneWidget,
        reason: 'which is what tells an overflow from a failed image load',
      );
    });

    testWidgets('counts a repeat rather than repeating it', (tester) async {
      // An error thrown from `paint` fires once per frame, and a panel driving
      // frames continuously would show one overflow as several hundred rows.
      await pumpProblems(
        tester,
        report: reported(const [InspectError(exception: 'boom', count: 412)]),
      );
      expect(find.textContaining('412×'), findsOneWidget);
      expect(find.textContaining('boom'), findsAtLeastNWidgets(1));
    });

    testWidgets('says it is clean rather than showing an empty list', (
      tester,
    ) async {
      await pumpProblems(tester, report: reported(const []));
      expect(find.textContaining('without the framework reporting'), findsOne);
    });

    testWidgets('is told apart from not having rendered yet', (tester) async {
      // Nothing read is not the same answer as nothing wrong, and reporting a
      // demo clean before it has drawn is the more expensive mistake.
      await pumpProblems(tester);
      expect(find.textContaining('Waiting for the entry'), findsOne);
    });

    testWidgets('holds the compile error too, since nothing below it ran', (
      tester,
    ) async {
      // The entry that most obviously has a problem is the one that does not
      // build — and it never renders, so waiting for a render report is
      // waiting for something that will never arrive. This pane sat on
      // "waiting…" forever for exactly that entry.
      await pumpProblems(tester, compileError: 'Method not found: Nope');

      expect(find.textContaining('Waiting for the entry'), findsNothing);
      expect(find.textContaining('Method not found'), findsAtLeastNWidgets(1));
      expect(find.textContaining('compiler'), findsOneWidget);
    });

    testWidgets('badges the tab, so a throw finds you on another one', (
      tester,
    ) async {
      // The whole point of a badge: you are looking at the knobs and the demo
      // has quietly started throwing.
      await pumpProblems(
        tester,
        tab: InspectTab.controls,
        report: reported(const [
          InspectError(exception: 'one'),
          InspectError(exception: 'two'),
        ]),
      );
      expect(find.text('2'), findsOneWidget);
    });

    testWidgets('counts a compile error on the badge like any other', (
      tester,
    ) async {
      await pumpProblems(
        tester,
        tab: InspectTab.controls,
        compileError: 'nope',
        report: reported(const [InspectError(exception: 'and one at render')]),
      );
      expect(find.text('2'), findsOneWidget);
    });

    testWidgets('and carries no badge when there is nothing to carry', (
      tester,
    ) async {
      await pumpProblems(
        tester,
        tab: InspectTab.controls,
        report: reported(const []),
      );
      expect(find.text('0'), findsNothing);
    });

    testWidgets('refuses a report that names another entry', (tester) async {
      await pumpProblems(
        tester,
        report: const InspectErrors(
          entryId: 'demo/other.dart#other',
          errors: [InspectError(exception: 'a problem of the previous demo')],
        ),
      );
      expect(find.textContaining('previous demo'), findsNothing);
      expect(find.textContaining('Waiting for the entry'), findsOne);
    });
  });

  group('narrow', () {
    // Overflow stripes across an inspector are a poor advertisement for one,
    // and both of these were painting them.
    //
    // The panel is mounted **alone**, in a box of the width being tested,
    // rather than through [CatalogView]: a whole view squeezed to 420px
    // overflows in the entry list and the top bar too, and a test that caught
    // those would fail for reasons that have nothing to do with the widget it
    // names. `tester.takeException` is the assertion — a `RenderFlex` overflow
    // is reported through `FlutterError`, so this fails on the layout itself.
    Future<void> pumpNarrow(
      WidgetTester tester,
      InspectTree withTree, {
      double width = 360,
    }) async {
      var session = sessionOf(withTree: withTree);
      await tester.pumpWidget(
        MaterialApp(
          home: AddressRoot(
            address: ValueNotifier(
              Address(worktree: 't', plugin: 'flutterware.previews'),
            ),
            onChanged: (_) {},
            child: Scaffold(
              body: AddressScope(
                namespace: 'inspect',
                child: Align(
                  alignment: Alignment.topLeft,
                  child: SizedBox(
                    width: width,
                    height: 500,
                    child: InspectPanel(
                      session: session,
                      available: 500,
                      highlight: ValueNotifier(null),
                      semanticsHighlight: ValueNotifier(null),
                      picking: ValueNotifier(false),
                      controls: (_) => const SizedBox(),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
    }

    testWidgets('the tab strip scrolls rather than overflowing', (
      tester,
    ) async {
      await pumpNarrow(tester, tree, width: 240);
      expect(tester.takeException(), isNull);
      // And the tabs are still reachable, which is what scrolling buys over
      // simply clipping them.
      expect(find.text('Controls'), findsOneWidget);
      expect(find.text('Problems'), findsOneWidget);
    });

    testWidgets('the strip buttons sit at the right edge', (tester) async {
      // Not against the tabs. A `Spacer` beside the `Expanded` holding them
      // does not push these to the edge — the two divide the free space, so
      // the buttons parked somewhere in the middle.
      await pumpNarrow(tester, tree, width: 600);
      var strip = tester.getRect(find.byTooltip('Hide the panel'));
      expect(strip.right, greaterThan(600 - 40));
    });

    testWidgets('the sizes line up as a column', (tester) async {
      // They used to land wherever each row's description happened to stop:
      // the type, the description and a `Spacer` were three flex children
      // dividing the free space, so the right edge moved with the text.
      // Wide enough that the tree pane itself clears the size column's
      // threshold — it gets 62% of the panel, not all of it.
      await pumpNarrow(tester, tree, width: 900);
      var sizes = find.byWidgetPredicate(
        (w) => w is Text && (w.data ?? '').contains('×'),
      );
      expect(sizes, findsAtLeastNWidgets(2), reason: 'several to compare');

      var edges = <double>{
        for (var element in sizes.evaluate())
          tester.getTopRight(find.byWidget(element.widget)).dx,
      };
      expect(edges, hasLength(1), reason: 'they share one right edge');
    });

    testWidgets('a deep row gives way instead of overflowing', (tester) async {
      // A node twelve levels down indents its row most of the way across a
      // narrow panel, which is what left no room for the type.
      var deep = node(
        List.filled(12, '0').join('/'),
        'Leaf',
        layout: const InspectLayout(x: 0, y: 0, width: 100, height: 100),
      );
      for (var i = 11; i >= 0; i--) {
        deep = node(
          List.filled(i, '0').join('/'),
          'AVeryLongWidgetTypeName$i',
          description: 'AVeryLongWidgetTypeName$i(with: "a long argument")',
          layout: const InspectLayout(x: 0, y: 0, width: 100, height: 100),
          children: [deep],
        );
      }

      await pumpNarrow(tester, InspectTree(entryId: beta.id, root: deep));
      expect(tester.takeException(), isNull);
    });
  });

  group('the picker', () {
    // The overlay lives inside the texture's box, and a widget test has no
    // texture — the guest is not running. What is reachable is the arming,
    // which is the half that decides whether a click reaches the demo.
    Finder pickerButton() => find.byTooltip('Pick a widget in the preview');

    testWidgets('arming it opens the tree, because that is what it fills', (
      tester,
    ) async {
      var session = sessionOf(withTree: tree)..inspectTab = InspectTab.controls;
      await pump(tester, session);
      expect(find.text('Column'), findsNothing);

      await tester.tap(pickerButton());
      await tester.pump();

      // Picking a widget and landing on the knobs would be answering a
      // question nobody asked.
      expect(session.inspectTab, InspectTab.elements);
      expect(find.text('Column'), findsOneWidget);
    });

    testWidgets('says it is armed, since a mode that looks like nothing is a '
        'mode you forget', (tester) async {
      await pump(tester, sessionOf(withTree: tree));
      expect(pickerButton(), findsOneWidget);

      await tester.tap(pickerButton());
      await tester.pump();

      expect(find.byTooltip('Stop picking (esc)'), findsOneWidget);
      expect(pickerButton(), findsNothing);
    });

    testWidgets('disarms when pressed again', (tester) async {
      await pump(tester, sessionOf(withTree: tree));
      await tester.tap(pickerButton());
      await tester.pump();
      await tester.tap(find.byTooltip('Stop picking (esc)'));
      await tester.pump();
      expect(pickerButton(), findsOneWidget);
    });
  });

  group('the panel', () {
    testWidgets('opens closed, on Controls, and reads no tree until you ask', (
      tester,
    ) async {
      var session =
          CatalogSession(
              appPackageRoot: '/app',
              flutterSdkRoot: '/sdk',
              projectRoot: '/project',
            )
            ..phase = CatalogSessionPhase.ready
            ..quarantined = [const QuarantinedEntry(entry: beta, error: 'boom')]
            ..selected = beta
            ..active = beta
            ..tree = tree;
      await pump(tester, session);

      // Most entries declare no knobs, so an open panel is 260px of every
      // catalog spent explaining what a knob is. And the everyday loop is
      // turning one and watching the demo, so when it does open it opens there
      // — onto a wall of widget rows reads as the panel having an opinion about
      // what you came here to do.
      expect(session.panelCollapsed, isTrue);
      expect(session.inspectTab, InspectTab.controls);
      expect(find.text('Column'), findsNothing);
      expect(
        find.text('Controls'),
        findsOneWidget,
        reason: 'the strip stays, or there is nothing to open',
      );
      expect(
        session.inspecting,
        isFalse,
        reason: 'and nothing is paying for a tree nobody is looking at',
      );

      await tester.tap(find.text('Elements'));
      await tester.pump();
      expect(find.text('Column'), findsOneWidget);
      expect(session.inspecting, isTrue);
    });

    testWidgets('says how many knobs the entry has, without opening', (
      tester,
    ) async {
      // The other half of opening closed: a demo with knobs has to be able to
      // say so from the strip, or the feature is behind a panel nobody has a
      // reason to open. Zero draws nothing at all.
      var session = sessionOf()
        ..knobs = KnobReport(
          entryId: beta.id,
          knobs: const [
            KnobDescriptor(
              name: 'label',
              kind: KnobKind.string,
              value: 'Hello',
              defaultValue: 'Hello',
            ),
            KnobDescriptor(
              name: 'dense',
              kind: KnobKind.boolean,
              value: false,
              defaultValue: false,
            ),
          ],
        );
      await pump(tester, session);

      expect(find.text('2'), findsOneWidget);
    });

    testWidgets('a collapse survives leaving the plugin', (tester) async {
      // The shell rebuilds the panel from scratch every time you come back to
      // it, which is why the tab lives on the session — and the collapse did
      // not, so the panel came back open however you had left it.
      var session = sessionOf(withTree: tree);
      await pump(tester, session);
      await tester.tap(find.byTooltip('Hide the panel'));
      await tester.pump();

      await pump(tester, session);
      expect(find.text('Column'), findsNothing);
      expect(find.byTooltip('Show the panel'), findsOneWidget);
    });

    testWidgets('stops reading the tree when it is folded away', (
      tester,
    ) async {
      var session = sessionOf(withTree: tree);
      await pump(tester, session);
      await tester.pump();
      expect(session.inspecting, isTrue);

      await tester.tap(find.byTooltip('Hide the panel'));
      await tester.pump();
      expect(session.inspecting, isFalse);
    });

    testWidgets('collapses and comes back', (tester) async {
      await pump(tester, sessionOf(withTree: tree));
      expect(find.text('Column'), findsOneWidget);

      await tester.tap(find.byTooltip('Hide the panel'));
      await tester.pump();
      expect(find.text('Column'), findsNothing);
      expect(
        find.text('Elements'),
        findsOneWidget,
        reason: 'the tabs stay, or there is no way back',
      );

      await tester.tap(find.byTooltip('Show the panel'));
      await tester.pump();
      expect(find.text('Column'), findsOneWidget);
    });

    testWidgets('switches tabs, and remembers on the session', (tester) async {
      var session = sessionOf(withTree: tree);
      await pump(tester, session);

      await tester.tap(find.text('Controls'));
      await tester.pump();
      expect(find.text('Column'), findsNothing);
      expect(session.inspectTab, InspectTab.controls);

      // The session outlives the panel, so a remount comes back to the tab you
      // left open — the same courtesy as coming back to the entry you had.
      await pump(tester, session);
      expect(find.text('Column'), findsNothing);
    });

    testWidgets('cannot be dragged tall enough to eat the preview', (
      tester,
    ) async {
      await pump(tester, sessionOf(withTree: tree));
      var before = tester.getSize(find.byType(InspectPanel)).height;

      // Far past the top of the window. A `Column` hands a non-flex child an
      // unbounded main axis, so a panel that measured its own room would read
      // infinity here and clamp against nothing — it would resize straight off
      // the bottom of the window, taking the canvas with it.
      await tester.drag(
        find.byWidgetPredicate(
          (w) =>
              w is MouseRegion && w.cursor == SystemMouseCursors.resizeUpDown,
        ),
        const Offset(0, -1000),
      );
      await tester.pump();

      var after = tester.getSize(find.byType(InspectPanel)).height;
      var window = tester.getSize(find.byType(CatalogView)).height;
      expect(after, greaterThan(before), reason: 'it did resize');
      expect(
        after,
        lessThan(window - 100),
        reason: 'and stopped short of the preview',
      );
    });

    testWidgets('clicking the open tab hides the panel', (tester) async {
      await pump(tester, sessionOf(withTree: tree));
      await tester.tap(find.text('Elements'));
      await tester.pump();
      expect(find.text('Column'), findsNothing);
    });
  });
}
