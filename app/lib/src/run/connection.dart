import 'dart:async';

import 'package:meta/meta.dart';
import 'package:vm_service/vm_service.dart';
import 'package:vm_service/vm_service_io.dart';

/// A connection to one running app's VM service — the only channel the cockpit
/// has once a launch is detached.
///
/// The two tiers are visible here. `hotReload` and `hotRestart` are not VM
/// capabilities: `flutter_tools` *registers* them as service methods on the
/// app's VM service, so they exist exactly as long as the `flutter run` that
/// registered them, and their real names are namespaced by the VM (`s0.`
/// something) rather than fixed. Everything else — the isolate, `ext.flutter.*`
/// — belongs to the app and outlives its launcher. See
/// `app/lib/src/utils/hot_reload.dart`, which does the same thing for this GUI
/// against its own process.
class RunConnection {
  RunConnection._(this.service, this._isolateId);

  final VmService service;

  String? _isolateId;

  /// The app's main isolate — the one every `ext.` call here is addressed to
  /// — or null when it has none yet.
  String? get isolateId => _isolateId;

  /// A connection over a [service] somebody else stood up, for a test — no
  /// `getVM`, no registration wait, because a fake VM has nothing to discover.
  @visibleForTesting
  static Future<RunConnection> forTesting(
    VmService service,
    String isolateId,
  ) async => RunConnection._(service, isolateId);

  final _methods = <String, String>{};

  /// Connects and waits long enough to learn what is registered.
  ///
  /// Throws whatever the connection threw. Callers that only want to know
  /// whether the app is there should use the cheaper `probeRunHandle`, which
  /// does not pay [settle].
  static Future<RunConnection> connect(
    String wsUri, {
    Set<String> waitFor = const {},
    Duration timeout = const Duration(seconds: 5),
    Duration settle = const Duration(milliseconds: 800),
  }) async {
    var service = await vmServiceConnectUri(wsUri).timeout(timeout);
    try {
      var vm = await service.getVM().timeout(timeout);
      var connection = RunConnection._(service, rootIsolateOf(vm.isolates));
      await connection._watchRegistrations(waitFor, settle);
      return connection;
    } on Object {
      unawaited(service.dispose());
      rethrow;
    }
  }

  /// The app's own isolate among [isolates].
  ///
  /// A list, not a single thing. An app is one isolate until something
  /// spawns another — a sync engine, a database worker, a plugin that runs
  /// Dart on a second engine — and the first entry then stops being a safe
  /// guess. Everything this class calls (`ext.flutter.exit`, the drive
  /// transaction, the http profile) lives in the root isolate and nowhere
  /// else, so a wrong pick answers `Unknown method` for all of them:
  /// measured against a live app's worker isolate, `ext.flutterware.act`
  /// comes back as `RPCError -32601`, exactly what a genuinely guest-less app
  /// returns.
  ///
  /// Free in the ordinary case: with one isolate there is nothing to choose,
  /// and the name settles the rest without a round trip — Flutter's root
  /// isolate is `main`. [findIsolateWith] is the version that asks what is
  /// registered, for when this guess turns out wrong.
  static String? rootIsolateOf(List<IsolateRef>? isolates) {
    if (isolates == null || isolates.isEmpty) return null;
    if (isolates.length == 1) return isolates.single.id;
    for (var isolate in isolates) {
      if (isolate.name == 'main') return isolate.id;
    }
    return isolates.first.id;
  }

  /// Which isolate has [extension] registered, re-read from the VM, with a
  /// census of what was asked for the caller's message.
  ///
  /// The expensive, certain answer — one `getIsolate` per isolate — so it is
  /// only paid when the cheap guess has already failed. Both halves are
  /// returned because both are needed: the id to retry against, and the
  /// census so a refusal that says "this app has no guest" can say what it
  /// looked at rather than assert it.
  Future<({String? id, String census})> findIsolateWith(
    String extension,
  ) async {
    List<IsolateRef> isolates;
    try {
      isolates = (await service.getVM()).isolates ?? const [];
    } on Object {
      return (id: null, census: 'the VM would not say which isolates it has');
    }
    String? found;
    var seen = <String>[];
    for (var isolate in isolates) {
      var registered = false;
      try {
        registered =
            (await service.getIsolate(isolate.id!)).extensionRPCs
                ?.contains(extension) ??
            false;
      } on Object {
        // An isolate that exited between the two calls is not an answer, and
        // not a failure either: the census says what it could see.
      }
      seen.add('${isolate.name ?? isolate.id}${registered ? ' ✓' : ''}');
      if (registered) found ??= isolate.id;
    }
    return (id: found, census: seen.join(', '));
  }

  /// Points this connection at [id] — what [findIsolateWith] found.
  void useIsolate(String id) => _isolateId = id;

  /// The VM publishes what is already registered when the stream is subscribed
  /// to, so listening covers both what exists now and what arrives later — but
  /// it publishes them *asynchronously*, and there is no snapshot RPC to ask
  /// instead. So this waits.
  ///
  /// It waits for [waitFor] specifically rather than for [settle] flatly,
  /// because the flat version is most of what a reload costs: the registrations
  /// arrive in tens of milliseconds and sleeping through the rest of the budget
  /// turned an 86ms hot reload into an 886ms one. The full [settle] is still
  /// paid when the method never arrives — which is the case where the answer is
  /// "the launcher is gone", and being sure of that is worth the wait.
  Future<void> _watchRegistrations(Set<String> waitFor, Duration settle) async {
    service.onServiceEvent.listen((event) {
      var name = event.service;
      var method = event.method;
      if (name == null || method == null) return;
      if (event.kind == EventKind.kServiceRegistered) {
        _methods[name] = method;
      } else if (event.kind == EventKind.kServiceUnregistered) {
        _methods.remove(name);
      }
    });
    await service.streamListen(EventStreams.kService);
    if (waitFor.isEmpty) return;
    var deadline = DateTime.now().add(settle);
    while (DateTime.now().isBefore(deadline)) {
      if (waitFor.every(_methods.containsKey)) return;
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
  }

  /// What the launcher registered — `reloadSources`, `hotRestart`,
  /// `flutterVersion`, `compileExpression`. Empty means the app is up and its
  /// `flutter run` is not.
  Set<String> get registered => _methods.keys.toSet();

  Future<void>? _extensions;

  /// Subscribes to the `Extension` stream, once, and answers when the VM has
  /// acknowledged it.
  ///
  /// Deliberately not part of [connect]. Flutter posts `Flutter.Frame` on
  /// this stream for *every frame* it renders
  /// (`scheduler/binding.dart:_profileFramePostEvent`), so subscribing eagerly
  /// would drag sixty events a second across the wire for every connected run,
  /// whether or not anything wanted them. Only a caller that has something to
  /// listen for pays.
  Future<void> listenExtensions() =>
      _extensions ??= service.streamListen(EventStreams.kExtension);

  /// Events posted by the app with `dart:developer`'s `postEvent`. Live only
  /// after [listenExtensions].
  Stream<Event> get extensionEvents => service.onExtensionEvent;

  bool get canReload => _methods.containsKey(_reloadSources);
  bool get canRestart => _methods.containsKey(_hotRestart);

  /// Applies edited sources to the running app.
  ///
  /// Throws [StateError] when the launcher is gone, which is a real state and
  /// not a bug: the app is still there and still inspectable, and the way back
  /// to reloading it is `flutter attach`.
  Future<void> reload() async {
    var method = _methods[_reloadSources];
    if (method == null) {
      throw StateError(
        'Hot reload is not available: the `flutter run` that launched this '
        'app has exited. The app itself is still running.',
      );
    }
    await service.callMethod(method, args: {'isolateId': ?isolateId});
  }

  /// Restarts the app from scratch, without rebuilding it.
  Future<void> restart() async {
    var method = _methods[_hotRestart];
    if (method == null) {
      throw StateError(
        'Hot restart is not available: the `flutter run` that launched this '
        'app has exited. The app itself is still running.',
      );
    }
    await service.callMethod(method);
  }

  /// Asks the app to exit itself.
  ///
  /// The framework's own extension, so it works whoever launched the app and
  /// whether or not a launcher is still alive — unlike killing the `flutter
  /// run`, which on Android leaves the app running on the phone.
  Future<void> exitApp() async {
    var isolate = isolateId;
    if (isolate == null) return;
    try {
      await service.callServiceExtension(
        'ext.flutter.exit',
        isolateId: isolate,
      );
    } on Object {
      // The app exiting is the *point*, and an app that exits mid-call takes
      // the connection with it. A thrown RPC here usually means it worked.
    }
  }

  Future<void> close() => service.dispose();
}

const _reloadSources = 'reloadSources';
const _hotRestart = 'hotRestart';
