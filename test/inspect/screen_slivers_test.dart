import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutterware/src/inspect/guest_inspect.dart';
import 'package:flutterware/src/inspect/node.dart';
import 'package:flutterware/src/inspect/screen.dart';

/// The screen projection over the shapes that carry no box.
///
/// A sliver's render object is a `RenderSliver`, so nothing in a capture hands
/// it a rect — and a screen written the ordinary way, `CustomScrollView` over
/// slivers the app's own code spells out, forks at exactly those nodes. Every
/// case here threw `Bad state: Too many elements` and took the whole
/// observation down with it: the reply lost its verb, its picture and its
/// journal entry, and the message named neither the screen nor the projection
/// it came out of.
///
/// A `ListView` never showed it, which is why it survived so long: its
/// `SliverList` is built by the framework and the summary tree drops it, so the
/// fork lands on the `ListView` itself, which has a box.
void main() {
  Future<Screen> screenOf(WidgetTester tester, Widget body) async {
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: body)));
    return Screen.of(
      GuestInspector(
        rootOf: () => tester.binding.rootElement,
        entryIdOf: () => null,
      ).read(),
    );
  }

  testWidgets('slivers the app writes itself', (tester) async {
    var screen = await screenOf(
      tester,
      CustomScrollView(
        slivers: [
          const SliverAppBar(title: Text('Home')),
          SliverList(
            delegate: SliverChildListDelegate(const [
              Text('one'),
              Text('two'),
              Text('View more'),
            ]),
          ),
        ],
      ),
    );

    expect(screen.items.map((i) => i.words), contains('View more'));
  });

  testWidgets("a widget of the app's that returns a sliver", (tester) async {
    var screen = await screenOf(
      tester,
      const CustomScrollView(slivers: [_Section('A'), _Section('B')]),
    );

    expect(screen.items.map((i) => i.words), [
      'A header',
      'A row',
      'A View more',
      'B header',
      'B row',
      'B View more',
    ]);
    // Each section is where the screen forks, so each is a region — over the
    // rect its rows cover, since the sliver itself has none, and pointing at
    // the line of the app's own code that built it.
    var sections = screen.root!.children.whereType<ScreenRegion>().toList();
    expect(sections, hasLength(2));
    for (var section in sections) {
      expect(
        section.label,
        startsWith('SliverList @ screen_slivers_test.dart'),
      );
      expect(section.box[3], greaterThan(0));
    }
  });

  testWidgets('a list the framework slivers is unchanged', (tester) async {
    var screen = await screenOf(
      tester,
      ListView.builder(itemCount: 3, itemBuilder: (_, i) => Text('row $i')),
    );

    expect(screen.items.map((i) => i.words), ['row 0', 'row 1', 'row 2']);
  });

  testWidgets('the sliver node is the one with no box', (tester) async {
    // The oracle behind all of this, pinned so a change in what a capture
    // measures shows up here rather than as a crash on a user's screen.
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: CustomScrollView(
            slivers: [
              SliverList(
                delegate: SliverChildListDelegate(const [Text('one')]),
              ),
            ],
          ),
        ),
      ),
    );
    var tree = GuestInspector(
      rootOf: () => tester.binding.rootElement,
      entryIdOf: () => null,
    ).read();

    var sliver = _find(tree.root!, 'SliverList');
    expect(sliver, isNotNull);
    expect(sliver!.layout, isNull);
  });
}

InspectNode? _find(InspectNode node, String type) {
  if (node.type.split('<').first == type) return node;
  for (var child in node.children) {
    var found = _find(child, type);
    if (found != null) return found;
  }
  return null;
}

class _Section extends StatelessWidget {
  const _Section(this.name);

  final String name;

  @override
  Widget build(BuildContext context) => SliverList(
    delegate: SliverChildListDelegate([
      Text('$name header'),
      Text('$name row'),
      Text('$name View more'),
    ]),
  );
}
