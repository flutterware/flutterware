import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutterware/plugins.dart';
// ignore: implementation_imports
import 'package:flutterware/src/log_client.dart';
import 'package:flutterware_app/src/context.dart';
import 'package:flutterware_app/src/plugins/manifest_loader.dart';
import 'package:flutterware_app/src/plugins/native_plugin.dart';
import 'package:flutterware_app/src/plugins/plugin_core.dart';
import 'package:flutterware_app/src/plugins/registry.dart';
import 'package:flutterware_app/src/shell/shell_controller.dart';
import 'package:flutterware_app/src/shell/shell_view.dart';
import 'package:flutterware_app/src/shell/worktree_discovery.dart';
import 'package:flutterware_app/src/utils/flutter_sdk.dart';

/// The ⋮ on a sidebar child row.
///
/// Generic on purpose — the shell asks the plugin what it offers and draws
/// whatever comes back — so these use a fake plugin rather than the catalog.
/// What the catalog puts behind it is one command; what the shell has to get
/// right is that the affordance exists, only where a plugin offers something,
/// and hands the choice back.
const _listing = 'worktree /repo\nbranch refs/heads/main\n';

const _manifestJson =
    '{"version":1,"plugins":['
    '{"id":"a.deps","label":"Dependencies"},'
    '{"id":"a.tests","label":"Tests"}]}';

class _FakeCore extends PluginCore {
  _FakeCore(super.host, {this.children = const []});

  final List<PluginChild> children;

  @override
  PluginReport get report =>
      PluginReport(id: host.id, label: host.label, children: children);
}

/// Offers a command on every child row, and records which row chose it.
class _Commanding extends NativePlugin<_FakeCore> {
  _Commanding(super.core);

  static final chosen = <String>[];

  @override
  List<PluginChildCommand> childCommands(
    BuildContext context,
    String childId,
  ) => [
    PluginChildCommand(
      label: 'Build a web page…',
      onSelected: (_) => chosen.add(childId),
    ),
  ];

  @override
  Widget buildPanel(BuildContext context) => const SizedBox();
}

/// Offers nothing, which is what every plugin does until it opts in.
class _Silent extends NativePlugin<_FakeCore> {
  _Silent(super.core);

  @override
  Widget buildPanel(BuildContext context) => const SizedBox();
}

class _StubLoader implements ManifestLoader {
  @override
  String? get flutterRoot => null;

  @override
  Future<PluginManifest?> load(String path) async =>
      PluginManifest.parse(_manifestJson);

  @override
  Future<({PluginManifest? manifest, String? error})> tryLoad(
    String path,
  ) async => (manifest: PluginManifest.parse(_manifestJson), error: null);

  @override
  String get dartExecutable => 'dart';

  @override
  Duration get timeout => Duration.zero; // Unused: no stub spawns a process.
}

Future<ShellController> _pump(WidgetTester tester) async {
  var shell = ShellController(
    appContext: AppContext(logger: LogClient.print()),
    flutterSdk: FlutterSdkPath('/tmp/flutter'),
    registry: PluginRegistry({
      'a.deps': panelFor<_FakeCore>(_Commanding.new),
      'a.tests': panelFor<_FakeCore>(_Silent.new),
    }),
    coreRegistry: PluginCoreRegistry({
      'a.deps': (h) => _FakeCore(
        h,
        children: const [
          PluginChild(id: '.', label: 'root', status: Status.info('building')),
          PluginChild(
            id: 'packages/ui',
            label: 'packages/ui',
            status: Status.warn('10 assets · 347 kB · 2 problems'),
          ),
        ],
      ),
      'a.tests': (h) => _FakeCore(
        h,
        children: const [PluginChild(id: '.', label: 'root')],
      ),
    }),
    manifestLoader: _StubLoader(),
    discovery: WorktreeDiscovery(
      runProcess: (_, _, {workingDirectory}) async =>
          ProcessResult(0, 0, _listing, ''),
    ),
  );
  await shell.start('/repo');
  await tester.pumpWidget(ShellApp(shell));
  await tester.pumpAndSettle();
  return shell;
}

/// Moves the pointer onto [finder] and leaves it there — the ⋮ is drawn only
/// under the pointer, so a test that merely taps where it would be taps the row.
Future<void> _hover(WidgetTester tester, Finder finder) async {
  var pointer = TestPointer(1, PointerDeviceKind.mouse);
  await tester.sendEventToBinding(pointer.hover(tester.getCenter(finder)));
  await tester.pumpAndSettle();
}

void main() {
  setUp(_Commanding.chosen.clear);

  testWidgets('a row shows no ⋮ until the pointer is on it', (tester) async {
    var shell = await _pump(tester);
    shell.selectPlugin('a.deps');
    await tester.pumpAndSettle();

    // The selected row keeps its ⋮ — you have just clicked it, and a control
    // that vanishes as you travel to it is one you cannot use.
    expect(find.byIcon(Icons.more_vert), findsOneWidget);

    await _hover(tester, find.text('packages/ui'));
    expect(find.byIcon(Icons.more_vert), findsNWidgets(2));
  });

  testWidgets('a plugin offering nothing gets no ⋮', (tester) async {
    var shell = await _pump(tester);
    shell.selectPlugin('a.tests');
    await tester.pumpAndSettle();

    await _hover(tester, find.text('root'));
    expect(find.byIcon(Icons.more_vert), findsNothing);
  });

  testWidgets('the ⋮ sits at the right edge, whatever the status says', (
    tester,
  ) async {
    var shell = await _pump(tester);
    shell.selectPlugin('a.deps');
    await tester.pumpAndSettle();

    // Two rows whose statuses are very different lengths. The ⋮ has to land in
    // the same column on both: it used to follow the status text, because the
    // label and the status split the row's free space between them and the
    // half the status did not use became trailing space after the button.
    await _hover(tester, find.text('packages/ui'));

    var dots = find.byIcon(Icons.more_vert);
    expect(dots, findsNWidgets(2));

    var rights = [for (var i = 0; i < 2; i++) tester.getRect(dots.at(i)).right];
    expect(rights[0], moreOrLessEquals(rights[1], epsilon: 0.5));

    // And flush against the row's own right padding rather than floating.
    var row = tester.getRect(find.text('packages/ui').hitTestable()).right;
    expect(rights[1], greaterThan(row));
  });

  testWidgets('the status sits against the name, not in the middle', (
    tester,
  ) async {
    var shell = await _pump(tester);
    shell.selectPlugin('a.deps');
    await tester.pumpAndSettle();

    // The row reads `root  building  ⋮`. When the label was Expanded it filled its
    // whole share first, which left the status stranded mid-row with the name
    // nowhere near it.
    var label = tester.getRect(find.text('root'));
    var status = tester.getRect(find.text('building'));

    // One gap between them, nothing else.
    expect(status.left - label.right, lessThan(8.0));
  });

  testWidgets('a status that fits is not truncated to make room', (
    tester,
  ) async {
    var shell = await _pump(tester);
    shell.selectPlugin('a.deps');
    await tester.pumpAndSettle();

    // A flexible child is clamped to its *share* of the row whether or not the
    // other child wanted it, so a flexible status came out as "buildi…" beside
    // a four-letter name with the rest of the row empty. The catalog entry is
    // what showed it; this is what keeps it shown.
    var status = tester.renderObject<RenderParagraph>(find.text('building'));
    expect(status.didExceedMaxLines, isFalse);
  });

  testWidgets('choosing a command says which row it was', (tester) async {
    var shell = await _pump(tester);
    shell.selectPlugin('a.deps');
    await tester.pumpAndSettle();

    await _hover(tester, find.text('packages/ui'));
    // The second ⋮ is the hovered row's; the first belongs to the selected one.
    await tester.tap(find.byIcon(Icons.more_vert).last);
    await tester.pumpAndSettle();

    await tester.tap(find.text('Build a web page…'));
    await tester.pumpAndSettle();

    // The child id, not the label: a command acts on the package the row
    // stands for, and those differ for the root.
    expect(_Commanding.chosen, ['packages/ui']);
  });
}
