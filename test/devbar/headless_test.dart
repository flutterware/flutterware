import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:material_ui/material_ui.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutterware/devbar.dart';

/// The subject: something with enough going on that a stray `FittedBox` or an
/// extra `Stack` child would move a pixel.
Widget _app() => MaterialApp(
  home: Scaffold(
    appBar: AppBar(title: const Text('Subject')),
    body: Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text('hello'),
          Container(width: 120, height: 40, color: Colors.teal),
          const Icon(Icons.star, size: 48),
        ],
      ),
    ),
    floatingActionButton: FloatingActionButton(
      onPressed: () {},
      child: const Icon(Icons.add),
    ),
  ),
);

/// Photographs the root view exactly the way the run guest does
/// (`lib/src/drive/guest_drive.dart`'s `_screenshot`) — the same layer, the
/// same rasterisation. Comparing anything else would be comparing something
/// the cockpit never looks at.
Future<Uint8List> _shot(WidgetTester tester, Widget child) async {
  await tester.pumpWidget(child);
  await tester.pumpAndSettle();
  var view = tester.binding.renderViews.single;
  var dpr = view.flutterView.devicePixelRatio;
  var image = (view.debugLayer! as OffsetLayer).toImageSync(
    Offset.zero & (view.size * dpr),
    pixelRatio: 1 / dpr,
  );
  late Uint8List bytes;
  await tester.runAsync(() async {
    bytes = (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!.buffer
        .asUint8List();
  });
  image.dispose();
  return bytes;
}

void main() {
  /// E2, the gate on the whole devbar split.
  ///
  /// The cockpit photographs the app's tree: every `flutterware_act` reply,
  /// every scenario shot, every screenshot in the Screen tab. If mounting a
  /// devbar changes one pixel, then every one of those pictures is of a
  /// slightly different app than the one that ships, and nobody would ever
  /// connect the difference back to here.
  ///
  /// `overlayVisible: false` deliberately does *not* satisfy this — see the
  /// test below it, which is why `headless` had to exist as a separate path.
  testWidgets('a headless devbar leaves the picture byte-identical', (
    tester,
  ) async {
    var bare = await _shot(tester, _app());
    var wrapped = await _shot(
      tester,
      Devbar(plugins: const [], headless: true, child: _app()),
    );

    expect(wrapped, bare);
  });

  /// What `overlayVisible: false` does not buy, measured.
  ///
  /// The pixels *do* match with the panel shut and no plugin adding a button —
  /// which was not what this design assumed, and is recorded here so nobody
  /// re-derives the wrong reason. What does not match is the tree, and the
  /// tree is half of what an `act` reply carries: `Target` resolution walks
  /// it, `nth` counts in it, and a tap resolves against it.
  testWidgets('hiding the button leaves the chrome in the tree', (
    tester,
  ) async {
    await tester.pumpWidget(
      Devbar(
        plugins: const [],
        headless: false,
        overlayVisible: false,
        child: _app(),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(FittedBox), findsWidgets);
    expect(find.byIcon(Icons.bug_report), findsNothing);

    await tester.pumpWidget(
      Devbar(plugins: const [], headless: true, child: _app()),
    );
    await tester.pumpAndSettle();

    expect(find.byType(FittedBox), findsNothing);
  });

  testWidgets('a headless devbar still hosts its plugins and its flags', (
    tester,
  ) async {
    var flag = FeatureFlag<bool>('newCheckout', false);
    DevbarState? state;
    bool? seen;

    await tester.pumpWidget(
      Devbar(
        plugins: [(devbar) => _CountingPlugin()],
        headless: true,
        flags: [flag.withValue(true)],
        child: Builder(
          builder: (context) {
            state = Devbar.of(context);
            seen = flag.dependsOnValue(context);
            return const SizedBox();
          },
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(state, isNotNull, reason: 'the state is still findable by plugins');
    expect(state!.maybePlugin<_CountingPlugin>(), isNotNull);
    expect(seen, isTrue, reason: 'a flag works with nobody watching the panel');
  });

  /// The first frame is deferred while plugins load, so a throwing factory
  /// used to leave it deferred forever: a blank window, the error buried in a
  /// future nobody awaits. The contract now is that the error is *reported*
  /// and the app still comes up.
  testWidgets('a throwing plugin factory is reported, not a blank app', (
    tester,
  ) async {
    await tester.pumpWidget(
      Devbar(
        plugins: [
          (devbar) => throw StateError('broken factory'),
          (devbar) => _CountingPlugin(),
        ],
        headless: true,
        child: _app(),
      ),
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isA<StateError>());
    expect(find.text('hello'), findsOneWidget);
  });

  testWidgets('the overlay is absent from the tree, not merely invisible', (
    tester,
  ) async {
    await tester.pumpWidget(
      Devbar(plugins: const [], headless: true, child: _app()),
    );
    await tester.pumpAndSettle();

    expect(find.byIcon(Icons.bug_report), findsNothing);
    expect(find.byType(FittedBox), findsNothing);
  });

  /// The ambient defaults are not chrome, and this is what it cost to learn
  /// that. Reported by a consumer wiring Run into a real app: the visible
  /// branch supplied a `Directionality` for the overlay's own `Stack` and the
  /// headless branch did not, so an app with a widget above its `MaterialApp`
  /// that needed one rendered *nothing* and logged `No Directionality widget
  /// found`. Only ever under flutterware, because `isHeadless` defaults to
  /// `GuestChannels.installed` — a plain `flutter run` took the branch that
  /// supplied one, so the author saw it break in the single path they could
  /// not reproduce, in a widget they had written themselves.
  ///
  /// The subject is that shape: a `Stack` above the app's `MaterialApp`, which
  /// is the environment banner / device frame / watermark every one of these
  /// apps has. It must render under both branches and by the same rule as
  /// every other widget — the picture test above is what holds the two to
  /// identical *pixels*; this holds them to identical *inherited context*.
  testWidgets('a banner above the app renders headless as it does visible', (
    tester,
  ) async {
    for (var headless in [true, false]) {
      await tester.pumpWidget(
        Devbar(
          plugins: const [],
          headless: headless,
          child: Stack(
            children: [
              _app(),
              const Positioned(top: 0, left: 0, child: Text('staging')),
            ],
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(
        tester.takeException(),
        isNull,
        reason:
            'headless: $headless — the banner needs an ambient '
            'Directionality, and the devbar is what supplies it',
      );
      expect(find.text('staging'), findsOneWidget);
      expect(find.text('hello'), findsOneWidget);
    }
  });
}

class _CountingPlugin implements DevbarPlugin {
  @override
  void dispose() {}
}
