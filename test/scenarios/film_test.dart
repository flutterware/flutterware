import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:material_ui/material_ui.dart';
import 'package:flutterware/flutter_test.dart';
import 'package:flutterware/reel.dart';
import 'package:flutterware/scene_authoring.dart' show SceneColor;
import 'package:flutterware/src/scenarios/film.dart';
import 'package:flutterware/src/scenarios/run_args.dart';

/// Rendering a scenario as a **film**: every pumped frame kept, the beats a
/// viewer needs pumped between the verbs, and a cursor drawn over the lot.
/// Design: `docs/superpowers/specs/2026-09-08-scenario-video-design.md`.
///
/// Like `motion_test.dart`, these tests stand in for the harness: they set the
/// run args the runner would set and read what landed on disk.
void main() {
  late Directory directory;

  void film(
    FilmSettings Function(String directory) settings, {
    ScenarioAssignment? on,
    Reel? reel,
    ReelStage Function()? stage,
  }) {
    setUp(() {
      directory = Directory.systemTemp.createTempSync('fw-film');
      var args = ScenarioRunArgs(
        film: settings(directory.path),
        reel: reel,
        stage: stage?.call(),
      );
      // `withDevice` is what the harness applies when a run names a device:
      // the geometry, the platform and the assignment the keyboard reads.
      scenarioRunArgs = on == null ? args : args.withDevice(on.device!);
    });
    tearDown(() {
      scenarioRunArgs = null;
      resetFilms();
      if (directory.existsSync()) directory.deleteSync(recursive: true);
    });
  }

  group('a filmed scenario', () {
    film(
      (directory) => FilmSettings(
        directory: directory,
        fps: 30,
        scale: 1,
        // Short beats: the point of the assertions below is the shape of the
        // timeline, and a default-paced film of a two-verb scenario is 60
        // frames of holding still.
        open: const Duration(milliseconds: 100),
        travel: const Duration(milliseconds: 200),
        press: const Duration(milliseconds: 100),
        dwell: const Duration(milliseconds: 100),
        close: const Duration(milliseconds: 100),
      ),
    );

    scenario('writes a frame per pump, and a timeline for them', (s) async {
      await s.pumpWidget(const _App());
      await s.tap('Fade in');
    });

    tearDown(() {
      var film = _timeline(directory);
      var frames = directory
          .listSync()
          .whereType<File>()
          .where((file) => file.path.endsWith('.raw'))
          .toList();
      expect(frames, hasLength(film['frames']));
      expect(film['frames'], greaterThan(20));
      expect(film['dropped'], isNull);
      // Every frame is whole: raw video carries no header, so a short file is
      // not a small frame, it is the rest of the clip sheared.
      var bytes = (film['width']! as int) * (film['height']! as int) * 4;
      for (var frame in frames) {
        expect(frame.lengthSync(), bytes, reason: frame.path);
      }
      // The default test view, at the film's scale.
      expect(film['width'], 800);
      expect(film['height'], 600);
      expect(film['fps'], 30);
      expect(film['pointer'], 'touch');
    });
  });

  group("a filmed scenario's beats", () {
    film(
      (directory) => FilmSettings(
        directory: directory,
        scale: 1,
        open: const Duration(milliseconds: 100),
        travel: const Duration(milliseconds: 200),
        press: const Duration(milliseconds: 100),
        dwell: const Duration(milliseconds: 100),
        close: const Duration(milliseconds: 100),
      ),
    );

    scenario('name every stretch of it, in order and without gaps', (s) async {
      await s.pumpWidget(const _App());
      await s.tap('Fade in');
    });

    tearDown(() {
      var beats = _beats(_timeline(directory));
      expect(
        [for (var beat in beats) beat['kind']],
        [
          // The app arrives and is held; the cursor flies to the button, rests
          // a moment over it and presses; the fade plays; the result is held;
          // the film ends on a hold rather than on the frame the verb landed
          // on.
          'act',
          'open',
          'travel',
          'aim',
          'press',
          'act',
          'dwell',
          'close',
        ],
      );
      expect(
        [for (var beat in beats) beat['verb']],
        ['pumpWidget', null, 'tap', 'tap', 'tap', 'tap', null, null],
      );
      // Contiguous: every frame of the film belongs to exactly one beat, so a
      // caption hung on a beat cannot fall in a gap between two of them.
      var next = 0;
      for (var beat in beats) {
        expect(beat['frame'], next, reason: '${beat['kind']}');
        next += beat['frames']! as int;
      }
      expect(next, _timeline(directory)['frames']);
      // 200ms of travel at 30fps — a full-height reach on this screen, so the
      // nominal — then the pause over the target and the press.
      expect(beats[2]['frames'], 6);
      expect(beats[3]['frames'], 4);
      expect(beats[4]['frames'], 3);
    });
  });

  group("a filmed verb's cursor", () {
    film((directory) => FilmSettings(directory: directory, scale: 1));

    scenario('flies to the target, presses it, and is drawn on the frame', (
      s,
    ) async {
      await s.pumpWidget(const _App());
      await s.tap('Fade in');
    });

    tearDown(() async {
      var timeline = _timeline(directory);
      var samples = [
        for (var sample in timeline['samples']! as List)
          sample as Map<String, Object?>,
      ];
      var travel = _beats(timeline).firstWhere((b) => b['kind'] == 'travel');
      var press = _beats(timeline).firstWhere((b) => b['kind'] == 'press');
      var during = [
        for (var sample in samples)
          if ((sample['frame']! as int) >= (travel['frame']! as int)) sample,
      ];
      expect(during, isNotEmpty);
      // Nothing before the first travel: a film that opens with a cursor
      // parked on the screen opens on a claim about a user who has not
      // arrived.
      expect(
        samples.first['frame'],
        travel['frame'],
        reason: 'the cursor exists only once a verb has somewhere to send it',
      );
      // It comes in from below the stage and climbs to the button, which is
      // above the middle of this app.
      expect(during.first['y']! as num, greaterThan(600));
      expect(during.last['y']! as num, lessThan(300));
      expect(during.first['down'], isNull);
      // Down for the press, and only there.
      var pressed = [
        for (var sample in samples)
          if (sample['down'] == true) sample['frame']! as int,
      ];
      expect(pressed.first, press['frame']);
      expect(pressed, hasLength(press['frames']));

      // And it is on the pixels. The app is black under the button and every
      // mark the cursor makes carries a light edge — that is how it survives a
      // dark screen as well as a light one — so a bright pixel near the
      // contact point is the cursor, and the frame before it arrived has none.
      var at = samples.firstWhere((s) => s['down'] == true);
      var x = (at['x']! as num).round();
      var y = (at['y']! as num).round();
      var width = timeline['width']! as int;
      expect(
        _bright(_frame(directory, at['frame']! as int), width, x, y),
        isTrue,
        reason: 'the cursor is drawn on the frame it is pressing',
      );
      expect(
        _bright(_frame(directory, 0), width, x, y),
        isFalse,
        reason: 'and the app under it is dark',
      );
    });
  });

  group('a filmed long press', () {
    film(
      (directory) => FilmSettings(
        directory: directory,
        scale: 1,
        open: const Duration(milliseconds: 100),
        travel: const Duration(milliseconds: 100),
        press: const Duration(milliseconds: 100),
        dwell: const Duration(milliseconds: 100),
        close: const Duration(milliseconds: 100),
      ),
    );

    scenario('is held long enough to read as one', (s) async {
      await s.pumpWidget(const _App());
      await s.longPress('Fade in');
    });

    tearDown(() {
      var beats = _beats(_timeline(directory));
      var press = beats.firstWhere((beat) => beat['kind'] == 'press');
      // `tester.longPress` spends no fake time at all, so a film that took the
      // beat at its word would show a tap. 550ms at 30fps is 17 frames; the
      // 100ms beat above would have been 3.
      expect(press['frames'], 17);
      expect(press['verb'], 'longPress');
    });
  });

  // What the drag carried, filled by the scenario below and read by the plain
  // widget test after it — the two halves of one comparison.
  var carried = <double>[];

  group('a filmed drag', () {
    var controller = ScrollController();
    film(
      (directory) => FilmSettings(
        directory: directory,
        scale: 1,
        open: const Duration(milliseconds: 100),
        travel: const Duration(milliseconds: 100),
        press: const Duration(milliseconds: 100),
        dwell: const Duration(milliseconds: 100),
        close: const Duration(milliseconds: 100),
      ),
    );

    scenario('moves the finger frame by frame', (s) async {
      await s.pumpWidget(_ScrollApp(controller));
      await s.drag(find.byType(ListView), const Offset(0, -300));
      carried.add(controller.offset);
    });

    tearDown(() {
      var timeline = _timeline(directory);
      var drag = _beats(timeline).firstWhere((beat) => beat['kind'] == 'drag');
      // A scenario's own drag dispatches down, move and up with no frames
      // between them, so a film of it shows a list that teleports.
      expect(drag['frames']! as int, greaterThan(10));
      // From the frame the finger went down on — the drag's own first frame
      // has already moved a little, which is the point.
      var during = [
        for (var sample in timeline['samples']! as List)
          if (((sample as Map)['frame']! as int) >= (drag['frame']! as int) - 1)
            (sample['y']! as num).toDouble(),
      ];
      // The finger travels with the frames rather than ahead of them, and it
      // travels the whole way.
      expect(during.first - during.last, closeTo(300, 0.01));
      // And it rests before it lifts, which is what keeps the list from
      // flinging past where the suite's own drag leaves it.
      expect(during.sublist(during.length - 4).toSet(), hasLength(1));
    });
  });

  testWidgets("a filmed drag lands where the suite's own drag lands", (
    tester,
  ) async {
    var controller = ScrollController();
    await tester.pumpWidget(_ScrollApp(controller));
    await tester.drag(find.byType(ListView), const Offset(0, -300));
    await tester.pumpAndSettle();

    // The property this rests on, and the reason the film holds the finger
    // still before it lifts: a drag spread over frames has *velocity*, and a
    // list that flings past where the suite left it is a film of a different
    // app — one whose next assertion may not hold.
    expect(controller.offset, 300);
    expect(carried.single, closeTo(controller.offset, 0.5));
  });

  // Where the filmed scroll left the list, against where the suite's own walk
  // leaves it.
  var scrolled = <double>[];

  group('a filmed scroll', () {
    var controller = ScrollController();
    film(
      (directory) => FilmSettings(
        directory: directory,
        scale: 1,
        open: const Duration(milliseconds: 100),
        travel: const Duration(milliseconds: 100),
        press: const Duration(milliseconds: 100),
        dwell: const Duration(milliseconds: 100),
        close: const Duration(milliseconds: 100),
      ),
    );

    scenario('walks the list with a thumb', (s) async {
      await s.pumpWidget(_ScrollApp(controller));
      await s.scrollTo('Row 40');
      scrolled.add(controller.offset);
    });

    tearDown(() {
      var timeline = _timeline(directory);
      var beats = _beats(timeline);
      var swipes = [
        for (var beat in beats)
          if (beat['kind'] == 'swipe') beat,
      ];
      // A list that scrolls itself is the one thing in a reel that reads as a
      // bug rather than as a user: one swipe per iteration of the walk, each
      // one a drag the finger is on.
      expect(swipes, isNotEmpty);
      expect(swipes.first['verb'], 'scrollTo');
      var down = [
        for (var sample in timeline['samples']! as List)
          if ((sample as Map)['down'] == true) (sample['y']! as num).toDouble(),
      ];
      expect(down, isNotEmpty);
      // The finger travels while it is down — it is the finger that moves the
      // list, not the other way round.
      expect(
        down.reduce((a, b) => a > b ? a : b) -
            down.reduce((a, b) => a < b ? a : b),
        greaterThan(100),
      );
    });
  });

  testWidgets("a filmed scroll lands where the suite's own walk lands", (
    tester,
  ) async {
    var controller = ScrollController();
    await tester.pumpWidget(_ScrollApp(controller));
    await tester.scrollUntilVisible(find.text('Row 40'), 200);
    await tester.pumpAndSettle();

    // Same walk, same step, same stopping condition, same tail — so the film
    // stops on the same iteration and the list ends where the suite's does.
    expect(scrolled.single, closeTo(controller.offset, 0.5));
  });

  group('filmed typing', () {
    film(
      (directory) => FilmSettings(
        directory: directory,
        scale: 1,
        open: const Duration(milliseconds: 100),
        travel: const Duration(milliseconds: 100),
        press: const Duration(milliseconds: 100),
        dwell: const Duration(milliseconds: 100),
        close: const Duration(milliseconds: 100),
      ),
    );

    scenario('goes in a character at a time', (s) async {
      await s.pumpWidget(const _FormApp());
      await s.enterText(TextField, 'hello world');
      expect(find.text('hello world'), findsOneWidget);
    });

    tearDown(() {
      var typing = _beats(_timeline(directory))
          .firstWhere((beat) => beat['kind'] == 'type');
      expect(typing['verb'], 'enterText');
      // `enterText` spends no fake time of its own, so every one of these
      // frames is the film's: ten characters at three frames each, and five
      // for the word gap.
      expect(typing['frames'], 35);
      expect(typing['target'], 'hello world');
    });
  });

  group('filmed typing on a phone', () {
    film(
      (directory) => FilmSettings(
        directory: directory,
        scale: 1,
        open: const Duration(milliseconds: 100),
        travel: const Duration(milliseconds: 100),
        press: const Duration(milliseconds: 100),
        dwell: const Duration(milliseconds: 100),
        close: const Duration(milliseconds: 100),
      ),
      on: const ScenarioAssignment(device: Devices.iphone16),
    );

    scenario('waits for the keyboard before the words appear', (s) async {
      await s.pumpWidget(const _FormApp());
      await s.enterText(TextField, 'hi');
    });

    tearDown(() {
      var beats = _beats(_timeline(directory));
      var kinds = [for (var beat in beats) beat['kind']];
      // The order nothing does: type into a screen with no keyboard on it and
      // raise one afterwards. The focus beat is where the slab slides up, and
      // its frames exist because something was animating through them.
      expect(kinds.indexOf('focus'), lessThan(kinds.indexOf('type')));
      var focus = beats.firstWhere((beat) => beat['kind'] == 'focus');
      expect(focus['frames']! as int, greaterThan(3));
    });
  });

  group('a filmed scenario that splits', () {
    film((directory) => FilmSettings(directory: directory, scale: 1));

    scenario('refuses a branch it was not given', (s) async {
      await s.pumpWidget(const _App());
      await expectLater(
        s.split({
          'fades in': () async => s.tap('Fade in'),
          'stays put': () async => s.screen('Still'),
        }),
        throwsA(
          isA<ScenarioFilmRefusal>().having(
            (refusal) => refusal.message,
            'message',
            allOf(
              contains('`fades in` and `stays put`'),
              contains("--branch='fades in'"),
            ),
          ),
        ),
      );
    });
  });

  group('a filmed scenario given its branch', () {
    film(
      (directory) =>
          FilmSettings(directory: directory, scale: 1, branches: ['stays put']),
    );

    var walked = <String>[];
    scenario('walks that one, once', (s) async {
      await s.pumpWidget(const _App());
      await s.split({
        'fades in': () async {
          walked.add('fades in');
          await s.tap('Fade in');
        },
        'stays put': () async {
          walked.add('stays put');
          await s.screen('Still');
        },
      });
    });

    tearDown(() {
      // One path, not both, and not the first by default: a suite wants every
      // branch and a film wants the one worth watching.
      expect(walked, ['stays put']);
      walked = [];
    });
  });

  group('a film that runs long', () {
    film(
      (directory) =>
          FilmSettings(directory: directory, scale: 1, maxFrames: 12),
    );

    scenario('is cut, and says so', (s) async {
      await s.pumpWidget(const _App());
      await s.tap('Fade in');
    });

    tearDown(() {
      var timeline = _timeline(directory);
      expect(timeline['frames'], 12);
      // Reported rather than swallowed: a clip that stops early is not a
      // scenario that ended there.
      expect(timeline['dropped']! as int, greaterThan(0));
    });
  });

  group('a dry pass hands its take on', () {
    film(
      (directory) => FilmSettings(
        directory: directory,
        scale: 1,
        pixels: false,
        open: const Duration(milliseconds: 100),
        travel: const Duration(milliseconds: 200),
        press: const Duration(milliseconds: 100),
        dwell: const Duration(milliseconds: 100),
        close: const Duration(milliseconds: 100),
      ),
    );

    scenario('to whoever runs the film pass', reel: const _Edit(), (s) async {
      await s.pumpWidget(const _App());
      s.film.emit(const _Basket(3));
      await s.tap('Fade in');
    });

    tearDown(() {
      // What the harness collects between the two passes: the film that
      // finished, carrying the edit the scenario declared and a take with the
      // cue *objects* — not their JSON — beside the beats.
      var finished = takeFinishedFilm();
      expect(finished, isNotNull);
      expect(finished!.edit, isA<_Edit>());
      var take = finished.take;
      expect(take.dry, isTrue);
      expect(take.beats.whereType<Tapped>(), hasLength(1));
      var said = take.beats.whereType<Said>().single;
      expect(said.cue, const _Basket(3));
      // Once: the next request's second pass must never be handed this one.
      expect(takeFinishedFilm(), isNull);
    });
  });

  group('a dry pass', () {
    film(
      (directory) => FilmSettings(
        directory: directory,
        scale: 1,
        pixels: false,
        open: const Duration(milliseconds: 100),
        travel: const Duration(milliseconds: 200),
        press: const Duration(milliseconds: 100),
        dwell: const Duration(milliseconds: 100),
        close: const Duration(milliseconds: 100),
      ),
    );

    scenario('pumps every beat and draws none of them', (s) async {
      s.title('Order a coffee');
      await s.pumpWidget(const _App());
      s.film.emit(const _Basket(3));
      await s.tap('Fade in');
    });

    tearDown(() {
      var timeline = _timeline(directory);
      // The whole point: the timeline is the same account of the same run,
      // and nothing was rasterised to make it.
      expect(timeline['dry'], isTrue);
      expect(timeline['frames']! as int, greaterThan(20));
      expect(
        directory.listSync().whereType<File>().where(
          (file) => file.path.endsWith('.raw'),
        ),
        isEmpty,
      );
      // No head: nothing can be drained from a pass with no frames, and the
      // head is what an encoder opens on.
      expect(
        File('${directory.path}/${ScenarioFilm.headFileName}').existsSync(),
        isFalse,
      );
      // It still knows how big the film would have been — an edit lays a
      // stage out against that and there are no pixels to read it off.
      expect(timeline['width']! as int, greaterThan(0));
      expect(timeline['height']! as int, greaterThan(0));
      expect(timeline['composeMs'], 0);
      expect(timeline['writeMs'], 0);
    });
  });

  group('a filmed scenario with a reel', () {
    // Output ≠ source. Eighteen frames of the app, nine of the same frame
    // held, six more of the app — 33 output frames out of 24 pumped ones,
    // which is the whole claim. The freeze lands mid-travel on purpose: with
    // the cursor moving, a held frame is visibly a held frame.
    var seen = <_Seen>[];
    var reel = Reel(
      shots: [
        ReelShot(
          at: Duration.zero,
          duration: const Duration(milliseconds: 600),
          frozen: false,
        ),
        ReelShot(
          at: const Duration(milliseconds: 600),
          duration: const Duration(milliseconds: 300),
          frozen: true,
        ),
        ReelShot(
          at: const Duration(milliseconds: 900),
          duration: const Duration(milliseconds: 200),
          frozen: false,
        ),
      ],
      cues: [
        CueSpan(
          at: Duration.zero,
          duration: const Duration(milliseconds: 300),
          cue: const ScenarioTitle('Order a coffee'),
        ),
      ],
      // The pause the app arrives in — beat 1, after `pumpWidget`'s own.
      holds: {1: const Duration(milliseconds: 200)},
      // On the reel, because a reel's own stage is the one in force: an edit
      // that built a picture built it for its own timing.
      stage: _WatchingStage(seen),
    );

    film(
      (directory) => FilmSettings(
        directory: directory,
        scale: 1,
        fps: 30,
        open: const Duration(milliseconds: 100),
        travel: const Duration(milliseconds: 400),
        press: const Duration(milliseconds: 100),
        dwell: const Duration(milliseconds: 100),
        close: const Duration(milliseconds: 100),
      ),
      reel: reel,
    );
    setUp(seen.clear);

    scenario('shows what the reel says, for as long as it says', (s) async {
      await s.pumpWidget(const _App());
      await s.tap('Fade in');
    });

    tearDown(() {
      var frames =
          directory
              .listSync()
              .whereType<File>()
              .where((file) => file.path.endsWith('.raw'))
              .toList()
            ..sort((a, b) => a.path.compareTo(b.path));
      // 1100ms of reel at 30fps, whatever the run did.
      expect(frames, hasLength(33));

      // The nine frozen frames are the frame before them, byte for byte —
      // and the one after is not, because the cursor was travelling through
      // all of it and a freeze is the picture stopping, not the app.
      var held = frames[17].readAsBytesSync();
      for (var i = 18; i <= 26; i++) {
        expect(frames[i].readAsBytesSync(), held, reason: 'frame $i');
      }
      expect(frames[27].readAsBytesSync(), isNot(held));

      // The stage was told what the reel was saying, and only while it said
      // it: nine frames of title at 30fps.
      expect(seen, hasLength(33));
      expect(seen.where((f) => f.title == 'Order a coffee'), hasLength(9));
      expect(seen.first.at, Duration.zero);
      // 32/30 of a second: output time is frames, exactly, and not rounded to
      // a millisecond on the way.
      expect(seen.last.at, const Duration(microseconds: 1066667));

      // And the hold really pumped: the pause the app arrives in is the
      // film's own 100ms plus the 200ms the reel asked for.
      var open = _beats(_timeline(directory))
          .firstWhere((b) => b['kind'] == 'open');
      expect(open['durationMs'], 300);
    });
  });

  group('a filmed scenario with a scene reel', () {
    // The take an edit would have read off a dry pass of this scenario, with
    // every beat shorter than the film will really pump — the projector
    // drops what the source never reaches, so a take that claims *more*
    // than the run would end short, and one that claims less ends exactly
    // where the reel says.
    Map<String, Object?> phase(
      String kind,
      int atMs,
      int durationMs, {
      String? verb,
      String? target,
      Rect? aim,
    }) => {
      'kind': kind,
      'frame': atMs ~/ 33,
      'atMs': atMs,
      'frames': durationMs ~/ 33,
      'durationMs': durationMs,
      'verb': ?verb,
      'target': ?target,
      if (aim != null)
        'aim': {'x': aim.left, 'y': aim.top, 'w': aim.width, 'h': aim.height},
    };
    var take = Take.decode({
      'version': 2,
      'scenario': 'Fade in',
      'fps': 30,
      'scale': 1,
      'width': 800,
      'height': 600,
      'screen': {'width': 800, 'height': 600},
      'frames': 60,
      'durationMs': 2000,
      'beats': [
        phase('act', 0, 33, verb: 'pumpWidget'),
        phase('open', 33, 100),
        phase('travel', 133, 100, verb: 'tap'),
        phase('aim', 233, 66, verb: 'tap'),
        phase('press', 299, 100, verb: 'tap'),
        phase(
          'act',
          399,
          33,
          verb: 'tap',
          target: '"Fade in"',
          aim: const Rect.fromLTWH(360, 280, 80, 40),
        ),
        phase('dwell', 432, 100),
        phase('close', 532, 100),
      ],
      'cues': [
        {
          'atMs': 33,
          'type': 'ScenarioTitle',
          'label': 'title: Order a coffee',
          'data': {'text': 'Order a coffee'},
        },
      ],
    });
    var reel = const StockSceneReel(
      holdAfterFirstTap: Duration(milliseconds: 300),
      // Longer than the closing's 500ms dim, so the last frame is the dim
      // finished and not a third of the way through it.
      tail: Duration(milliseconds: 600),
      // A ground no app has, so the closing — the app dimmed to 35% over
      // it — is unmistakably the scene's doing and not the app's.
      ground: SceneColor(0xFFFF0000),
    ).edit(take);

    film(
      (directory) => FilmSettings(
        directory: directory,
        scale: 1,
        fps: 30,
        open: const Duration(milliseconds: 100),
        travel: const Duration(milliseconds: 400),
        press: const Duration(milliseconds: 100),
        dwell: const Duration(milliseconds: 100),
        close: const Duration(milliseconds: 100),
      ),
      reel: reel,
    );

    scenario("renders the scene over the app, for the reel's length", (
      s,
    ) async {
      await s.pumpWidget(const _App());
      await s.tap('Fade in');
    });

    tearDown(() {
      var frames = directory
          .listSync()
          .whereType<File>()
          .where((file) => file.path.endsWith('.raw'))
          .length;
      // Exactly the reel: the take's 632ms, the 300ms hold, the 600ms tail.
      expect(reel.duration, const Duration(milliseconds: 632 + 300 + 600));
      expect(frames, (reel.duration.inMilliseconds * 30 / 1000).round());
      // The hold reached the run: the pause after the tap is the film's own
      // 100ms plus the 300ms the edit asked for.
      var dwell = _beats(_timeline(directory))
          .firstWhere((b) => b['kind'] == 'dwell');
      expect(dwell['durationMs'], 400);
      // And the scene is what was drawn — not the bare stage a film falls
      // back to. The app is black; the closing dims it to 35% over a red
      // ground, so the last frame is mostly red and the first is not. A
      // frame count alone let a reel render with no stage at all and pass.
      var raws =
          directory
              .listSync()
              .whereType<File>()
              .where((file) => file.path.endsWith('.raw'))
              .toList()
            ..sort((a, b) => a.path.compareTo(b.path));
      expect(_meanRed(raws.first), lessThan(40));
      expect(_meanRed(raws.last), greaterThan(120));
    });
  });

  group('a film a scenario talks to', () {
    film(
      (directory) => FilmSettings(
        directory: directory,
        scale: 1,
        pixels: false,
        open: const Duration(milliseconds: 100),
        travel: const Duration(milliseconds: 200),
        press: const Duration(milliseconds: 100),
        dwell: const Duration(milliseconds: 100),
        close: const Duration(milliseconds: 100),
      ),
    );

    scenario('records what it said, and when', (s) async {
      await s.pumpWidget(const _App());
      s.title('Order a coffee');
      await s.tap('Fade in');
      s.film.emit(const _Basket(3));
    });

    tearDown(() {
      var timeline = _timeline(directory);
      var cues = [
        for (var cue in timeline['cues']! as List) cue as Map<String, Object?>,
      ];
      expect(cues.map((c) => c['type']), ['ScenarioTitle', '_Basket']);
      // A cue that can write itself down does; one that cannot still leaves
      // its name and its words, which is what a person reading the file needs.
      expect(cues.first['data'], {'text': 'Order a coffee'});
      expect(cues.last['label'], 'a basket of 3');
      // And read back, it is a take: beats with types, woven into the order
      // they happened. The title was said in the breath before the tap — at
      // the very frame the tap begins on — and a caption that arrives after
      // the tap it introduces is a caption that arrived late.
      var take = Take.read(directory.path);
      expect(take.beats.map((b) => b.runtimeType.toString()), [
        // `pumpWidget` is a verb with no finger, then the opening hold.
        'Acted',
        'Opened',
        'Said',
        'Tapped',
        'Said',
        'Closed',
      ]);
      expect(take.beats.whereType<Said>(), hasLength(2));
      // Spelled the way every other surface spells a target — quoted, because
      // `describeTarget` is what wrote it and a step page shows the same.
      expect(take.beats.whereType<Tapped>().single.label, '"Fade in"');
      expect(
        take.beats.whereType<Said>().first.cue,
        const ScenarioTitle('Order a coffee'),
      );
      expect(take.duration.inMilliseconds, greaterThan(0));
    });
  });
}

/// An edit a scenario declares for itself.
class _Edit extends ScenarioReelEdit {
  const _Edit();

  @override
  Reel edit(Take take) => const StockReel().edit(take);
}

class _Basket implements ScenarioCueData {
  const _Basket(this.count);

  final int count;

  @override
  Map<String, Object?> toJson() => {'count': count};

  @override
  String toString() => 'a basket of $count';
}

Map<String, Object?> _timeline(Directory directory) => jsonDecode(
  File('${directory.path}/${ScenarioFilm.timelineFileName}').readAsStringSync(),
) as Map<String, Object?>;

List<Map<String, Object?>> _beats(Map<String, Object?> timeline) => [
  for (var beat in timeline['beats']! as List) beat as Map<String, Object?>,
];

Uint8List _frame(Directory directory, int index) =>
    File('${directory.path}/${'$index'.padLeft(6, '0')}.raw').readAsBytesSync();

/// Whether anything within the cursor's own reach of a point is close to
/// white — which on this scenario's black screen means the cursor is there.
///
/// A box rather than a pixel, and a threshold rather than a colour: the mark's
/// radius, its ring width and its fill are a *look*, and a test that pinned
/// them would fail every time the look improved.
bool _bright(Uint8List frame, int width, int x, int y) {
  for (var dy = -26; dy <= 26; dy++) {
    for (var dx = -26; dx <= 26; dx++) {
      var at = ((y + dy) * width + (x + dx)) * 4;
      if (at < 0 || at + 2 >= frame.length) continue;
      if (frame[at] > 0xC0 && frame[at + 1] > 0xC0 && frame[at + 2] > 0xC0) {
        return true;
      }
    }
  }
  return false;
}

class _FormApp extends StatelessWidget {
  const _FormApp();

  @override
  Widget build(BuildContext context) => const MaterialApp(
    home: Scaffold(
      body: Padding(padding: EdgeInsets.all(40), child: TextField()),
    ),
  );
}

class _ScrollApp extends StatelessWidget {
  const _ScrollApp(this.controller);

  final ScrollController controller;

  @override
  Widget build(BuildContext context) => MaterialApp(
    home: Scaffold(
      body: ListView.builder(
        controller: controller,
        itemCount: 200,
        itemExtent: 60,
        itemBuilder: (context, index) => Text('Row $index'),
      ),
    ),
  );
}

class _App extends StatelessWidget {
  const _App();

  @override
  Widget build(BuildContext context) => MaterialApp(
    home: Scaffold(
      backgroundColor: Colors.black,
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextButton(onPressed: () {}, child: const Text('Fade in')),
            const SizedBox(height: 200),
          ],
        ),
      ),
    ),
  );
}

/// One moment, as the stage under test saw it.
class _Seen {
  _Seen(this.at, this.title);

  final Duration at;
  final String? title;
}

/// The bare stage, writing down what it was told.
class _WatchingStage extends ReelStage {
  _WatchingStage(this.seen);

  final List<_Seen> seen;

  @override
  Widget build(StageFrame frame) {
    seen.add(
      _Seen(frame.at, switch (frame.cue<ScenarioTitle>()?.cue) {
        ScenarioTitle(:var text) => text,
        _ => null,
      }),
    );
    return const Stack(children: [Screen(), Pointer()]);
  }
}

/// The average red channel of a raw RGBA frame — a cheap "how light is it".
int _meanRed(File frame) {
  var bytes = frame.readAsBytesSync();
  var total = 0;
  var count = 0;
  for (var i = 0; i < bytes.length; i += 4 * 64) {
    total += bytes[i];
    count++;
  }
  return total ~/ count;
}
