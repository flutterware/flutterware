import 'package:flutterware/world.dart';

/// What a person's browser shows before the route their app reports: the
/// address the app is served at ([Launch.url]), or the entry point's name as
/// a host, `lab.localhost`, for an app the world gave no address.
String browserHost(Launch? app) {
  if (app?.url case var url?) {
    return url.endsWith('/') ? url.substring(0, url.length - 1) : url;
  }
  var name = app?.entrypoint ?? 'app';
  var slug = name.toLowerCase().replaceAll(RegExp('[^a-z0-9]+'), '-');
  return '$slug.localhost';
}

/// The route [link] goes to in an app served at [address] ([Launch.url]),
/// or null when [link] is not under that address.
///
/// Under it means the same scheme, host and port, and a path that is the
/// address's or below it. The route is what follows the address, read the
/// way a Flutter web app reads its location: after the `#` when the rest
/// starts `#/`, as the hash strategy writes it
/// (`…/clinic/acme#/invitation/t1` goes to `/invitation/t1`), and otherwise
/// the path after the address with its query
/// (`…/clinic/acme/invitation/t1?x=1` goes to `/invitation/t1?x=1`).
String? routeUnder(String address, String link) {
  var served = Uri.tryParse(address);
  var uri = Uri.tryParse(link.trim());
  if (served == null || uri == null || !uri.hasScheme) return null;
  if (uri.scheme != served.scheme ||
      uri.host != served.host ||
      uri.port != served.port) {
    return null;
  }
  var base = served.path.endsWith('/')
      ? served.path.substring(0, served.path.length - 1)
      : served.path;
  if (uri.path != base && !uri.path.startsWith('$base/')) return null;
  var rest = uri.path.substring(base.length);
  if ((rest.isEmpty || rest == '/') &&
      uri.hasFragment &&
      uri.fragment.startsWith('/')) {
    return uri.fragment;
  }
  return '${rest.isEmpty ? '/' : rest}${uri.hasQuery ? '?${uri.query}' : ''}';
}

/// The route an address typed into a person's browser goes to, or null for
/// a link to open in their app instead.
///
/// An address under [host] ([browserHost]) goes to its route, as
/// [routeUnder] reads it; typed without its scheme, it is taken as the
/// app's. Any other address with a scheme is a link. Anything else is taken
/// from its first `/`, so a path typed alone goes to that path.
String? typedRoute(String typed, {required String host}) {
  var scheme = RegExp('^[a-zA-Z][a-zA-Z0-9+.-]*://');
  if (scheme.firstMatch(host) case var served?) {
    if (!scheme.hasMatch(typed) &&
        typed.startsWith(host.substring(served.end))) {
      typed = '${served[0]}$typed';
    }
    if (scheme.hasMatch(typed)) return routeUnder(host, typed);
  }
  if (scheme.hasMatch(typed)) return null;
  var slash = typed.indexOf('/');
  return slash < 0 ? '/' : typed.substring(slash);
}
