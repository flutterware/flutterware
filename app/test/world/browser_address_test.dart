import 'package:flutter_test/flutter_test.dart';
import 'package:flutterware/world.dart';
import 'package:flutterware_app/src/world/web_address.dart';

void main() {
  test('a browser shows where the app is served, or its entry point as a '
      'host', () {
    expect(browserHost(const Launch('Lab')), 'lab.localhost');
    expect(browserHost(const Launch('Front desk')), 'front-desk.localhost');
    expect(
      browserHost(
        const Launch('Desk', url: 'http://localhost:8080/clinic/acme/'),
      ),
      'http://localhost:8080/clinic/acme',
    );
  });

  test("an address typed under the app's own goes to the route after it, "
      'with or without its scheme', () {
    const host = 'http://localhost:8080/clinic/acme';
    String? go(String typed) => typedRoute(typed, host: host);

    expect(go('http://localhost:8080/clinic/acme/patients/3'), '/patients/3');
    expect(go('localhost:8080/clinic/acme/patients'), '/patients');
    expect(go('http://localhost:8080/clinic/acme'), '/');
    expect(go('http://localhost:8080/clinic/acme?tab=2'), '/?tab=2');
    // A web build on the hash strategy reads its route after the `#`.
    expect(go('http://localhost:8080/clinic/acme#/patients/3'), '/patients/3');
    // A path alone is a route of this app.
    expect(go('/patients'), '/patients');
    // Anything else with a scheme is a link, opened in the app.
    expect(go('http://localhost:8080/clinic/other'), isNull);
    expect(go('lab://orders/o3'), isNull);
  });

  test('a link under the address an app is served at is the route after '
      'it, read as a web build reads its location', () {
    const served = 'http://localhost:20032/clinic/acme';
    String? route(String link) => routeUnder(served, link);

    // The hash strategy: the route is what follows the `#`, query included.
    expect(
      route('http://localhost:20032/clinic/acme#/invitation/t1'),
      '/invitation/t1',
    );
    expect(
      route('http://localhost:20032/clinic/acme/#/invitation/t1?x=1'),
      '/invitation/t1?x=1',
    );
    // The path strategy: the path after the address, with its query.
    expect(
      route('http://localhost:20032/clinic/acme/invitation/t1?x=1'),
      '/invitation/t1?x=1',
    );
    expect(route('http://localhost:20032/clinic/acme'), '/');
    expect(route('http://localhost:20032/clinic/acme/'), '/');
    // An anchor is not a route.
    expect(route('http://localhost:20032/clinic/acme/help#top'), '/help');
    expect(routeUnder('$served/', '$served/patients'), '/patients');
    expect(routeUnder('http://localhost:20032', '$served/x'), '/clinic/acme/x');

    // Not under it: another scheme, host, port or path.
    for (var link in [
      'https://localhost:20032/clinic/acme#/invitation/t1',
      'http://127.0.0.1:20032/clinic/acme#/invitation/t1',
      'http://localhost:20033/clinic/acme#/invitation/t1',
      'http://localhost:20032/clinic/acmex#/invitation/t1',
      'http://localhost:20032/clinic#/invitation/t1',
      'clinic://invitation/t1',
      '/invitation/t1',
      'not a link',
    ]) {
      expect(route(link), isNull, reason: link);
    }
  });

  test('an app with no address of its own takes a route after its host', () {
    expect(
      typedRoute('lab.localhost/orders', host: 'lab.localhost'),
      '/orders',
    );
    expect(typedRoute('lab.localhost', host: 'lab.localhost'), '/');
    expect(typedRoute('lab://orders/o3', host: 'lab.localhost'), isNull);
  });
}
