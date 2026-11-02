@TestOn('browser')
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:flutterware/src/router_outlet/path.dart';
import 'package:flutterware/src/router_outlet/url_source_web.dart';
import 'package:web/web.dart' as web;

void main() {
  // A Flutter web app served under a path has a `<base href>` pointing at its
  // asset folder, and a relative URL handed to the history API resolves
  // against it. The page this test runs in has none, so one is planted.
  late String href;
  late web.HTMLBaseElement base;

  setUp(() {
    href = web.window.location.href;
    base = web.HTMLBaseElement()
      ..href = '${web.window.location.origin}/assets/';
    web.document.head!.append(base);
  });

  tearDown(() {
    base.remove();
    web.window.history.replaceState(null, '', href);
  });

  test('go with replace keeps the page at its own path', () {
    var source = UrlSourceWeb();
    var pathname = web.window.location.pathname;
    var search = web.window.location.search;
    expect(web.document.baseURI, endsWith('/assets/'));

    source.go(PagePath('/detail/1?tab=2'), replace: true);

    expect(web.window.location.pathname, pathname);
    expect(web.window.location.search, search);
    expect(web.window.location.hash, '#/detail/1?tab=2');
    source.dispose();
  });
}
