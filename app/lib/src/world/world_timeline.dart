import 'dart:math';

// ignore: implementation_imports
import 'package:flutterware/src/world/step_names.dart' show worldActionsOwner;

import 'world_trace.dart';

/// Which side of the timeline a column stands on: the people on the left,
/// what they reached through on the right.
enum TimelineSide { people, system }

/// A column of the timeline: someone in the world, or a part of the system
/// something passed through.
class TimelineColumn {
  const TimelineColumn(this.id, this.name, this.side);

  /// A person's name, [worldActionsOwner] for the world's own actions, or
  /// `system/…` for a part of the system: never the same across the sides.
  final String id;

  /// As its header says it: `Leo`, `World`, `lab`, `SMS`.
  final String name;
  final TimelineSide side;
}

/// One row of the timeline: something someone did, or one thing it caused.
class TimelineRow {
  const TimelineRow({
    required this.at,
    required this.step,
    required this.level,
    required this.label,
    required this.from,
    this.to = const [],
    this.beat,
    this.within,
  });

  final DateTime at;

  /// The step it is, or the one that caused it.
  final TraceStep step;
  final TraceLevel level;

  /// `taps "Order"`, `POST /orders  200 in 1.8 ms`, `SMS: Your code is 1234`.
  final String label;

  /// The column it starts in: whoever acted, or the part that sent it.
  final String from;

  /// The columns an arrow reaches; empty for a pill on [from] — something
  /// done there that reached nobody.
  final List<String> to;

  /// What of the trace it shows; null for the step itself.
  final TraceBeat? beat;

  /// The line [beat] happened within, when it is one — the request that
  /// wrote a row — even at a level that does not show that line.
  final TraceBeat? within;

  bool get isStep => beat == null;

  /// Whether it starts in or reaches [column].
  bool touches(String column) => from == column || to.contains(column);
}

/// One entry of the timeline as drawn: a row, a run of rows alike folded
/// into one, or a pause between two.
sealed class TimelineEntry {
  const TimelineEntry();
}

/// Nothing happened for [length]: drawn as *12.4 s later* rather than as
/// empty height.
class TimelineGap extends TimelineEntry {
  const TimelineGap(this.length);

  final Duration length;
}

/// A row, or [alike] — three or more rows of one step differing only in
/// their numbers — [folded] into the first of them.
class TimelineLine extends TimelineEntry {
  const TimelineLine(
    this.row, {
    this.alike = const [],
    this.fold,
    this.folded = false,
  });

  final TimelineRow row;

  /// Every row of its run, the first first, when it has one; empty for a
  /// row alone.
  final List<TimelineRow> alike;

  /// What unfolds its run, or folds it again; null for a row alone, and for
  /// every row of an unfolded run but its first.
  final String? fold;

  /// Whether it stands for the rest of its run.
  final bool folded;

  /// When the last row it stands for happened.
  DateTime get until => folded ? alike.last.at : row.at;
}

/// A world's steps and what they caused, as a sequence diagram: a column
/// for each person and each part of the system, time running down, and a
/// row for each thing that happened at one [TraceLevel].
class Timeline {
  Timeline._(this.columns, this.rows);

  /// [traced] at [level]. The columns are [people]'s — the world's own
  /// first when it has [actions] — and then each part of the system in the
  /// order it first did something, at any level: switching level changes
  /// the rows and never moves a column. [servers] are what the trace heard
  /// report, and tell a server that answers calls from a service that only
  /// sent a message.
  factory Timeline.of(
    List<TracedStep> traced, {
    required List<String> people,
    required Iterable<SystemServer> servers,
    TraceLevel level = TraceLevel.product,
    bool actions = false,
  }) {
    var serving = {
      for (var server in servers)
        if (server.parts.isNotEmpty || server.tables.isNotEmpty) server.name,
    };
    var reporting = {for (var server in servers) server.name};
    var system = <String, TimelineColumn>{};
    var world = actions;

    String column(String id, String name) {
      system.putIfAbsent(
        id,
        () => TimelineColumn(id, name, TimelineSide.system),
      );
      return id;
    }

    String serverColumn(String server) => reporting.contains(server)
        ? column('system/server/$server', server)
        : column('system/host/$server', server);

    String? personColumn(String? person) {
      if (person == worldActionsOwner) {
        world = true;
        return worldActionsOwner;
      }
      return people.contains(person) ? person : null;
    }

    TimelineRow? rowOf(TraceStep step, TraceBeat beat, TraceBeat? within) {
      var server = beat.server;
      var person = personColumn(beat.person);
      String? from;
      var to = <String>[];
      var label = beat.said;
      switch (beat.kind) {
        case BeatKind.call:
          var target = server == null ? null : serverColumn(server);
          // A request no app here recorded, on a step of the world's own:
          // the script sent it.
          var caller =
              person ??
              (step.person == worldActionsOwner ? worldActionsOwner : null);
          if (caller != null && target != null) {
            from = personColumn(caller);
            to = [target];
          } else {
            from = target ?? person;
          }
        case BeatKind.sms || BeatKind.mail || BeatKind.push:
          var channel = beat.kind.name;
          from = server != null && !serving.contains(server)
              ? serverColumn(server)
              : column('system/sent/$channel', _channelNames[channel]!);
          label = '${_channelNames[channel]}: ${beat.said}';
          if (person != null) to = [person];
        case BeatKind.reach:
          from = server == null ? null : serverColumn(server);
          if (person != null) to = [person];
        case BeatKind.record when beat.inbound:
          from = column('system/sync', 'Sync');
          if (person != null) to = [person];
        case BeatKind.record:
          from = person;
        case _:
          from = server == null ? person : serverColumn(server);
      }
      if (from == null) return null;
      return TimelineRow(
        at: beat.at,
        step: step,
        level: beat.level,
        label: label,
        from: from,
        to: to,
        beat: beat,
        within: within,
      );
    }

    // What each line is within, looked up by the line: [atLevel] copies
    // them, so the one it hid is found in what it was given.
    Map<(DateTime, String), TraceBeat> withinOf(List<TraceBeat> beats) {
      var within = <(DateTime, String), TraceBeat>{};
      void walk(List<TraceBeat> beats, TraceBeat? parent) {
        for (var beat in beats) {
          if (parent != null) within[(beat.at, beat.said)] = parent;
          walk(beat.children, beat);
        }
      }

      walk(beats, null);
      return within;
    }

    List<TimelineRow> rowsAt(TraceLevel shown) {
      var rows = <TimelineRow>[];
      for (var (:step, :beats) in traced) {
        if (personColumn(step.person) case var from?) {
          rows.add(
            TimelineRow(
              at: step.at!,
              step: step,
              level: TraceLevel.product,
              label: didOf(step),
              from: from,
            ),
          );
        }
        var within = withinOf(beats);
        for (var beat in everyBeat(atLevel(beats, shown))) {
          if (rowOf(step, beat, within[(beat.at, beat.said)]) case var row?) {
            rows.add(row);
          }
        }
      }
      return _together(rows);
    }

    // Every level's rows, so a column one level alone reaches is there at
    // all of them; the widest first, whose order the columns take.
    var all = {
      for (var shown in TraceLevel.values.reversed) shown: rowsAt(shown),
    };
    var timeline = Timeline._([
      if (world)
        const TimelineColumn(worldActionsOwner, 'World', TimelineSide.people),
      for (var person in people)
        TimelineColumn(person, person, TimelineSide.people),
      ...system.values,
    ], all[level]!);
    timeline.counts.addAll({
      for (var MapEntry(key: shown, value: rows) in all.entries)
        shown: rows.length,
    });
    return timeline;
  }

  final List<TimelineColumn> columns;

  /// Oldest first.
  final List<TimelineRow> rows;

  /// How many rows each level has: what the switch between them says.
  final counts = <TraceLevel, int>{};

  /// How long between two rows is drawn as a pause.
  static const pause = Duration(seconds: 2);

  /// How many rows alike fold into one.
  static const foldAt = 3;

  /// [rows] as drawn: only those touching [focus] when there is one, a run
  /// of rows alike folded unless its key is in [unfolded], and a
  /// [TimelineGap] wherever nothing happened for longer than [pause].
  List<TimelineEntry> entries({
    String? focus,
    Set<String> unfolded = const {},
  }) {
    var shown = [
      for (var row in rows)
        if (focus == null || row.touches(focus)) row,
    ];
    var runs = <String, List<TimelineRow>>{};
    for (var row in shown) {
      if (_foldKey(row) case var key?) runs.putIfAbsent(key, () => []).add(row);
    }
    var entries = <TimelineEntry>[];
    DateTime? last;
    for (var row in shown) {
      var key = _foldKey(row);
      var run = key == null ? null : runs[key]!;
      var line = switch (run) {
        var run? when run.length >= foldAt && !unfolded.contains(key) =>
          run.first == row
              ? TimelineLine(row, alike: run, fold: key, folded: true)
              : null,
        var run? when run.length >= foldAt => TimelineLine(
          row,
          alike: run,
          fold: run.first == row ? key : null,
        ),
        _ => TimelineLine(row),
      };
      if (line == null) continue;
      if (last != null && row.at.difference(last) > pause) {
        entries.add(TimelineGap(row.at.difference(last)));
      }
      entries.add(line);
      if (last == null || line.until.isAfter(last)) last = line.until;
    }
    return entries;
  }

  /// What makes two rows alike: one step, one level, one kind, the same
  /// columns and the same words but for their numbers — `GET /orders/o7`
  /// and `GET /orders/o8`. Null for a step's own row, which is never alike.
  static String? _foldKey(TimelineRow row) {
    var beat = row.beat;
    if (beat == null) return null;
    return [
      row.step.id,
      row.level.name,
      beat.kind.name,
      row.from,
      row.to.join(','),
      row.label.replaceAll(_digits, '#'),
    ].join('|');
  }

  static final _digits = RegExp(r'\d+');

  /// [rows] with one broadcast a row: the same words from the same column
  /// on one step, within [_together] of each other, reach everyone they
  /// reached on one arrow.
  static List<TimelineRow> _together(List<TimelineRow> rows) {
    var together = <TimelineRow>[];
    for (var row in rows) {
      var previous = together.lastOrNull;
      if (previous != null &&
          !row.isStep &&
          !previous.isStep &&
          row.to.isNotEmpty &&
          previous.to.isNotEmpty &&
          previous.step == row.step &&
          previous.beat!.kind == row.beat!.kind &&
          previous.from == row.from &&
          previous.label == row.label &&
          row.at.difference(previous.at) <= _broadcast) {
        together.last = TimelineRow(
          at: previous.at,
          step: previous.step,
          // Seen wherever any of it is.
          level: previous.level.index <= row.level.index
              ? previous.level
              : row.level,
          label: previous.label,
          from: previous.from,
          to: [
            ...previous.to,
            for (var column in row.to)
              if (!previous.to.contains(column)) column,
          ],
          beat: previous.beat,
          within: previous.within,
        );
        continue;
      }
      together.add(row);
    }
    return together;
  }

  static const _broadcast = Duration(milliseconds: 100);

  static const _channelNames = {'sms': 'SMS', 'mail': 'Mail', 'push': 'Push'};

  /// What [step] did, as a row says it after its column's name: `taps
  /// "Order"`, `runs "Mia orders a flat white"`.
  static String didOf(TraceStep step) {
    var target = step.target ?? '';
    return switch (step.verb) {
      'tap' => 'taps $target',
      'longPress' => 'long-presses $target',
      'drag' => 'drags $target',
      'type' => 'types $target',
      'open' => 'opens $target',
      'start' => 'starts $target',
      'action' => 'runs $target',
      _ => step.did,
    }.trim();
  }
}

/// `21.4 s`, `1:02.3`: when, since the world opened.
String clockOf(DateTime at, DateTime since) {
  var seconds = max(0, at.difference(since).inMilliseconds) / 1000;
  if (seconds < 60) return '${seconds.toStringAsFixed(1)} s';
  var minutes = seconds ~/ 60;
  var rest = (seconds - minutes * 60).toStringAsFixed(1).padLeft(4, '0');
  return '$minutes:$rest';
}

/// `12.4 s`, `3 min 5 s`: how long a pause was.
String lengthOf(Duration length) {
  var seconds = length.inMilliseconds / 1000;
  if (seconds < 60) return '${seconds.toStringAsFixed(1)} s';
  var minutes = length.inMinutes;
  var rest = length.inSeconds - minutes * 60;
  return rest == 0 ? '$minutes min' : '$minutes min $rest s';
}
