/// Whether the scan on screen is still the scan the disk would produce.
///
/// Polled, not watched, and that is a decision rather than a shortcut. The
/// reasons are specific to this plugin and are worth keeping next to the code,
/// because `ConfigWatcher` sits two directories away doing the opposite:
///
/// - **The set is not one file.** It is the config, *every image the config
///   references*, and the generated artifacts — around fifteen paths across four
///   directories. A designer re-exporting `logo.png` has to move the preview,
///   and a watch on the config alone would never see it.
/// - **`DirectoryWatcher` is recursive.** `ConfigWatcher` gets away with it
///   because `tool/` holds three files; pointing one at a package root would
///   walk `build/`, `.dart_tool/`, `android/` and `ios/`.
/// - **The budget is different.** `ConfigWatcher` feeds a compile-and-swap loop
///   that wants sub-100ms. A preview is fine at 750ms.
/// - **The scan already `stat`s all of it.** A fingerprint costs what the scan
///   costs to validate itself, which is nothing.
///
/// None of that makes polling reliable enough to be the only mechanism — a
/// network mount or a clock with one-second granularity can still hide an edit,
/// and a stale preview is indistinguishable from a correct one. Hence the manual
/// reload beside it, which is permanent rather than a fallback.
library;

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import 'files.dart';
import 'generated.dart';
import 'scan.dart';

/// A cheap summary of every file [scan] depended on, plus the files that would
/// *become* a config if they appeared.
///
/// Two fingerprints differing means the scan is out of date. Two fingerprints
/// matching means it almost certainly is not — "almost" because a filesystem
/// with second-granularity mtimes can hide a rewrite of identical length inside
/// the same second. That is what the reload button is for.
///
/// [scan] is null before the first scan, or after one that threw. The config
/// candidates are still checked in that case, so a project whose config is
/// fixed or added recovers on the next poll.
String splashFingerprint({
  required String packageRoot,
  SplashScan? scan,
  SplashFiles files = const LiveSplashFiles(),
}) {
  var entries = <String>[];
  void stat(String absolute) {
    var s = files.stat(absolute);
    if (s == null) {
      // Recorded rather than skipped: a config file being deleted has to read as
      // a change, not as one fewer line in the digest.
      entries.add('$absolute|-');
      return;
    }
    entries.add('$absolute|${s.modified.microsecondsSinceEpoch}|${s.size}');
  }

  // The two fixed candidates, whether or not either exists — this is what makes
  // "the project grew a flutter_native_splash.yaml" a change rather than a thing
  // nobody notices until the next restart.
  stat(p.join(packageRoot, 'flutter_native_splash.yaml'));
  stat(p.join(packageRoot, 'pubspec.yaml'));
  // Flavor files, which are discovered rather than named, so the listing itself
  // is part of the answer.
  if (files.isDirectory(packageRoot)) {
    for (var entity in files.list(packageRoot)) {
      if (files.isDirectory(entity)) continue;
      if (splashFlavorFilePattern.hasMatch(p.basename(entity))) {
        stat(entity);
      }
    }
  }

  for (var config in scan?.configs ?? const <SplashConfigScan>[]) {
    for (var facts in config.images.values) {
      stat(facts.absolutePath ?? p.join(packageRoot, facts.path));
    }
    for (var artifact in config.artifacts) {
      stat(p.join(packageRoot, artifact.path));
    }

    // The artifact *directories*, because statting the files we already know
    // about cannot see a file that was added. A directory's own mtime moves when
    // an entry is created or removed inside it, which is exactly the event a
    // fresh `create` produces.
    for (var directory in [
      androidResFolder(config.config.flavor),
      p.join('ios', 'Runner', 'Assets.xcassets'),
      p.join('web', 'splash', 'img'),
    ]) {
      stat(p.join(packageRoot, directory));
    }
  }

  // Sorted so the digest depends on the *content* of the set rather than on the
  // order a directory listing happened to come back in.
  entries.sort();
  return '${sha1.convert(entries.join('\n').codeUnits)}';
}
