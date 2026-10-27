import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutterware/plugins.dart';
import 'package:meta/meta.dart';

import '../../session/job.dart';
import '../../ui/age.dart';
import '../../utils/run_dir.dart';
import '../plugin_core.dart';
import '../plugin_host.dart';
import 'delegated_service_core.dart';
import 'dev_stack_results.dart';
import 'owned_service_core.dart';
import 'stack_history.dart';
import 'stack_service_core.dart';

export 'delegated_service_core.dart';
export 'owned_service_core.dart';
export 'service_handle.dart';
export 'stack_history.dart';
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
  /// [history] is where starts and stops are written down: the file beside
  /// the cache unless a caller — the catalog — hands it another.
  DevStackCore(super.host, {StackHistoryStore? history})
    : _historyStore =
          history ??
          FileStackHistory(
            () => stackHistoryPath(runDirProvider(), host.worktree.path),
          ) {
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
    for (var service in _services) {
      service.history = _historyStore;
    }
  }

  final StackHistoryStore _historyStore;

  /// The latest starts and stops of every service, newest first, as of the
  /// last read.
  List<StackEvent> get history => _events;
  List<StackEvent> _events = const [];

  /// What the store said its stamp was at the last read. Starts as something
  /// no stamp equals, so the first read always happens.
  Object? _eventsStamp = const Object();

  /// Following the history while something watches, because an agent's
  /// starts happen in another process and arrive only through the file.
  StreamSubscription<void>? _historyChanges;

  /// Whether there is a history to show: only a stack something here can
  /// start or stop has one.
  bool get keepsHistory => _services.any((service) => service.canControl);

  void _readHistory() {
    var stamp = _historyStore.stamp;
    if (stamp == _eventsStamp) return;
    _eventsStamp = stamp;
    _events = _historyStore.read(limit: 50);
    notifyChanged();
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
  Future<void> computeAll() async {
    _loadCache();
    _readHistory();
  }

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
    _historyChanges ??= _historyStore.changes().listen((_) => _readHistory());
    _readHistory();
  }

  void unwatch() {
    for (var service in _services) {
      service.unwatch();
    }
    if (!isWatching) {
      unawaited(_historyChanges?.cancel());
      _historyChanges = null;
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

  // ── ensure ───────────────────────────────────────────────────────────────

  /// Brings up the services named by [ids], and every service they need
  /// first, then says how each one ended up. Every service when [ids] is
  /// empty.
  ///
  /// The order is [StackService.needs]: a service starts only once everything
  /// it needs is up. One that is already up is left alone; one that someone
  /// else is starting is waited for rather than started twice. One that does
  /// not come up is reported with why and what it printed, and nothing that
  /// needs it is started. Services that do not depend on it still are.
  ///
  /// What a caller that needs the stack calls before it runs: an agent before
  /// it launches the app, a world before it opens. The result carries each
  /// service's port and URL where flutterware knows them, so the caller does
  /// not have to ask the project's tools a second time.
  ///
  /// [onStarting] is told the name of each service as `ensure` starts it, and
  /// [onEnsured] how each one ended, as it ends: what a world opening shows in
  /// its log while it waits.
  ///
  /// Refuses, starting nothing, when an id or a need names no service, names
  /// one this build cannot read, or the needs go round in a circle.
  Future<StackEnsureResult> ensure({
    Iterable<String> ids = const [],
    void Function(String name)? onStarting,
    void Function(EnsuredService service)? onEnsured,
  }) async {
    var order = _ensureOrder(ids);
    var notUp = <String>{};
    var results = <EnsuredService>[];
    for (var service in order) {
      var blocked = [
        for (var need in service.declaration.needs)
          if (notUp.contains(need)) _labelOf(need),
      ];
      if (blocked.isNotEmpty) {
        notUp.add(service.id);
        var skipped = EnsuredService(
          id: service.id,
          name: service.label,
          outcome: EnsureOutcome.skipped,
          failure:
              'Not started, because it needs ${blocked.join(' and ')}, '
              'which did not come up.',
        );
        results.add(skipped);
        onEnsured?.call(skipped);
        continue;
      }
      var ensured = await _ensureOne(service, onStarting: onStarting);
      if (!ensured.outcome.isUp) notUp.add(service.id);
      results.add(ensured);
      onEnsured?.call(ensured);
    }
    return StackEnsureResult(results);
  }

  /// [ids] and everything they need, each after what it needs and otherwise in
  /// declaration order.
  List<StackServiceCore> _ensureOrder(Iterable<String> ids) {
    var byId = {for (var service in _services) service.id: service};
    var requested = ids.isEmpty ? byId.keys.toList() : ids.toList();
    var order = <StackServiceCore>[];
    var path = <String>[];
    void visit(String id, String? neededBy) {
      if (order.any((service) => service.id == id)) return;
      if (path.contains(id)) {
        var circle = [...path.sublist(path.indexOf(id)), id];
        throw ActionRefusal(
          'These services need each other in a circle: '
          '${circle.join(' → ')}. Nothing was started. Remove one of these '
          'needs in tool/flutterware.dart.',
        );
      }
      var service = byId[id];
      if (service == null) {
        var reason = [
          for (var unreadable in _unreadable)
            if (unreadable.id == id) unreadable.reason,
        ].firstOrNull;
        var subject = neededBy == null
            ? 'There is no service "$id"'
            : '"$neededBy" needs "$id", but there is no service "$id"';
        throw ActionRefusal(
          reason == null
              ? '$subject. The services are: ${byId.keys.join(', ')}. '
                    'Nothing was started.'
              : '"$id" cannot be read, so it cannot be started: $reason '
                    'Nothing was started.',
        );
      }
      path.add(id);
      for (var need in service.declaration.needs) {
        visit(need, id);
      }
      path.removeLast();
      order.add(service);
    }

    for (var id in requested) {
      visit(id, null);
    }
    return order;
  }

  String _labelOf(String id) =>
      [
        for (var service in _services)
          if (service.id == id) service.label,
      ].firstOrNull ??
      id;

  /// One service, brought up or explained.
  Future<EnsuredService> _ensureOne(
    StackServiceCore service, {
    void Function(String name)? onStarting,
  }) async {
    EnsuredService ended(
      EnsureOutcome outcome,
      StackReading reading, {
      String? failure,
      String output = '',
    }) => EnsuredService(
      id: service.id,
      name: service.label,
      outcome: outcome,
      reading: reading,
      port: outcome.isUp ? service.port : null,
      url: outcome.isUp ? service.url : null,
      failure: failure,
      output: output,
    );

    var started = false;
    while (true) {
      // A start or stop already in flight, from the panel or another caller,
      // is let finish rather than refused: what it leaves is what to look at.
      while (service.busy != null && !service.isDisposed) {
        await Future<void>.delayed(const Duration(milliseconds: 200));
      }
      var reading = await service.refresh();
      if (reading.state == StackState.starting) {
        reading = await _whileStarting(service, reading);
      }
      if (reading.state == StackState.up) {
        return ended(
          started ? EnsureOutcome.started : EnsureOutcome.alreadyUp,
          reading,
        );
      }
      if (started || service.isDisposed) {
        return ended(
          EnsureOutcome.failed,
          reading,
          failure:
              reading.failure ?? 'It is ${reading.state.name} after its start.',
        );
      }
      if (!service.canStart) {
        return ended(
          EnsureOutcome.failed,
          reading,
          failure:
              '${reading.failure ?? 'It is ${reading.state.name}.'} It has no '
              'start command, so flutterware cannot start it.',
        );
      }
      DevStackRunResult result;
      try {
        onStarting?.call(service.label);
        result = await service.start();
      } on Object catch (e) {
        // Someone else claimed it between the look and the start. Wait for
        // theirs.
        if (service.busy != null) continue;
        return ended(
          EnsureOutcome.failed,
          reading,
          failure: e is ActionRefusal ? e.message : '$e',
        );
      }
      started = true;
      reading = result.reading ?? await service.refresh();
      if (reading.state == StackState.starting) {
        reading = await _whileStarting(service, reading);
      }
      if (reading.state == StackState.up) {
        return ended(EnsureOutcome.started, reading);
      }
      return ended(
        EnsureOutcome.failed,
        reading,
        failure: failureOf(result, 'start'),
        output: result.output,
      );
    }
  }

  /// Polls a service that is running and not answering yet until it answers,
  /// stops starting, or [StackService.commandTimeout] runs out.
  Future<StackReading> _whileStarting(
    StackServiceCore service,
    StackReading reading,
  ) async {
    var deadline = DateTime.now().add(service.declaration.commandTimeout);
    // An owned service's look is a pid check and a connect; a delegated one's
    // is a process, so it is asked less often.
    var interval = service is OwnedServiceCore
        ? const Duration(milliseconds: 250)
        : const Duration(seconds: 1);
    while (reading.state == StackState.starting &&
        !service.isDisposed &&
        DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(interval);
      reading = await service.refresh();
    }
    return reading;
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
    _readHistory();
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
    // Not on a stack this machine only watches: with nothing to start, there
    // is nothing to bring up.
    if (_services.any((service) => service.canStart))
      PluginAction(
        'ensure',
        'Bring up everything',
        returns: StackEnsureResult,
        description:
            'Brings services up with the services they need, in order, and '
            'waits until each one is up. A service that is already up is left '
            'alone. If one does not come up, nothing that needs it is '
            'started, and the result says why with what it printed. Each '
            'service comes back with its port and URL when flutterware knows '
            'them. Without `services`, it brings up every service.',
        parameters: [
          ActionParameter(
            'services',
            'Services',
            required: false,
            repeatable: true,
            description:
                'The services to bring up, by id: '
                '${_services.map((service) => service.id).join(', ')}.',
          ),
        ],
      ),
    if (keepsHistory)
      PluginAction(
        'history',
        'Show history',
        returns: StackHistoryResult,
        description:
            'The latest starts and stops of every service, newest first: who '
            'asked (the studio, fw in a terminal, or an agent), how it ended, '
            'and why when it failed. A process that exited with nobody '
            'stopping it is listed too.',
        parameters: [
          ActionParameter(
            'limit',
            'Limit',
            kind: ActionParameterKind.integer,
            required: false,
            defaultValue: '20',
            description: 'How many events, newest first.',
          ),
        ],
      ),
    for (var service in _services)
      ...service.actions(prefix: _prefixFor(service.id)),
  ];

  /// The projection: flat for one service, a section each for several.
  PluginView get _view {
    if (only case var service?) {
      return PluginView([...service.viewRows(), ?_historySection]);
    }
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
      ?_historySection,
    ]);
  }

  /// The last few starts and stops, for `fw status` and an agent's status
  /// call. The rest is the `history` action.
  ViewNode? get _historySection {
    if (_events.isEmpty) return null;
    return ViewSection('History', [
      ViewItems([
        for (var event in _events.take(5))
          ViewItem(
            eventHeadline(event),
            detail: [
              eventCaller(event),
              ?ageOf(event.at),
              ?eventDetail(event),
            ].join(' · '),
            tone: event.outcome.isProblem ? Tone.error : Tone.neutral,
          ),
      ]),
    ]);
  }

  @override
  Future<Object?> invoke(
    String actionId, {
    Map<String, Object?> arguments = const {},
  }) async {
    if (actionId == 'ensure') return ensure(ids: _ids(arguments['services']));
    if (actionId == 'history') {
      var limit = arguments['limit'] as int? ?? 20;
      return StackHistoryResult(_historyStore.read(limit: limit));
    }
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
    unawaited(_historyChanges?.cancel());
    for (var service in _services) {
      service.dispose();
    }
    super.dispose();
  }
}

/// A list of ids however it arrived: a list, or one string the CLI joined
/// with commas.
List<String> _ids(Object? raw) => [
  for (var part in raw is List ? raw : '${raw ?? ''}'.split(','))
    if ('$part'.trim().isNotEmpty) '$part'.trim(),
];

PluginCore devStackCoreFactory(PluginHost host) => DevStackCore(host);
