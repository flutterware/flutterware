import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutterware/run_guest.dart' show GuestDrive;
import 'package:flutterware/src/router_outlet/path.dart';
import 'package:flutterware/src/router_outlet/router_outlet.dart';
import 'package:flutterware/src/router_outlet/router_root.dart';
import 'package:flutterware/src/router_outlet/url_source_fake.dart';

void main() {
  Widget app(UrlSourceFake source) {
    return RouterRoot(
      urlSource: source,
      child: RouterOutlet({
        'detail/:id': (c) => _RouteState(id: c['id']),
        '': (c) => const Text('home', textDirection: TextDirection.ltr),
      }),
    );
  }

  testWidgets('changing a path argument tears down the route state', (
    tester,
  ) async {
    var source = UrlSourceFake(initial: PagePath('/detail/1'));
    await tester.pumpWidget(app(source));
    expect(find.text('init:1 current:1'), findsOneWidget);

    source.go(PagePath('/detail/2'));
    await tester.pump();
    expect(find.text('init:2 current:2'), findsOneWidget);
  });

  testWidgets('changing only query parameters keeps the route state', (
    tester,
  ) async {
    var source = UrlSourceFake(initial: PagePath('/detail/1'));
    await tester.pumpWidget(app(source));
    expect(find.text('init:1 current:1'), findsOneWidget);

    source.go(PagePath('/detail/1?tab=2'));
    await tester.pump();
    expect(find.text('init:1 current:1'), findsOneWidget);
  });

  testWidgets('navigating to another route swaps the widget', (tester) async {
    var source = UrlSourceFake(initial: PagePath('/detail/1'));
    await tester.pumpWidget(app(source));

    source.go(PagePath.root);
    await tester.pump();
    expect(find.text('home'), findsOneWidget);

    source.go(PagePath('/detail/3'));
    await tester.pump();
    expect(find.text('init:3 current:3'), findsOneWidget);
  });

  group('a route the platform pushes', () {
    tearDown(() => GuestDrive.navigator = null);

    testWidgets('moves the source, query string included', (tester) async {
      var source = UrlSourceFake(initial: PagePath('/detail/1'));
      await tester.pumpWidget(app(source));

      var taken = await _pushRoute(tester, '/detail/7?tab=2');
      await tester.pump();

      expect(taken, isTrue);
      expect(source.current, PagePath('/detail/7?tab=2'));
      expect(find.text('init:7 current:7'), findsOneWidget);
    });

    testWidgets('is no longer taken once the root is gone', (tester) async {
      await tester.pumpWidget(app(UrlSourceFake(initial: PagePath.root)));
      await tester.pumpWidget(const SizedBox());

      var taken = await _pushRoute(tester, '/detail/8');

      expect(taken, isFalse);
    });
  });

  group('the drive navigate handler', () {
    tearDown(() => GuestDrive.navigator = null);

    testWidgets('is registered by RouterRoot and moves the source', (
      tester,
    ) async {
      var source = UrlSourceFake(initial: PagePath('/detail/1'));
      await tester.pumpWidget(app(source));

      GuestDrive.navigator!('/detail/2?tab=3');
      await tester.pump();

      expect(source.current, PagePath('/detail/2?tab=3'));
      expect(source.current.queryParameters, {'tab': '3'});
      expect(find.text('init:2 current:2'), findsOneWidget);

      // A relative route is taken from the root, the way the URL carries it.
      GuestDrive.navigator!('detail/4');
      await tester.pump();
      expect(find.text('init:4 current:4'), findsOneWidget);
    });

    testWidgets('follows the source a RouterRoot is given', (tester) async {
      var first = UrlSourceFake(initial: PagePath.root);
      var second = UrlSourceFake(initial: PagePath.root);
      await tester.pumpWidget(app(first));
      await tester.pumpWidget(app(second));

      GuestDrive.navigator!('/detail/5');
      await tester.pump();

      expect(second.current, PagePath('/detail/5'));
      expect(first.current, PagePath.root);
    });

    testWidgets('survives a replacement root and leaves with the last one', (
      tester,
    ) async {
      // A new root's initState runs before the old root's dispose, so the old
      // one must not clear a slot that is no longer its own.
      var first = UrlSourceFake(initial: PagePath.root);
      var second = UrlSourceFake(initial: PagePath.root);
      await tester.pumpWidget(
        KeyedSubtree(key: UniqueKey(), child: app(first)),
      );
      await tester.pumpWidget(
        KeyedSubtree(key: UniqueKey(), child: app(second)),
      );

      expect(GuestDrive.navigator, isNotNull);
      GuestDrive.navigator!('/detail/6');
      await tester.pump();
      expect(second.current, PagePath('/detail/6'));

      await tester.pumpWidget(const SizedBox());
      expect(GuestDrive.navigator, isNull);
    });
  });
}

/// What the engine sends when the platform opens the app on a link.
Future<bool> _pushRoute(WidgetTester tester, String location) async {
  var channel = SystemChannels.navigation;
  var reply = Completer<bool>();
  await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
    channel.name,
    channel.codec.encodeMethodCall(
      MethodCall('pushRouteInformation', {'location': location, 'state': null}),
    ),
    (data) => reply.complete(
      data != null && channel.codec.decodeEnvelope(data) == true,
    ),
  );
  return reply.future;
}

class _RouteState extends StatefulWidget {
  final String id;

  const _RouteState({required this.id});

  @override
  State<_RouteState> createState() => _RouteStateState();
}

class _RouteStateState extends State<_RouteState> {
  // Captured once: only survives navigation if the State is reused.
  late final String initialId = widget.id;

  @override
  Widget build(BuildContext context) {
    return Text(
      'init:$initialId current:${widget.id}',
      textDirection: TextDirection.ltr,
    );
  }
}
