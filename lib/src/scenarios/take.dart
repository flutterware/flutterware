import 'dart:convert';
import 'dart:io';
import 'dart:ui';

import 'package:path/path.dart' as p;

import 'cues.dart';

/// What a scenario did, where, and when — the reading an **edit** plans
/// against.
///
/// A take is the timeline a film writes, read back as types. It is produced by
/// a *dry* pass ([FilmSettings.pixels] off), which pumps every beat and
/// rasterises none of them — ~300ms against ~1.3s for the same pass at scale 2
/// — so an edit can be written, run and rewritten without paying for pixels
/// until it is worth looking at.
///
/// It is a **map, not a recording**. It says what beats exist and where things
/// were; the truth of a reel is whatever the live instances do when driven.
/// An edit that inserts time changes when later beats happen and not which
/// ones — so anything comparing two passes compares the *sequence*.
class Take {
  Take({
    required this.scenario,
    required this.branches,
    required this.fps,
    required this.scale,
    required this.size,
    required this.screen,
    required this.duration,
    required this.beats,
    required this.dry,
  });

  /// The scenario this is a take of. One take is one scenario and one path
  /// through it.
  final String scenario;

  /// The branch chosen at each `split`, outermost first.
  final List<String> branches;

  /// Frames a second — of the film, and of the fake clock, which are the same
  /// number.
  final int fps;

  /// Film pixels per logical pixel of the app.
  final double scale;

  /// The output's size in film pixels — the stage's answer, times [scale].
  final Size size;

  /// The app's own frame in logical pixels: what a stage places, and what
  /// every rect in a beat is measured in.
  final Size screen;

  /// How long the whole take ran.
  final Duration duration;

  /// Everything that happened, in order: the verbs, the pauses, and what the
  /// scenario itself said. A cue is a beat of zero length rather than a list
  /// beside this one, because an edit walks time once.
  final List<Beat> beats;

  /// Whether the pass that produced this drew any pixels.
  final bool dry;

  /// Reads `film.json` from [directory].
  static Take read(String directory) => decode(
    jsonDecode(File(p.join(directory, 'film.json')).readAsStringSync())
        as Map<String, Object?>,
  );

  /// Reads a timeline.
  ///
  /// [cues] replaces the cues the file carries with the objects that were
  /// actually said — which is what an edit running in the same process as the
  /// scenario has and a file can never have. Without it, a cue the decoder
  /// does not recognise arrives as a [ScenarioCueRecord].
  static Take decode(
    Map<String, Object?> json, {
    List<(Duration, Object)>? cues,
  }) {
    var fps = (json['fps'] as num?)?.toInt() ?? 30;
    var rawPhases = json['beats'] as List? ?? const [];
    var phases = [
      for (var (i, raw) in rawPhases.indexed)
        Phase._decode(raw as Map<String, Object?>, i),
    ];
    var said = cues != null
        ? [for (var (at, cue) in cues) Said._(at, cue)]
        : [
            for (var raw in (json['cues'] as List? ?? const []))
              Said._decode(raw as Map<String, Object?>),
          ];
    var beats = _merge(_group(phases), said);
    return Take(
      scenario: json['scenario'] as String? ?? '',
      branches: [for (var b in (json['branches'] as List? ?? const [])) '$b'],
      fps: fps,
      scale: (json['scale'] as num?)?.toDouble() ?? 1,
      size: Size(
        (json['width'] as num?)?.toDouble() ?? 0,
        (json['height'] as num?)?.toDouble() ?? 0,
      ),
      screen: switch (json['screen']) {
        Map screen => Size(
          (screen['width'] as num?)?.toDouble() ?? 0,
          (screen['height'] as num?)?.toDouble() ?? 0,
        ),
        // An older timeline, or a film whose stage was the app itself: the
        // output is the screen.
        _ => Size(
          ((json['width'] as num?)?.toDouble() ?? 0) /
              ((json['scale'] as num?)?.toDouble() ?? 1),
          ((json['height'] as num?)?.toDouble() ?? 0) /
              ((json['scale'] as num?)?.toDouble() ?? 1),
        ),
      },
      duration: Duration(
        milliseconds: (json['durationMs'] as num?)?.toInt() ?? 0,
      ),
      beats: beats,
      dry: json['dry'] == true,
    );
  }

  /// Weaves what was said into what was done.
  ///
  /// A merge rather than a sort, because `List.sort` is not stable and the tie
  /// is the case that matters: a cue said in the breath before a verb is said
  /// *at* the frame the verb starts on, and it belongs before it — a title
  /// that lands after the tap it introduces is the caption arriving late.
  static List<Beat> _merge(List<Beat> beats, List<Said> said) {
    var out = <Beat>[];
    var i = 0;
    var j = 0;
    while (i < beats.length || j < said.length) {
      if (i == beats.length) {
        out.add(said[j++]);
      } else if (j == said.length) {
        out.add(beats[i++]);
      } else if (said[j].at <= beats[i].at) {
        out.add(said[j++]);
      } else {
        out.add(beats[i++]);
      }
    }
    return out;
  }

  /// Groups the film's phases into beats.
  ///
  /// The film marks what a stretch of frames *is* — a travel, an aim, a press,
  /// the verb's own frames, the pause after it — which is the right grain for
  /// a camera and the wrong one for an edit: `for (var beat in take.beats)`
  /// should hand over a tap, not five fifths of one. So a phase that opens a
  /// verb starts a beat and the rest of that verb's phases join it, and the
  /// beat's type is chosen from the verb rather than read from a string at the
  /// call site.
  static List<Beat> _group(List<Phase> phases) {
    var beats = <Beat>[];
    var current = <Phase>[];

    void close() {
      if (current.isEmpty) return;
      beats.add(_beatOf(List.of(current)));
      current.clear();
    }

    for (var phase in phases) {
      var opens = switch (phase.kind) {
        PhaseKind.open || PhaseKind.close || PhaseKind.travel => true,
        PhaseKind.focus => true,
        // A pause belongs to the verb it follows, and stands alone only when
        // nothing precedes it.
        PhaseKind.dwell => current.isEmpty,
        // A verb with no finger — `screen`, `settle`, a `pumpWidget` — marks
        // only its own frames, so its `act` is where its beat begins.
        _ => current.isEmpty || current.last.verb != phase.verb,
      };
      if (opens) close();
      current.add(phase);
    }
    close();
    return beats;
  }

  static Beat _beatOf(List<Phase> phases) {
    var verb = phases.map((p) => p.verb).nonNulls.firstOrNull;
    var target = phases.map((p) => p.target).nonNulls.firstOrNull;
    var rect = phases.map((p) => p.rect).nonNulls.firstOrNull;
    return switch (verb) {
      'tap' ||
      'tapAt' => Tapped._(phases, label: target, target: rect, held: false),
      'longPress' => Tapped._(phases, label: target, target: rect, held: true),
      'enterText' => Typed._(
        phases,
        text:
            phases
                .where((p) => p.kind == PhaseKind.type)
                .map((p) => p.target)
                .nonNulls
                .firstOrNull ??
            '',
        field: rect,
      ),
      'drag' || 'dragFrom' => Dragged._(phases, from: rect),
      'scrollTo' => Scrolled._(phases, label: target, pane: rect),
      null => switch (phases.first.kind) {
        PhaseKind.open => Opened._(phases),
        PhaseKind.close => Closed._(phases),
        _ => Idled._(phases),
      },
      _ => Acted._(phases, verb: verb, label: target, target: rect),
    };
  }
}

/// One stretch of a take: a verb, a pause, or something the scenario said.
sealed class Beat {
  Beat._(this.at, this.duration, this.phases);

  /// Where this begins, in take time.
  final Duration at;

  /// How long it lasted. Zero for a cue, which marks a moment.
  final Duration duration;

  /// What the film called the frames underneath — a travel, an aim, a press.
  /// An edit that wants the camera moving before the finger presses anchors
  /// on one of these.
  final List<Phase> phases;

  Duration get end => at + duration;

  /// The phase of [kind], when this beat has one.
  Phase? phase(PhaseKind kind) =>
      phases.where((p) => p.kind == kind).firstOrNull;
}

/// The app arriving on screen.
class Opened extends Beat {
  Opened._(List<Phase> p) : super._(p.first.at, _span(p), p);
}

/// The last hold, after everything.
class Closed extends Beat {
  Closed._(List<Phase> p) : super._(p.first.at, _span(p), p);
}

/// Nobody touching anything.
class Idled extends Beat {
  Idled._(List<Phase> p) : super._(p.first.at, _span(p), p);
}

/// A tap, or — with [held] — a long press.
class Tapped extends Beat {
  Tapped._(
    List<Phase> p, {
    required this.label,
    required this.target,
    required this.held,
  }) : super._(p.first.at, _span(p), p);

  /// What the verb named, spelled the way every other surface spells a
  /// target — `describeTarget`'s rendering, so a string target arrives
  /// quoted. It is a label for a person, not a finder to re-resolve.
  final String? label;

  /// The box it resolved to, in the app's own logical pixels.
  final Rect? target;

  final bool held;
}

/// Text going into a field, a character at a time.
class Typed extends Beat {
  Typed._(List<Phase> p, {required this.text, required this.field})
    : super._(p.first.at, _span(p), p);

  final String text;
  final Rect? field;
}

/// A finger dragging.
class Dragged extends Beat {
  Dragged._(List<Phase> p, {required this.from})
    : super._(p.first.at, _span(p), p);

  final Rect? from;
}

/// A pane being swiped until something is on screen.
class Scrolled extends Beat {
  Scrolled._(List<Phase> p, {required this.label, required this.pane})
    : super._(p.first.at, _span(p), p);

  final String? label;
  final Rect? pane;
}

/// Any other verb — `screen`, `settle`, `back`, `pumpWidget`.
class Acted extends Beat {
  Acted._(
    List<Phase> p, {
    required this.verb,
    required this.label,
    required this.target,
  }) : super._(p.first.at, _span(p), p);

  final String verb;
  final String? label;
  final Rect? target;
}

/// Something the scenario said — `s.title(...)`, `s.film.emit(...)`.
///
/// [cue] is the author's own object when the edit runs in the process that
/// said it, and a [ScenarioCueRecord] when it was read back from a file.
class Said extends Beat {
  Said._(Duration at, this.cue) : super._(at, Duration.zero, const []);

  factory Said._decode(Map<String, Object?> json) {
    var at = Duration(milliseconds: (json['atMs'] as num?)?.toInt() ?? 0);
    var type = json['type'] as String? ?? '';
    var data = json['data'] as Map<String, Object?>?;
    // The stock cues survive the round trip as themselves; anything else is
    // the author's class, which a file cannot hold.
    if (type == 'ScenarioTitle' && data != null) {
      return Said._(at, ScenarioTitle('${data['text']}'));
    }
    return Said._(
      at,
      ScenarioCueRecord(
        type: type,
        label: json['label'] as String? ?? '',
        data: data ?? const {},
      ),
    );
  }

  final Object cue;
}

/// A cue that came back from a file rather than from the run that said it.
class ScenarioCueRecord {
  const ScenarioCueRecord({
    required this.type,
    required this.label,
    required this.data,
  });

  /// The name of the class that was emitted.
  final String type;

  /// Its `toString`.
  final String label;

  /// Its fields, when it implemented [ScenarioCueData].
  final Map<String, Object?> data;

  @override
  String toString() => label.isEmpty ? type : label;
}

/// What the film called one stretch of frames.
enum PhaseKind {
  open,
  travel,
  aim,
  press,
  focus,
  type,
  drag,
  swipe,
  act,
  dwell,
  close,
}

/// One stretch of frames, as the film marked it.
class Phase {
  Phase({
    required this.index,
    required this.kind,
    required this.at,
    required this.duration,
    required this.frame,
    required this.frames,
    this.verb,
    this.target,
    this.rect,
  });

  static Phase _decode(Map<String, Object?> json, int index) => Phase(
    index: index,
    kind:
        PhaseKind.values.where((k) => k.name == json['kind']).firstOrNull ??
        PhaseKind.act,
    at: Duration(milliseconds: (json['atMs'] as num?)?.toInt() ?? 0),
    duration: Duration(
      milliseconds: (json['durationMs'] as num?)?.toInt() ?? 0,
    ),
    frame: (json['frame'] as num?)?.toInt() ?? 0,
    frames: (json['frames'] as num?)?.toInt() ?? 0,
    verb: json['verb'] as String?,
    target: json['target'] as String?,
    rect: switch (json['aim']) {
      Map aim => Rect.fromLTWH(
        _d(aim['x']),
        _d(aim['y']),
        _d(aim['w']),
        _d(aim['h']),
      ),
      _ => null,
    },
  );

  /// Where this sits in the film's own run of marks.
  ///
  /// Assigned by the reader rather than written down, because it is only ever
  /// used to say the same thing twice: a reel keyed a hold on phase 12 of the
  /// dry pass, and the filming pass counts its own marks to find it. If the
  /// two runs ever disagree about the sequence, that is the drift the digest
  /// guard is for — not something a stored number would have caught.
  final int index;

  final PhaseKind kind;
  final Duration at;
  final Duration duration;

  /// Where this starts in the film's frames, and how many it covers. An edit
  /// counts time; an encoder counts these.
  final int frame;
  final int frames;

  final String? verb;
  final String? target;

  /// What the verb aimed at, in the app's own logical pixels.
  final Rect? rect;

  Duration get end => at + duration;

  static double _d(Object? v) => v is num ? v.toDouble() : 0;
}

Duration _span(List<Phase> phases) => phases.last.end - phases.first.at;
