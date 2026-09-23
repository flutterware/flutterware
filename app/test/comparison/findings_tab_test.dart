import 'package:flutterware/comparison_report.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutterware_app/src/comparison/shot_store.dart';
import 'package:flutterware_app/src/comparison/ui/findings_tab.dart';
import 'package:flutterware_app/src/ui/theme.dart';

/// The page's landing view: everything worth attention, worst first, both
/// halves together.
///
/// The comment has always merged the halves and the page split them back into
/// two tabs, so a reader who clicked *Open the full comparison* from a ranked
/// list of eleven findings landed on a previews rail that could not mention
/// the scenarios.
void main() {
  var opened = <(String, String)>[];

  setUp(opened.clear);

  ComparedItem entry(
    String id,
    ComparedState state, {
    String? note,
    ({String base, String head})? shots,
  }) => ComparedItem(id: id, state: state, note: note, shots: shots);

  Future<void> pump(
    WidgetTester tester, {
    List<ComparedItem> previews = const [],
    List<ScenarioComparison> scenarios = const [],
    String? previewsNote,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: appTheme,
        home: Scaffold(
          body: FindingsTab(
            index: ComparisonIndex(
              base: 'abc123',
              against: 'origin/master',
              previewItems: previews,
              scenarios: scenarios,
              previewsHalf: ComparedHalf(note: previewsNote),
            ),
            store: _NoShots(),
            onOpen: (tab, id) => opened.add((tab, id)),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('both halves rank into one list, worst first', (tester) async {
    await pump(
      tester,
      previews: [
        entry('demo/card.dart#card', ComparedState.changed),
        entry('demo/gone.dart#gone', ComparedState.removed),
      ],
      scenarios: [
        const ScenarioComparison.notRun(
          scenario: 'test/pay_test.dart#Pay',
          state: ComparedState.broke,
        ),
      ],
    );

    // `ComparedState` is declared worst-first, so this order is the ranking —
    // and the scenario is above both previews, which is the whole point of
    // merging them.
    var rows = tester
        .widgetList<Text>(find.byType(Text))
        .map((text) => text.data)
        .whereType<String>()
        .toList();
    expect(
      rows.indexOf('Pay'),
      lessThan(rows.indexOf('gone')),
      reason: 'broke outranks removed',
    );
    expect(rows.indexOf('gone'), lessThan(rows.indexOf('card')));
  });

  // The detail — the five-mode stage, the merged flow — already lives in the
  // halves, and a third copy of either is the drift this codebase keeps paying
  // for. So a row is a door rather than a page.
  testWidgets('a row hands itself to the half that owns it', (tester) async {
    await pump(
      tester,
      previews: [entry('demo/card.dart#card', ComparedState.changed)],
      scenarios: [
        const ScenarioComparison.notRun(
          scenario: 'test/pay_test.dart#Pay',
          state: ComparedState.broke,
        ),
      ],
    );

    await tester.tap(find.byKey(findingRowKey('demo/card.dart#card')));
    await tester.tap(find.byKey(findingRowKey('test/pay_test.dart#Pay')));

    expect(opened, [
      ('previews', 'demo/card.dart#card'),
      ('scenarios', 'test/pay_test.dart#Pay'),
    ]);
  });

  testWidgets('a row that is neither same nor skipped is the only kind shown', (
    tester,
  ) async {
    await pump(
      tester,
      previews: [
        entry('demo/card.dart#card', ComparedState.changed),
        entry('demo/quiet.dart#quiet', ComparedState.same),
        entry('demo/untouched.dart#untouched', ComparedState.skipped),
      ],
    );

    expect(find.byKey(findingRowKey('demo/card.dart#card')), findsOneWidget);
    expect(find.byKey(findingRowKey('demo/quiet.dart#quiet')), findsNothing);
  });

  // A compile failure's note is the compiler's whole output. The row is a
  // line in a list; the detail page is where the rest belongs.
  testWidgets('a multi-line note is one line', (tester) async {
    await pump(
      tester,
      previews: [
        entry(
          'demo/broken.dart#broken',
          ComparedState.failed,
          note: 'lib/a.dart:1:1: Error: not found\nWidget a() => B();\n  ^^^',
        ),
      ],
    );

    expect(find.text('lib/a.dart:1:1: Error: not found'), findsOneWidget);
    expect(find.textContaining('Widget a()'), findsNothing);
  });

  // A flow's own verdict is a roll-up and carries no picture, so a row drawn
  // from what the flow says would show nothing at all.
  testWidgets('a scenario shows its worst step that has frames', (
    tester,
  ) async {
    var store = _RecordingShots();
    await tester.pumpWidget(
      MaterialApp(
        theme: appTheme,
        home: Scaffold(
          body: FindingsTab(
            index: ComparisonIndex(
              base: 'abc123',
              against: 'origin/master',
              previewItems: const [],
              scenarios: [
                ScenarioComparison(
                  scenario: 'test/pay_test.dart#Pay',
                  state: ComparedState.broke,
                  branches: const [],
                  items: const [
                    ComparedItem(id: '#1', state: ComparedState.changed),
                    ComparedItem(id: '#2', state: ComparedState.broke),
                    ComparedItem(id: '#3', state: ComparedState.changed),
                  ],
                  frames: const {
                    '#1': (
                      base: FrameRef(path: 'one.png', width: 4, height: 4),
                      head: null,
                    ),
                    '#2': (
                      base: FrameRef(path: 'two.png', width: 4, height: 4),
                      head: null,
                    ),
                  },
                ),
              ],
            ),
            store: store,
            onOpen: (tab, id) {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // `#2` broke and `#1` merely changed; `#3` is worse than nothing but has
    // no frames, so it could not be the face even if it had ranked first.
    expect(store.asked, contains('two.png'));
    expect(store.asked, isNot(contains('one.png')));
  });

  testWidgets('a scenario shows a step whose pixels moved over one that did '
      'not', (tester) async {
    var store = _RecordingShots();
    await tester.pumpWidget(
      MaterialApp(
        theme: appTheme,
        home: Scaffold(
          body: FindingsTab(
            index: ComparisonIndex(
              base: 'abc123',
              against: 'origin/master',
              previewItems: const [],
              scenarios: [
                ScenarioComparison(
                  scenario: 'test/pay_test.dart#Pay',
                  state: ComparedState.changed,
                  branches: const [],
                  items: [
                    const ComparedItem(
                      id: '#1',
                      state: ComparedState.changed,
                      texts: TextChannel(added: ['Pay'], removed: ['Buy']),
                    ),
                    ComparedItem(
                      id: '#2',
                      state: ComparedState.changed,
                      pixels: PixelChannel(
                        PixelDiff(
                          width: 4,
                          height: 4,
                          changedPixels: 16,
                          comparedPixels: 16,
                          sizeChanged: false,
                          clusters: const [],
                        ),
                      ),
                    ),
                  ],
                  frames: const {
                    '#1': (
                      base: FrameRef(path: 'one.png', width: 4, height: 4),
                      head: FrameRef(path: 'one.png', width: 4, height: 4),
                    ),
                    '#2': (
                      base: FrameRef(path: 'two.png', width: 4, height: 4),
                      head: FrameRef(path: 'two.png', width: 4, height: 4),
                    ),
                  },
                ),
              ],
            ),
            store: store,
            onOpen: (tab, id) {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // `#1` comes first and changed only its texts: its two frames are the same
    // picture. `#2` is where the change can be seen.
    expect(store.asked, contains('two.png'));
    expect(store.asked, isNot(contains('one.png')));
  });

  // Every finding is listed; a page that decoded four hundred pairs of frames
  // would spend its memory on rows nobody has scrolled to.
  testWidgets('only the first rows ask for their frames', (tester) async {
    var store = _RecordingShots();
    await tester.pumpWidget(
      MaterialApp(
        theme: appTheme,
        home: Scaffold(
          body: FindingsTab(
            index: ComparisonIndex(
              base: 'abc123',
              against: 'origin/master',
              previewItems: [
                for (var n = 0; n < FindingsTab.framedRows + 5; n++)
                  ComparedItem(
                    // Zero-padded so the ranking's tiebreak — the id — is the
                    // order they were written in.
                    id: 'demo/e${'$n'.padLeft(2, '0')}.dart#e',
                    state: ComparedState.changed,
                    shots: (base: 'b$n', head: 'h$n'),
                  ),
              ],
              scenarios: const [],
            ),
            store: store,
            onOpen: (tab, id) {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(store.asked, contains('h0'));
    expect(store.asked, isNot(contains('h${FindingsTab.framedRows}')));
  });

  // Drawn at eighty-four pixels; decoded at twenty times that would be a
  // hundred megabytes of images nobody can see.
  testWidgets('frames are decoded at thumbnail size', (tester) async {
    var store = _RecordingShots();
    await tester.pumpWidget(
      MaterialApp(
        theme: appTheme,
        home: Scaffold(
          body: FindingsTab(
            index: const ComparisonIndex(
              base: 'abc123',
              against: 'origin/master',
              previewItems: [
                ComparedItem(
                  id: 'demo/card.dart#card',
                  state: ComparedState.changed,
                  shots: (base: 'b', head: 'h'),
                ),
              ],
              scenarios: [],
            ),
            store: store,
            onOpen: (tab, id) {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(store.widths, everyElement(isNotNull));
  });

  // An 84×64 cell drew a phone screen thirty pixels wide. The cell takes the
  // frame's shape, from what the report knows before anything decodes.
  testWidgets("a cell takes its frame's shape, and decodes at twice it", (
    tester,
  ) async {
    var store = _RecordingShots();
    await tester.pumpWidget(
      MaterialApp(
        theme: appTheme,
        home: Scaffold(
          body: FindingsTab(
            index: const ComparisonIndex(
              base: 'abc123',
              against: 'origin/master',
              previewItems: [
                ComparedItem(
                  id: 'demo/wide.dart#wide',
                  state: ComparedState.changed,
                  shots: (base: 'b', head: 'h'),
                  pixels: PixelChannel(
                    PixelDiff(
                      width: 900,
                      height: 600,
                      changedPixels: 10,
                      comparedPixels: 540000,
                      sizeChanged: false,
                      clusters: [],
                    ),
                  ),
                ),
              ],
              scenarios: [
                ScenarioComparison(
                  scenario: 'test/phone_test.dart#Phone',
                  state: ComparedState.changed,
                  branches: [],
                  items: [
                    ComparedItem(id: 'Menu', state: ComparedState.changed),
                  ],
                  frames: {
                    'Menu': (
                      base: FrameRef(path: 'menu.png', width: 390, height: 844),
                      head: null,
                    ),
                  },
                ),
              ],
            ),
            store: store,
            onOpen: (tab, id) {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // 140 tall: the phone as narrow as its shape, the laptop as wide.
    expect(store.widths, containsAll([(140 * 390 / 844 * 2).ceil(), 420]));
  });

  // The id is a file and a function; a reader knows the preview by the name
  // the panel shows, and a flow by which of its steps moved.
  testWidgets('a row is named, and a flow says where it changed', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: appTheme,
        home: Scaffold(
          body: FindingsTab(
            index: const ComparisonIndex(
              base: 'abc123',
              against: 'origin/master',
              previewItems: [
                ComparedItem(
                  id: 'demo/shop.dart#shopConfirmation',
                  state: ComparedState.changed,
                  label: 'Order placed',
                ),
              ],
              scenarios: [
                ScenarioComparison(
                  scenario: 'test/shop_test.dart#Order a cappuccino',
                  state: ComparedState.changed,
                  branches: [],
                  items: [
                    ComparedItem(id: 'Welcome', state: ComparedState.same),
                    ComparedItem(id: 'Menu', state: ComparedState.changed),
                    ComparedItem(
                      id: 'Order placed',
                      state: ComparedState.changed,
                    ),
                  ],
                ),
              ],
            ),
            store: _NoShots(),
            onOpen: (tab, id) {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Order placed'), findsOneWidget);
    expect(find.text('shopConfirmation'), findsNothing);
    expect(find.text('changed at Menu, Order placed'), findsOneWidget);
  });

  // Stretched across a wide window, a row's name and its verdict were a
  // thousand pixels apart.
  testWidgets('a row keeps its width on a wide window', (tester) async {
    tester.view.physicalSize = const Size(2400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await pump(
      tester,
      previews: [entry('demo/card.dart#card', ComparedState.changed)],
    );

    expect(
      tester.getSize(find.byKey(findingRowKey('demo/card.dart#card'))).width,
      lessThanOrEqualTo(FindingsTab.rowMaxWidth),
    );
  });

  test('past three steps, the rest are counted', () {
    expect(changedAt(['a']), 'changed at a');
    expect(
      changedAt(['a', 'b', 'c', 'd', 'e']),
      'changed at a, b, c and 2 other steps',
    );
  });

  group('nothing worth attention', () {
    testWidgets('says so', (tester) async {
      await pump(
        tester,
        previews: [entry('demo/card.dart#card', ComparedState.same)],
      );

      expect(find.text('Nothing changed'), findsOneWidget);
    });

    // "Nothing changed" over a half whose harness would not build is the
    // silent pass a verdict gap exists to break — the same rule the comment
    // learned.
    testWidgets('unless a half produced no verdict', (tester) async {
      await pump(tester, previewsNote: 'ops: the catalog does not compile');

      expect(
        find.textContaining('the previews half produced no verdict'),
        findsOneWidget,
      );
    });
  });
}

class _NoShots implements ShotStore {
  @override
  Future<Shot?> byKey(String key, {int? width}) async => null;

  @override
  Future<Shot?> byRef(FrameRef ref, {int? width}) async => null;
}

/// Answers nothing and remembers what it was asked — which is the whole of
/// what these tests are about: *which* frames a row decides to draw.
class _RecordingShots implements ShotStore {
  final asked = <String>[];
  final widths = <int?>[];

  @override
  Future<Shot?> byKey(String key, {int? width}) async {
    asked.add(key);
    widths.add(width);
    return null;
  }

  @override
  Future<Shot?> byRef(FrameRef ref, {int? width}) async {
    asked.add(ref.path);
    widths.add(width);
    return null;
  }
}
