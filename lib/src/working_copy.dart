import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import 'utils/list_files.dart';

/// The mirror of a pub-cache flutterware in a writable tree: where it goes,
/// what it is made of, and when it has stopped being current.
///
/// The one place that knows what the copy is a **function of**. Getting that
/// wrong does not look like a stale copy — it looks like a compile error a
/// minute into a GUI build, in a package the project never asked for.

/// Where a pub-cache package is mirrored so there is a writable tree to resolve
/// and build in.
///
/// The hash is of the *flutterware package root*, which for a hosted dependency
/// already contains the version — so this is one copy per flutterware version
/// per machine, shared across every project that uses it, not one per project.
///
/// Split from the copy itself because the plan has to be decided before
/// anything runs, and deciding it means knowing this path first: whether the
/// CLI and the GUI need building are questions about files inside it.
String workingCopyPath(String packageRoot) =>
    p.join(userHomePath(), '.flutterware', hashOf(packageRoot));

/// Where [copyPackageInto] records the stamp of the copy it made.
File workingCopyStampFile(String root) => File(p.join(root, '.source_stamp'));

/// The files the copy is made of: everything the walk finds except
/// `pubspec.lock`.
///
/// A lock is a resolution, and a resolution is a fact about one SDK.
/// flutterware resolves its own workspace against the SDK it is developed on;
/// the copy is resolved and built by whichever SDK the consumer's project
/// names. Carrying the lock across that boundary hands them package versions
/// picked for a Dart they are not running, and `pub get` — lock-preserving by
/// design — honours it for as long as the file exists. A consumer on a newer
/// Flutter than this repository's pin gets a resolution that predates their
/// SDK, and the way that surfaces is a package in the middle of the graph
/// failing to *parse*. The copy resolves where it is built.
///
/// The same list backs [copyPackageInto] and [workingCopyStamp], so a file the
/// copy skips cannot invalidate it.
Iterable<File> packageFiles(String packageRoot) => listFilesInDirectory(
  packageRoot,
  ignoreRoot: packageRoot,
).where((file) => p.basename(file.path) != 'pubspec.lock');

/// Identifies everything the copy is built from, so one that is no longer
/// current is noticed without being declared.
///
/// The SDK is an input, not a constant. The tree is resolved by the Dart
/// running the launcher and built by the Flutter beside it, so the same sources
/// under a different SDK are a different copy: the versions that satisfied the
/// old one are not the versions the new one would pick, and the binaries are
/// the old one's output. Fingerprinting the sources alone made the copy "once
/// per flutterware version" exactly as the panel says — and left a project that
/// upgraded its SDK holding a resolution nothing would ever revisit.
///
/// [sdk] defaults to the running one; it is a parameter so a test can change
/// SDKs without changing Dart.
String workingCopyStamp(String packageRoot, {String? sdk}) {
  var files = <String>[];
  for (var file in packageFiles(packageRoot)) {
    var stat = file.statSync();
    files.add(
      '${p.relative(file.path, from: packageRoot)}'
      '|${stat.size}|${stat.modified.millisecondsSinceEpoch}',
    );
  }
  files.sort();
  return sha1
      .convert(utf8.encode([sdk ?? Platform.version, ...files].join('\n')))
      .toString();
}

/// [packageRoot] is its own ignore root, here and in [workingCopyStamp] and in
/// the launcher's freshness test: this package sits in the pub cache, and a
/// rule from some unrelated repository above it — `$HOME` kept as a dotfiles
/// repository is the way that happens — would drop files the copy has to carry.
void copyPackageInto(String packageRoot, String destination, String stamp) {
  for (var file in packageFiles(packageRoot)) {
    var target = p.join(destination, p.relative(file.path, from: packageRoot));
    File(target).createSync(recursive: true);
    file.copySync(target);
  }

  // Deleted rather than merely not copied: a copy an older flutterware made
  // brought one, and `pub get` would go on honouring it for as long as it sat
  // there. Removing it is what turns the next resolve into the consumer's own.
  var lock = File(p.join(destination, 'pubspec.lock'));
  if (lock.existsSync()) lock.deleteSync();

  _dropAbsentMembers(destination);

  // Last, so an interrupted copy is not recorded as a complete one.
  workingCopyStampFile(destination).writeAsStringSync(stamp);
}

/// Cuts the copy's `workspace:` list down to the members the copy has.
///
/// The root pubspec lists every package this repository develops together —
/// the studio, the demo, the fixture, the web demo — and `.pubignore` keeps all
/// of them but `app/` out of the archive. The copy resolves `app/`, a workspace
/// member, so pub reads that list and refuses the first entry it cannot find:
/// *No workspace packages matching `fixtures/probe_app`*. Every hosted install
/// stopped there, before anything was built.
void _dropAbsentMembers(String root) {
  var pubspec = File(p.join(root, 'pubspec.yaml'));
  if (!pubspec.existsSync()) return;
  var before = pubspec.readAsStringSync();
  var inWorkspace = false;
  var kept = <String>[];
  for (var line in before.split('\n')) {
    if (RegExp(r'^workspace:\s*$').hasMatch(line)) {
      inWorkspace = true;
    } else if (inWorkspace) {
      var member = RegExp(r'''^\s+-\s+['"]?([^'"\s#]+)''').firstMatch(line);
      if (member != null) {
        var present = File(p.join(root, member.group(1)!, 'pubspec.yaml'))
            .existsSync();
        if (!present) continue;
      } else if (RegExp(r'^[^\s#]').hasMatch(line)) {
        inWorkspace = false;
      }
    }
    kept.add(line);
  }
  var after = kept.join('\n');
  if (after != before) pubspec.writeAsStringSync(after);
}

/// Deletes the build state a working copy will never build in again, and
/// answers how many entries it removed.
///
/// A copy is a mirror of an *immutable* pub-cache package: its sources cannot
/// change, so [workingCopyStamp] never moves and nothing here ever builds a
/// second time. Everything a build leaves behind to make the next one
/// incremental is therefore dead the moment the first one succeeds — and it is
/// most of the copy. Measured on this machine: a built copy is ~1500 MB, of
/// which the product is 65 MB and the `fw` binary 17 MB. `FlutterMacOS
/// .framework.dSYM` alone is 501 MB of engine debug symbols, in a release
/// build, that nothing here symbolicates.
///
/// Two things are removed:
///
/// - **Everything beside [guiProduct]** within the platform build directory
///   that holds it. The freshness test both build sites use is
///   `DesktopGui.binary.existsSync()` — the product and nothing else — and a
///   release bundle is self-contained: its frameworks are embedded and its
///   rpaths are relative to the executable, so nothing outside it is
///   referenced. Trimming to it is measured at 1188 MB → 66 MB.
/// - **The Dart and Flutter build caches** — `app/.dart_tool/flutter_build` and
///   the workspace's `.dart_tool/hooks_runner`, ~265 MB together. Both are
///   inputs to a next build, not to running; `dart build cli` copies the build
///   assets it needs into its own bundle and `flutter build` embeds them in the
///   product. `.dart_tool/package_config.json` is deliberately **not** touched:
///   that is the resolution, and losing it would turn a warm run into a
///   `pub get`.
///
/// **Only ever a copy.** A checkout builds again constantly, and there the
/// incremental state is the whole point — the caller passes `editable` before
/// it gets here.
///
/// **Only ever after a build that worked**, and that takes two tests rather
/// than one.
///
/// [guiProduct] existing is the precondition for all of it, not just for the
/// pruning around it: a copy with no product is either mid-way through a first
/// build or holding the wreckage of one that failed, and that wreckage is what
/// the next attempt resumes from. It is asked here rather than left to each
/// caller so there is no way to reach the deletions without it.
///
/// The caller owes the other half — that no build *in this pass* failed — and
/// the two are not redundant. Observed: a GUI build that failed in the Dart
/// kernel step had **already staged a partial `.app`**, so the product was
/// there and the tree was not finished. Product-exists alone would have
/// reclaimed 1129 MB the retry was about to resume from.
///
/// The cost of that precondition is a copy that only ever built the CLI, which
/// keeps `hooks_runner` — 12 MB, and genuinely an input to the GUI build it has
/// not run yet.
///
/// Safe to call on every launch rather than only after a build: with nothing to
/// delete it is a handful of `listSync` calls, measured at 45–63 µs, and
/// calling it on the warm path is what reclaims the copies made before this
/// existed. It must be called under the same build lock as the build itself, so
/// it cannot delete intermediates from under another process's `flutter build`.
///
/// Every failure is swallowed per entry. This is housekeeping, and no launch
/// should fail over reclaiming disk.
int trimWorkingCopy(String appPath, {required Directory guiProduct}) {
  if (!guiProduct.existsSync()) return 0;

  // Walk up from the product to the platform directory under `build/`,
  // recording the chain — and only act once it is known to terminate there. A
  // product that is not under this copy's `build/` is somebody else's tree, and
  // the failure mode of guessing is deleting it.
  var buildDir = p.join(appPath, 'build');
  var chain = <String>[guiProduct.path];
  var here = p.dirname(guiProduct.path);
  while (!p.equals(here, buildDir)) {
    var parent = p.dirname(here);
    if (parent == here) return 0;
    chain.add(here);
    here = parent;
  }

  // Deepest first, so each step names what its parent must keep. The last entry
  // is `build/<platform>`; `build/` itself is never pruned, because that is
  // where `cli/`, `catalog/` and the build logs live.
  var deleted = 0;
  for (var i = 0; i < chain.length - 1; i++) {
    deleted += _deleteBeside(chain[i], within: chain[i + 1]);
  }

  for (var cache in [
    p.join(appPath, '.dart_tool', 'flutter_build'),
    p.join(p.dirname(appPath), '.dart_tool', 'hooks_runner'),
  ]) {
    if (_delete(Directory(cache))) deleted++;
  }

  return deleted;
}

/// Deletes every child of [within] except [keep].
int _deleteBeside(String keep, {required String within}) {
  List<FileSystemEntity> entries;
  try {
    entries = Directory(within).listSync();
  } on FileSystemException {
    return 0;
  }
  var deleted = 0;
  for (var entity in entries) {
    if (p.equals(entity.path, keep)) continue;
    if (_delete(entity)) deleted++;
  }
  return deleted;
}

bool _delete(FileSystemEntity entity) {
  try {
    if (!entity.existsSync()) return false;
    entity.deleteSync(recursive: true);
    return true;
  } on FileSystemException {
    return false;
  }
}

String userHomePath() {
  var envKey = Platform.isWindows ? 'APPDATA' : 'HOME';
  return Platform.environment[envKey] ?? '.';
}

String hashOf(String input) => sha1
    .convert(utf8.encode(input))
    .bytes
    .map((b) => b.toRadixString(16).padLeft(2, '0'))
    .join();
