/// Loads a [ChangeSet] for the screen, **off the UI isolate**.
///
/// Even the good case is ~70 ms of git plus a scan over half a megabyte, and
/// the screen re-runs it whenever the worktree moves. On the UI isolate that is
/// several dropped frames every time an agent saves a file, which is exactly
/// when a window must not stutter.
///
/// `Isolate.run` builds the probe *inside* the isolate, so the only thing
/// captured is the path — a closure holding an injected process runner could
/// not cross, and would not want to.
library;

import 'dart:async';
import 'dart:isolate';

import 'package:clock/clock.dart';
import 'package:flutter/foundation.dart';

import '../worktrees/facts_store.dart';
import '../worktrees/watchers.dart';
import 'change_set.dart';
import 'changes_config_cache.dart';
import 'changes_probe.dart';

/// One worktree's delta, loaded and reloadable.
///
/// Stale-then-fresh, never empty-then-full: [value] keeps the last answer
/// while the next one is computed, so a reload never blanks the screen. The
/// first load is the only one with nothing to show, and it shows the worktree's
/// identity rather than a spinner over an empty page.
class ChangesController extends ChangeNotifier {
  ChangesController({
    required this.worktreePath,
    this.repoRoot,
    Future<ChangeSet> Function(String path)? load,
    // ignore: prefer_initializing_formals
  }) : _load = load;

  final String worktreePath;

  /// The main checkout, which is what the facts cache — and so the remembered
  /// `ChangesConfig` — is keyed by.
  ///
  /// Null when the shell has not worked one out, in which case **nothing is
  /// ranked at all** — not "ranked by defaults". There are no built-in rules
  /// in either direction any more, so a missing key means an empty *Important*
  /// tab, the same as an unopened worktree shows.
  final String? repoRoot;

  final Future<ChangeSet> Function(String path)? _load;

  /// Resolved per call rather than at construction, so [debugChangesLoader] set
  /// after a widget is built still takes effect.
  Future<ChangeSet> Function(String path) get _loader =>
      _load ?? debugChangesLoader ?? _withConfig;

  Future<ChangeSet> _withConfig(String path) {
    var root = repoRoot;
    return Isolate.run(() {
      var resolved = root == null
          ? ResolvedChangesConfig.defaults
          : resolveChangesConfig(path, WorktreeFactsStore.open(root));
      return ChangesProbe().probe(
        path,
        config: resolved.config,
        configState: resolved.state,
      );
    });
  }

  ChangeSet? get value => _value;
  ChangeSet? _value;

  /// True while a load is in flight. The screen shows this beside the last
  /// answer, never instead of it.
  bool get isLoading => _inFlight != null;
  Future<void>? _inFlight;

  Object? get failure => _failure;
  Object? _failure;

  /// When the last load finished, whatever it found. The header shows this, so
  /// a screen that has been sitting open says how old what it is showing is.
  DateTime? get readAt => _readAt;
  DateTime? _readAt;

  /// Live, and not by polling. One recursive watch on this checkout's
  /// working tree — the [WorkingTreeWatcher] exception to the explorer's rule —
  /// plus [gitMoved] for the half a working tree cannot see: staging and
  /// committing write a linked worktree's index somewhere else entirely.
  ///
  /// Started by the screen and stopped with it, because *visible* is the gate:
  /// the popover card holds one of these too and deliberately never calls this.
  void watch({Stream<void>? gitMoved, WorkingTreeWatcher? watcher}) {
    if (_watcher != null || _disposed) return;
    _watcher =
        watcher ??
        WorkingTreeWatcher(
          worktreePath: worktreePath,
          onFailure: (error) =>
              // Costs liveness, never correctness — the button still works.
              debugPrint('not watching $worktreePath: $error'),
        );
    _events = _watcher!.changes.listen((_) => unawaited(refresh()));
    _gitEvents = gitMoved?.listen((_) => unawaited(refresh()));
    _watcher!.start();
  }

  /// Whether [watch] was called and the watch took. See
  /// [WorkingTreeWatcher.isWatching].
  bool get isWatching => _watcher?.isWatching ?? false;

  WorkingTreeWatcher? _watcher;
  StreamSubscription<void>? _events;
  StreamSubscription<void>? _gitEvents;

  /// Idempotent: callers refresh without knowing what is already running.
  ///
  /// A call that arrives mid-probe is remembered rather than dropped. It used to
  /// join the running one and return its answer, which is fine for a button
  /// pressed twice and wrong for a watcher: the save that fired it landed
  /// *after* that probe read the disk, so joining reports the state before the
  /// edit and nothing fires again until the next one. On a checkout an agent
  /// has just gone quiet in, that is the last edit — the one you were waiting
  /// to see — going missing until you press refresh.
  Future<void> refresh() {
    if (_inFlight case var running?) {
      _again = true;
      return running;
    }
    var running = _run();
    _inFlight = running;
    notifyListeners();
    return running;
  }

  var _again = false;

  Future<void> _run() async {
    try {
      var set = await _loader(worktreePath);
      if (_disposed) return;
      // **The previous object survives an unchanged answer**, which is the
      // common case rather than the rare one: most of what a watch fires on is
      // build output git ignores, and re-probing it produces this set again.
      // Keeping the old one keeps every expanded hunk's decoded text, and the
      // screen does not rebuild. See [ChangeSet.sameAnswerAs].
      _value = _value?.sameAnswerAs(set) ?? false ? _value : set;
      _failure = null;
      _readAt = clock.now();
    } on Object catch (error) {
      if (_disposed) return;
      // The last good answer survives a failed reload. A worktree that just
      // vanished should say so beside what it last said, not instead of it.
      _failure = error;
    } finally {
      _inFlight = null;
      if (!_disposed) {
        notifyListeners();
        if (_again) {
          _again = false;
          unawaited(refresh());
        }
      }
    }
  }

  var _disposed = false;

  @override
  void dispose() {
    _disposed = true;
    unawaited(_events?.cancel());
    unawaited(_gitEvents?.cancel());
    unawaited(_watcher?.dispose());
    super.dispose();
  }
}

/// Replaces the loader everywhere, for tests that build the shell rather than
/// the screen and so cannot pass one in.
///
/// Without it a widget test spawns an isolate and shells out to `git` against a
/// path that does not exist — slow, and answering a question nobody asked. Set
/// it in `setUp`; clear it in `addTearDown`.
@visibleForTesting
Future<ChangeSet> Function(String path)? debugChangesLoader;
