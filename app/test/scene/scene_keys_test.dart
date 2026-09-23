// Authoring keys: creating them seeds from what the track already says,
// groups are born placed, and a group moves as one.
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutterware/scene_authoring.dart';
import 'package:flutterware_app/src/scene/editor.dart';
import 'package:flutterware_app/src/scene/fixtures.dart';
import 'package:flutterware_app/src/scene/playback.dart';

void main() {
  late SceneEditor editor;
  late MotionDocument motion;
  const m = 'BannerIntro';

  setUp(() {
    var scene = coffeeBannerDraft();
    motion = coffeeIntroDraft(scene);
    editor = SceneEditor(scene, motions: {m: motion});
  });

  test('a key on an existing track takes the value evaluated there', () {
    var ref = editor.addKey(
      m,
      'headlineIn',
      'opacity',
      const Duration(milliseconds: 130),
    );
    var key = editor.keyOf(ref)!;
    expect(key.at, const Duration(milliseconds: 130));
    expect(
      key.value,
      closeTo(sceneCurvesByName['easeOut']!.transform(0.5), 1e-9),
    );
    expect(
      motion.groupNamed('headlineIn')!.tracks['opacity']!.keys,
      hasLength(3),
    );
    expect(editor.selectedKeys.single, ref);
    expect(editor.undoLabel, 'Add key');
    editor.undo();
    expect(
      motion.groupNamed('headlineIn')!.tracks['opacity']!.keys,
      hasLength(2),
    );
  });

  test('a key on a new track starts from what the node shows', () {
    var ref = editor.addKey(m, 'headlineIn', 'fontSize', Duration.zero);
    expect(editor.keyOf(ref)!.value, 54.0);
    expect(motion.groupNamed('headlineIn')!.tracks['fontSize'], isNotNull);
  });

  test('a key within a millisecond of another moves that one', () {
    var before = motion
        .groupNamed('headlineIn')!
        .tracks['opacity']!
        .keys
        .length;
    var ref = editor.addKey(
      m,
      'headlineIn',
      'opacity',
      const Duration(milliseconds: 260),
      value: 0.4,
    );
    expect(
      motion.groupNamed('headlineIn')!.tracks['opacity']!.keys,
      hasLength(before),
    );
    expect(editor.keyOf(ref)!.value, 0.4);
  });

  test('a group is born on the timeline and animates its node', () {
    var cup = editor.doc.nodeNamed('cup')!;
    var group = editor.addGroup(m, cup, at: const Duration(milliseconds: 300));
    expect(group.name, 'cupMotion');
    expect(motion.placements[group.name], const Duration(milliseconds: 300));
    expect(editor.groupsTargeting(m, cup).single, same(group));
    var again = editor.addGroup(m, cup);
    expect(again.name, 'cupMotion2');
    expect(motion.placements[again.name], Duration.zero);
  });

  test('value, curve and time edit through the journal', () {
    var track = motion.groupNamed('headlineIn')!.tracks['opacity']!;
    var ref = MotionKeyRef(m, 'headlineIn', 'opacity', track.keys[1].id);
    editor.setKeyValue(ref, 0.5, mergeKey: 'scrub');
    editor.setKeyValue(ref, 0.6, mergeKey: 'scrub');
    editor.endMerge();
    editor.setKeyCurve([ref], SceneCurves.bounceOut);
    editor.setKeyTime(ref, const Duration(milliseconds: 100));
    var key = editor.keyOf(ref)!;
    expect(
      (key.value, key.curve, key.at),
      (0.6, SceneCurves.bounceOut, const Duration(milliseconds: 100)),
    );
    editor.undo();
    editor.undo();
    editor.undo();
    key = editor.keyOf(ref)!;
    expect(
      (key.value, key.curve, key.at),
      (1.0, SceneCurves.easeOut, const Duration(milliseconds: 260)),
    );
  });

  test('a group moves as one, and only from the top level', () {
    editor.moveGroup(m, 'headlineIn', const Duration(milliseconds: 200));
    expect(motion.placements['headlineIn'], const Duration(milliseconds: 200));
    editor.moveGroup(m, 'badgePop', Duration.zero);
    expect(motion.placements['badgePop'], Duration.zero);
    expect(motion.timeline, isA<ParExpr>());
    motion.timeline = SeqExpr([
      motion.groupNamed('headlineIn')!,
      motion.groupNamed('badgePop')!,
    ]);
    expect(
      () => editor.moveGroup(m, 'badgePop', Duration.zero),
      throwsArgumentError,
    );
  });

  test('moving a group the timeline never placed places it', () {
    expect(motion.placements.containsKey('tapPulse'), isFalse);
    editor.moveGroup(m, 'tapPulse', const Duration(milliseconds: 500));
    expect(motion.placements['tapPulse'], const Duration(milliseconds: 500));
    editor.undo();
    expect(motion.placements.containsKey('tapPulse'), isFalse);
  });

  testWidgets('playback rebinds when the motion grows a group', (tester) async {
    late ScenePlayback playback;
    await tester.pumpWidget(_Host(editor, (p) => playback = p));
    var cup = editor.doc.nodeNamed('cup')!;
    var group = editor.addGroup(m, cup);
    editor.addKey(m, group.name, 'opacity', Duration.zero, value: 0.2);
    editor.addKey(
      m,
      group.name,
      'opacity',
      const Duration(milliseconds: 400),
      value: 1.0,
    );
    playback.seek(Duration.zero);
    expect(cup.fxRendered('opacity'), 0.2, reason: 'the new group is bound');
    editor.undo();
    editor.undo();
    editor.undo();
    playback.seek(Duration.zero);
    expect(cup.fxRendered('opacity'), 1.0, reason: 'and unbound with the undo');
  });
}

class _Host extends StatefulWidget {
  const _Host(this.editor, this.onPlayback);

  final SceneEditor editor;
  final ValueChanged<ScenePlayback> onPlayback;

  @override
  State<_Host> createState() => _HostState();
}

class _HostState extends State<_Host> with TickerProviderStateMixin {
  late final playback = ScenePlayback(
    widget.editor,
    'BannerIntro',
    vsync: this,
  );

  @override
  void initState() {
    super.initState();
    widget.onPlayback(playback);
  }

  @override
  void dispose() {
    playback.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => const SizedBox();
}
