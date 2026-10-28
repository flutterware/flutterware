import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutterware/src/world/guest_input.dart';

void main() {
  testWidgets('a link reaches the app whole, as deep linking delivers it', (
    tester,
  ) async {
    var heard = <Uri>[];
    var observer = _Links(heard, takes: true);
    tester.binding.addObserver(observer);
    addTearDown(() => tester.binding.removeObserver(observer));

    var link = 'https://example.com/invite?token=a%2Bb';
    expect(await push(tester, link), isTrue);
    expect(heard, [Uri.parse(link)]);
  });

  testWidgets('a Router goes where the link says', (tester) async {
    var provider = PlatformRouteInformationProvider(
      initialRouteInformation: RouteInformation(uri: Uri.parse('/')),
    );
    addTearDown(provider.dispose);
    await tester.pumpWidget(
      WidgetsApp.router(
        color: const Color(0xFF000000),
        routeInformationProvider: provider,
        routeInformationParser: _Parser(),
        routerDelegate: _Delegate(),
      ),
    );
    expect(find.text('/'), findsOneWidget);

    expect(await push(tester, 'https://example.com/invite'), isTrue);
    await tester.pump();
    expect(find.text('/invite'), findsOneWidget);
  });

  testWidgets('says when nothing in the app took it', (tester) async {
    var observer = _Links([], takes: false);
    tester.binding.addObserver(observer);
    addTearDown(() => tester.binding.removeObserver(observer));

    expect(await push(tester, 'https://example.com/x'), isFalse);
  });
}

/// The channel answers on the real event loop, which a widget test's fake
/// clock does not run.
Future<bool?> push(WidgetTester tester, String link) =>
    tester.runAsync(() => pushRouteInformation(link));

class _Links with WidgetsBindingObserver {
  _Links(this.heard, {required this.takes});

  final List<Uri> heard;
  final bool takes;

  @override
  Future<bool> didPushRouteInformation(RouteInformation routeInformation) {
    heard.add(routeInformation.uri);
    return Future.value(takes);
  }
}

class _Parser extends RouteInformationParser<String> {
  @override
  Future<String> parseRouteInformation(RouteInformation routeInformation) =>
      Future.value(routeInformation.uri.path);
}

class _Delegate extends RouterDelegate<String> with ChangeNotifier {
  var _path = '/';

  @override
  String get currentConfiguration => _path;

  @override
  Future<void> setNewRoutePath(String configuration) async {
    _path = configuration;
    notifyListeners();
  }

  @override
  Future<bool> popRoute() => Future.value(false);

  @override
  Widget build(BuildContext context) =>
      Text(_path, textDirection: TextDirection.ltr);
}
