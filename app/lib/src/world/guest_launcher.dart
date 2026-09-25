import 'dart:async';

import 'package:path/path.dart' as p;
import 'package:vm_service/vm_service.dart';
import 'package:vm_service/vm_service_io.dart';

import '../run/connection.dart';

/// What a guest has instead of a `flutter run`: the owner that compiled it,
/// registered on its VM service under the two services Run looks for,
/// `reloadSources` and `hotRestart`. Run's reload and restart then reach a
/// guest exactly as they reach any app, and Run needs to know nothing about
/// guests.
///
/// What a reload *does* stays the owner's. A world compiles once for all its
/// people, so a reload asked of one person's app reloads everyone's from the
/// one delta — they run one program, and letting two of its copies drift
/// apart would make the next delta wrong for one of them.
class GuestLauncher {
  GuestLauncher._(this._service);

  final VmService _service;

  /// Connects to the guest's VM service at [vmService], the `http://` page it
  /// prints.
  static Future<GuestLauncher> connect(String vmService) async {
    var ws = '${vmService.replaceFirst('http://', 'ws://')}ws';
    return GuestLauncher._(await vmServiceConnectUri(ws));
  }

  /// Registers `reloadSources` and `hotRestart`, answered by [reload] and
  /// [restart] — the owner's, which compile and then call [reloadFrom] and
  /// [restartFrom] on whichever guests they mean.
  Future<void> serve({
    required Future<void> Function() reload,
    required Future<void> Function() restart,
  }) async {
    for (var (name, answer) in [
      ('reloadSources', reload),
      ('hotRestart', restart),
    ]) {
      _service.registerServiceCallback(name, (params) async {
        try {
          await answer();
          return {
            'result': {'type': 'Success'},
          };
        } on Object catch (e) {
          return {
            'error': {'code': -32000, 'message': '$e'},
          };
        }
      });
      // The alias `flutter run` registers under, so anything that reads
      // it — DevTools, an IDE — takes this for what it stands in for.
      await _service.registerService(name, 'Flutter Tools');
    }
  }

  /// Loads the kernel delta at [dill] into the app and has it rebuild.
  Future<void> reloadFrom(String dill) async {
    var isolate = await _rootIsolate();
    var report = await _service.reloadSources(isolate, rootLibUri: dill);
    if (report.success != true) {
      throw StateError(
        'reloadSources refused ${p.basename(dill)}: ${report.json}',
      );
    }
    await _service.callServiceExtension(
      'ext.flutter.reassemble',
      isolateId: isolate,
    );
  }

  /// Starts the app again from the whole program at [dill], in the same
  /// process and the same view — what `flutter run` does for a hot restart,
  /// through the engine's own `_flutter.runInView`, which every embedder's
  /// shell answers.
  Future<void> restartFrom(String dill, {required String assets}) async {
    var views = await _service.callMethod('_flutter.listViews');
    var viewId = ((views.json!['views'] as List).first as Map)['id'];
    try {
      await _service.streamListen(EventStreams.kIsolate);
    } on RPCError {
      // Already listening, from an earlier restart.
    }
    var runnable = _service.onIsolateEvent.firstWhere(
      (event) => event.kind == EventKind.kIsolateRunnable,
    );
    await _service.callMethod(
      '_flutter.runInView',
      args: {
        'viewId': viewId,
        'mainScript': '${p.toUri(dill)}',
        'assetDirectory': '${p.toUri(assets)}',
      },
    );
    await runnable.timeout(const Duration(seconds: 10));
  }

  /// Looked up each time rather than kept: a restart replaces it.
  Future<String> _rootIsolate() async {
    var id = RunConnection.rootIsolateOf((await _service.getVM()).isolates);
    if (id == null) throw StateError('The guest has no isolate to reload.');
    return id;
  }

  Future<void> dispose() => _service.dispose();
}
