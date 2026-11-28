import 'dart:async';
import 'dart:developer' as developer;
import 'dart:isolate' as isolate;

import 'package:vm_service/vm_service.dart';
import 'package:vm_service/vm_service_io.dart';

import 'value_stream.dart';

/// Hot reload and hot restart of the flutterware GUI itself, from inside it.
///
/// Neither is a VM capability. The VM can swap sources, but producing the
/// new kernel is `flutter_tools`' job, so `flutter run` *registers* the two
/// operations as VM-service methods and any client may call them
/// (`packages/flutter_tools/lib/src/vmservice.dart` — `kReloadSourcesServiceName`,
/// `kHotRestartServiceName`, both aliased `Flutter Tools`). Its own comment
/// says why: a client uses the external service instead of the VM's internal
/// one, so it can invoke Flutter hot reload against an app started in hot mode.
///
/// Two consequences worth stating, because they decide what the UI may promise:
///
/// - **No `flutter run`, no reload.** A release build has no VM service at all,
///   and a debug build launched some other way has one with nothing registered.
///   [available] is false in both cases and the buttons do not appear.
/// - **The method names are namespaced per client** — `s0.reloadSources`, not
///   `reloadSources` — and the prefix is assigned by the VM. It cannot be
///   guessed; it arrives in `ServiceRegistered` events, which is why this
///   listens rather than calling a constant.
class HotReload {
  HotReload._(this._service, this._isolateId);

  final VmService _service;
  final String? _isolateId;

  /// Registered name by service name — `reloadSources` -> `s0.reloadSources`.
  final _methods = <String, String>{};

  final _available = ValueStream(false);

  /// Whether `flutter run` is driving this process, so the buttons should show.
  ValueStream<bool> get available => _available;

  /// Connects to this process's own VM service, or returns null when there is
  /// none — which is the ordinary case for anyone who did not build this — or
  /// when it will not take the socket.
  static Future<HotReload?> connect() async {
    developer.ServiceProtocolInfo info;
    try {
      info = await developer.Service.getInfo();
    } on UnsupportedError {
      return null; // No dart:developer service on this platform.
    }
    var uri = info.serverUri;
    if (uri == null) return null;

    VmService service;
    try {
      service = await vmServiceConnectUri(
        hotReloadWebSocketUri(uri).toString(),
      );
    } catch (_) {
      // A scenario with the network off refuses the socket, for one. The
      // buttons' initState calls this without awaiting it, so a throw here
      // would be an error nothing handles.
      return null;
    }
    var reload = HotReload._(
      service,
      developer.Service.getIsolateId(isolate.Isolate.current),
    );
    await reload._watchRegistrations();
    return reload;
  }

  /// The VM publishes what is already registered when the stream is subscribed
  /// to, so listening covers both what exists now and what arrives later.
  Future<void> _watchRegistrations() async {
    _service.onServiceEvent.listen((event) {
      var name = event.service;
      var method = event.method;
      if (name == null || method == null) return;
      if (event.kind == EventKind.kServiceRegistered) {
        _methods[name] = method;
      } else if (event.kind == EventKind.kServiceUnregistered) {
        _methods.remove(name);
      }
      _available.value = _methods.containsKey(_reloadSources);
    });
    await _service.streamListen(EventStreams.kService);
  }

  bool get canReload => _methods.containsKey(_reloadSources);
  bool get canRestart => _methods.containsKey(_hotRestart);

  /// Applies edited sources to the running app.
  Future<void> reload() async {
    var method = _methods[_reloadSources];
    if (method == null) return;
    await _service.callMethod(method, args: {'isolateId': ?_isolateId});
  }

  /// Restarts the app from scratch.
  ///
  /// This tears down the process that drew the button, so nothing after the
  /// call is guaranteed to run — the window goes away and comes back.
  Future<void> restart() async {
    var method = _methods[_hotRestart];
    if (method == null) return;
    await _service.callMethod(method);
  }

  Future<void> dispose() async {
    await _available.close();
    await _service.dispose();
  }
}

/// `Service.getInfo` hands back an HTTP URI; the protocol speaks WebSocket on
/// the same path plus `ws`.
///
/// The auth token is part of the *path*, so appending has to respect whether
/// it already ends in a separator — `…/TOKEN/ws`, never `…/TOKENws`.
Uri hotReloadWebSocketUri(Uri http) => http.replace(
  scheme: 'ws',
  path: http.path.endsWith('/') ? '${http.path}ws' : '${http.path}/ws',
);

const _reloadSources = 'reloadSources';
const _hotRestart = 'hotRestart';
