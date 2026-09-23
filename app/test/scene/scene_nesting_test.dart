// A nested scene: one node standing for another scene file, drawn as that
// scene with the parent's overrides on its parameters, edited in its own
// file. The parent never addresses the child's internals.
import 'dart:convert';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutterware/scene.dart';
import 'package:flutterware/scene_authoring.dart';
import 'package:flutterware_app/src/scene/editor.dart';
import 'package:flutterware_app/src/scene/fixtures.dart';
import 'package:flutterware_app/src/scene/scene_file.dart';
import 'package:flutterware_app/src/scene/workspace.dart';

/// A badge scene with two parameters: the word and the tint.
SceneDocument badgeTemplate() {
  var text = TextNode('New', name: 'text')
    ..fontSize = 14
    ..weight = SceneFontWeight.w700
    ..color = const SceneColor(0xFFFFFFFF)
    ..bindings['text'] = const ParamRef('label');
  var root = FrameNode(name: 'root', layout: NodeLayout.row)
    ..width = 140
    ..height = 32
    ..fill = const SceneColor(0xFFE8632B)
    ..corner = 16
    ..bindings['fill'] = const ParamRef('tint')
    ..children.add(text);
  return SceneDocument(root)
    ..params.addAll([
      SceneParamDecl('label', SceneParamKind.string, 'New'),
      SceneParamDecl(
        'tint',
        SceneParamKind.color,
        const SceneColor(0xFFE8632B),
      ),
    ]);
}

SceneDocument bannerWithBadge() {
  var scene = coffeeBannerDraft();
  scene.root.children.add(
    SceneRefNode.read('PromoBadge', name: 'promo', args: {'label': 'Now open'})
      ..x = 64
      ..y = 48,
  );
  return scene;
}

void main() {
  test('an instance is the template with the args applied', () {
    var inst = instantiateScene(badgeTemplate(), {'label': 'Now open'});
    expect((inst.nodeNamed('text')! as TextNode).text, 'Now open');
    expect(inst.root.fill, const SceneColor(0xFFE8632B), reason: 'default');
    expect(inst.params, hasLength(2), reason: 'it can take new args later');
  });

  test('syncInstance puts every parameter back, not only the overridden', () {
    var ref = SceneRefNode.read(
      'PromoBadge',
      name: 'promo',
      args: {'label': 'Hi'},
    )..instance = instantiateScene(badgeTemplate(), {'label': 'Hi'});
    ref.writeFx('m', 'args.tint', const SceneColor(0xFF00FF00));
    ref.syncInstance();
    expect(ref.instance!.root.fill, const SceneColor(0xFF00FF00));
    ref.clearFxWriter('m');
    ref.syncInstance();
    expect(ref.instance!.root.fill, const SceneColor(0xFFE8632B));
    expect((ref.instance!.nodeNamed('text')! as TextNode).text, 'Hi');
  });

  test('only number and color parameters animate', () {
    var ref = SceneRefNode.read('PromoBadge', name: 'promo')
      ..instance = instantiateScene(badgeTemplate(), const {});
    var props = animatableProps(ref).map((p) => p.name).toList();
    expect(props, contains('opacity'));
    expect(props, contains('args.tint'));
    expect(props, isNot(contains('args.label')));
    expect(
      animatableProps(SceneRefNode.read('Y', name: 'x')).map((p) => p.name),
      isNot(contains(startsWith('args.'))),
      reason: 'unresolved: imposed only',
    );
  });

  test('the authored JSON round-trips the reference, not the instance', () {
    var scene = bannerWithBadge();
    var back = sceneFromJson(
      jsonDecode(jsonEncode(scene.toJson())) as Map<String, Object?>,
    );
    var promo = back.nodeNamed('promo')! as SceneRefNode;
    expect(promo.sceneClassName, 'PromoBadge');
    expect(promo.args, {'label': 'Now open'});
    expect(promo.instance, isNull);
  });

  test('the grammar spells a nested scene as SceneRefNode with a class', () {
    var scene = bannerWithBadge();
    (scene.nodeNamed('promo')! as SceneRefNode).args['tint'] = const SceneColor(
      0xFF3E7C4F,
    );
    var source = emitSceneFile(scene, className: 'BannerScene');
    // dart_style decides the line breaks; the words are what is asserted.
    expect(
      source.replaceAll(RegExp(r'\s+'), ''),
      contains(
        "SceneRefNode(constPromoBadgeArgs(label:'Nowopen',"
        'tint:SceneColor(0xFF3E7C4F)),x:64,y:48,)',
      ),
    );
    var parsed = parseSceneFile(source);
    expect(parsed.ok, isTrue, reason: parsed.refusals.join('\n'));
    var promo = parsed.doc!.nodeNamed('promo')! as SceneRefNode;
    expect(promo.sceneClassName, 'PromoBadge');
    expect(promo.args['label'], 'Now open');
    expect(promo.args['tint'], const SceneColor(0xFF3E7C4F));
    expect(emitSceneFile(parsed.doc!, className: 'BannerScene'), source);
  });

  test('a Scene with no class name is refused with a line', () {
    var source = emitSceneFile(coffeeBannerDraft(), className: 'B').replaceFirst(
      'late final glow = ShapeNode(',
      'late final promo = SceneRefNode(x: 1);\n  late final glow = ShapeNode(',
    );
    var parsed = parseSceneFile(source);
    expect(parsed.ok, isFalse);
    // The orphaned field is refused too; the one about the name teaches.
    expect(
      parsed.refusals.map((r) => r.message),
      anyElement(contains('SceneRefNode(const PromoBadgeArgs(')),
    );
  });

  test('the wire inlines the instance under the ref, names prefixed', () {
    var scene = bannerWithBadge();
    var promo = scene.nodeNamed('promo')! as SceneRefNode
      ..instance = instantiateScene(badgeTemplate(), {'label': 'Now open'});
    promo.effect().opacity = 0.5;
    var wire = jsonDecode(jsonEncode(scene.toWire())) as Map<String, Object?>;
    var back = sceneFromWire((wire['root']! as Map).cast<String, Object?>());
    var drawn = back.nodeNamed('promo')! as FrameNode;
    expect(drawn.x, 64);
    expect(drawn.width, 140, reason: 'hugs the child root');
    expect(drawn.fill, const SceneColor(0xFFE8632B));
    expect(drawn.opacity, closeTo(0.5, 1e-9));
    expect(back.nodeNamed('promo/text'), isA<TextNode>());
    expect((back.nodeNamed('promo/text')! as TextNode).text, 'Now open');
    expect(back.nodeNamed('text'), isNull, reason: 'internals never collide');
  });

  test('an unresolved ref is an empty frame on the wire', () {
    var scene = bannerWithBadge();
    var wire = jsonDecode(jsonEncode(scene.toWire())) as Map<String, Object?>;
    var back = sceneFromWire((wire['root']! as Map).cast<String, Object?>());
    expect(back.nodeNamed('promo'), isA<FrameNode>());
    expect(back.nodeNamed('promo')!.children, isEmpty);
  });

  test('duplicate and undo keep the kind, the class and an instance', () {
    var scene = bannerWithBadge();
    var editor = SceneEditor(scene);
    (scene.nodeNamed('promo')! as SceneRefNode).instance = instantiateScene(
      badgeTemplate(),
      {'label': 'Now open'},
    );
    editor.select(scene.nodeNamed('promo'));
    editor.duplicateSelection();
    var copy = scene.nodeNamed('promo1')! as SceneRefNode;
    expect(copy.sceneClassName, 'PromoBadge');
    expect(copy.instance, isNotNull);
    expect(
      identical(
        copy.instance,
        (scene.nodeNamed('promo')! as SceneRefNode).instance,
      ),
      isFalse,
    );
    editor.perform('Rename label', () => copy.args['label'] = 'Later');
    editor.undo();
    expect(copy.args['label'], 'Now open');
    expect(scene.nodeNamed('promo1'), same(copy), reason: 'revived in place');
  });

  group('workspace', () {
    SceneFile badgeFile() => SceneFile(
      path: '/demo/promo_badge.scene.dart',
      className: 'PromoBadge',
      scene: badgeTemplate(),
    );
    SceneFile bannerFile() => SceneFile(
      path: '/demo/banner.scene.dart',
      className: 'BannerScene',
      scene: bannerWithBadge(),
    );

    test('opening resolves every reference into an instance', () {
      var badge = badgeFile();
      var workspace = SceneWorkspace(
        bannerFile(),
        resolveNested: (node) =>
            node is SceneRefNode && node.sceneClassName == 'PromoBadge'
            ? badge
            : null,
      );
      var promo = workspace.active.scene.nodeNamed('promo')! as SceneRefNode;
      expect(promo.instance, isNotNull);
      expect((promo.instance!.nodeNamed('text')! as TextNode).text, 'Now open');
    });

    test('an edit inside the child redraws the parent on the way out', () {
      var badge = badgeFile();
      var workspace = SceneWorkspace(
        bannerFile(),
        resolveNested: (node) => node is SceneRefNode ? badge : null,
      );
      var promo = workspace.active.scene.nodeNamed('promo')! as SceneRefNode;
      expect(promo.instance!.root.corner, 16);
      workspace.enter(promo);
      expect(workspace.active, same(badge));
      badge.editor.perform('Square it', () => badge.scene.root.corner = 0);
      workspace.exit();
      expect(promo.instance!.root.corner, 0);
      expect(promo.instance!.nodeNamed('text'), isNotNull);
      expect(
        (promo.instance!.nodeNamed('text')! as TextNode).text,
        'Now open',
        reason: 'the override survives the refresh',
      );
      expect(workspace.editor.selectionNames, ['promo']);
    });

    test('the resolver may hand out a fresh file; the open one wins', () {
      var opened = 0;
      var workspace = SceneWorkspace(
        bannerFile(),
        resolveNested: (node) {
          opened++;
          return node is SceneRefNode ? badgeFile() : null;
        },
      );
      var promo = workspace.active.scene.nodeNamed('promo')! as SceneRefNode;
      workspace.enter(promo);
      var child = workspace.active;
      child.editor.perform('Edit', () => child.scene.root.corner = 0);
      workspace.exit();
      workspace.enter(promo);
      expect(workspace.active, same(child), reason: 'not a second copy');
      expect(workspace.active.isDirty, isTrue);
      expect(opened, greaterThan(1), reason: 'the resolver was asked again');
    });
  });

  testWidgets('SceneView draws the instance inside the ref, keys apart', (
    tester,
  ) async {
    var scene = bannerWithBadge();
    (scene.nodeNamed('promo')! as SceneRefNode).instance = instantiateScene(
      badgeTemplate(),
      {'label': 'Now open'},
    );
    var rects = <String, SceneRect>{};
    await tester.pumpWidget(
      MaterialApp(
        home: SizedBox(
          width: 1024,
          height: 500,
          child: SceneView.document(
            scene,
            onMeasured: (r) => rects = namedRects(r),
          ),
        ),
      ),
    );
    await tester.pump();
    expect(find.text('Now open'), findsOneWidget);
    expect(rects['promo']!.left, 64);
    expect(rects['promo']!.width, 140);
    expect(rects.containsKey('text'), isFalse, reason: 'internals unmeasured');
  });
}
