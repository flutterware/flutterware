import 'dart:async';
import 'dart:js_interop';

import 'package:flutter_web_plugins/flutter_web_plugins.dart';
import 'package:web/web.dart' as html;

import 'path.dart';
import 'url_source.dart';

UrlSource createSource() => UrlSourceWeb();

class UrlSourceWeb implements UrlSource {
  final _onChangeController = StreamController<PagePath>.broadcast();
  late PagePath _current;

  UrlSourceWeb() {
    setUrlStrategy(null);

    html.window.addEventListener(
      'hashchange',
      () {
        var path = _getHash();
        // Path with extra should not be replaced with the event triggered
        // by the change in the hash
        if (!path.equalsWithoutExtra(_current)) {
          go(path);
        }
      }.toJS,
    );

    _current = _getHash();
  }

  PagePath _getHash() {
    var hash = html.window.location.hash;
    if (hash.startsWith('#')) {
      hash = hash.substring(1);
    }
    return PagePath(hash, isAbsolute: true);
  }

  @override
  Stream<PagePath> get onChange => _onChangeController.stream;

  @override
  PagePath get current => _current;

  @override
  void go(PagePath path, {bool replace = false}) {
    assert(path.isAbsolute);

    // Change in the extra should trigger an onChange
    if (!path.equalsWithExtra(current)) {
      _current = path;
      _onChangeController.add(path);
      if (replace) {
        // replaceState overwrites the current entry and — unlike assigning
        // location.hash — does not fire `hashchange`. We already notified
        // in-app listeners above, so no external event is needed.
        //
        // The page's own path and query are spelled out because a relative
        // URL here resolves against the document's `<base href>`, and a
        // Flutter web app served under a path points that at its asset
        // folder. A bare `#…` moved the address to that folder, and a reload
        // asked the server for it. Assigning `location.hash` never resolves
        // anything, so the other branch keeps its short form.
        var location = html.window.location;
        html.window.history.replaceState(
          null,
          '',
          '${location.pathname}${location.search}#${path.toString()}',
        );
      } else {
        html.window.location.hash = path.toString();
      }
    }
  }

  @override
  void dispose() {
    _onChangeController.close();
  }
}
