import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutterware/plugins.dart';
import 'package:path/path.dart' as p;

/// Where a worktree's last stack reading is cached, under the run dir.
///
/// One formula, two readers. The core writes this file after every probe;
/// the worktree explorer reads it for every checkout in the repository, and
/// reads *only* this — a list of eight worktrees must not spawn eight
/// subprocesses to fill a column. The two halves cannot be allowed to disagree
/// about where the file is, so neither of them spells the name.
String stackCachePath(String runDir, String worktreePath) => p.join(
  runDir,
  'stack-${sha1.convert(utf8.encode(worktreePath)).toString().substring(0, 16)}.json',
);

/// What a worktree's cache file holds: the last reading of each declared
/// service, keyed by [StackService.id].
///
/// **One file, not one per service**, which is the constraint the explorer
/// imposes: a list of eight worktrees reads eight files, and it must not
/// become eight times however many services each declares. The map is what
/// lets the panel restore every row from that single read.
class StackCache {
  const StackCache(this.readings);

  const StackCache.empty() : readings = const {};

  final Map<String, StackReading> readings;

  /// The whole worktree as one reading, for a surface with room for one line.
  ///
  /// Every declared service becomes a [ProbedService] row, so the fraction the
  /// column already knows how to draw — `up 2/3` — counts *services* here
  /// where it counts containers inside a single delegated one. Same shape,
  /// one level up.
  ///
  /// The headline is the most urgent thing true of any of them, in the order
  /// a reader cares: something is up (with the fraction saying how much),
  /// something is moving, something cannot be read, otherwise down. A broken
  /// probe outranks `down` because "can't tell" is the one state you cannot
  /// infer and should not have to open a tab to discover.
  StackReading get aggregate {
    var known = {
      for (var entry in readings.entries)
        if (entry.value.isKnown) entry.key: entry.value,
    };
    if (known.isEmpty) return const StackReading.unknown();
    // **One service answers for itself, whole.** Summarising it would replace
    // its own detail and its own probe-reported parts — `localhost:8080`, four
    // named containers — with a single row saying its id back, which is less
    // than the file already holds. Every project that has ever used this
    // plugin is this case.
    if (known.length == 1) return known.values.single;
    var states = known.values.map((r) => r.state).toList();
    var state = switch (states) {
      _ when states.any((s) => s == StackState.up) => StackState.up,
      _ when states.any((s) => s.isMoving) => StackState.starting,
      _ when states.any((s) => s == StackState.unavailable) =>
        StackState.unavailable,
      _ => StackState.down,
    };
    // The newest, because this answers "when did a session last look here",
    // which is what the column dims on.
    DateTime? at;
    for (var reading in known.values) {
      var seen = reading.at;
      if (seen != null && (at == null || seen.isAfter(at))) at = seen;
    }
    return StackReading(
      state: state,
      at: at,
      services: [
        for (var entry in known.entries)
          ProbedService(name: entry.key, state: entry.value.state),
      ],
      failure: known.values
          .map((r) => r.failure)
          .whereType<String>()
          .firstOrNull,
    );
  }

  Map<String, Object?> toJson() => {
    'services': {
      for (var entry in readings.entries) entry.key: entry.value.toJson(),
    },
  };

  /// Reads the keyed shape, and the single-reading shape that preceded it.
  ///
  /// A cache written by an older flutterware is one stack's reading at the top
  /// level, which is exactly what the `stack` id means today — so it is
  /// adopted under that key rather than discarded. Getting this wrong costs a
  /// cold sidebar its only fact.
  static StackCache fromJson(Map<String, Object?> json) {
    if (json['services'] case Map raw) {
      return StackCache({
        for (var entry in raw.entries)
          if (entry.value is Map)
            '${entry.key}': StackReading.fromJson(
              (entry.value as Map).cast<String, Object?>(),
            ),
      });
    }
    var reading = StackReading.fromJson(json);
    return reading.isKnown
        ? StackCache({'stack': reading})
        : StackCache.empty();
  }
}

/// What state a [DevStack] is in.
///
/// Five, not four, and the fifth is the one a first draft leaves out.
/// [unavailable] is *the probe failed*, which is not the same fact as [down]:
/// a health check that cannot reach the docker daemon fails exactly like one
/// that finds nothing running, and reporting "down" there offers a Bring-up
/// button that cannot work. The worktree explorer draws the same distinction
/// with `FactState.unavailable`, for the same reason.
enum StackState {
  /// Nothing has looked yet. Distinct from [down] — an empty sidebar should not
  /// claim the stack is not running.
  unknown,

  down,

  /// A `start` is in flight. `docker compose up --wait` takes tens of seconds,
  /// which is why this is a state and not a spinner on a button.
  starting,

  up,

  stopping,

  /// The probe itself failed or could not be read.
  unavailable;

  static StackState byName(String? name) =>
      values.firstWhere((v) => v.name == name, orElse: () => unknown);

  bool get isMoving => this == starting || this == stopping;
}

/// One part a probe reported, when it said that much.
///
/// Not to be confused with [StackService], which is what a project *declares*
/// — the two are a level apart. A declared service has a lifecycle, an id and
/// actions; this is a row a delegated service's probe listed underneath
/// itself, which is where `up 3/4` comes from.
///
/// Only [Probe.json] produces these; an exit-code probe has nothing to build
/// them from and reports the service as a whole.
class ProbedService {
  const ProbedService({required this.name, this.port, this.state});

  final String name;
  final int? port;

  /// The service's own state where the probe reports one — a compose project
  /// can be half up, and "3 of 4" is the fact that explains a slow start.
  final StackState? state;

  Map<String, Object?> toJson() => {
    'name': name,
    if (port != null) 'port': port,
    if (state != null) 'state': state!.name,
  };

  static ProbedService? fromJson(Map<String, Object?> json) {
    var name = json['name'];
    if (name is! String || name.isEmpty) return null;
    return ProbedService(
      name: name,
      port: json['port'] is int ? json['port']! as int : null,
      state: json['state'] == null
          ? null
          : StackState.byName(json['state'] as String?),
    );
  }
}

/// One run of the probe — everything this plugin knows.
///
/// Carries [at] because a reading is a fact that happened: it gets old rather
/// than becoming wrong. That is the same rule `RunCore`'s device cache follows,
/// and it is what lets a cold `fw status` and a freshly opened sidebar say
/// something true without spawning anything.
class StackReading implements PluginResult {
  const StackReading({
    required this.state,
    required this.at,
    this.detail,
    this.services = const [],
    this.failure,
  });

  const StackReading.unknown() : this(state: StackState.unknown, at: null);

  final StackState state;

  /// One line beside the status — `slot 8200-8208 · 4 containers`. For an
  /// exit-code probe this is the command's last non-empty output line, which
  /// is where a health check usually puts its summary.
  final String? detail;

  final List<ProbedService> services;

  /// Why the probe could not be believed. Only set with
  /// [StackState.unavailable].
  final String? failure;

  /// When this was read. Null only for [StackState.unknown].
  final DateTime? at;

  bool get isKnown => state != StackState.unknown;

  /// How many services the probe reported as up, out of how many it named.
  ///
  /// Null when the probe named none — an exit-code probe, or a JSON one that
  /// only reports the whole. `(3, 4)` is what turns `up` into `up 3/4`, and it
  /// is the one number the block used to parse and then throw away.
  (int up, int total)? get serviceCount {
    if (services.isEmpty) return null;
    // A service with no state of its own cannot be counted against the ones
    // that have one, so a partial declaration reports nothing rather than
    // reporting everything as down.
    if (services.any((s) => s.state == null)) return null;
    return (
      services.where((s) => s.state == StackState.up).length,
      services.length,
    );
  }

  /// True when the probe called the stack up but not everything under it is.
  ///
  /// The summary is *derived* from the rows rather than written beside them,
  /// which is the only way a green headline cannot end up sitting above an
  /// amber service.
  bool get isPartial {
    if (state != StackState.up) return false;
    var count = serviceCount;
    return count != null && count.$1 < count.$2;
  }

  @override
  Map<String, Object?> toJson() => {
    'state': state.name,
    if (detail != null) 'detail': detail,
    if (services.isNotEmpty) 'services': [for (var s in services) s.toJson()],
    if (failure != null) 'failure': failure,
    if (at != null) 'checkedAt': at!.toIso8601String(),
  };

  static StackReading fromJson(Map<String, Object?> json) => StackReading(
    state: StackState.byName(json['state'] as String?),
    detail: json['detail'] as String?,
    services: [
      for (var entry in (json['services'] as List? ?? const []))
        if (entry is Map)
          ?ProbedService.fromJson(entry.cast<String, Object?>()),
    ],
    failure: json['failure'] as String?,
    at: DateTime.tryParse('${json['checkedAt']}'),
  );
}

/// `start`, `stop` and every declared command hand this back.
class DevStackRunResult implements PluginResult {
  const DevStackRunResult({
    required this.command,
    required this.exitCode,
    bool? ok,
    this.stdout = '',
    this.stderr = '',
    this.output = '',
    this.timedOut = false,
    this.reading,
  }) : ok = ok ?? exitCode == 0;

  /// What was actually run, joined — so a caller that wants to run it directly
  /// next time can.
  final String command;

  /// Null when the command has not exited — see [timedOut]. Zero would be a
  /// claim that it worked, and any other number a claim that it failed.
  final int? exitCode;

  /// Whether the action did what was asked.
  ///
  /// Normally that is the exit code, because normally the action *is* a
  /// command that ran and finished. An owned service's `start` has no exit
  /// code to read — the process has deliberately not exited, which is the
  /// whole point of it — so that one passes `ok:` outright, meaning whether
  /// the service came up, which is the only question the caller asked.
  final bool ok;

  /// The wait ended before the command did, and the process was left running.
  /// [exitCode] is null and [stderr] says so.
  final bool timedOut;

  /// Combined stdout and stderr, trimmed to the tail. The full text is on
  /// screen and in the process' own log; this is what fits in a result.
  ///
  /// Kept beside [stdout] and [stderr] because it is what the panel draws and
  /// what a terminal wants: one stream in the order things were said.
  final String output;

  /// The two streams apart, each trimmed to its own tail.
  ///
  /// Because almost nothing writing structured output has stderr to itself.
  /// `dart` announces `Running build hooks...` there, docker writes deprecation
  /// warnings, a wrapper's `set -x` writes every line it runs — so a renderer
  /// that wants to put that somewhere other than under the reader's eye needs
  /// to know which half it is, and [output] has already merged them.
  final String stdout;
  final String stderr;

  /// The probe run immediately afterwards, when the command was one that
  /// changes the state. A caller asking to bring the stack up wants to be told
  /// whether it came up, not merely that the command exited.
  final StackReading? reading;

  @override
  Map<String, Object?> toJson() => {
    'command': command,
    if (exitCode != null) 'exitCode': exitCode,
    'ok': ok,
    if (timedOut) 'timedOut': true,
    if (output.isNotEmpty) 'output': output,
    // Only when they add something. A command that said everything on one
    // stream would otherwise carry its whole output twice.
    if (stdout.isNotEmpty && stderr.isNotEmpty) ...{
      'stdout': stdout,
      'stderr': stderr,
    },
    if (reading != null) 'reading': reading!.toJson(),
  };
}
