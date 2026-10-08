/// The settings half of a film, kept free of Flutter.
///
/// Split from [ScenarioFilm] for the reason `pixels.dart` is split from
/// everything that reads it: the CLI names these in a request and is compiled
/// with `dart compile exe`, where `package:flutter` cannot load
/// (`app/test/utils/entry_point_purity_test.dart` fails the build over it).
/// The film itself rasterises frames and lives on the other side of that line.
library;

/// How a film is paced, sized and where it is written.
///
/// A film run is a *second* run of the same body whose only product is a
/// video: it captures every frame it pumps, not only the frames of a
/// transition, and it spends fake time on beats no scenario contains — the
/// travel of a cursor toward a button, the pause after a screen arrives.
class FilmSettings {
  const FilmSettings({
    required this.directory,
    this.fps = 30,
    this.scale = 3,
    this.branches = const [],
    this.open = const Duration(milliseconds: 500),
    this.travel = const Duration(milliseconds: 350),
    this.aim = const Duration(milliseconds: 140),
    this.press = const Duration(milliseconds: 120),
    this.dwell = const Duration(milliseconds: 600),
    this.close = const Duration(milliseconds: 800),
    this.typing = const Duration(milliseconds: 95),
    this.drag = const Duration(milliseconds: 420),
    this.maxFrames = 1800,
    this.batch = 15,
    this.pixels = true,
  });

  /// The same pass with the pixels turned off: a **dry** run.
  ///
  /// Every beat still pumps, the clock still advances, the pointer is still
  /// tracked and the timeline is still written — only the rasterising, the
  /// composing and the writing are skipped. So what comes out is the film's
  /// own account of itself with none of the film: a [Take]. Measured on a
  /// 355-frame scenario, ~300ms against ~1.3s for the same pass at scale 2,
  /// because pixels are two thirds of a film.
  ///
  /// A dry pass writes no head, so nothing can be drained from it.
  final bool pixels;

  /// Where the frames and the timeline go. Emptied when the film starts, so a
  /// second render never encodes half of the one before it.
  final String directory;

  /// Frames a second — of the film, and of the fake clock, which are the same
  /// number. A pump advances time by exactly one frame, so what the film shows
  /// is the app's own animation curve with nothing dropped and nothing
  /// jittered.
  final int fps;

  /// Output pixels per logical pixel.
  ///
  /// Three rather than the run's one: `yuv420p` is the only chroma format
  /// every player accepts and it halves the colour resolution, which shows on
  /// crisp UI text. Rendering above the size the film is watched at is what
  /// puts the softening below the pixel a viewer sees.
  final double scale;

  /// Which branch to take at each `split`, outermost first.
  ///
  /// A film is one path. Every path is the right answer for a suite and the
  /// wrong one for a video, so the author names it — see [ScenarioFilmRefusal].
  final List<String> branches;

  /// The hold after the first screen arrives, before anything is touched.
  final Duration open;

  /// How long the cursor takes to fly to its target.
  final Duration travel;

  /// The beat between arriving and pressing: the finger is over the target and
  /// has not touched it yet.
  ///
  /// Small, and the difference between a hand and a machine. Nobody lands on a
  /// button and presses it in the same instant — there is always a moment of
  /// *having arrived*, and without it every verb reads as hurried however
  /// gently the reach itself is paced.
  final Duration aim;

  /// The press: the cursor is down and the verb has not fired yet.
  final Duration press;

  /// The hold after a verb has settled — the time a reader spends looking at
  /// what just happened.
  final Duration dwell;

  /// The final hold, so the clip does not cut on the frame of the last verb.
  final Duration close;

  /// How long one character takes to type.
  ///
  /// Ten a second, which is a fast but human hand. A bare `enterText` spends
  /// no fake time — it sets the whole value in one pump — so this is not a
  /// slowdown of anything: it is the only place the typing exists. One that
  /// types at a pace of its own (`typing:`) keeps it, film or not.
  final Duration typing;

  /// How long a drag takes when the scenario did not say.
  ///
  /// A bare `s.drag` moves the finger in one jump, which is right for a suite
  /// — the velocity tracker sees no time pass and the list stops dead where
  /// the finger stopped — and is nothing at all to look at. The film spreads
  /// the same travel over this, and then holds the finger still before lifting
  /// so the gesture ends with the same zero velocity the suite's did.
  final Duration drag;

  /// The ceiling on one film's frames. At 30fps this is a minute.
  ///
  /// Not optional, and not a `RangeError` either: a film that runs long is
  /// cut and says so in the timeline, because the alternative is a scenario
  /// that renders for an hour before anyone can watch the first second of it.
  final int maxFrames;

  /// How many frames pile up before they are written out.
  ///
  /// The bank holds rasterised images — 10MB each at 1080×2340 — so it cannot
  /// hold a whole film. It cannot hold one frame either: writing is
  /// asynchronous and every drain costs a `runAsync`, so paying that per frame
  /// is what made the naive motion recorder 25× slower than the one that
  /// banks. Fifteen frames is half a second of film and ~150MB at the default
  /// scale.
  final int batch;

  /// The fake time one frame of film is worth.
  Duration get frame => Duration(microseconds: (1000000 / fps).round());

  /// These settings as a **dry** pass written to [directory] — the same
  /// pacing, the same path, no pixels. What a reel's first pass runs under:
  /// the take it produces is measured in the film's own beats, so the two
  /// passes agree on every instant.
  FilmSettings dry(String directory) => FilmSettings(
    directory: directory,
    fps: fps,
    scale: scale,
    branches: branches,
    open: open,
    travel: travel,
    aim: aim,
    press: press,
    dwell: dwell,
    close: close,
    typing: typing,
    drag: drag,
    maxFrames: maxFrames,
    batch: batch,
    pixels: false,
  );
}

/// What a film run throws when a `split` is reached that its
/// [FilmSettings.branches] did not name.
///
/// A film is one path through the scenario, and which path is the author's
/// call — never a default, and never all of them spliced end to end.
class ScenarioFilmRefusal implements Exception {
  ScenarioFilmRefusal(this.message);

  final String message;

  @override
  String toString() => message;
}
