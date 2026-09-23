import 'package:material_ui/material_ui.dart';
import 'package:flutterware/flutter_test.dart';

/// The reachability rule behind every pointer verb: a target below the fold is
/// scrolled into view first, and one the pointer cannot reach is refused
/// loudly — where `flutter_test` alone prints a warning and lets the flow
/// sail on from the wrong screen.
void main() {
  scenario('a tap below the fold scrolls its target into view first', (
    s,
  ) async {
    await s.pumpWidget(const _TallApp());
    // Built — a SingleChildScrollView builds everything — but off screen,
    // which is exactly the case a raw tap silently misses.
    expect(find.text('Buy'), findsOneWidget);

    await s.tap('Buy');

    expect(find.text('bought'), findsOneWidget);
  });

  scenario('enterText scrolls the field into view too', (s) async {
    await s.pumpWidget(const _TallApp());

    await s.enterText(const Key('name'), 'Xavier');

    expect(find.text('Xavier'), findsOneWidget);
  });

  scenario('a covered target is refused, not silently missed', (s) async {
    await s.pumpWidget(const _CoveredApp());

    await expectLater(
      () => s.tap('Buy'),
      throwsA(
        isA<ScenarioTargetError>().having(
          (e) => '$e',
          'message',
          allOf(contains('"Buy"'), contains('covers it')),
        ),
      ),
    );
    // The covered button was never pressed through the overlay.
    expect(find.text('bought'), findsNothing);
  });

  scenario('off screen with nothing scrolling to it is refused', (s) async {
    await s.pumpWidget(const _OffstageApp());

    await expectLater(
      () => s.tap('Buy'),
      throwsA(
        isA<ScenarioTargetError>().having(
          (e) => '$e',
          'message',
          allOf(contains('"Buy"'), contains('off screen')),
        ),
      ),
    );
  });

  scenario('an unbuilt lazy-list item points at scrollTo', (s) async {
    await s.pumpWidget(const _LazyListApp());

    await expectLater(
      () => s.tap('Item 40'),
      throwsA(
        isA<ScenarioTargetError>().having(
          (e) => '$e',
          'message',
          allOf(contains('nothing matches'), contains('s.scrollTo')),
        ),
      ),
    );
  });
}

/// A screen taller than the viewport: the button and the field live below the
/// fold of a `SingleChildScrollView`, in the tree but out of reach.
class _TallApp extends StatefulWidget {
  const _TallApp();

  @override
  State<_TallApp> createState() => _TallAppState();
}

class _TallAppState extends State<_TallApp> {
  var _note = '';

  @override
  Widget build(BuildContext context) => MaterialApp(
    home: Scaffold(
      body: SingleChildScrollView(
        child: Column(
          children: [
            Text(_note),
            const SizedBox(height: 2000),
            TextButton(
              onPressed: () => setState(() => _note = 'bought'),
              child: const Text('Buy'),
            ),
            const TextField(key: Key('name')),
          ],
        ),
      ),
    ),
  );
}

/// The button is on screen, and an opaque overlay takes every pointer first.
class _CoveredApp extends StatefulWidget {
  const _CoveredApp();

  @override
  State<_CoveredApp> createState() => _CoveredAppState();
}

class _CoveredAppState extends State<_CoveredApp> {
  var _note = '';

  @override
  Widget build(BuildContext context) => MaterialApp(
    home: Scaffold(
      body: Stack(
        children: [
          Center(
            child: TextButton(
              onPressed: () => setState(() => _note = 'bought'),
              child: const Text('Buy'),
            ),
          ),
          Text(_note),
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () {},
            ),
          ),
        ],
      ),
    ),
  );
}

/// The button sits at y=2000 of an unclipped stack — off screen, and nothing
/// around it scrolls.
class _OffstageApp extends StatelessWidget {
  const _OffstageApp();

  @override
  Widget build(BuildContext context) => MaterialApp(
    home: Scaffold(
      body: Stack(
        clipBehavior: Clip.none,
        children: [
          Positioned(
            top: 2000,
            left: 0,
            child: TextButton(onPressed: () {}, child: const Text('Buy')),
          ),
        ],
      ),
    ),
  );
}

class _LazyListApp extends StatelessWidget {
  const _LazyListApp();

  @override
  Widget build(BuildContext context) => MaterialApp(
    home: Scaffold(
      body: ListView.builder(
        itemCount: 60,
        itemBuilder: (context, i) =>
            SizedBox(height: 80, child: Text('Item $i')),
      ),
    ),
  );
}
