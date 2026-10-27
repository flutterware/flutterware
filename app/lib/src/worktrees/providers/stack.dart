/// What each checkout's dev stack was last seen doing, read from the run dir.
///
/// A file read, and only ever a file read. Every other answer in this
/// screen is available for an unopened checkout, because the shell
/// computes it — but a stack's state belongs to the *project*, and finding it
/// out means running the project's own probe. Doing that per row would spawn
/// one subprocess per worktree per refresh, which is exactly the cost the
/// explorer is designed never to pay.
///
/// So this reads the cache the panel writes: `stack-<hash>.json`, one per
/// worktree, updated whenever a session actually probes. That makes the column
/// a **ledger**, in the same sense as `devices.json` — a fact that happened,
/// which gets old rather than becoming wrong, and which is drawn with its age.
///
/// Two consequences worth stating plainly, because they look like bugs
/// otherwise:
///
/// - **A worktree that has never been opened shows nothing**, even if it declares a
///   stack. Nothing has ever looked, and finding out would mean running its
///   config and its probe.
/// - **A reading can be out of date.** Someone tearing a stack down from a
///   terminal does not update a file flutterware writes. This is why the cell
///   dims past [freshFor] instead of asserting.
library;

import 'dart:convert';
import 'dart:io';

import '../../plugins/native/dev_stack_results.dart';
import '../../utils/run_dir.dart';

/// One way of finding out what a checkout's stack was doing.
abstract class StackProbe {
  /// The last reading for the checkout at [worktreePath], or null when there
  /// has never been one.
  Future<StackReading?> probe(String worktreePath);
}

/// How recently a reading has to have been taken to be drawn as current.
///
/// Comfortably longer than any sane poll interval — a worktree open in a tab
/// re-reads every ten or fifteen seconds — so in practice this separates *a
/// session is watching this stack right now* from *this is the last reading
/// taken*.
const stackFreshFor = Duration(minutes: 1);

class RunDirStackProbe implements StackProbe {
  RunDirStackProbe({String Function()? runDir})
    : _runDir = runDir ?? flutterwareRunDir;

  final String Function() _runDir;

  @override
  Future<StackReading?> probe(String worktreePath) async {
    try {
      var file = File(stackCachePath(_runDir(), worktreePath));
      if (!file.existsSync()) return null;
      var json = jsonDecode(await file.readAsString());
      if (json is! Map) return null;
      // The whole worktree as one reading, because the column has one line.
      // A checkout declaring four services reads as `up 3/4` here, which is
      // the same sentence a single delegated service's containers already
      // produce — see [StackCache.aggregate].
      var reading = StackCache.fromJson(json.cast<String, Object?>()).aggregate;
      // A reading with no clock cannot be aged, and an un-ageable reading is
      // worse than none: it would sit in the column looking current forever.
      return reading.isKnown && reading.at != null ? reading : null;
    } on Object {
      // A half-written or hand-edited cache is no cache. Every failure here is
      // "no stack", which the column already draws as a quiet nothing — the
      // same contract the agent probe holds itself to, and for the same
      // reason: nothing on this screen may hinge on an optional fact.
      return null;
    }
  }
}
