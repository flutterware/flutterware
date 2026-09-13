import 'dart:async';

import 'package:flutterware/plugins.dart';
import 'package:path/path.dart' as p;

import '../../launcher_icon/model/role.dart';
import '../../launcher_icon/model/scan.dart';
import '../../session/job.dart';
import '../plugin_core.dart';
import '../plugin_host.dart';
import '../scan_cache.dart';
import 'icon_address.dart';
import 'icon_results.dart';

/// The registered id — also what `tool/flutterware.dart` declares.
const launcherIconPluginId = 'flutterware.launcher_icon';

/// What this plugin is, for a reader who has only the id — see
/// `PluginReport.description`.
const _pluginDescription =
    'Every launcher icon each declared package has, and what each operating '
    'system actually shows of them.';

/// Every launcher icon a package has, and what each operating system does with
/// it.
///
/// The subject is what the OS shows rather than what a generator wrote. Nothing
/// here opens `icons_launcher.yaml` or `flutter_launcher_icons.yaml`, and
/// nothing here can run a generator: a config is one project's way of
/// producing these files, and an agent reads it better than a transcription
/// that goes stale every release. What is left is the part with no coupling at
/// all — the files, the project's own wiring, and the platform rules that
/// decide which of them a user ever sees.
///
/// That independence is deliberate. This reads the same on a project that
/// generated its icons, one that drew them by hand, and one that let Xcode do
/// it.
///
/// Holds to the two rules every core holds to: the constructor allocates
/// nothing, and [report] only formats what a previous call caused to load.
/// Loading is listing directories and reading image headers.
class LauncherIconCore extends PluginCore {
  /// [scan] is where a scan comes from — [scanIcons] off the package on disk
  /// unless told otherwise.
  ///
  /// This is the one door a **recorded** core needs. Everything the panel
  /// reads is a pass-through of the cache this fills, so a core handed a
  /// reader that answers from a fixture is this same class with the disk left
  /// out: same report, same actions, same panel, no second implementation to
  /// keep in step. The studio's own catalog demos, its scenario tests and the
  /// web demo all come through here.
  LauncherIconCore(super.host, {IconScanner? scan}) : _scan = scan ?? _liveScan;

  final IconScanner _scan;

  static IconScan _liveScan({
    required String Function() packageRoot,
    required String packagePath,
    String? flavor,
  }) => scanIcons(
    packageRoot: packageRoot(),
    packagePath: packagePath,
    flavor: flavor,
  );

  /// Declared packages, filtered to those the workspace knows about, so a typo
  /// cannot make the plugin scan a directory that is not there.
  late final List<String> packages = [
    for (var path in host.packagePaths)
      if (host.workspace.exists(path)) path,
  ];

  /// Keyed by package *and* source set: a flavour is a different set of files
  /// in the same package, so it cannot share one scan.
  ///
  /// The package root is resolved lazily, inside the loader, because resolving
  /// it means asking the filesystem for an absolute path — which a recorded
  /// core never needs and a browser cannot answer.
  late final _cache = ScanCache<(String path, String? flavor), IconScan>(
    scan: (key) async => await _scan(
      packageRoot: () => host.workspace.packageFor(key.$1).absolutePath,
      packagePath: key.$1,
      flavor: key.$2,
    ),
    onChanged: notifyChanged,
  );

  /// The scan for one package and source set, or null when nothing has looked
  /// at it yet.
  IconScan? scanFor(String path, {String? flavor}) => _cache[(path, flavor)];

  String? failureFor(String path, {String? flavor}) =>
      _cache.failureFor((path, flavor));

  bool isScanning(String path, {String? flavor}) =>
      _cache.isScanning((path, flavor));

  /// Where a cell *is*.
  ///
  /// Built here rather than left to a reader to reassemble, which is how two
  /// surfaces come to disagree about what a thing is called.
  Address addressFor(
    String packagePath, {
    String? flavor,
    IconRole? role,
    AdaptiveMask? mask,
  }) => Address(
    worktree: host.worktree.name,
    plugin: host.id,
    segments: iconSegments(packagePath, flavor),
    axes: iconAxes(role: role, mask: mask),
  );

  /// Scans [path], unless it already has been. Idempotent.
  void track(String path, {String? flavor}) => _cache.track((path, flavor));

  /// Drops the cached scan so the next [track] re-reads.
  void invalidate(String path, {String? flavor}) =>
      _cache.invalidate((path, flavor));

  /// Reads the tree again, and completes when the new scan is in.
  ///
  /// [track] is fire-and-forget, which is right for mounting — nothing is
  /// waiting — and wrong for a button, where the thing that pressed it wants to
  /// show the result. Returning the future lets the caller await rather than
  /// depend on some ancestor happening to listen for the change.
  Future<void> reload(String path, {String? flavor}) =>
      _cache.reload((path, flavor));

  @override
  Future<void> computeAll() async {
    await Future.wait([for (var path in packages) _cache.load((path, null))]);
  }

  // ---- Report ------------------------------------------------------------

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

  /// The plugin's own row, which stays **quiet**.
  ///
  /// A viewer has nothing to announce most of the time, and "not computed" is
  /// the resting state every plugin is in until you click it — saying so on
  /// every sidebar paint draws the eye to nothing. So this speaks only for
  /// things that are the plugin's rather than a package's, and the counts live
  /// on the package rows where they belong.
  Status get _status => Status.none;

  /// The worst thing any package has to say, as a mark rather than a sentence.
  StatusBadge get _badge {
    var worst = Tone.neutral;
    for (var path in packages) {
      if (_cache.failureFor((path, null)) != null) {
        return const StatusBadge.dot(Tone.error);
      }
      var scan = _cache[(path, null)];
      if (scan == null) continue;
      for (var finding in scan.findings) {
        if (finding.tone == Tone.error) {
          return const StatusBadge.dot(Tone.error);
        }
        if (finding.tone == Tone.warn) worst = Tone.warn;
      }
    }
    return worst == Tone.warn
        ? const StatusBadge.dot(Tone.warn)
        : StatusBadge.none;
  }

  Status _childStatus(String path) {
    var failure = _cache.failureFor((path, null));
    if (failure != null) return Status.error(failure);

    var scan = _cache[(path, null)];
    if (scan == null) {
      // Silent until it has been looked at: the resting state is not news.
      return _cache.isScanning((path, null))
          ? const Status.info('Reading…')
          : Status.none;
    }

    if (scan.isEmpty) return const Status.neutral('No icons found');

    var errors = scan.findings.where((f) => f.tone == Tone.error).length;
    if (errors > 0) {
      return Status.error('$errors problem${errors == 1 ? '' : 's'}');
    }
    var warnings = scan.findings.where((f) => f.tone == Tone.warn).length;
    if (warnings > 0) {
      return Status.warn('$warnings warning${warnings == 1 ? '' : 's'}');
    }
    return Status.good('${scan.fileCount} files');
  }

  PluginView get _view {
    var nodes = <ViewNode>[];
    for (var path in packages) {
      var scan = _cache[(path, null)];
      if (scan == null) continue;
      nodes.add(
        ViewSection(path == '.' ? 'root' : path, [
          if (scan.isEmpty)
            const ViewText('No launcher icons found in this package.')
          else ...[
            for (var platform in scan.platforms)
              ..._platformNodes(path, scan, platform),
            ..._contextNodes(scan),
            if (scan.findings.isNotEmpty)
              ViewSection('Findings', [
                ViewItems([
                  for (var finding in scan.findings)
                    ViewItem(
                      finding.role?.label ?? 'project',
                      detail: finding.message,
                      tone: finding.tone,
                      address: finding.role == null
                          ? null
                          : addressFor(
                              path,
                              flavor: scan.flavor,
                              role: finding.role,
                            ),
                    ),
                ]),
              ]),
          ],
        ]),
      );
    }
    return PluginView(nodes);
  }

  List<ViewNode> _platformNodes(
    String packagePath,
    IconScan scan,
    IconPlatform platform,
  ) {
    var roles = [
      for (var role in scan.forPlatform(platform))
        if (role.isNotEmpty) role,
    ];
    if (roles.isEmpty) return const [];

    return [
      ViewSection(platform.label, [
        ViewTable(
          const ['Role', 'Files', 'Largest', 'Shown'],
          [
            for (var role in roles)
              [
                role.role.label,
                role.color != null && role.files.isEmpty
                    ? role.color!
                    : '${role.files.length}',
                _largest(role),
                _shown(role),
              ],
          ],
        ),
      ]),
    ];
  }

  static String _largest(IconRoleScan role) {
    var largest = role.largest;
    if (largest == null) return '—';
    if (largest.icoFrames.isNotEmpty) {
      return '${largest.icoFrames.length} frames to ${largest.icoFrames.last}px';
    }
    if (largest.width == null) return '—';
    return '${largest.width}×${largest.height}';
  }

  /// Whether the OS reaches this, in a word.
  static String _shown(IconRoleScan role) => switch (role.referenced) {
    false => 'never — unreferenced',
    true => role.role.since ?? 'yes',
    null => role.role.since ?? 'yes',
  };

  /// The facts that decide what the tables above actually mean.
  List<ViewNode> _contextNodes(IconScan scan) => [
    ViewSection('Project', [
      if (scan.ios != IosCatalog.none)
        ViewField('iOS icons', switch (scan.ios) {
          IosCatalog.appIconSet => 'AppIcon.appiconset',
          IosCatalog.iconComposer =>
            'Icon Composer — ${scan.iconBundles.join(', ')}',
          IosCatalog.both =>
            'both an Icon Composer bundle and AppIcon.appiconset',
          IosCatalog.none => 'none',
        }, tone: scan.ios == IosCatalog.both ? Tone.warn : Tone.neutral),
      if (scan.flavors.isNotEmpty)
        ViewField('Icon sets', scan.flavors.map(_flavorSummary).join(', ')),
    ]),
  ];

  // ---- Actions -----------------------------------------------------------

  ActionParameter get _packageParameter => ActionParameter(
    'package',
    'Package',
    kind: ActionParameterKind.choice,
    required: false,
    description: 'Which declared package; the first when omitted',
    options: [
      for (var path in packages)
        ActionOption(path, label: path == '.' ? 'root' : path),
    ],
  );

  static const _flavorParameter = ActionParameter(
    'flavor',
    'Flavor',
    required: false,
    description:
        'Which icon set — a flutter_launcher_icons-<flavor>.yaml, an '
        'android/app/src/<flavor>/ or an AppIcon-<flavor>.appiconset; the '
        'unflavored one when omitted. These names come from the files, which '
        "is the generator's convention rather than the project's flavor "
        'list: a project that wires its own Gradle sourceSets and '
        'ASSETCATALOG_COMPILER_APPICON_NAME can share one set across several '
        'flavors, and then this name is not one `flutter run --flavor` takes. '
        'Whatever a set does not override falls back to the unflavored one, '
        'the way the build does.',
  );

  List<PluginAction> get _actions => [
    PluginAction(
      'inventory',
      'Inventory',
      returns: IconInventoryResult,
      description:
          'Every launcher icon on disk, what the OS does with each, and which '
          'of them the project never actually references',
      parameters: [_packageParameter, _flavorParameter],
    ),
  ];

  @override
  Future<Object?> invoke(
    String actionId, {
    Map<String, Object?> arguments = const {},
  }) async {
    var path = _packageArgument(arguments);
    var flavor = arguments['flavor'];
    var wanted = flavor is String && flavor.isNotEmpty ? flavor : null;

    await _cache.load((path, wanted));
    var failure = _cache.failureFor((path, wanted));
    if (failure != null) throw ActionRefusal(failure);

    return switch (actionId) {
      'inventory' => _inventory(path, wanted),
      _ => throw ArgumentError.value(
        actionId,
        'actionId',
        'unknown action on $id',
      ),
    };
  }

  String _packageArgument(Map<String, Object?> arguments) {
    var given = arguments['package'];
    if (given is String && given.isNotEmpty) {
      if (!packages.contains(given)) {
        throw ArgumentError.value(
          given,
          'package',
          'not declared for this plugin; try one of ${packages.join(', ')}',
        );
      }
      return given;
    }
    if (packages.isEmpty) {
      throw ActionRefusal('No packages are configured for $id.');
    }
    return packages.first;
  }

  /// An icon set as one readable phrase — the name, and what is behind it when
  /// that is not everything.
  ///
  /// The qualification is what matters. "dev (configured, not generated)" is a
  /// different instruction from "dev", and the bare name was the only thing
  /// this could ever say back when a set was a directory listing.
  static String _flavorSummary(IconFlavor flavor) {
    if (flavor.isUnbuilt) return '${flavor.name} (not generated)';
    var missing = [
      if (!flavor.has(IconFlavorSource.androidSourceSet)) 'Android',
      if (!flavor.has(IconFlavorSource.iosCatalog)) 'iOS',
    ];
    if (missing.isEmpty) return flavor.name;
    return '${flavor.name} (no ${missing.join(' or ')} icons)';
  }

  IconInventoryResult _inventory(String path, String? flavor) {
    var scan = _cache[(path, flavor)]!;
    var packageRoot = host.workspace.packageFor(path).absolutePath;

    if (flavor != null && !scan.flavors.any((f) => f.name == flavor)) {
      throw ArgumentError.value(
        flavor,
        'flavor',
        'no icon set "$flavor" in "$path" — nothing names it: no '
            'flutter_launcher_icons-$flavor.yaml, no android/app/src/$flavor/ '
            'and no AppIcon-$flavor.appiconset. '
            'Found: ${scan.flavors.isEmpty ? 'none' : scan.flavors.map((f) => f.name).join(', ')}',
      );
    }

    return IconInventoryResult(
      package: path,
      address: '${addressFor(path, flavor: flavor)}',
      flavor: flavor,
      flavors: [
        for (var entry in scan.flavors)
          IconFlavorEntry(
            name: entry.name,
            sources: [for (var s in entry.sources) s.name]..sort(),
          ),
      ],
      iosCatalog: scan.ios.name,
      iconBundles: scan.iconBundles,
      roles: [
        for (var role in scan.roles)
          if (role.isNotEmpty)
            IconRoleEntry(
              role: role.role.id,
              label: role.role.label,
              platform: role.role.platform.name,
              treatment: role.role.treatment.name,
              mask: role.role.mask.name,
              since: role.role.since,
              referenced: role.referenced,
              color: role.color,
              files: [
                for (var file in role.files)
                  IconFileEntry(
                    // Worktree-relative: an agent's tools are scoped to the
                    // repo, not to one package inside it.
                    path: p.relative(
                      p.join(packageRoot, file.path),
                      from: host.worktree.path,
                    ),
                    modified: file.modified.toIso8601String(),
                    width: file.width,
                    height: file.height,
                    hasAlpha: file.hasAlpha,
                    density: file.density,
                    icoFrames: file.icoFrames,
                    declaredSize: file.sizeMismatch ? file.declaredSize : null,
                  ),
              ],
            ),
      ],
      findings: [
        for (var finding in scan.findings)
          IconFindingEntry(
            tone: finding.tone.name,
            message: finding.message,
            role: finding.role?.id,
          ),
      ],
    );
  }
}

PluginCore launcherIconCoreFactory(PluginHost host) => LauncherIconCore(host);
