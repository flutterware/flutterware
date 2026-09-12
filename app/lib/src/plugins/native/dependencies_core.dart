import 'dart:async';

// `Dependencies` here is the app's dependency model, not the plugin
// declaration of the same name in package:flutterware.
import 'package:flutterware/plugins.dart' hide Dependencies;

import '../../dependencies/model/package_origin.dart';
import '../../dependencies/model/pub_deps_store.dart';
import '../../dependencies/model/service.dart';
import '../../dependencies/model/source.dart';
import '../../utils/async_value.dart';
import '../plugin_core.dart';
import 'dependencies_address.dart';
import 'dependencies_results.dart';
import '../plugin_host.dart';

/// The registered id — also what `tool/flutterware.dart` declares.
const dependenciesPluginId = 'flutterware.dependencies';

/// What this plugin is, for a reader who has only the id — see
/// `PluginReport.description`.
const _pluginDescription =
    'Every pub dependency of each declared package: what the pubspec asked '
    'for, what pub resolved it to, and where it came from.';

/// Pub dependencies for each declared package — all of the behaviour, none of
/// the widgets.
///
/// Shows the shape every plugin core follows, including the rule that matters
/// most: nothing here starts work. The constructor allocates nothing and
/// [report] only reads what a previous call caused to load. Loading begins in
/// [track], which the panel calls on mount and `fw` calls for the duration of
/// a request.
class DependenciesCore extends PluginCore {
  DependenciesCore(super.host, {DependencySource? source})
    : source = source ?? LiveDependencySource(pubDepsStore: PubDepsStore());

  /// Where every service this core builds reads from — the project and
  /// pub.dev, unless a recording is standing in for them.
  ///
  /// One for all of them, and the live one carries one [PubDepsStore], which
  /// is the reason `fw status` is no longer dominated by this plugin. `pub
  /// deps` reports the whole resolution wherever it runs, so the three
  /// declared packages of this repo were three identical ~0.6s subprocesses;
  /// the store makes them one, and caches it on disk against the lockfile so
  /// a cold `fw` pays nothing either.
  final DependencySource source;

  final _tracked = <String, StreamSubscription<Snapshot<Dependencies>>>{};

  /// This plugin's own services, one per package, built on first use. Owned
  /// here rather than by the workspace: a service belongs to the plugin that
  /// knows what it is for.
  final _services = <String, DependenciesService>{};

  /// Declared packages, filtered to those the workspace knows about.
  late final List<String> packages = [
    for (var path in host.packagePaths)
      if (host.workspace.exists(path)) path,
  ];

  DependenciesService serviceFor(String path) => _services.putIfAbsent(
    path,
    () => DependenciesService(host.workspace.packageFor(path), source: source),
  );

  /// Whether [path]'s service has been built yet — the laziness rule, made
  /// observable. False until something subscribes.
  bool isRealised(String path) => _services.containsKey(path);

  /// Starts (and keeps) the load for [path]. Idempotent.
  void track(String path) {
    if (_tracked.containsKey(path)) return;
    // AsyncValue loads on its first subscriber, so this *is* the trigger.
    _tracked[path] = _sourceFor(path).listen((_) => notifyChanged());
    notifyChanged();
  }

  /// Releases [path]. The data stays cached — demand decides what work is
  /// justified, not what has to be discarded.
  void untrack(String path) {
    var subscription = _tracked.remove(path);
    if (subscription == null) return;
    unawaited(subscription.cancel());
    notifyChanged();
  }

  AsyncValue<Dependencies> _sourceFor(String path) =>
      serviceFor(path).dependencies;

  /// Cached snapshot for [path], or null when nothing has looked at it yet.
  /// Deliberately does **not** build the package's service.
  Snapshot<Dependencies>? _cached(String path) =>
      _services.containsKey(path) ? _services[path]!.dependencies.value : null;

  /// Whether anything being watched is still resolving.
  ///
  /// Tracked, not declared. [track] is what the panel calls on mount, so
  /// this answers about what someone is actually looking at rather than about
  /// every package in the workspace — and asking about an untracked package
  /// would build its service, which is the whole thing [_cached] avoids.
  ///
  /// The same condition `_status` reports as "loading…", read from the same
  /// snapshots, so the sidebar and a window capture can never disagree about
  /// whether this panel is ready.
  bool get isLoading => _tracked.keys.any((path) {
    var snapshot = _cached(path);
    return snapshot == null ||
        (snapshot.data == null && snapshot.error == null);
  });

  @override
  PluginReport get report {
    var known = <String, Snapshot<Dependencies>>{};
    for (var path in packages) {
      var snapshot = _cached(path);
      if (snapshot != null) known[path] = snapshot;
    }
    return PluginReport(
      id: host.id,
      label: host.label,
      description: _pluginDescription,
      status: _status(known),
      children: [
        for (var path in packages)
          PluginChild(
            id: path,
            label: path == '.' ? 'root' : path,
            status: _packageStatus(known[path]),
          ),
      ],
      badge: known.values.any((s) => s.error != null)
          ? const StatusBadge.dot(Tone.error)
          : StatusBadge.none,
      actions: [
        PluginAction(
          'list',
          'List',
          returns: DependencyListResult,
          description:
              'Every dependency of a package, with its version — the whole '
              'list, not the projection the report carries',
          parameters: [
            ActionParameter(
              'package',
              'Package',
              kind: ActionParameterKind.choice,
              required: false,
              description: 'Which declared package; all of them when omitted',
              options: [
                for (var path in packages)
                  ActionOption(path, label: path == '.' ? 'root' : path),
              ],
            ),
            const ActionParameter(
              'transitive',
              'Include transitive',
              kind: ActionParameterKind.boolean,
              required: false,
              defaultValue: 'false',
              description:
                  'List what the package pulls in indirectly too. The counts '
                  'are reported either way.',
            ),
          ],
        ),
      ],
      view: _view(known),
    );
  }

  /// Silent once loaded. Counting dependencies across packages by *summing*
  /// them is meaningless — everything shared gets counted once per package —
  /// and the per-package number is already a click away in the panel. The row
  /// speaks only while it is working or when something went wrong.
  Status _status(Map<String, Snapshot<Dependencies>> known) {
    if (packages.isEmpty) return Status.none;
    if (known.values.any((s) => s.error != null)) {
      return const Status.error('failed to load');
    }
    var loading = known.values.where((s) => s.data == null).length;
    return loading == 0 ? Status.none : const Status.info('loading…');
  }

  Status _packageStatus(Snapshot<Dependencies>? snapshot) {
    if (snapshot == null) return Status.none;
    if (snapshot.error != null) return const Status.error('failed');
    if (snapshot.data == null) return const Status.info('loading…');
    return Status.none;
  }

  PluginView _view(Map<String, Snapshot<Dependencies>> known) {
    if (packages.isEmpty) {
      return const PluginView([
        ViewText(
          'This plugin has no packages. Add them in tool/flutterware.dart.',
          tone: Tone.warn,
        ),
      ]);
    }

    return PluginView([
      for (var path in packages)
        ViewSection(path, [
          // Honest: nothing has looked at this package, so nothing was
          // computed. That is not the same as "zero dependencies".
          ...?(known[path] == null ? null : _packageNodes(path, known[path]!)),
          if (known[path] == null) const ViewText('not computed'),
        ]),
    ]);
  }

  List<ViewNode> _packageNodes(String path, Snapshot<Dependencies> snapshot) {
    if (snapshot.error != null) {
      return [ViewField('Error', '${snapshot.error}', tone: Tone.error)];
    }
    var data = snapshot.data;
    if (data == null) return const [ViewText('loading…')];

    return [
      ViewField('Direct', '${data.directs.length}'),
      ViewField('Dev', '${data.devs.length}'),
      ViewField('Transitive', '${data.transitives.length}'),
      // Items rather than a table, because only an item can carry an address.
      // `searchReport` walks items and skips tables, so as a table not one of
      // these packages was reachable from the command palette — the plugin's
      // only search hit was the plugin itself.
      //
      // **Every declared package, uncapped.** A projection is normally
      // truncated because it is read rather than scrolled, but truncating here
      // also decides what is findable, and "the first twelve dependencies are
      // searchable" is not a rule anyone could hold in their head. What a
      // package declares is a bounded list — tens, not hundreds — and it is
      // the list this plugin exists to show. Transitives stay a count: they
      // are the unbounded half, and you go looking for what you asked for.
      ViewItems([
        for (var dependency in [...data.directs, ...data.devs])
          ViewItem(
            dependency.name,
            detail: _describeVersion(dependency),
            address: addressFor(path, dependency.name),
          ),
      ]),
    ];
  }

  /// What a row says about a package after its name.
  ///
  /// The origin is appended only when it is not an ordinary pub.dev package, so
  /// a git or path dependency stands out in a list where almost everything came
  /// from pub — which is exactly when you want to notice it.
  static String _describeVersion(Dependency dependency) {
    var origin = dependency.origin;
    if (!dependency.hasMeaningfulVersion) return origin.label;
    if (origin is HostedOrigin && origin.isPubDev) {
      return dependency.resolvedVersion;
    }
    var detail = origin.detail;
    return '${dependency.resolvedVersion} · ${detail ?? origin.label}';
  }

  /// Where one dependency's detail page is. The same segments the panel writes
  /// when you click a row, built from the one helper both directions share.
  Address addressFor(String packagePath, String dependency) => Address(
    worktree: host.worktree.name,
    plugin: host.id,
    segments: dependencySegments(packagePath, dependency: dependency),
  );

  @override
  Future<Object?> invoke(
    String actionId, {
    Map<String, Object?> arguments = const {},
  }) async {
    if (actionId != 'list') {
      return super.invoke(actionId, arguments: arguments);
    }
    return _list(arguments);
  }

  /// The dependencies of one package, or of every declared package.
  ///
  /// Loads what it needs. A report may never start work; an action asked
  /// for by name may, and must — in `fw` and MCP the process was born for this
  /// request and holds nothing, so a query that only read the cache would
  /// answer "nothing" every time. That is what the plugin's two dead
  /// cache-invalidation actions used to do.
  ///
  /// One package failing does not sink the others: its error is reported in
  /// its place, the same way the report shows it.
  Future<DependencyListResult> _list(Map<String, Object?> arguments) async {
    var requested = arguments['package'];
    if (requested != null && requested is! String) {
      throw ArgumentError.value(requested, 'package', 'must be a package path');
    }
    var paths = requested == null ? packages : [requested as String];
    for (var path in paths) {
      if (!packages.contains(path)) {
        throw ArgumentError.value(
          path,
          'package',
          'not declared for this plugin. Declared: ${packages.join(', ')}',
        );
      }
    }

    var transitive = arguments['transitive'] == true;

    var loaded = await Future.wait([for (var path in paths) _load(path)]);

    return DependencyListResult(
      packages: [
        for (var (index, snapshot) in loaded.indexed)
          _describe(paths[index], snapshot, transitive: transitive),
      ],
    );
  }

  Future<Snapshot<Dependencies>> _load(String path) async {
    track(path);
    try {
      await _sourceFor(path).refresh();
    } catch (_) {
      // Carried on the snapshot below — the report reads it the same way.
    }
    return _sourceFor(path).value;
  }

  DependencyListPackage _describe(
    String path,
    Snapshot<Dependencies> snapshot, {
    required bool transitive,
  }) {
    if (snapshot.error case var error?) {
      return DependencyListPackage(path: path, error: '$error');
    }
    var data = snapshot.data;
    if (data == null) {
      return DependencyListPackage(path: path, error: 'did not load');
    }

    return DependencyListPackage(
      path: path,
      direct: data.directs.length,
      dev: data.devs.length,
      transitive: data.transitives.length,
      dependencies: [
        for (var dependency in [
          ...data.directs,
          ...data.devs,
          if (transitive) ...data.transitives,
        ])
          DependencyEntry(
            name: dependency.name,
            version: dependency.resolvedVersion,
            constraint: dependency.constraint,
            direct: dependency.isDirect,
            dev: dependency.isDev,
            source: dependency.node.source,
            origin: dependency.origin.detail,
          ),
      ],
    );
  }

  /// Loads every declared package and waits — what `fw` does for the duration
  /// of one request, where there is no widget to subscribe on its behalf.
  @override
  Future<void> computeAll() async {
    for (var path in packages) {
      track(path);
    }
    await Future.wait([for (var path in packages) _sourceFor(path).refresh()]);
  }

  @override
  void dispose() {
    for (var path in _tracked.keys.toList()) {
      untrack(path);
    }
    for (var service in _services.values) {
      service.dispose();
    }
    _services.clear();
    super.dispose();
  }
}

PluginCore dependenciesCoreFactory(PluginHost host) => DependenciesCore(host);
