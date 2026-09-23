import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutterware/scene.dart';
import 'package:flutterware/scene_authoring.dart';
import 'package:flutterware_app/src/scene/fixtures.dart';
import 'package:flutterware_app/src/scene/editor.dart';
import 'package:flutterware_app/src/scene/playback.dart';
import 'package:flutterware_app/src/scene/ui/transport.dart';
import 'package:flutterware_app/src/scene/motion_file.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('the grammar and the runtime agree on the curve allowlist', () {
    expect(sceneCurvesByName.keys.toSet(), motionCurves.toSet());
  });

  group('track evaluation', () {
    var track = MotionTrack([
      MotionKey(at: Duration.zero, value: 0.0),
      MotionKey(
        at: const Duration(milliseconds: 400),
        value: 1.0,
        curve: SceneCurves.easeOut,
      ),
    ], kind: TrackKind.number);

    test('the hold rule at both edges', () {
      expect(track.evaluate(const Duration(milliseconds: -50)), 0.0);
      expect(track.evaluate(Duration.zero), 0.0);
      expect(track.evaluate(const Duration(milliseconds: 400)), 1.0);
      expect(track.evaluate(const Duration(seconds: 9)), 1.0);
    });

    test('the curve rides the arriving key', () {
      var mid = track.evaluate(const Duration(milliseconds: 200)) as double;
      expect(mid, Curves.easeOut.transform(0.5));
      expect(mid, isNot(0.5));
    });

    test('a color track lerps through SceneColor.lerp', () {
      var colors = MotionTrack([
        MotionKey(at: Duration.zero, value: const SceneColor(0xFF000000)),
        MotionKey(
          at: const Duration(milliseconds: 100),
          value: const SceneColor(0xFFFFFFFF),
        ),
      ], kind: TrackKind.color);
      var mid = colors.evaluate(const Duration(milliseconds: 50));
      expect(
        mid,
        SceneColor.lerp(
          const SceneColor(0xFF000000),
          const SceneColor(0xFFFFFFFF),
          0.5,
        ),
      );
    });

    test('an empty track refuses to evaluate', () {
      expect(
        () => MotionTrack([], kind: TrackKind.number).evaluate(Duration.zero),
        throwsStateError,
      );
    });
  });

  group('the fx plane composes over the live base', () {
    test(
      'operators: opacity multiplies, translate adds, fontSize replaces',
      () {
        var node = TextNode('hi', name: 't')..opacity = 0.8;
        Object writer1 = 'w1', writer2 = 'w2';
        node.writeFx(writer1, 'opacity', 0.5);
        node.writeFx(writer2, 'opacity', 0.5);
        expect(node.fxRendered('opacity'), closeTo(0.2, 1e-9));
        node.writeFx(writer1, 'translateY', 10.0);
        node.writeFx(writer2, 'translateY', -4.0);
        expect(node.fxRendered('translateY'), 6.0);
        node.writeFx(writer1, 'fontSize', 30.0);
        expect(node.fxRendered('fontSize'), 30.0);
      },
    );

    test('the base is read live: an authored mutation composes next read', () {
      var node = ShapeNode(name: 's')..opacity = 0.8;
      node.writeFx('m', 'opacity', 0.5);
      expect(node.fxRendered('opacity'), closeTo(0.4, 1e-9));
      node.opacity = 0.4; // the app retunes mid-flight
      expect(node.fxRendered('opacity'), closeTo(0.2, 1e-9));
    });

    test('effect handles are independent writers', () {
      var node = ShapeNode(name: 's');
      var hover = node.effect()..scale = 1.04;
      var press = node.effect()..scale = 0.96;
      node.writeFx('motion', 'scale', 1.2);
      expect(node.fxRendered('scale'), closeTo(1.2 * 1.04 * 0.96, 1e-9));
      press.clear();
      expect(node.fxRendered('scale'), closeTo(1.2 * 1.04, 1e-9));
      hover.scale = null;
      expect(node.fxRendered('scale'), closeTo(1.2, 1e-9));
    });

    test('a writer keeps its stack position through re-writes', () {
      var node = ShapeNode(name: 's');
      var a = node.effect()..opacity = 0.5;
      var b = node.effect()..opacity = 0.8;
      a.opacity = 0.6;
      expect(a.opacity, 0.6); // a handle reads back its own contribution
      expect(b.opacity, 0.8);
      expect(
        node.fx.keys.map(
          (k) => identical(k.$1, a)
              ? 'a'
              : identical(k.$1, b)
              ? 'b'
              : '?',
        ),
        ['a', 'b'],
      );
    });

    test('an ext node folds arg contributions into renderedArgs', () {
      var node = ExternalNode.read(
        'DrinkBadge',
        name: 'e',
        args: {'size': 140.0},
      );
      node.writeFx('m', 'args.size', 0.5);
      expect(node.renderedArgs, {'size': 0.5});
      expect(node.args, {'size': 140.0}); // authored untouched
    });
  });

  group('the bound pair', () {
    test('the coffee intro plays over the coffee banner', () {
      var scene = coffeeBannerDraft();
      var bound = BoundMotion.bind(coffeeIntroDraft(scene), scene);
      expect(bound.duration, const Duration(milliseconds: 1800));

      var headline = scene.nodeNamed('headline')!;
      var badge = scene.nodeNamed('badge')! as ExternalNode;
      var glow = scene.nodeNamed('glow')!;

      bound.apply(Duration.zero);
      expect(headline.fxRendered('opacity'), 0.0);
      expect(headline.fxRendered('translateY'), 24.0);
      // badgePop sits behind At(400.ms): its window has not opened.
      expect(badge.fxRendered('scale'), 0.6);

      bound.apply(const Duration(milliseconds: 130));
      expect(headline.fxRendered('opacity'), Curves.easeOut.transform(0.5));

      bound.apply(const Duration(milliseconds: 700));
      expect(headline.fxRendered('opacity'), 1.0);
      expect(badge.fxRendered('scale'), 1.0); // local 300, track ended at 240
      expect(badge.renderedArgs['size'], 140.0);

      bound.apply(const Duration(milliseconds: 900));
      // glow's authored opacity is 0.7; the mood dims it to 0.85 of that.
      expect(glow.fxRendered('opacity'), closeTo(0.7 * 0.85, 1e-9));

      // Backwards seek is pure.
      bound.apply(Duration.zero);
      expect(headline.fxRendered('opacity'), 0.0);

      // Cancel: fx drops, authored untouched.
      bound.clearFx();
      expect(headline.fx, isEmpty);
      expect(headline.fxRendered('opacity'), 1.0);
    });

    test('an unplaced group plays independently', () {
      var scene = coffeeBannerDraft();
      var bound = BoundMotion.bind(coffeeIntroDraft(scene), scene);
      var cta = scene.nodeNamed('cta')!;
      var headline = scene.nodeNamed('headline')!;

      bound.group('tapPulse').apply(const Duration(milliseconds: 120));
      expect(cta.fxRendered('scale'), 1.06);
      expect(headline.fx, isEmpty); // the timeline never played

      // And the timeline never plays the asset: apply leaves it at its
      // last written value only because we wrote it ourselves.
      expect(() => bound.group('ghost'), throwsArgumentError);
    });

    test('a playable remembers where it was last applied', () {
      var scene = coffeeBannerDraft();
      var bound = BoundMotion.bind(coffeeIntroDraft(scene), scene);
      expect(bound.position, Duration.zero);
      var heard = 0;
      bound.clock.addListener(() => heard++);
      bound.apply(const Duration(milliseconds: 250));
      expect(bound.position, const Duration(milliseconds: 250));
      bound.apply(const Duration(milliseconds: 250));
      expect(heard, 1); // the same time again is not news
    });

    test('binding against a scene missing the target refuses, named', () {
      // The motion is authored against one scene and bound against another,
      // which is the mistake: a group holds a node, and this one's node is
      // in a document nobody is drawing.
      var motion = coffeeIntroDraft();
      var scene = SceneDocument(FrameNode(name: 'root'));
      expect(
        () => BoundMotion.bind(motion, scene),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('"headline"'),
          ),
        ),
      );
    });
  });

  group('combinators are pure time transforms', () {
    (SceneDocument, MotionDocument) pair(
      TimelineExpr Function(AnimateGroup a, AnimateGroup b) timeline,
    ) {
      var scene = coffeeBannerDraft();
      var doc = MotionDocument(sceneClassName: 'BannerScene');
      var a = AnimateGroup(scene.nodeNamed('glow')!, name: 'a');
      a.tracks['opacity'] = MotionTrack([
        MotionKey(at: Duration.zero, value: 0.0),
        MotionKey(at: const Duration(milliseconds: 200), value: 1.0),
      ], kind: TrackKind.number);
      var b = AnimateGroup(scene.nodeNamed('cup')!, name: 'b');
      b.tracks['opacity'] = MotionTrack([
        MotionKey(at: Duration.zero, value: 1.0),
        MotionKey(at: const Duration(milliseconds: 300), value: 0.0),
      ], kind: TrackKind.number);
      doc.groups.addAll([a, b]);
      doc.timeline = timeline(a, b);
      return (scene, doc);
    }

    test('Seq: the second child waits, holding its start', () {
      var (scene, doc) = pair((a, b) => SeqExpr([a, b]));
      var bound = BoundMotion.bind(doc, scene);
      expect(bound.duration, const Duration(milliseconds: 500));
      var cup = scene.nodeNamed('cup')!;
      bound.apply(const Duration(milliseconds: 100));
      expect(cup.fxRendered('opacity'), 1.0); // held at its start
      bound.apply(const Duration(milliseconds: 350));
      expect(cup.fxRendered('opacity'), closeTo(0.5, 1e-9));
    });

    test("a child's clock is its own time, not the parent's", () {
      const offset = Duration(milliseconds: 100);
      var (scene, doc) = pair((a, b) => ParExpr([a, AtExpr(offset, b)]));
      var bound = BoundMotion.bind(doc, scene);
      const parentTime = Duration(milliseconds: 250);
      bound.apply(parentTime);
      expect(bound.position, parentTime);
      expect(bound.group('b').position, parentTime - offset);
    });

    test('Speed halves or doubles the clock', () {
      var (scene, doc) = pair((a, b) => ParExpr([SpeedExpr(2, a), b]));
      var bound = BoundMotion.bind(doc, scene);
      var glow = scene.nodeNamed('glow')!;
      bound.apply(const Duration(milliseconds: 50));
      // 50ms at 2x is local 100 of 200 — and the contribution composes
      // over glow's authored 0.7.
      expect(glow.fxRendered('opacity'), closeTo(0.7 * 0.5, 1e-9));
    });

    test('Repeat cycles, and its last frame holds the end', () {
      var (scene, doc) = pair((a, b) => RepeatExpr(3, a));
      var bound = BoundMotion.bind(doc, scene);
      expect(bound.duration, const Duration(milliseconds: 600));
      var glow = scene.nodeNamed('glow')!;
      bound.apply(const Duration(milliseconds: 300)); // cycle 2, local 100
      expect(glow.fxRendered('opacity'), closeTo(0.7 * 0.5, 1e-9));
      bound.apply(const Duration(milliseconds: 600)); // the very end
      expect(glow.fxRendered('opacity'), closeTo(0.7 * 1.0, 1e-9));
    });
  });

  group('the player', () {
    (SceneDocument, BoundMotion) shortPair() {
      var scene = coffeeBannerDraft();
      var doc = MotionDocument(sceneClassName: 'BannerScene');
      var g = AnimateGroup(scene.nodeNamed('glow')!, name: 'g');
      g.tracks['translateY'] = MotionTrack([
        MotionKey(at: Duration.zero, value: 0.0),
        MotionKey(at: const Duration(milliseconds: 200), value: 100.0),
      ], kind: TrackKind.number);
      doc.groups.add(g);
      doc.timeline = ParExpr([g]);
      return (scene, BoundMotion.bind(doc, scene));
    }

    testWidgets('play ticks, applies, and stops itself at the end', (
      tester,
    ) async {
      var (scene, bound) = shortPair();
      var glow = scene.nodeNamed('glow')!;
      var player = MotionPlayer.bound(bound, vsync: null);
      player.play();
      expect(player.status, MotionPlayerStatus.playing);
      await tester.pump(); // the ticker's first tick stamps its start time
      await tester.pump(const Duration(milliseconds: 100));
      expect(glow.fxRendered('translateY'), 50.0);
      await tester.pump(const Duration(milliseconds: 150));
      expect(player.status, MotionPlayerStatus.completed);
      expect(player.position, const Duration(milliseconds: 200));
      expect(glow.fxRendered('translateY'), 100.0);
      // Completed: the picture holds, the authored value was never touched.
      expect(glow.y, -110.0);
      player.dispose();
    });

    testWidgets('rate is the player knob: 2x finishes in half the time', (
      tester,
    ) async {
      var (_, bound) = shortPair();
      var player = MotionPlayer.bound(bound, vsync: null)..rate = 2;
      player.play();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 110));
      expect(player.status, MotionPlayerStatus.completed);
      player.dispose();
    });

    testWidgets('pause holds, seek is pure in any direction', (tester) async {
      var (scene, bound) = shortPair();
      var glow = scene.nodeNamed('glow')!;
      var player = MotionPlayer.bound(bound, vsync: null);
      player.play();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      player.pause();
      await tester.pump(const Duration(milliseconds: 500));
      expect(player.position, const Duration(milliseconds: 100));
      expect(glow.fxRendered('translateY'), 50.0);
      player.position = const Duration(milliseconds: 40);
      expect(glow.fxRendered('translateY'), 20.0);
      player.dispose();
    });

    testWidgets('stop is cancel: fx drops, base untouched', (tester) async {
      var (scene, bound) = shortPair();
      var glow = scene.nodeNamed('glow')!;
      var player = MotionPlayer.bound(bound, vsync: null);
      player.play();
      await tester.pump(const Duration(milliseconds: 100));
      player.stop();
      expect(glow.fx, isEmpty);
      expect(glow.fxRendered('translateY'), 0.0);
      expect(player.status, MotionPlayerStatus.idle);
      player.dispose();
    });

    testWidgets('one driver at a time, refused with a teaching message', (
      tester,
    ) async {
      var (_, bound) = shortPair();
      var first = MotionPlayer.bound(bound, vsync: null)..play();
      var second = MotionPlayer.bound(bound, vsync: null);
      expect(second.play, throwsStateError);
      first.dispose();
      // Released on stop: now the second may drive.
      second.play();
      second.dispose();
    });

    testWidgets('the wire carries the rendered picture', (tester) async {
      var scene = coffeeBannerDraft();
      var bound = BoundMotion.bind(coffeeIntroDraft(scene), scene);
      bound.apply(const Duration(milliseconds: 130));
      var root = scene.toWire()['root'] as Map<String, dynamic>;
      var copy = (root['children'] as List)[2] as Map<String, dynamic>;
      var headline = (copy['children'] as List)[0] as Map<String, dynamic>;
      expect(headline['opacity'], Curves.easeOut.transform(0.5));
      var fx = headline['fx'] as List;
      expect(fx[1], isNot(0)); // translateY mid-slide
      expect(fx[2], 1); // scale untouched
      var badge = (root['children'] as List)[3] as Map<String, dynamic>;
      // badgePop sits behind At(400.ms): its window has not opened, so the
      // arg holds its first key.
      expect(badge['args'], containsPair('size', 110.0));
      bound.apply(const Duration(milliseconds: 550));
      var later = scene.toWire()['root'] as Map<String, dynamic>;
      var badge2 = (later['children'] as List)[3] as Map<String, dynamic>;
      expect(badge2['args'], containsPair('size', 125.0));
      // Cancel: the wire returns to the authored picture, no fx field — and
      // an authored opacity of 1 is the default, which the picture omits.
      bound.clearFx();
      var again = scene.toWire()['root'] as Map<String, dynamic>;
      var headline2 =
          ((((again['children'] as List)[2] as Map)['children'] as List)[0])
              as Map<String, dynamic>;
      expect(headline2['opacity'] ?? 1.0, 1.0);
      expect(headline2.containsKey('fx'), isFalse);
    });

    testWidgets('SceneView draws the rendered plane', (tester) async {
      var scene = coffeeBannerDraft();
      var headline = scene.nodeNamed('headline')!;
      headline.writeFx('m', 'opacity', 0.25);
      headline.writeFx('m', 'translateY', 12.0);
      await tester.pumpWidget(
        MaterialApp(
          home: SizedBox(
            width: 1024,
            height: 500,
            child: SceneView.document(scene),
          ),
        ),
      );
      var text = find.text('Fresh coffee, faster');
      var fade = tester.widget<Opacity>(
        find.ancestor(of: text, matching: find.byType(Opacity)).first,
      );
      expect(fade.opacity, 0.25);
      var moved = tester.widget<Transform>(
        find.ancestor(of: text, matching: find.byType(Transform)).first,
      );
      expect(moved.transform.getTranslation().y, 12.0);
    });

    testWidgets('the transport plays the pair end to end', (tester) async {
      var scene = coffeeBannerDraft();
      var headline = scene.nodeNamed('headline')!;
      var editor = SceneEditor(
        scene,
        motions: {'BannerIntro': coffeeIntroDraft(scene)},
      );
      await tester.pumpWidget(
        MaterialApp(home: Scaffold(body: _TransportHost(editor))),
      );
      await tester.tap(find.byTooltip('Play'));
      await tester.pump(); // the ticker's first tick stamps its start time
      await tester.pump(const Duration(milliseconds: 130));
      expect(headline.fxRendered('opacity'), Curves.easeOut.transform(0.5));
      await tester.tap(find.byTooltip('Pause'));
      await tester.pump(const Duration(seconds: 1));
      expect(headline.fxRendered('opacity'), Curves.easeOut.transform(0.5));
      await tester.tap(find.byIcon(Icons.stop));
      await tester.pump();
      expect(headline.fx, isEmpty);
      expect(headline.fxRendered('opacity'), 1.0);
    });

    testWidgets('a parked seek repaints SceneView with the parked frame', (
      tester,
    ) async {
      // A seek AFTER completion must rebuild the picture: the flush rides
      // notifyListeners, and SceneView listens to the document.
      var scene = coffeeBannerDraft();
      var editor = SceneEditor(
        scene,
        motions: {'BannerIntro': coffeeIntroDraft(scene)},
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Column(
              children: [
                _TransportHost(editor),
                Expanded(child: FittedBox(child: SceneView.document(scene))),
              ],
            ),
          ),
        ),
      );
      await tester.tap(find.byTooltip('Play'));
      await tester.pump();
      await tester.pump(const Duration(seconds: 2)); // runs to completion
      await tester.pump(const Duration(milliseconds: 50));
      var opacities = tester
          .widgetList<Opacity>(find.byType(Opacity))
          .map((o) => o.opacity);
      expect(opacities, isNot(contains(0.0))); // end pose: identity fx

      tester
          .state<_TransportHostState>(find.byType(_TransportHost))
          .playback
          .seek(Duration.zero);
      await tester.pump(); // the flush's post-frame notify
      await tester.pump(); // the rebuild it schedules
      opacities = tester
          .widgetList<Opacity>(find.byType(Opacity))
          .map((o) => o.opacity);
      expect(opacities, contains(0.0)); // headline at t=0 is invisible
    });

    testWidgets('a burst of fx writes is one notification', (tester) async {
      var (scene, bound) = shortPair();
      var notifications = 0;
      scene.addListener(() => notifications++);
      for (var i = 0; i < 500; i++) {
        bound.apply(Duration(milliseconds: i % 200));
      }
      expect(notifications, 0); // nothing until the frame
      await tester.pump();
      expect(notifications, 1);
    });
  });
}

class _TransportHost extends StatefulWidget {
  const _TransportHost(this.editor);

  final SceneEditor editor;

  @override
  State<_TransportHost> createState() => _TransportHostState();
}

class _TransportHostState extends State<_TransportHost>
    with TickerProviderStateMixin {
  late final playback = ScenePlayback(
    widget.editor,
    'BannerIntro',
    vsync: this,
  );

  @override
  void dispose() {
    playback.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => SceneTransport(playback);
}
