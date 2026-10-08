/// Where a worktree's `ChangesConfig` comes from when nothing is running it.
///
/// The config is *executed*, like every other config in flutterware. The
/// difficulty is that this screen has to rank a worktree that is **not open**,
/// and not opening it is exactly what "closed" means. So:
///
/// > **One writer, one reader.** Whatever executes `tool/flutterware.dart`
/// > writes the value it got, stamped with what it read it from. Everything
/// > that ranks — the screen, `fw changes`, an open worktree, a closed one —
/// > reads that one cache.
///
/// Which collapses the four situations below into one code path, and makes the
/// first row of the table true by construction rather than by a second
/// mechanism: an open worktree is fresh because opening it is what wrote the
/// entry.
///
/// | situation | state | ranks by |
/// |---|---|---|
/// | open, or `fw` ran here | [ChangesConfigState.fresh] | the executed config |
/// | closed, config file unchanged | [ChangesConfigState.fresh] | the same value |
/// | closed, config file has moved | [ChangesConfigState.stale] | it, and says so |
/// | never opened, or no config file | [ChangesConfigState.none] | nothing — no rules exist |
///
/// Not written into the checkout, tempting as `.dart_tool/flutterware/` is
/// — the kernel cache is already there. A worktree's `.gitignore` is
/// *versioned*: switch to a branch that does not have the entry and a cache
/// written inside the checkout becomes an untracked row on the very screen it
/// feeds. That is the same trap `--untracked-files=normal` exists for.
///
/// Pure Dart — `fw changes` resolves the same way the GUI does.
library;

import 'dart:io';

import 'package:flutterware/plugins.dart';
import 'package:path/path.dart' as p;

import '../plugins/manifest_loader.dart';
import '../worktrees/facts_store.dart';

/// How much the config being ranked by is worth believing.
enum ChangesConfigState {
  /// The cached value, and the config file has not moved since. This is the
  /// executed value.
  fresh,

  /// The config file was edited after this value was computed. Still used —
  /// yesterday's rules beat no rules — but the screen flags it.
  stale,

  /// Nothing cached, or the project has no config file. Built-in defaults.
  none,
}

/// A config and how much to believe it.
class ResolvedChangesConfig {
  const ResolvedChangesConfig(this.config, this.state);

  static const defaults = ResolvedChangesConfig(null, ChangesConfigState.none);

  /// Null when there is nothing to rank by — and there are no built-in rules
  /// to fall back on, so null means every file comes out ordinary.
  final ChangesConfig? config;
  final ChangesConfigState state;

  /// What the header says, or null when there is nothing worth saying.
  ///
  /// Only the stale case gets a sentence: a screen that narrates its cache on
  /// every load is a screen whose one important message goes unread.
  String? get notice => state == ChangesConfigState.stale
      ? 'Ranking by the last $configFilePath that ran here. The file has '
            'changed since; open this worktree to run it again.'
      : null;
}

/// What the cached config was computed from: the config file's mtime and size.
///
/// Null when the worktree has no config file at all, which is a worktree with
/// nothing to cache rather than one whose cache is empty.
///
/// mtime and size rather than content, unlike the kernel cache next door.
/// That one is keyed on content because `pub get` rewrites files without
/// changing them and re-compiling costs half a second; this one costs a
/// subprocess we are not going to run either way, so the cheap key is the right
/// one and being wrong means showing a *stale* banner rather than a wrong
/// ranking.
String? changesConfigKey(String worktreePath) {
  var file = File(p.join(worktreePath, configFilePath));
  try {
    var stat = file.statSync();
    if (stat.type == FileSystemEntityType.notFound) return null;
    return '${stat.modified.microsecondsSinceEpoch}:${stat.size}';
  } on FileSystemException {
    return null;
  } on UnsupportedError {
    // A browser: no file to key on, so no entry is remembered.
    return null;
  }
}

/// Reads the ranking rules for [worktreePath] out of [store].
ResolvedChangesConfig resolveChangesConfig(
  String worktreePath,
  WorktreeFactsStore store,
) {
  var cached = store.changesConfig(worktreePath);
  if (cached == null) return ResolvedChangesConfig.defaults;
  var key = changesConfigKey(worktreePath);
  // A config file that has since been *deleted* is not a stale cache, it is a
  // project that no longer says anything. Ranking by a file the user removed
  // would be the one case where the cache is not merely old but wrong.
  if (key == null) return ResolvedChangesConfig.defaults;
  return ResolvedChangesConfig(
    cached.config,
    key == cached.validityKey
        ? ChangesConfigState.fresh
        : ChangesConfigState.stale,
  );
}

/// Remembers what running [worktreePath]'s config produced.
///
/// Called from the one place that runs it. A manifest with no `ChangesConfig`
/// is still worth remembering: "this project says nothing" is an answer, and
/// caching it is what stops a closed worktree looking permanently unknown.
///
/// Saves immediately. The entry is only useful on a *later* launch, so
/// holding it in memory until something else happens to save the store is the
/// one timing where it would reliably be lost.
void rememberChangesConfig(
  String worktreePath,
  ChangesConfig? config,
  WorktreeFactsStore store,
) {
  var key = changesConfigKey(worktreePath);
  if (key == null) return;
  var entry = CachedChangesConfig(
    config: config ?? const ChangesConfig(),
    validityKey: key,
  );
  var existing = store.changesConfig(worktreePath);
  if (existing != null &&
      existing.validityKey == key &&
      existing.config == entry.config) {
    return;
  }
  store
    ..putChangesConfig(worktreePath, entry)
    ..save();
}
