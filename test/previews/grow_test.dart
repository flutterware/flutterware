import 'package:flutter_test/flutter_test.dart';
import 'package:flutterware/src/previews/grow.dart';
import 'package:material_ui/material_ui.dart';

/// `--full`: the screen made as tall as its lists, so one picture holds all
/// of them — and the three layouts that would otherwise grow it forever.
void main() {
  const phone = Size(440, 956);

  var resizes = 0;
  Future<Grown> grow(WidgetTester tester, {double maxHeight = 20000}) {
    resizes = 0;
    return growToContent(
      () => tester.binding.rootElement,
      height: tester.view.physicalSize.height / tester.view.devicePixelRatio,
      resize: (height) async {
        resizes++;
        tester.view.physicalSize = Size(
          phone.width * tester.view.devicePixelRatio,
          height * tester.view.devicePixelRatio,
        );
        await tester.pump();
      },
      settle: () => tester.pumpAndSettle(),
      maxHeight: maxHeight,
    );
  }

  TestFlutterView view() =>
      TestWidgetsFlutterBinding.instance.platformDispatcher.views.single;

  setUp(() {
    view()
      ..physicalSize = phone * 3
      ..devicePixelRatio = 3;
  });
  tearDown(() => view().reset());

  double bottomOf(WidgetTester tester, String text) => tester
      .getRect(
        find.ancestor(of: find.text(text), matching: find.byType(ListTile)),
      )
      .bottom;

  testWidgets('a list grows the screen until its last row is on it', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          appBar: AppBar(title: const Text('Menu')),
          body: ListView.builder(
            itemCount: 100,
            itemBuilder: (_, i) => ListTile(title: Text('Row $i')),
          ),
          bottomNavigationBar: NavigationBar(
            destinations: const [
              NavigationDestination(icon: Icon(Icons.home), label: 'Home'),
              NavigationDestination(icon: Icon(Icons.person), label: 'Me'),
            ],
          ),
        ),
      ),
    );

    var grown = await grow(tester);

    expect(grown.from, 956);
    expect(grown.to, greaterThan(956));
    expect(grown.truncated, isFalse);
    expect(find.text('Row 99'), findsOneWidget);
    // Nothing left over: the last row ends where the navigation bar starts.
    expect(
      bottomOf(tester, 'Row 99'),
      closeTo(tester.getTopLeft(find.byType(NavigationBar)).dy, 0.5),
    );
  });

  testWidgets('a screen with nothing to scroll is left as it is', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: Center(child: Text('Only'))),
      ),
    );

    var grown = await grow(tester);

    expect(grown.to, grown.from);
    expect(resizes, 0);
  });

  testWidgets('a list in a box of its own height is left scrolled', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ListView(
            children: [
              for (var i = 0; i < 20; i++) ListTile(title: Text('Top $i')),
              SizedBox(
                height: 200,
                child: ListView(
                  children: [for (var i = 0; i < 30; i++) Text('Inner $i')],
                ),
              ),
              for (var i = 0; i < 20; i++) ListTile(title: Text('Bottom $i')),
            ],
          ),
        ),
      ),
    );

    var grown = await grow(tester);

    // The page's forty rows and the box: what the page holds, and no more.
    expect(grown.to, closeTo(40 * 56 + 200, 0.5));
    expect(grown.truncated, isFalse);
    expect(find.text('Bottom 19'), findsOneWidget);
  });

  testWidgets('a list with no end stops at the cap and says so', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ListView.builder(
            itemBuilder: (_, i) => ListTile(title: Text('Row $i')),
          ),
        ),
      ),
    );

    var grown = await grow(tester, maxHeight: 3000);

    expect(grown.to, 3000);
    expect(grown.truncated, isTrue);
  });

  testWidgets('a list longer than the cap is cut short too', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ListView.builder(
            itemCount: 100,
            itemBuilder: (_, i) => ListTile(title: Text('Row $i')),
          ),
        ),
      ),
    );

    var grown = await grow(tester, maxHeight: 3000);

    expect(grown.to, 3000);
    expect(grown.truncated, isTrue);
  });

  testWidgets('rows a lazy list guessed wrong leave nothing blank below', (
    tester,
  ) async {
    // Tall rows first and short ones after: the list estimates its length
    // from the rows it built, which are the tall ones, and overshoots.
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ListView.builder(
            itemCount: 60,
            itemBuilder: (_, i) =>
                SizedBox(height: i < 10 ? 200 : 20, child: Text('Row $i')),
          ),
        ),
      ),
    );

    var grown = await grow(tester);

    expect(grown.to, closeTo(10 * 200 + 50 * 20, 0.5));
    expect(find.text('Row 59'), findsOneWidget);
  });

  testWidgets('the list under a pushed page is not what the screen grows for', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: ListView.builder(
              itemCount: 100,
              itemBuilder: (_, i) => ListTile(
                title: Text('Row $i'),
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => const Scaffold(body: Text('Details')),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Row 0'));
    await tester.pumpAndSettle();

    var grown = await grow(tester);

    expect(grown.to, grown.from);
    // Not even tried: the list underneath would not have grown with it, and
    // finding that out costs two layouts of a screen nobody photographs.
    expect(resizes, 0);
  });
}
