import 'dart:async';

import 'package:flutter/widgets.dart';

import '../inspect/guest_errors.dart';
import '../inspect/guest_images.dart';
import '../inspect/guest_inspect.dart';
import '../inspect/guest_logs.dart';
import '../server/vm_transport.dart';
import 'guest_drive.dart';
import 'http_capture_stub.dart' if (dart.library.io) 'http_capture_io.dart';
import 'human_actions.dart';

/// Installs the run guest around a user app's `main` — what the generated
/// run entrypoint calls.
///
/// The whole of main runs inside the log-capturing zone, binding and all —
/// same rule as the previews entrypoint, and just as irreversible:
/// `PlatformDispatcher.onBeginFrame` captures `Zone.current` when it is set,
/// and the binding sets it in `initInstances`. A zone started after
/// `ensureInitialized` would capture nothing from build, layout or paint,
/// which is where the prints this exists for come from.
///
/// Unlike the previews guest there is no keyboard or text-input replacement
/// here: this app runs on a real platform with a real IME, and `enterText`
/// goes through `TextInput.updateEditingValue` instead.
FutureOr<void> runGuest(FutureOr<void> Function() appMain) {
  return GuestLogs.instance.install(() {
    // Before anything that could open a connection: the http profile records
    // nothing retroactively, and startup requests are the ones a host can
    // never catch by enabling over the wire.
    armHttpCapture();
    RunGuestBinding.ensureInitialized();
    // Framework errors, on stdout *and* kept where they can be asked for —
    // the bundle's `errors` field is the diff of this buffer.
    GuestErrors.instance.install();
    GuestErrors.instance.registerExtensions();
    GuestImages.instance.registerExtensions();
    GuestLogs.instance.registerExtensions();
    // The whole app is the subject — no catalog chrome to scope away, so the
    // root element is the root of the reported tree. Null until the first
    // build, and that is an answer.
    var inspector = GuestInspector(
      rootOf: () => WidgetsBinding.instance.rootElement,
      entryIdOf: () => null,
    )..registerExtensions();
    // Held for the life of the run, unlike the catalog's — which turns it on
    // only while the Semantics tab is open, because there it is a tab nobody
    // may have opened. Here it is load-bearing: it is what says which control
    // is the current one, and what labels the ones the app never labelled, so
    // the screen in every reply depends on it.
    //
    // Free, and measured rather than assumed: 24 timed taps came back at a
    // median of 431ms without the handle and 434ms with it, and a frame-timing
    // probe over 30 whole-tree-dirty frames could not separate the two. iOS
    // turns semantics on by itself; Android does not, which is the case this
    // covers.
    inspector.enableSemantics(true);
    // The other half of co-driving: the human's taps between tool steps ride
    // the next reply and land in the journal as `actor: human`.
    var humanActions = HumanActions()..install();
    GuestDrive(
      inspector: inspector,
      humanActions: humanActions,
    ).registerExtensions();
    // The channel transport, with no channels on it yet. Installed here rather
    // than by whoever first has something to report, because registering an
    // extension after the host has already looked for it is a race the host
    // cannot win — and an empty channel list is a real answer.
    GuestChannels.install();
    return appMain();
  });
}

/// The binding a guest makes before the app's own `main` runs.
///
/// An app that wraps `main` in a zone of its own — `runZonedGuarded` around
/// the lot, which is how a crash reporter is set up — calls `runApp` from that
/// zone, and Flutter checks it is the zone the binding was made in. Without
/// flutterware it is: the app's own `ensureInitialized` made the binding
/// there. Under a guest the binding is the guest's, made in the zone that
/// wraps the app's, so every such launch printed "Zone mismatch" as though the
/// app had got it wrong, and every drive step carried it under `errors`.
///
/// So a zone inside the one the binding was made in passes. That nesting is
/// the guest's doing, never the app's; a zone that is *not* inside it still
/// gets Flutter's own error. What the message warns about does hold here, and
/// is the price of a binding made before the app runs: frames run in the
/// guest's zone, so an error a build throws asynchronously reaches
/// `PlatformDispatcher.onError` rather than the app's zone handler.
/// `FlutterError.onError`, where the framework reports what it catches, is
/// unaffected.
class RunGuestBinding extends WidgetsFlutterBinding {
  /// Makes the guest's binding, unless a guest already made one — the world
  /// guest makes its own subclass first, for what only a binding can do.
  static WidgetsBinding ensureInitialized() {
    if (_made == null) RunGuestBinding();
    return WidgetsBinding.instance;
  }

  static RunGuestBinding? _made;

  late final Zone _zone;

  @override
  void initInstances() {
    super.initInstances();
    // The zone the binding records for its own check, which is the one this
    // constructor runs in.
    _zone = Zone.current;
    _made = this;
  }

  @override
  bool debugCheckZone(String entryPoint) {
    for (Zone? zone = Zone.current; zone != null; zone = zone.parent) {
      if (identical(zone, _zone)) return true;
    }
    return super.debugCheckZone(entryPoint);
  }
}
