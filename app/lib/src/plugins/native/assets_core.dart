import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:flutterware/plugins.dart';
import 'package:path/path.dart' as p;

import '../../assets/model/asset_catalog.dart';
import '../../assets/model/asset_facts.dart';
import '../../assets/model/asset_scan.dart';
import '../../previews/package_config_locator.dart';
import '../../utils/list_files.dart';
import '../../utils/string/plural.dart';
import '../plugin_core.dart';
import '../plugin_host.dart';
import '../scan_cache.dart';
import 'assets_address.dart';
import 'assets_results.dart';

/// The registered id — also what `tool/flutterware.dart` declares.
const assetsPluginId = 'flutterware.assets';

/// What this plugin is, for a reader who has only the id — see
/// `PluginReport.description`.
const _pluginDescription =
    "What each declared package's asset bundle actually resolves to at run "
    'time — including what its dependencies contribute, and excluding the file '
    'sitting on disk that nothing declared.';

/// Own assets the projection lists before it starts counting. A projection is
/// read, not scrolled.
const _projectedAssets = 15;

/// Dependencies listed by name before the rest become a count. A real app has
/// dozens contributing nothing but a licence file.
const _projectedOwners = 8;

const _projectedProblems = 10;

/// What each declared package's bundle actually resolves to.
///
/// The subject is deliberately **the bundle, not the folder**: what
/// `Image.asset` will find at run time, including the assets a dependency
/// contributes and excluding the file sitting on disk that nothing declared.
/// The gap between those two is the whole reason the plugin exists, so
/// [AssetCatalog] — the same resolver that feeds the embedder guest — is the
/// only thing here that decides what resolves.
///
/// Holds to the two rules every core holds to: the constructor allocates
/// nothing, and [report] only formats what a previous call caused to load.
/// Loading is a scan, which is parsing and `stat`ing and nothing more.
class AssetsCore extends PluginCore {
  AssetsCore(super.host);

  /// Declared packages, filtered to those the workspace knows about, so a typo
  /// cannot make the plugin scan a directory that is not there.
  late final List<String> packages = [
    for (var path in host.packagePaths)
      if (host.workspace.exists(path)) path,
  ];

  late final _cache = ScanCache<String, AssetScan>(
    scan: _scan,
    onChanged: notifyChanged,
  );

  /// The scan for [path], or null when nothing has looked at it yet.
  AssetScan? scanFor(String path) => _cache[path];

  /// The scan failure for [path], for a panel that wants to show it directly.
  String? failureFor(String path) => _cache.failureFor(path);

  bool isScanning(String path) => _cache.isScanning(path);

  /// Where an asset *is*.
  ///
  /// Built here rather than left to a reader to reassemble from the package and
  /// the key, which is how two surfaces come to disagree about what an asset is
  /// called. [axes] are applied — a density, a Lottie frame, a preview
  /// background — never identity.
  Address addressFor(
    String packagePath, [
    String? assetKey,
    Map<String, String> axes = const {},
  ]) => Address(
    worktree: host.worktree.name,
    plugin: host.id,
    segments: assetSegments(packagePath, assetKey),
    axes: axes,
  );

  /// Scans [path], unless it already has been. Idempotent.
  void track(String path) => _cache.track(path);

  /// Drops the cached scan so the next [track] re-reads.
  void invalidate(String path) => _cache.invalidate(path);

  /// Reads the bundle again, and **completes when the new scan is in** — what
  /// the panel's refresh awaits. Also the way out of a failure: the pub-get
  /// hint below is only useful if running pub get can be followed by this.
  Future<void> reload(String path) => _cache.reload(path);

  /// Scans every declared package and waits — what `fw` and MCP do for the
  /// duration of one request, where there is no panel to subscribe on their
  /// behalf.
  @override
  Future<void> computeAll() async {
    await Future.wait([for (var path in packages) _cache.load(path)]);
  }

  Future<AssetScan> _scan(String path) async {
    var root = host.workspace.packageFor(path).absolutePath;
    var config = findPackageConfig(root);
    if (config == null) {
      throw ScanFailure(
        'No .dart_tool/package_config.json above "$root". '
        'Run `flutter pub get` in that project first.',
      );
    }
    return _resolve(root, config);
  }

  /// Off the main isolate because a scan is a few thousand `stat`s on a real
  /// project, and the GUI runs a compositor on this one.
  ///
  /// A static method rather than a closure over `this`: `Isolate.run` sends
  /// what the closure captures, and a core holds a whole workspace.
  static Future<AssetScan> _resolve(String root, String configPath) =>
      Isolate.run(
        () async => AssetScan.of(
          await AssetCatalog.resolve(
            rootPackageRoot: root,
            packageConfigPath: configPath,
          ),
        ),
      );

  @override
  PluginReport get report => PluginReport(
    id: host.id,
    label: host.label,
    description: _pluginDescription,
    status: _status,
    badge: _badge,
    children: [
      for (var path in packages)
        PluginChild(
          id: path,
          label: path == '.' ? 'root' : path,
          status: _childStatus(path),
        ),
    ],
    actions: _actions,
    view: _view,
  );

  /// The package parameter, written once because all three actions take it.
  ActionParameter get _packageParameter => ActionParameter(
    'package',
    'Package',
    kind: ActionParameterKind.choice,
    required: false,
    description: 'Which declared package; all of them when omitted',
    options: [
      for (var path in packages)
        ActionOption(path, label: path == '.' ? 'root' : path),
    ],
  );

  List<PluginAction> get _actions => [
    PluginAction(
      'list',
      'List',
      returns: AssetListResult,
      description:
          "Every key a package's bundle resolves to — the whole list, not "
          'the projection the report carries',
      parameters: [
        _packageParameter,
        const ActionParameter(
          'dependencies',
          'Include dependencies',
          kind: ActionParameterKind.boolean,
          required: false,
          defaultValue: 'false',
          description:
              'List the assets dependencies contribute as well. They are in '
              'the bundle either way, and counted either way.',
        ),
      ],
    ),
    PluginAction(
      'describe',
      'Describe',
      returns: AssetDescription,
      description:
          'One asset in full: where it came from, what its densities are, '
          'what the file itself says, and the Dart that loads it',
      parameters: [
        const ActionParameter(
          'asset',
          'Asset key',
          description:
              'The key as the engine knows it — `assets/logo.png`, or '
              '`packages/<name>/…` for one a dependency contributes. Read '
              'them with `list`.',
        ),
        _packageParameter,
      ],
    ),
    // **Every finding here is a bug or a number you asked for, never an
    // opinion about a choice.** There is no way to silence one, and until
    // there is, a finding a project has already decided against is a finding
    // it will decide against again every run — which is how a panel teaches
    // people to ignore it, and takes the real findings down with it.
    //
    // Two used to break that rule and are gone. `duplicate` reported identical
    // bytes under several keys and concluded the extra copies were "shipped
    // for nothing": measured on a real bundle it was 20 of 27 findings, all of
    // them one deliberate icon aliased per symptom so a generated map could
    // stay readable. `density-gap` judged a ladder a project may have chosen
    // not to fill. Both were right on the facts and wrong to conclude.
    //
    // `over-budget` went for a different reason, and it is the one worth
    // remembering: it broke no rule and nobody wanted it. It only spoke when
    // you passed `budget`, so it was silent for every project that never
    // thought about one — and a project that *has* a weight target measures it
    // against a built artifact, not against this sum. A parameter whose whole
    // job is to enable a finding nobody asks for is a parameter that costs
    // more to explain than it ever returned. `bytes` is still on the result;
    // the number was never the problem, the verdict was.
    //
    // What survives says something nobody argues with: a declaration that
    // resolves to nothing and a file no declaration reaches are broken, and
    // `oversized` has `maxEdge` and found 1.4 MB of slides exported at print
    // size on that same bundle. A new finding belongs here only if it clears
    // the same bar — or if suppression exists by then, which is a
    // plugin-framework question and not an assets one.
    PluginAction(
      'audit',
      'Audit',
      returns: AssetAuditResult,
      description:
          'Everything wrong with a bundle that can be found without running '
          'the app: declarations that resolve to nothing, files a directory '
          'declaration does not reach, and rasters bigger than anything that '
          'will draw them. Reports the bundle weight alongside them, without '
          'an opinion about it.',
      parameters: [
        _packageParameter,
        const ActionParameter(
          'maxEdge',
          'Largest edge',
          kind: ActionParameterKind.integer,
          required: false,
          defaultValue: '2048',
          description:
              'Report a raster longer than this on either side. A phone never '
              'draws one that big; something was exported at print size.',
        ),
      ],
    ),
  ];

  int get _problemCount =>
      _cache.values.fold(0, (sum, scan) => sum + scan.problems.length);

  Status get _status {
    // Silent when unconfigured, too: a project that does not use the feature
    // is not in trouble, and the panel is where the setup instructions live.
    if (packages.isEmpty) return Status.none;
    if (_cache.anyFailed) return const Status.error('failed to scan');
    if (_cache.anyScanning) return const Status.info('scanning…');
    var problems = _problemCount;
    // Silent when there is nothing wrong. A total across packages would be
    // meaningless anyway — every package's bundle contains its dependencies',
    // so summing them counts the same file once per package that ships it.
    return problems == 0
        ? Status.none
        : Status.warn('$problems ${problems == 1 ? 'problem' : 'problems'}');
  }

  StatusBadge get _badge {
    if (_cache.anyFailed) return const StatusBadge.dot(Tone.error);
    return _problemCount > 0
        ? const StatusBadge.dot(Tone.warn)
        : StatusBadge.none;
  }

  Status _childStatus(String path) {
    if (_cache.failureFor(path) != null) return const Status.error('failed');
    if (_cache.isScanning(path)) return const Status.info('scanning…');
    var scan = _cache[path];
    if (scan == null) return Status.none;
    // Deliberately short. This shares a sidebar row with the package's name,
    // and the count of problems is already on the plugin's own row above —
    // saying it again here costs the name the space it needs.
    var summary =
        '${counted(scan.totalCount, 'asset')} · ${formatBytes(scan.totalBytes)}';
    return scan.problems.isEmpty ? Status.info(summary) : Status.warn(summary);
  }

  PluginView get _view {
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
        ViewSection(path == '.' ? 'root' : path, _packageNodes(path)),
    ]);
  }

  List<ViewNode> _packageNodes(String path) {
    if (_cache.failureFor(path) case var failure?) {
      return [ViewField('Error', failure, tone: Tone.error)];
    }
    var scan = _cache[path];
    // Honest: nothing has looked at this package, so nothing was computed.
    // That is not the same as "no assets".
    if (scan == null) {
      return [ViewText(_cache.isScanning(path) ? 'scanning…' : 'not computed')];
    }

    return [
      ViewField('Assets', '${scan.totalCount}'),
      ViewField('Weight', formatBytes(scan.totalBytes)),
      if (scan.ownKinds.isNotEmpty)
        ViewField(
          'Kinds',
          [
            for (var entry in scan.ownKinds.entries)
              '${entry.value} ${entry.key.plural.toLowerCase()}',
          ].join(', '),
        ),
      ..._ownNodes(path, scan),
      ..._dependencyNodes(scan),
      ..._fontNodes(scan),
      ..._problemNodes(scan),
    ];
  }

  List<ViewNode> _ownNodes(String path, AssetScan scan) {
    if (scan.own.isEmpty) return const [];
    return [
      ViewItems([
        for (var asset in scan.own.take(_projectedAssets))
          ViewItem(
            asset.key,
            detail: _detailFor(asset),
            address: addressFor(path, asset.key),
          ),
      ], truncated: scan.own.length - _projectedAssets),
    ];
  }

  String _detailFor(ResolvedAsset asset) {
    var variants = asset.variants.length;
    return [
      formatBytes(asset.totalBytes),
      if (variants > 0) '$variants ${variants == 1 ? 'variant' : 'variants'}',
    ].join(' · ');
  }

  /// Dependencies get a line each rather than an asset each: the question here
  /// is "what is in my bundle that I did not put there", and it is answered by
  /// weight, not by filename.
  List<ViewNode> _dependencyNodes(AssetScan scan) {
    if (scan.fromPackages.isEmpty) return const [];
    var shown = scan.fromPackages.take(_projectedOwners).toList();
    return [
      ViewSection('From packages (${formatBytes(scan.dependencyBytes)})', [
        ViewItems([
          for (var owner in shown)
            ViewItem(
              owner.package,
              detail:
                  '${counted(owner.assets.length, 'asset')} · ${formatBytes(owner.bytes)}',
            ),
        ], truncated: scan.fromPackages.length - shown.length),
      ]),
    ];
  }

  List<ViewNode> _fontNodes(AssetScan scan) {
    if (scan.fonts.isEmpty) return const [];
    return [
      ViewSection('Fonts', [
        ViewItems([
          for (var family in scan.fonts)
            ViewItem(
              family.family,
              detail:
                  '${family.fonts.length} '
                  '${family.fonts.length == 1 ? 'file' : 'files'}',
            ),
        ]),
      ]),
    ];
  }

  /// A problem names a declaration that resolves to nothing, so — unlike every
  /// other row here — it deliberately carries no address. There is nowhere to
  /// go: that is what is wrong with it.
  List<ViewNode> _problemNodes(AssetScan scan) {
    if (scan.problems.isEmpty) return const [];
    var shown = scan.problems.take(_projectedProblems).toList();
    return [
      ViewSection('Problems', [
        ViewItems([
          for (var problem in shown)
            ViewItem(
              problem.declaration,
              detail: problem.package == null
                  ? problem.kind.summary
                  : '${problem.kind.summary} (${problem.package})',
              tone: Tone.warn,
            ),
        ], truncated: scan.problems.length - shown.length),
      ]),
    ];
  }

  @override
  Future<Object?> invoke(
    String actionId, {
    Map<String, Object?> arguments = const {},
  }) async => switch (actionId) {
    'list' => await _list(arguments),
    'describe' => await _describe(arguments),
    'audit' => await _audit(arguments),
    _ => await super.invoke(actionId, arguments: arguments),
  };

  /// The packages an action was asked about, scanned and ready.
  ///
  /// Loads what it needs. A report may never start work; an action asked
  /// for by name may, and must — in `fw` and MCP the process was born for this
  /// request and holds nothing, so a query that only read the cache would
  /// answer "nothing" every time.
  Future<List<String>> _requested(Map<String, Object?> arguments) async {
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
    await Future.wait([for (var path in paths) _cache.load(path)]);
    return paths;
  }

  Future<AssetListResult> _list(Map<String, Object?> arguments) async {
    var paths = await _requested(arguments);
    var withDependencies = arguments['dependencies'] == true;

    return AssetListResult(
      packages: [
        for (var path in paths)
          if (_cache.failureFor(path) case var failure?)
            AssetListPackage(path: path, error: failure)
          else if (_cache[path] case var scan?)
            AssetListPackage(
              path: path,
              own: scan.own.length,
              fromPackages: scan.totalCount - scan.own.length,
              bytes: scan.totalBytes,
              assets: [
                for (var asset in [
                  ...scan.own,
                  if (withDependencies)
                    for (var owner in scan.fromPackages) ...owner.assets,
                ])
                  _entryFor(path, asset),
              ],
            ),
      ],
    );
  }

  AssetEntry _entryFor(String path, ResolvedAsset asset) => AssetEntry(
    key: asset.key,
    kind: assetKindOf(asset.key).label.toLowerCase(),
    bytes: asset.totalBytes,
    address: '${addressFor(path, asset.key)}',
    package: asset.package,
    densities: [for (var file in asset.variants) file.scale!],
  );

  /// One asset, including what the file says about itself.
  Future<AssetDescription> _describe(Map<String, Object?> arguments) async {
    var key = arguments['asset'];
    if (key is! String || key.isEmpty) {
      throw ArgumentError.value(key, 'asset', 'must be an asset key');
    }
    var paths = await _requested(arguments);

    for (var path in paths) {
      var asset = _cache[path]?.catalog.byKey[key];
      if (asset == null) continue;
      return _describeAsset(path, asset);
    }

    // Names what *is* there rather than only what is not: a key is usually
    // wrong by a directory or a `packages/` prefix, and the near miss is the
    // answer.
    var near = [
      for (var path in paths)
        for (var candidate
            in _cache[path]?.catalog.assets ?? const <ResolvedAsset>[])
          if (fuzzyMatch(p.basename(key), candidate.key) != null) candidate.key,
    ].take(5);
    throw ArgumentError.value(
      key,
      'asset',
      near.isEmpty
          ? 'no such asset in ${paths.join(', ')}. Read the keys with `list`.'
          : 'no such asset. Did you mean: ${near.join(', ')}?',
    );
  }

  Future<AssetDescription> _describeAsset(
    String path,
    ResolvedAsset asset,
  ) async {
    var kind = assetKindOf(asset.key);
    var font = _fontFor(path, asset.key);

    RasterFacts? raster;
    AnimationFacts? animation;
    // Only what the kind makes plausible: a `.txt` is not put through an
    // animation parser, and nothing but a raster has a header worth reading.
    if (kind == AssetKind.image) {
      raster = readRaster(await File(asset.main.path).readAsBytes());
    } else if (kind == AssetKind.data &&
        p.extension(asset.key).toLowerCase() == '.json') {
      animation = readLottie(await File(asset.main.path).readAsString());
    }

    return AssetDescription(
      key: asset.key,
      // `data` is what an extension can tell you; `animation` is what opening
      // the file told us. Describing a Lottie as "data" after having read its
      // layer list would be reporting the guess over the answer.
      kind: animation != null ? 'animation' : kind.label.toLowerCase(),
      address: '${addressFor(path, asset.key)}',
      declaration: asset.declaration,
      file: p.relative(asset.main.path, from: asset.packageRoot),
      bytes: asset.main.length,
      totalBytes: asset.totalBytes,
      code: snippetFor(asset.key, fontFamily: font?.family),
      package: asset.package,
      densities: [
        for (var file in asset.files)
          AssetDensity(
            scale: file.scale,
            file: p.relative(file.path, from: asset.packageRoot),
            bytes: file.length,
          ),
      ],
      raster: raster == null
          ? null
          : RasterFactsResult(
              width: raster.width,
              height: raster.height,
              frames: raster.frames,
            ),
      animation: animation == null
          ? null
          : AnimationFactsResult(
              width: animation.width,
              height: animation.height,
              frameRate: animation.frameRate,
              frames: animation.frames,
              durationMs: animation.duration.inMilliseconds,
              version: animation.version,
              layers: [
                for (var layer in animation.layers)
                  AnimationLayerResult(name: layer.name, type: layer.type),
              ],
              markers: animation.markers,
            ),
      font: font,
    );
  }

  /// Everything wrong with a bundle that can be found without running the app.
  ///
  /// Scoped to each package's own assets. A dependency's density ladder is
  /// not the reader's to fix, and hashing a few thousand files they cannot
  /// change is a slow way to produce an unactionable list. Weight is the
  /// exception: what a dependency contributes is exactly the thing worth
  /// knowing, so the byte total counts everything.
  ///
  /// Returns findings rather than throwing, which is the convention the
  /// catalog's own `audit` set: the report is the answer, and every one of them
  /// is in it rather than the first one being raised as an error. The verdict
  /// rides along — [AssetAuditResult.ok] is false when there is anything to
  /// report, and `fw` exits 1 on it — so gating a job on this is the command
  /// and no wrapper.
  Future<AssetAuditResult> _audit(Map<String, Object?> arguments) async {
    var paths = await _requested(arguments);
    var maxEdge = _integer(arguments, 'maxEdge') ?? 2048;

    var findings = <AssetFinding>[];
    var checked = 0;
    var bytes = 0;
    var unreadable = <String>[];

    for (var path in paths) {
      if (_cache.failureFor(path) != null) {
        unreadable.add(path);
        continue;
      }
      var scan = _cache[path];
      if (scan == null) continue;

      checked += scan.totalCount;
      bytes += scan.totalBytes;

      findings.addAll(_declaredMissing(path, scan));
      findings.addAll(_unreachableFiles(path, scan));
      findings.addAll(await _oversized(path, scan, maxEdge));
    }

    return AssetAuditResult(
      checked: checked,
      bytes: bytes,
      findings: findings,
      unreadable: unreadable,
    );
  }

  int? _integer(Map<String, Object?> arguments, String name) {
    var value = arguments[name];
    if (value == null) return null;
    if (value is int) return value;
    var parsed = int.tryParse('$value');
    if (parsed == null) {
      throw ArgumentError.value(value, name, 'must be a whole number');
    }
    return parsed;
  }

  /// Declarations the resolver already could not resolve.
  Iterable<AssetFinding> _declaredMissing(String path, AssetScan scan) => [
    for (var problem in scan.problems)
      AssetFinding(
        kind: 'declared-missing',
        package: path,
        summary: problem.kind.summary,
        detail: [
          problem.declaration,
          if (problem.package != null) 'declared by package:${problem.package}',
          if (problem.detail != null) problem.detail!,
        ].join(' · '),
        // No address on purpose: it resolves to nothing, so there is nowhere to
        // go, and that is what is wrong with it.
        path: problem.declaration,
      ),
  ];

  /// Files sitting under a declared directory that the bundle never reaches.
  ///
  /// The finding the whole plugin was worth building for: a directory
  /// declaration is **not recursive**, so `assets/` leaves `assets/icons/star.png`
  /// on disk, in version control, and out of the app — and nothing else says so.
  /// `flutter analyze` does not look, and the failure arrives at run time
  /// pointing at a path that visibly exists.
  Iterable<AssetFinding> _unreachableFiles(String path, AssetScan scan) {
    var resolved = {
      for (var asset in scan.catalog.assets)
        for (var file in asset.files) file.path,
    };

    var findings = <AssetFinding>[];
    for (var declaration in scan.catalog.declarations) {
      // Own declarations only: a dependency's stray file is not actionable here.
      if (declaration.package != null || !declaration.isDirectory) continue;
      var directory = p.join(declaration.packageRoot, declaration.path);
      if (!Directory(directory).existsSync()) continue;

      // Listed the way git lists — see `list_files.dart`. Both halves matter
      // here: an ignored file under an asset directory is not "on disk and out
      // of the app", it is generated output nobody meant to ship, and a
      // recursive `listSync` follows symlinks by default.
      for (var file in listFilesInDirectory(directory)) {
        if (resolved.contains(file.path)) continue;
        var relative = p.relative(file.path, from: declaration.packageRoot);
        findings.add(
          AssetFinding(
            kind: 'unreachable-file',
            package: path,
            summary: 'On disk, and not in the bundle.',
            detail:
                '$relative is under "${declaration.path}", which is declared, '
                'but a directory declaration reaches only the files directly '
                'inside it. Declare '
                '"${p.split(relative).sublist(0, p.split(relative).length - 1).join('/')}/" '
                'as well, or move the file up.',
            path: relative,
          ),
        );
      }
    }
    return findings;
  }

  /// Rasters bigger than anything that will be drawn.
  Future<Iterable<AssetFinding>> _oversized(
    String path,
    AssetScan scan,
    int maxEdge,
  ) async {
    var findings = <AssetFinding>[];
    for (var asset in scan.own) {
      if (assetKindOf(asset.key) != AssetKind.image) continue;
      RasterFacts? facts;
      try {
        facts = readRaster(await File(asset.main.path).readAsBytes());
      } catch (_) {
        continue;
      }
      if (facts == null) continue;
      var longest = facts.width > facts.height ? facts.width : facts.height;
      if (longest <= maxEdge) continue;
      findings.add(
        AssetFinding(
          kind: 'oversized',
          package: path,
          key: asset.key,
          address: '${addressFor(path, asset.key)}',
          summary: 'A raster larger than anything that will draw it.',
          detail:
              '${facts.width} × ${facts.height} at '
              '${formatBytes(asset.main.length)}, against a limit of '
              '$maxEdge px. Nothing on a phone asks for that many pixels; '
              'it was probably exported at print size.',
        ),
      );
    }
    return findings;
  }

  /// The `fonts:` entry that named [key], if one did. A font file is an asset
  /// like any other, and this is the half of it the pubspec knows.
  FontFactsResult? _fontFor(String path, String key) {
    for (var family in _cache[path]?.fonts ?? const <FontFamily>[]) {
      for (var font in family.fonts) {
        if (font.key == key) {
          return FontFactsResult(
            family: family.family,
            weight: font.weight,
            style: font.style,
          );
        }
      }
    }
    return null;
  }

  /// Every asset, not just the projected ones.
  ///
  /// The default walks [report], which would make exactly the first
  /// [_projectedAssets] of each package findable — and a palette that can only
  /// reach the alphabetical head of a list is worse than one that reaches
  /// nothing, because it looks like it works. A scan is already in memory, so
  /// walking all of it costs a fuzzy match per key and stays the pure read the
  /// contract requires.
  @override
  List<SearchHit> search(String query) {
    var trimmed = query.trim();
    if (trimmed.isEmpty) return const [];

    var hits = <SearchHit>[];
    var seen = <String>{};
    for (var path in packages) {
      var scan = _cache[path];
      if (scan == null) continue;
      for (var asset in scan.catalog.assets) {
        var match = fuzzyMatch(trimmed, asset.key);
        if (match == null) continue;
        var address = addressFor(path, asset.key);
        if (!seen.add('$address')) continue;
        hits.add(
          SearchHit(
            address: address,
            title: asset.key,
            subtitle: [
              _detailFor(asset),
              if (asset.package != null) 'from ${asset.package}',
            ].join(' · '),
            group: host.label,
            reason: SearchReason.item,
            score: match.score,
            matched: match.matched,
          ),
        );
      }
    }

    // The plugin row and the package children still come from the projection —
    // there is no reason to reimplement those, and the dedupe keeps the rows
    // that appear in both from arriving twice.
    for (var hit in searchReport(
      report,
      trimmed,
      worktree: host.worktree.name,
    )) {
      if (seen.add('${hit.address}')) hits.add(hit);
    }

    hits.sort((a, b) => b.score - a.score);
    return hits;
  }
}

PluginCore assetsCoreFactory(PluginHost host) => AssetsCore(host);
