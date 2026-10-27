import 'dart:convert';
import 'dart:io';

import 'package:flutterware/plugins.dart';
import 'package:meta/meta.dart';

import '../../utils/run_dir.dart';
import '../plugin_core.dart';
import '../plugin_host.dart';
import 'delegated_service_core.dart';
import 'dev_stack_results.dart';
import 'owned_service_core.dart';
import 'stack_service_core.dart';

export 'delegated_service_core.dart';
export 'owned_service_core.dart';
export 'service_handle.dart';
export 'stack_service_core.dart';

/// The registered id — also what `tool/flutterware.dart` declares.
const devStackPluginId = 'flutterware.dev_stack';

const _pluginDescription =
    'The services the app talks to locally — docker, the database, the API '
    "server — each one either run by the project's own commands or started "
    'and stopped by flutterware itself, read and driven from one list.';

/// The dev stack: docker, the database, the API server, whatever the app talks
/// to locally.
///
/// **A container.** Each declared service has its own [StackServiceCore] with
/// its own probe, control, commands and poll timer; what is here is only what
/// a plugin owes its shell and cannot be held by any one of them — the report,
/// action dispatch, the cache file, and the aggregate the sidebar shows when
/// there is no room for a list.
///
/// Holds to the [PluginCore.computeAll] budget by reading the cache file and
/// nothing else. Probing is a subprocess, so it happens only when something is
/// watching ([watch]) or when a caller named the action.
class DevStackCore extends PluginCore {
  DevStackCore(super.host) {
    for (var declared in StackService.listFromConfig(host.config)) {
      switch (declared) {
        case DelegatedStackService():
          _services.add(
            DelegatedServiceCore(host, declared, onChanged: _onServiceChanged),
          );
        case OwnedStackService():
          _services.add(
            OwnedServiceCore(
              host,
              declared,
              onChanged: _onServiceChanged,
              // Through the container's seam, not [flutterwareRunDir] direct:
              // a test that points the cache at a temp dir must have the
              // handles and logs land there too, or it writes a real process's
              // pid into the developer's own run dir.
              runDir: () => runDirProvider(),
            ),
          );
        case UnreadableStackService():
          _unreadable.add(declared);
      }
    }
  }

  /// Where the cache lives. A seam for tests, which point it at a temp dir
  /// rather than the developer's real run dir.
  @visibleForTesting
  static String Function() runDirProvider = flutterwareRunDir;

  final _services = <StackServiceCore>[];

  /// Services the config declared and this build cannot read.
  ///
  /// Kept rather than dropped: *the config declared something unreadable* and
  /// *the config declared nothing* are different sentences with different
  /// fixes, and a row that silently vanishes tells you neither. They have no
  /// lifecycle, so they contribute a status and a line of explanation and no
  /// actions at all.
  final _unreadable = <UnreadableStackService>[];

  /// Every service with a lifecycle, in declaration order.
  List<StackServiceCore> get services => List.unmodifiable(_services);

  List<UnreadableStackService> get unreadable => List.unmodifiable(_unreadable);

  /// The one service, when exactly one is declared and readable.
  ///
  /// The single-service case is not a special case in the model, but it is one
  /// in the vocabulary: with one service the actions are unprefixed and the
  /// projection is flat, so a project that declares one stack sees exactly
  /// what it saw before there was a list.
  StackServiceCore? get only => _services.length == 1 ? _services.first : null;

  /// `<id>.` when the ids have to be said out loud, empty when they do not.
  ///
  /// Read off *everything* declared rather than off [_services], so an
  /// unreadable second service still forces the prefix. Otherwise fixing the
  /// unreadable one — which is what the panel tells you to do — would silently
  /// rename every action the readable one offers.
  String _prefixFor(String id) =>
      _services.length + _unreadable.length > 1 ? '$id.' : '';

  /// Scripts every service's [StackServiceCore.runProcess] at once.
  ///
  /// The seam is per service — the catalog draws five stacks on one screen and
  /// they must not share one — so pointing a whole plugin at a scripted
  /// process means walking the list, and every caller that wants to was doing
  /// it by hand.
  void scriptProcess(
    Future<ProcessResult> Function(
      List<String> command, {
      String? workingDirectory,
    })
    run,
  ) {
    for (var service in _services) {
      service.runProcess = run;
    }
  }

  var _loadedCache = false;

  @override
  Future<void> computeAll() async => _loadCache();

  /// Starts polling every service, and stops when the last watcher leaves.
  ///
  /// Fanned out rather than held here: the reference count that decides
  /// whether a subprocess runs belongs to the thing that would spawn it, and
  /// the intervals differ per service.
  void watch() {
    _loadCache();
    for (var service in _services) {
      service.watch();
    }
  }

  void unwatch() {
    for (var service in _services) {
      service.unwatch();
    }
  }

  bool get isWatching => _services.any((s) => s.isWatching);

  /// Re-probes every service and hands back what each one said.
  Future<Map<String, StackReading>> refreshAll() async {
    var readings = <String, StackReading>{};
    await Future.wait([
      for (var service in _services)
        service.refresh().then((reading) => readings[service.id] = reading),
    ]);
    return readings;
  }

  /// What any service is still working on, or null. Read by the capture
  /// settler.
  ///
  /// The first one that is busy, not a list: this becomes one line of "waiting
  /// on…", and three services coming up at once is still one wait.
  String? get busyWith {
    for (var service in _services) {
      if (service.busyWith case var busy?) return busy;
    }
    return null;
  }

  // ── cache ────────────────────────────────────────────────────────────────
  //
  // Kept so the sidebar and `fw status` say something true the moment a GUI
  // opens, without either of them spawning anything. A reading with an age is
  // the same bargain `RunCore` strikes with `devices.json`: the fact happened,
  // it gets old, it does not become wrong.
  //
  // One file per worktree holding every service's reading — see [StackCache].
  // Written here rather than by each service, because a service writing its
  // own would clobber its neighbours' on every probe.
  //
  // `stack-*.json` is not swept by [sweepRunDir] — it matches none of its
  // rules — which is right for the same reason `devices.json` is spared: there
  // is one per worktree, it is tiny, and deleting it would only make a cold
  // read answer "nothing has ever looked" about a stack that had a state a
  // minute ago.

  String get _cachePath => stackCachePath(runDirProvider(), host.worktree.path);

  void _loadCache() {
    if (_loadedCache) return;
    _loadedCache = true;
    try {
      var file = File(_cachePath);
      if (!file.existsSync()) return;
      var json = jsonDecode(file.readAsStringSync());
      if (json is! Map) return;
      var cache = StackCache.fromJson(json.cast<String, Object?>());
      var adopted = false;
      for (var service in _services) {
        if (cache.readings[service.id] case var reading?) {
          service.adoptCached(reading);
          adopted = true;
        }
      }
      if (adopted) notifyChanged();
    } on Object {
      // A cache that will not parse is a cache that was never written properly.
      // Nothing here is worth reporting: the next probe replaces it.
    }
  }

  void _writeCache() {
    var readings = {
      for (var service in _services)
        if (service.reading.isKnown) service.id: service.reading,
    };
    if (readings.isEmpty) return;
    try {
      File(_cachePath)
          .writeAsStringSync(jsonEncode(StackCache(readings).toJson()));
    } on Object {
      // Best effort. A read-only home directory costs freshness on the next
      // cold start, not correctness now.
    }
  }

  void _onServiceChanged() {
    if (isDisposed) return;
    _writeCache();
    notifyChanged();
  }

  // ── report ───────────────────────────────────────────────────────────────

  @override
  PluginReport get report => PluginReport(
    id: id,
    label: label,
    description: _pluginDescription,
    status: _status,
    badge: _badge,
    actions: _actions,
    teardown: [
      for (var service in _services)
        ...service.teardown(prefix: _prefixFor(service.id)),
    ],
    children: _children,
    view: _view,
  );

  /// Every service as a sidebar sub-entry, so the breakdown is data rather
  /// than something only the panel can show.
  ///
  /// None at all when there is one service: a single child under a row that
  /// already says the same thing is an expander that expands to itself.
  List<PluginChild> get _children {
    if (_services.length + _unreadable.length < 2) return const [];
    return [
      for (var service in _services)
        PluginChild(
          id: service.id,
          label: service.label,
          status: service.status,
          badge: service.badge,
        ),
      for (var service in _unreadable)
        PluginChild(
          id: service.id,
          label: service.name ?? service.id,
          status: const Status.error("can't read"),
          badge: const StatusBadge.dot(Tone.error),
        ),
    ];
  }

  /// A word for the sidebar, which clamps it to about a dozen characters.
  ///
  /// One service answers for itself, unchanged. Several are counted the way a
  /// single stack's containers are counted — `up 2/3` — because that is the
  /// same question one level up, and the surface already knows how to read it.
  Status get _status {
    if (_unreadable.isNotEmpty && _services.isEmpty) {
      return const Status.error("can't read");
    }
    if (only case var service?) return service.status;
    if (_services.isEmpty) return Status.none;
    var known = [
      for (var service in _services)
        if (service.effectiveReading.isKnown) service.effectiveReading.state,
    ];
    if (known.isEmpty) return Status.none;
    var up = known.where((s) => s == StackState.up).length;
    if (known.any((s) => s.isMoving)) return const Status.info('moving');
    if (up == known.length) return const Status.good('up');
    if (up > 0) return Status.warn('up $up/${known.length}');
    if (known.any((s) => s == StackState.unavailable)) {
      return const Status.error("can't tell");
    }
    return const Status.neutral('down');
  }

  /// A badge only when something needs you — a probe that failed, or a service
  /// this build cannot read. Neither is inferable from anywhere else, and
  /// neither goes away on its own.
  StatusBadge get _badge =>
      _unreadable.isNotEmpty ||
          _services.any((s) => s.badge != StatusBadge.none)
      ? const StatusBadge.dot(Tone.error)
      : StatusBadge.none;

  List<PluginAction> get _actions => [
    for (var service in _services)
      ...service.actions(prefix: _prefixFor(service.id)),
  ];

  /// The projection: flat for one service, a section each for several.
  PluginView get _view {
    if (only case var service?) return PluginView(service.viewRows());
    return PluginView([
      for (var service in _services)
        ViewSection(
          service.label,
          service.viewRows(prefix: _prefixFor(service.id)),
        ),
      for (var service in _unreadable)
        ViewSection(service.name ?? service.id, [
          ViewText(service.reason, tone: Tone.error),
        ]),
    ]);
  }

  @override
  Future<Object?> invoke(
    String actionId, {
    Map<String, Object?> arguments = const {},
  }) async {
    for (var service in _services) {
      var prefix = _prefixFor(service.id);
      if (!actionId.startsWith(prefix)) continue;
      var local = actionId.substring(prefix.length);
      if (service.invoke(local, arguments: arguments) case var run?) {
        return await run;
      }
    }
    return await super.invoke(actionId, arguments: arguments);
  }

  @override
  void dispose() {
    for (var service in _services) {
      service.dispose();
    }
    super.dispose();
  }
}

PluginCore devStackCoreFactory(PluginHost host) => DevStackCore(host);
