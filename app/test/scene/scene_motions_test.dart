// A scene is static first; motions are opened, made and undone as a set.
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutterware/scene.dart';
import 'package:flutterware/scene_authoring.dart';
import 'package:flutterware_app/src/scene/editor.dart';
import 'package:flutterware_app/src/scene/fixtures.dart';
import 'package:flutterware_app/src/scene/measure.dart';
import 'package:flutterware_app/src/scene/playback.dart';
import 'package:flutterware_app/src/scene/scene_file.dart';
import 'package:flutterware_app/src/scene/ui/timeline.dart';
import 'package:flutterware_app/src/scene/ui/workspace_view.dart';
import 'package:flutterware_app/src/ui/theme.dart';

void main() {
  test('a new motion is named after the scene, empty, and opened', () {
    var editor = SceneEditor(coffeeBannerDraft());
    expect(editor.activeMotion, isNull, reason: 'static first');
    var name = editor.addMotion('BannerScene');
    expect(name, 'BannerSceneMotion');
    expect(editor.motions[name]!.groups, isEmpty);
    expect(editor.activeMotion, name);
    expect(editor.addMotion('BannerScene'), 'BannerSceneMotion2');
    expect(
      () => editor.addMotion('BannerScene', name: name),
      throwsArgumentError,
    );
    expect(
      () => editor.addMotion('BannerScene', name: 'not valid'),
      throwsArgumentError,
    );
  });

  test('renaming a motion keeps its place, its content and the active one', () {
    var scene = coffeeBannerDraft();
    var editor = SceneEditor(
      scene,
      motions: {'BannerIntro': coffeeIntroDraft(scene)},
    );
    var second = editor.addMotion('BannerScene');
    editor.activeMotion = 'BannerIntro';
    var intro = editor.motions['BannerIntro']!;
    editor.renameMotion('BannerIntro', 'BannerReveal');
    expect(editor.motions.keys.toList(), ['BannerReveal', second]);
    expect(identical(editor.motions['BannerReveal'], intro), isTrue);
    expect(editor.activeMotion, 'BannerReveal');
    expect(
      () => editor.renameMotion('BannerReveal', second),
      throwsArgumentError,
    );
    expect(
      () => editor.renameMotion('BannerReveal', 'not valid'),
      throwsArgumentError,
    );
    editor.undo();
    expect(editor.motions.keys.toList(), ['BannerIntro', second]);
    expect(editor.motions['BannerIntro']!.groups, isNotEmpty);
    editor.redo();
    expect(editor.motions.keys.toList(), ['BannerReveal', second]);
  });

  test('renaming a group rewrites the timeline that places it', () {
    var scene = coffeeBannerDraft();
    var motion = coffeeIntroDraft(scene);
    var editor = SceneEditor(scene, motions: {'BannerIntro': motion});
    var before = motion.placements;
    editor.renameGroup('BannerIntro', 'headlineIn', 'headlineRise');
    expect(motion.groupNamed('headlineIn'), isNull);
    expect(motion.groupNamed('headlineRise')!.node.name, 'headline');
    var after = motion.placements;
    expect(after['headlineRise'], before['headlineIn']);
    expect(after.containsKey('headlineIn'), isFalse);
    expect(after.length, before.length, reason: 'no reference lost');
    expect(
      () => editor.renameGroup('BannerIntro', 'headlineRise', 'badgePop'),
      throwsArgumentError,
    );
    editor.undo();
    expect(motion.groupNamed('headlineIn'), isNotNull);
    expect(motion.placements['headlineIn'], before['headlineIn']);
  });

  test('adding and removing motions is undoable as a set', () {
    var scene = coffeeBannerDraft();
    var editor = SceneEditor(
      scene,
      motions: {'BannerIntro': coffeeIntroDraft(scene)},
    );
    var name = editor.addMotion('BannerScene');
    editor.addKey(
      name,
      editor.addGroup(name, editor.doc.nodeNamed('cup')!).name,
      'opacity',
      Duration.zero,
      value: 0.5,
    );
    editor.undo(); // the key
    editor.undo(); // the group
    editor.undo(); // the motion
    expect(editor.motions.keys, ['BannerIntro']);
    expect(editor.activeMotion, isNull);
    editor.redo();
    expect(editor.motions.keys, ['BannerIntro', name]);
    expect(editor.motions[name]!.sceneClassName, 'BannerScene');
    editor.redo();
    editor.redo();
    expect(
      editor.motions[name]!.groups.single.tracks['opacity']!.keys,
      hasLength(1),
    );

    editor.removeMotion('BannerIntro');
    expect(editor.motions.containsKey('BannerIntro'), isFalse);
    editor.undo();
    expect(
      editor.motions['BannerIntro']!.groups,
      hasLength(4),
      reason: 'revived whole',
    );
  });

  test('an empty motion and an empty scene both survive the grammar', () {
    var root = FrameNode(name: 'root')
      ..width = 200
      ..height = 64
      ..fill = const SceneColor(0xFFFFFFFF);
    var doc = SceneDocument(root);
    var source = emitSceneFile(
      doc,
      className: 'Badge',
      motions: {'BadgeMotion': MotionDocument(sceneClassName: 'Badge')},
    );
    var parsed = parseSceneFile(source);
    expect(parsed.ok, isTrue, reason: parsed.refusals.join('\n'));
    expect(parsed.className, 'Badge');
    expect(parsed.doc!.root.width, 200);
    expect(parsed.motions.keys, ['BadgeMotion']);
    expect(parsed.motions['BadgeMotion']!.groups, isEmpty);
    expect(
      emitSceneFile(parsed.doc!, className: 'Badge', motions: parsed.motions),
      source,
    );
  });

  testWidgets('the timeline opens on a picked motion and a new one', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    var doc = coffeeBannerDraft();
    var editor = SceneEditor(
      doc,
      motions: {'BannerIntro': coffeeIntroDraft(doc)},
    );
    await tester.pumpWidget(MaterialApp(theme: appTheme, home: _Host(editor)));
    await tester.pump();
    expect(find.byType(SceneTimeline), findsNothing, reason: 'static first');
    // Nothing open: the motion is a row in the tree's outline, and the
    // drawer header says where to go.
    expect(find.text('BannerIntro'), findsOneWidget);
    expect(find.textContaining('Open a motion or a parameter'), findsOneWidget);

    // One click opens it below.
    await tester.tap(find.text('BannerIntro'));
    await tester.pump();
    expect(editor.activeMotion, 'BannerIntro');
    expect(find.byType(SceneTimeline), findsOneWidget);
    // Named twice now: the tree row and the drawer header.
    expect(find.text('BannerIntro'), findsNWidgets(2));
    expect(find.text('1.80s · 4 groups'), findsOneWidget);

    await tester.tap(find.byTooltip('New motion'));
    await tester.pump();
    expect(editor.activeMotion, 'BannerSceneMotion');
    expect(find.text('BannerSceneMotion'), findsWidgets);
    expect(
      find.text('Nothing animates yet — select a node to animate it'),
      findsOneWidget,
    );

    // The chevron folds the timeline away and keeps the motion open: the
    // header still names it, the picture still plays it.
    await tester.tap(
      find.byTooltip('Fold the timeline away — the motion stays open'),
    );
    await tester.pump();
    expect(find.byType(SceneTimeline), findsNothing);
    expect(
      editor.activeMotion,
      'BannerSceneMotion',
      reason: 'folded, not closed',
    );
    expect(find.text('BannerSceneMotion'), findsWidgets);
    await tester.tap(find.byTooltip('Show the timeline'));
    await tester.pump();
    expect(find.byType(SceneTimeline), findsOneWidget);

    // The cross is leaving the motion: the scene is static again, recording
    // is off, nothing is open.
    editor.autoKey = true;
    await tester.tap(
      find.byTooltip('Close the motion — the scene as authored'),
    );
    await tester.pump();
    expect(find.byType(SceneTimeline), findsNothing);
    expect(editor.activeMotion, isNull, reason: 'closed, not folded');
    expect(editor.autoKey, isFalse);
    expect(find.byTooltip('Open a motion to see its timeline'), findsOneWidget);
  });
}

class _Host extends StatefulWidget {
  const _Host(this.editor);

  final SceneEditor editor;

  @override
  State<_Host> createState() => _HostState();
}

class _HostState extends State<_Host> with TickerProviderStateMixin {
  final _playbacks = <String, ScenePlayback>{};

  @override
  void dispose() {
    for (var p in _playbacks.values) {
      p.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Material(
    child: SceneWorkspaceView(
      widget.editor,
      sceneClassName: 'BannerScene',
      playbackFor: (m) => _playbacks.putIfAbsent(
        m,
        () => ScenePlayback(widget.editor, m, vsync: this),
      ),
      content: SceneView.document(
        widget.editor.doc,
        onMeasured: (r) => applyMeasuredRects(widget.editor.doc, r),
      ),
    ),
  );
}
