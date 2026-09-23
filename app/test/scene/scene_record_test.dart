// Recording: the playhead parks anywhere, and while recording an edit is a
// key there rather than a change to the node.
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutterware/scene.dart';
import 'package:flutterware/scene_authoring.dart';
import 'package:flutterware_app/src/scene/editor.dart';
import 'package:flutterware_app/src/scene/fixtures.dart';
import 'package:flutterware_app/src/scene/playback.dart';
import 'package:flutterware_app/src/scene/ui/inspector.dart';
import 'package:flutterware_app/src/ui/theme.dart';

void main() {
  test('the player parks past the end, at the end pose', () {
    var scene = coffeeBannerDraft();
    var bound = BoundMotion.bind(coffeeIntroDraft(scene), scene);
    var player = MotionPlayer.bound(bound, vsync: null);
    var seen = <Duration>[];
    player.addListener(() => seen.add(player.position));
    player.position = const Duration(seconds: 5);
    expect(player.position, const Duration(seconds: 5));
    expect(scene.nodeNamed('headline')!.fxRendered('opacity'), 1.0);
    expect(seen, [const Duration(seconds: 5)]);
    player.dispose();
  });

  testWidgets('a stopped motion stays off the picture', (tester) async {
    var scene = coffeeBannerDraft();
    var editor = SceneEditor(
      scene,
      motions: {'BannerIntro': coffeeIntroDraft(scene)},
    );
    var playback = ScenePlayback(editor, 'BannerIntro', vsync: tester);
    addTearDown(playback.dispose);
    var headline = scene.nodeNamed('headline')!;
    // The first key is 0 where the node itself is opaque: the difference
    // between the motion being on the picture and off it.
    expect(headline.opacity, 1.0);
    playback.seek(Duration.zero);
    expect(headline.fxRendered('opacity'), 0.0);
    expect(playback.isApplied, isTrue, reason: 'parked at zero is applied');

    playback.stop();
    expect(
      headline.fxRendered('opacity'),
      1.0,
      reason: 'the scene as authored',
    );
    expect(playback.isApplied, isFalse);

    // Hovering a node notifies the editor, as does closing the motion —
    // neither may put the pose back.
    editor.hover = 'cup';
    editor.activeMotion = null;
    editor.select(scene.nodeNamed('cup'));
    expect(headline.fxRendered('opacity'), 1.0);

    // Editing a key while stopped leaves the picture alone; reopening the
    // motion puts it back on.
    editor.setKeyValue(
      MotionKeyRef(
        'BannerIntro',
        'headlineIn',
        'opacity',
        editor.motions['BannerIntro']!
            .groupNamed('headlineIn')!
            .tracks['opacity']!
            .keys
            .first
            .id,
      ),
      0.25,
    );
    expect(headline.fxRendered('opacity'), 1.0);
    playback.apply();
    expect(headline.fxRendered('opacity'), 0.25);
  });

  test('recording puts an edit on a key at the playhead', () {
    var scene = coffeeBannerDraft();
    var editor = SceneEditor(
      scene,
      motions: {'BannerIntro': coffeeIntroDraft(scene)},
    );
    var cup = editor.doc.nodeNamed('cup')!;
    expect(editor.recordKey(cup, 'opacity', 0.5), isFalse, reason: 'off');
    editor
      ..activeMotion = 'BannerIntro'
      ..autoKey = true
      ..playhead = const Duration(milliseconds: 700);
    expect(editor.records(cup, 'opacity'), isTrue);
    expect(editor.records(cup, 'x'), isFalse, reason: 'x is not animatable');
    expect(editor.recordKey(cup, 'opacity', 0.5), isTrue);
    var group = editor.groupsTargeting('BannerIntro', cup).single;
    var key = group.tracks['opacity']!.keys.single;
    expect((key.at, key.value), (const Duration(milliseconds: 700), 0.5));
    expect(cup.opacity, 1.0, reason: 'the node itself is untouched');
    // A nudge while recording travels: translate keys, not x/y.
    editor.select(cup);
    editor.nudgeSelection(10, -4, mergeKey: 'drag');
    editor.nudgeSelection(10, -4, mergeKey: 'drag');
    editor.endMerge();
    expect(group.tracks['translateX']!.keys.single.value, 20.0);
    expect(group.tracks['translateY']!.keys.single.value, -8.0);
    expect((cup.x, cup.y), (690.0, 110.0));
  });

  testWidgets('an inspector field records while the red dot is on', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    var scene = coffeeBannerDraft();
    var editor = SceneEditor(
      scene,
      motions: {'BannerIntro': coffeeIntroDraft(scene)},
    );
    var glow = editor.doc.nodeNamed('glow')!;
    editor
      ..select(glow)
      ..activeMotion = 'BannerIntro'
      ..autoKey = true
      ..playhead = const Duration(milliseconds: 900);
    await tester.pumpWidget(
      MaterialApp(
        theme: appTheme,
        home: Material(child: SceneInspector(editor)),
      ),
    );
    // The opacity slider: drag it down.
    var slider = find.byType(Slider);
    expect(slider, findsOneWidget);
    await tester.drag(slider, const Offset(-60, 0));
    await tester.pump();
    var track = editor
        .groupsTargeting('BannerIntro', glow)
        .single
        .tracks['opacity']!;
    // glowMood already keys opacity at 900ms: the edit moved that key.
    var key = track.keys.firstWhere(
      (k) => k.at == const Duration(milliseconds: 900),
    );
    expect(key.value, lessThan(0.85));
    expect(glow.opacity, 0.7, reason: 'the authored value is untouched');
  });
}
