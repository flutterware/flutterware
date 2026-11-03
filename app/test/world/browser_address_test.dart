import 'package:flutter_test/flutter_test.dart';
import 'package:flutterware/world.dart';
import 'package:flutterware_app/src/world/world_person.dart';

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

  test('an address typed under the app\'s own goes to the route after it, '
      'with or without its scheme', () {
    const host = 'http://localhost:8080/clinic/acme';
    String? go(String typed) => typedRoute(typed, host: host);

    expect(go('http://localhost:8080/clinic/acme/patients/3'), '/patients/3');
    expect(go('localhost:8080/clinic/acme/patients'), '/patients');
    expect(go('http://localhost:8080/clinic/acme'), '/');
    expect(go('http://localhost:8080/clinic/acme?tab=2'), '/?tab=2');
    // A path alone is a route of this app.
    expect(go('/patients'), '/patients');
    // Anything else with a scheme is a link, opened in the app.
    expect(go('http://localhost:8080/clinic/other'), isNull);
    expect(go('lab://orders/o3'), isNull);
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
