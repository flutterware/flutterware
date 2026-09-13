import 'dart:async';
import 'dart:js_interop';

import 'package:web/web.dart' as web;

/// Rewrites the page's fragment in place, without growing the history.
///
/// [fragment] is the decoded form; `Uri` spells the escapes, so an id's own
/// `#` survives the address bar. `replaceState` rather than assigning
/// `location.hash`, because thirty row clicks must not become thirty presses
/// of the back button.
///
/// The entry keeps whatever [pushUrlFragment] recorded on it: rewriting where
/// an entry is does not change where it was pushed from.
void writeUrlFragment(String fragment) {
  web.window.history.replaceState(
    web.window.history.state,
    '',
    Uri(fragment: fragment).toString(),
  );
}

/// Moves the page's fragment to [fragment] as a new history entry, so the
/// back button returns to the one before it. Spelled like [writeUrlFragment],
/// and like it fires no `hashchange`: the page already knows where it went.
///
/// [from] is recorded on the entry and read back by [urlFragmentPushedFrom],
/// so a page drawing its own back arrow can tell whether the browser's back
/// button would go to the same place.
void pushUrlFragment(String fragment, {String? from}) {
  web.window.history.pushState(
    from?.toJS,
    '',
    Uri(fragment: fragment).toString(),
  );
}

/// What the current entry was pushed from, or null when the page did not push
/// it — the entry a link arrived on, or one another page wrote.
String? get urlFragmentPushedFrom {
  var state = web.window.history.state;
  return state.isA<JSString>() ? (state! as JSString).toDart : null;
}

/// The browser's back button.
void urlHistoryBack() => web.window.history.back();

/// The decoded fragment, each time the browser itself changes it — a
/// hand-edited address, or history the page did not write.
Stream<String> get urlFragmentChanges {
  late StreamController<String> controller;
  JSFunction? listener;
  controller = StreamController<String>(
    onListen: () {
      listener = ((web.Event _) => controller.add(Uri.base.fragment)).toJS;
      web.window.addEventListener('hashchange', listener);
    },
    onCancel: () {
      if (listener case var held?) {
        web.window.removeEventListener('hashchange', held);
      }
      unawaited(controller.close());
    },
  );
  return controller.stream;
}
