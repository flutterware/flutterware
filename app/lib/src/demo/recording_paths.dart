/// Where things live inside a recording. Pure Dart, because the script that
/// writes a recording runs under `dart`, and the studio that reads one runs
/// under Flutter — and the two have to agree on every path without either
/// importing the other's world.
///
/// A **recording** is a fixture the real tool produced from a real project:
/// the launcher-icon scan of `fixtures/probe_app` with the files it names
/// copied in beside it, and a run of some of its scenarios with every frame
/// and tree the harness wrote. The studio's own catalog demos, its scenario
/// tests and the web demo all open one. See
/// `docs/superpowers/specs/2026-09-10-studio-over-a-fake-project-design.md`.
library;

/// Where the recorded project pretends to be. Never read from disk; it is what
/// the address bar shows, what the facts store is keyed by, and the root a
/// recorded run's artifact paths are spelled under so the core relativises
/// them back to recording-relative.
const recordedProjectRoot = '/recording';

/// The recording's package path for a package. `.` is `root`, and a nested
/// path flattens to one segment so every file of a recording sits at a known
/// depth — which is what lets the whole recording be declared as two asset
/// directories.
String recordedPackageSlug(String packagePath) =>
    packagePath == '.' ? 'root' : packagePath.replaceAll('/', '-');

/// The launcher-icon scan of one package and flavor.
String recordedIconScanPath(String packagePath, {String? flavor}) =>
    'launcher_icon/${recordedPackageSlug(packagePath)}'
    '${flavor == null ? '' : '.$flavor'}.json';

/// Where the copy of one of that scan's files goes. Flat, for the reason
/// [recordedPackageSlug] gives: a Flutter asset directory is not recursive,
/// and a mirror of `android/app/src/main/res/mipmap-xxxhdpi/…` would need a
/// pubspec line per density.
String recordedIconFilePath(String packagePath, String packageRelativePath) =>
    'launcher_icon/files/${recordedPackageSlug(packagePath)}-'
    '${packageRelativePath.replaceAll('/', '-')}';

/// The syntactic scan of one package's scenarios.
/// The servers a recording holds, by name, and one file per server: its
/// handle, its hello, its whole ring, the details behind each event and the
/// answers to the commands the panel can send.
String recordedServerIndexPath(String packagePath) =>
    'server/${recordedPackageSlug(packagePath)}.servers.json';

String recordedServerPath(String packagePath, String name) =>
    'server/${recordedPackageSlug(packagePath)}.$name.json';

/// The dev stack's script, as the recorder answered for it: what each
/// command printed, in each state the stack can be in.
String recordedStackPath(String packagePath) =>
    'stack/${recordedPackageSlug(packagePath)}.stack.json';

/// One package's translation catalogs, as its declared globs read them:
/// `{"globs": {"assets/i18n/*.json": {"assets/i18n/en.json": "…"}}}`. The
/// files' text, not a copy of the files — a recording cannot walk a glob, so
/// it keeps the walk's answer.
String recordedTranslationCatalogsPath(String packagePath) =>
    'translations/${recordedPackageSlug(packagePath)}.catalogs.json';

/// One package's translation export, verbatim: `keys.json` and the `shots/`
/// tree beside it, exactly as `fw run translations export` wrote them. The
/// panel resolves every shot under this directory, so it is also what the
/// recorded source answers for the export's directory.
String recordedTranslationExportDir(String packagePath) =>
    'translations/${recordedPackageSlug(packagePath)}';

/// One package's store export as the panel reads it: the pubspec's name and
/// description, and the manifest — `{"pubspec": {…}, "manifest": {…}}` —
/// with every set's `output` spelled under [recordedStoreRootDir].
String recordedStorePath(String packagePath) =>
    'store/${recordedPackageSlug(packagePath)}.store.json';

/// Where a recorded export's trees sit: an app's tree is under it by the
/// app's name, exactly as under `build/flutterware/store`, so the manifest's
/// paths resolve under the recording the way they resolve on disk.
String recordedStoreRootDir(String packagePath) =>
    'store/${recordedPackageSlug(packagePath)}';

/// One package's dependencies, everything the plugin reads in one file: the
/// pubspec and lockfile texts, `pub deps --json` verbatim, the package config
/// with every root spelled under [recordedDependencyRoot], and per package
/// its pubspec, readme, changelog, line count, size and pub.dev entry; the
/// pub.dev scores table cut to the packages present, and the package's own
/// imports.
String recordedDependenciesPath(String packagePath) =>
    'dependencies/${recordedPackageSlug(packagePath)}.dependencies.json';

/// Where a recorded resolution's packages pretend to be: one directory per
/// package name, flat, under the recorded project. What a dependency's
/// `rootPath` reads, and the key its recorded facts are filed under.
const recordedDependencyRoot = '$recordedProjectRoot/packages';

/// What the splash scan read of one package: every file it opened, with its
/// size and time, under `files`, and every directory it listed with what it
/// saw there under `directories` — both keyed by package-relative path, a
/// directory seen but never listed holding null. The files' bytes sit at
/// [recordedSplashFilePath].
String recordedSplashIndexPath(String packagePath) =>
    'splash/${recordedPackageSlug(packagePath)}.files.json';

/// Where the copy of one file the splash scan read goes: under the
/// package's slug at its own relative path, so the tree under the recording
/// is the tree the scan walked.
String recordedSplashFilePath(String packagePath, String packageRelative) =>
    'splash/${recordedPackageSlug(packagePath)}/$packageRelative';

String recordedScenarioScanPath(String packagePath) =>
    'scenarios/${recordedPackageSlug(packagePath)}.scan.json';

/// What the live harness listed for one package: profiles, devices, tags.
String recordedScenarioListingsPath(String packagePath) =>
    'scenarios/${recordedPackageSlug(packagePath)}.listings.json';

/// Which scenario files of one package were run and recorded.
String recordedScenarioRunsIndexPath(String packagePath) =>
    'scenarios/${recordedPackageSlug(packagePath)}.runs.json';

/// The project's launcher icon as the flow page's banner shows it.
String recordedScenarioAppIconPath(String packagePath) =>
    'scenarios/${recordedPackageSlug(packagePath)}.icon.png';

/// The harness's report for one scenario file's run, verbatim but for its
/// artifact paths, which are spelled relative to the recording.
String recordedScenarioRunPath(String packagePath, String file) =>
    'scenarios/${recordedPackageSlug(packagePath)}/'
    '${recordedScenarioFileSlug(file)}.json';

/// Where that run's artifacts for one scenario go — a directory per
/// scenario, each file keeping the name the harness gave it.
String recordedScenarioArtifactDir(
  String packagePath,
  String file,
  String scenario,
) =>
    'scenarios/${recordedPackageSlug(packagePath)}/'
    '${recordedScenarioFileSlug(file)}/${recordedScenarioSlug(scenario)}';

/// `test/scenarios/mobile/shop_test.dart` → `test-scenarios-mobile-shop_test`.
String recordedScenarioFileSlug(String file) =>
    file.replaceFirst(RegExp(r'\.dart$'), '').replaceAll('/', '-');

/// `Order a cappuccino` → `order-a-cappuccino`.
String recordedScenarioSlug(String scenario) => scenario
    .toLowerCase()
    .replaceAll(RegExp(r'[^a-z0-9]+'), '-')
    .replaceAll(RegExp(r'^-|-$'), '');

/// The git tape behind the changes screen: every call the probe and the
/// explorer's facts made over the recorded checkout, keyed by its arguments,
/// with where each answer's bytes sit. A text answer is a `.txt` beside it
/// and a binary one — a blob — a `.bin`.
const recordedGitTapePath = 'changes/git.json';

/// What the changes screen read off the recorded working tree: each file's
/// size and time, keyed by checkout-relative path. The bytes sit at
/// [recordedChangesFilePath].
const recordedChangesFilesIndexPath = 'changes/files.json';

/// Where the copy of one working-tree file the changes screen read goes: at
/// its own relative path, so the tree under the recording is the tree the
/// screen read.
String recordedChangesFilePath(String relative) => 'changes/root/$relative';

/// How a call is filed in the git tape: its arguments, joined by a byte no
/// argument carries. The recorder files with this; `RecordedGit` looks up
/// with it.
String gitTapeKey(List<String> arguments) => arguments.join('\u0000');

/// The comparison the recorder ran over the recorded checkout, as `fw
/// compare --export` writes it: the published index, with every frame it
/// names rewritten to a PNG at [recordedComparisonFilePath].
const recordedComparisonIndexPath = 'comparison/index.json';

/// Where one of the comparison's pictures sits: at the relative path the
/// export gave it, under the same directory as the index.
String recordedComparisonFilePath(String relative) => 'comparison/$relative';

/// The run dir a recorded run lives in, as the studio sees it: the handle,
/// the launcher's log, the journal and its pictures are spelled under this,
/// so the run plugin reads them by the same paths it would on a machine.
/// Never a directory on disk — `RecordedRunFiles` answers for it.
const recordedRunDir = '$recordedProjectRoot/run';

/// Where the recording keeps the files of [recordedRunDir]: the same tree,
/// under `run/`, so `$recordedRunDir/x` is `run/x`.
String recordedRunFilePath(String relative) => 'run/$relative';

/// Every file of the recorded run dir, relative to it — the listing a
/// directory walk would have given. The recorded end preloads them all.
const recordedRunIndexPath = 'run.index.json';

/// What a recorded run's app answered on its channels: the events it
/// replayed on attach, and the reply to each request the cockpit's App tab
/// makes, keyed by [recordedChannelRequestKey].
String recordedRunChannelsPath(String runKey) => 'run.channels/$runKey.json';

/// How a request is filed among a recorded app's answers: its channel, its
/// method and its parameters as JSON, which is how the App tab sends them.
String recordedChannelRequestKey(
  String channel,
  String method,
  Map<String, Object?> params,
) => '$channel/$method ${_canonicalJson(params)}';

String _canonicalJson(Object? value) => switch (value) {
  Map() =>
    '{${[for (var key in value.keys.map((k) => '$k').toList()..sort()) '"$key":${_canonicalJson(value[key])}'].join(',')}}',
  List() => '[${value.map(_canonicalJson).join(',')}]',
  String() => '"${value.replaceAll(r'\', r'\\').replaceAll('"', r'\"')}"',
  _ => '$value',
};
