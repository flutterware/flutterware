import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutterware/plugins.dart';
// ignore: implementation_imports
import 'package:flutterware/src/log_client.dart';
import 'package:flutterware_app/src/address/address_scope.dart';
import 'package:flutterware_app/src/context.dart';
import 'package:flutterware_app/src/plugins/manifest_loader.dart';
import 'package:flutterware_app/src/plugins/native_plugin.dart';
import 'package:flutterware_app/src/plugins/plugin_core.dart';
import 'package:flutterware_app/src/plugins/registry.dart';
import 'package:flutterware_app/src/shell/address_bar.dart';
import 'package:flutterware_app/src/shell/shell_controller.dart';
import 'package:flutterware_app/src/shell/shell_view.dart';
import 'package:flutterware_app/src/shell/worktree_discovery.dart';
import 'package:flutterware_app/src/ui/theme.dart';
import 'package:flutterware_app/src/utils/flutter_sdk.dart';

const _listing =
    'worktree /repo\nbranch refs/heads/main\n\n'
    'worktree /repo-explorer\nbranch refs/heads/feature/explorer\n';

class _FakeCore extends PluginCore {
  _FakeCore(super.host);

  @override
  PluginReport get report => PluginReport(id: host.id, label: host.label);
}

class _Fake extends NativePlugin<_FakeCore> {
  _Fake(super.core);

  @override
  Widget buildPanel(BuildContext context) {
    var segments = AddressScope.segments(context);
    return Center(
      child: Text('panel:$id/${segments.isEmpty ? '-' : segments.join('/')}'),
    );
  }
}

class _StubLoader implements ManifestLoader {
  @override
  String? get flutterRoot => null;

  @override
  Future<PluginManifest?> load(String path) async => PluginManifest.parse(
    '{"version":1,"plugins":[{"id":"a.deps","label":"Dependencies"}]}',
  );

  @override
  Future<({PluginManifest? manifest, String? error})> tryLoad(
    String path,
  ) async => (manifest: await load(path), error: null);

  @override
  String get dartExecutable => 'dart';

  @override
  Duration get timeout => Duration.zero; // Unused: no stub spawns a process.
}

Future<ShellController> _pumpShell(WidgetTester tester) async {
  var shell = ShellController(
    appContext: AppContext(logger: LogClient.print()),
    flutterSdk: FlutterSdkPath('/tmp/flutter'),
    registry: PluginRegistry({'a.deps': panelFor<_FakeCore>(_Fake.new)}),
    coreRegistry: PluginCoreRegistry({'a.deps': _FakeCore.new}),
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

/// Opens the editor by its own affordance, the `edit` button on the right.
Future<void> _expand(WidgetTester tester) async {
  await tester.tap(
    find.descendant(of: find.byType(AddressBar), matching: find.text('edit')),
  );
  await tester.pumpAndSettle();
}

/// Taps the chevron beside the worktree, which is the switcher.
Future<void> _openSwitcher(WidgetTester tester) async {
  // Scoped: the band above has its own chevron.
  await tester.tap(
    find.descendant(
      of: find.byType(AddressBar),
      matching: find.byIcon(Icons.expand_more),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _type(WidgetTester tester, String address) async {
  await tester.enterText(find.byType(TextField), address);
  await tester.testTextInput.receiveAction(TextInputAction.done);
  await tester.pumpAndSettle();
}

void main() {
  group('the bar shows where the shell is', () {
    testWidgets('as parts, so the ends survive a narrow window', (
      tester,
    ) async {
      var shell = await _pumpShell(tester);
      expect(find.text('fw:///'), findsOneWidget);
      expect(find.text(Address.worktreesSpace), findsOneWidget);
      expect(find.text('~'), findsOneWidget);

      shell.go(
        Address(
          worktree: '~',
          plugin: 'a.deps',
          segments: ['app', 'tool/demos', 'avatar.dart#members'],
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('a.deps'), findsOneWidget);
      // Each middle segment is its own part — and its own ellipsis under
      // pressure; the last segment never gives way.
      expect(find.text('app'), findsOneWidget);
      expect(find.text('tool/demos'), findsOneWidget);
      expect(find.text('avatar.dart#members'), findsOneWidget);
    });

    testWidgets('applied axes read as chips, not as a query string', (
      tester,
    ) async {
      var shell = await _pumpShell(tester);

      shell.go(
        Address(
          worktree: '~',
          plugin: 'a.deps',
          axes: {'axis.theme': 'dark', 'knob.count': '3'},
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('theme dark'), findsOneWidget);
      expect(find.text('count 3'), findsOneWidget);
    });

    testWidgets('and follows it as it moves', (tester) async {
      await _pumpShell(tester);

      await tester.tap(find.text('Dependencies'));
      await tester.pumpAndSettle();

      expect(find.text('a.deps'), findsOneWidget);
    });

    testWidgets('expanding shows the whole address', (tester) async {
      var shell = await _pumpShell(tester);
      shell.selectChild('a.deps', 'packages/app');
      await tester.pumpAndSettle();

      await _expand(tester);

      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        'fw:///worktrees/~/a.deps/packages%2Fapp',
      );
    });
  });

  group('the bar drives the shell', () {
    testWidgets('a typed address opens what it names', (tester) async {
      await _pumpShell(tester);
      await _expand(tester);

      await _type(tester, 'fw:///worktrees/~/a.deps/packages%2Fapp');

      expect(find.text('panel:a.deps/packages/app'), findsOneWidget);
      expect(find.text('packages/app'), findsOneWidget);
    });

    testWidgets('something that is not an address says so', (tester) async {
      await _pumpShell(tester);
      await _expand(tester);

      await _type(tester, 'not an address');

      expect(find.text('Not a flutterware address.'), findsOneWidget);
      // Still open, still holding what was typed: an error that closes the
      // thing you were editing is an error you cannot act on.
      expect(find.byType(TextField), findsOneWidget);
    });

    testWidgets('a worktree that exists but is closed is opened', (
      tester,
    ) async {
      var shell = await _pumpShell(tester);
      await _expand(tester);

      await _type(tester, 'fw:///worktrees/repo-explorer/a.deps');

      // Typing an address is naming a destination, and opening the worktree is
      // how you get there. Explaining a refusal was the second-best answer.
      expect(shell.address.toString(), 'fw:///worktrees/repo-explorer/a.deps');
      expect(shell.openWorktrees.map((w) => w.name), ['~', 'repo-explorer']);
      expect(find.textContaining('is not open'), findsNothing);
    });

    testWidgets('a worktree this repo has never heard of', (tester) async {
      await _pumpShell(tester);
      await _expand(tester);

      await _type(tester, 'fw:///worktrees/nowhere/a.deps');

      expect(find.textContaining('No worktree named'), findsOneWidget);
    });
  });

  group('the worktree segment switches checkout', () {
    testWidgets('it offers the others by the name you would recognise', (
      tester,
    ) async {
      await _pumpShell(tester);

      await _openSwitcher(tester);

      // Branches, because that is what a human knows a checkout by — with the
      // identity that actually goes in the address beside it. Scoped to the
      // menu: a branch name is also on a tab and in the rail above.
      expect(find.widgetWithText(MenuItemButton, 'main'), findsOneWidget);
      expect(
        find.widgetWithText(MenuItemButton, 'feature/explorer'),
        findsOneWidget,
      );
      expect(
        find.widgetWithText(MenuItemButton, 'repo-explorer'),
        findsOneWidget,
      );
      // Picking it will open it, and says so first.
      expect(find.widgetWithText(MenuItemButton, 'opens'), findsOneWidget);
    });

    testWidgets('picking one keeps the place and the axes', (tester) async {
      var shell = await _pumpShell(tester);
      shell.go(
        Address.parse(
          'fw:///worktrees/~/a.deps/packages%2Fapp?axis.theme=dark',
        ),
      );
      await tester.pumpAndSettle();

      await _openSwitcher(tester);
      await tester.tap(find.widgetWithText(MenuItemButton, 'feature/explorer'));
      await tester.pumpAndSettle();

      // The whole point: same package, same theme, other checkout.
      expect(
        shell.address.toString(),
        'fw:///worktrees/repo-explorer/a.deps/packages%2Fapp?axis.theme=dark',
      );
    });

    testWidgets('the chevron opens it, and not the editor', (tester) async {
      await _pumpShell(tester);

      await _openSwitcher(tester);

      // The bar underneath opens the editor; the switcher part has to win the
      // arena or it can never be reached. The field on screen is the filter,
      // not the editor's address field.
      expect(find.text('Press ↵ to go there.'), findsNothing);
      expect(find.widgetWithText(MenuItemButton, 'main'), findsOneWidget);
    });

    testWidgets('the worktree text opens it too — name and chevron are one '
        'target', (tester) async {
      await _pumpShell(tester);

      await tester.tap(find.text('~'));
      await tester.pumpAndSettle();

      expect(find.widgetWithText(MenuItemButton, 'main'), findsOneWidget);
      expect(find.text('Press ↵ to go there.'), findsNothing);
    });

    testWidgets('it filters as you type, on either name', (tester) async {
      await _pumpShell(tester);
      await _openSwitcher(tester);

      await tester.enterText(find.byType(TextField), 'expl');
      await tester.pumpAndSettle();

      expect(
        find.widgetWithText(MenuItemButton, 'feature/explorer'),
        findsOneWidget,
      );
      expect(find.widgetWithText(MenuItemButton, 'main'), findsNothing);

      // The run that kept the row in the list is lit: the label is rich text
      // now, with the matched characters washed amber.
      var label = tester.widget<Text>(
        find.descendant(
          of: find.byType(MenuItemButton),
          matching: find.text('feature/explorer'),
        ),
      );
      expect(label.textSpan, isNotNull);
    });

    testWidgets('a title on the row does not hide the branch', (tester) async {
      // The shell's worktrees carry no title yet, so this is the readout on
      // its own — which is what it was built to be testable as. A titled row
      // shows the title, and the branch is then a name that is on the checkout
      // and nowhere on the screen: it still has to be filterable, and what
      // kept the row has to be visible on it.
      var picked = <String>[];
      await tester.pumpWidget(
        MaterialApp(
          theme: appTheme,
          home: Material(
            child: Align(
              alignment: Alignment.bottomLeft,
              child: AddressReadout(
                address: Address(worktree: '~'),
                worktrees: const [
                  WorktreeChoice(
                    name: '~',
                    displayName: 'master',
                    branch: 'master',
                    isOpen: true,
                  ),
                  WorktreeChoice(
                    name: 'repo-split',
                    displayName: 'Split button rework',
                    branch: 'claude/split-button-rework',
                    isOpen: false,
                  ),
                ],
                onGo: (_) {},
                onPickWorktree: (choice) => picked.add(choice.name),
                onEdit: () {},
              ),
            ),
          ),
        ),
      );
      // The readout's own chevron: there is no bar around it here.
      await tester.tap(
        find.descendant(
          of: find.byType(AddressReadout),
          matching: find.byIcon(Icons.expand_more),
        ),
      );
      await tester.pumpAndSettle();

      await tester.enterText(
        find.byType(TextField),
        'claude/split-button-rework',
      );
      await tester.pumpAndSettle();

      expect(find.text('No worktree matches.'), findsNothing);
      expect(
        find.widgetWithText(MenuItemButton, 'Split button rework'),
        findsOneWidget,
      );
      // The branch is beside the title, lit where the query landed.
      var branch = tester.widget<Text>(
        find.descendant(
          of: find.byType(MenuItemButton),
          matching: find.text('claude/split-button-rework'),
        ),
      );
      expect(branch.textSpan, isNotNull);

      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      expect(picked, ['repo-split']);
    });

    testWidgets('↵ picks the first match', (tester) async {
      var shell = await _pumpShell(tester);
      await _openSwitcher(tester);

      await tester.enterText(find.byType(TextField), 'expl');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();

      expect(shell.address.worktree, 'repo-explorer');
    });

    testWidgets('nothing matching says so, and ↵ does nothing', (tester) async {
      var shell = await _pumpShell(tester);
      await _openSwitcher(tester);

      await tester.enterText(find.byType(TextField), 'zzz');
      await tester.pumpAndSettle();

      expect(find.text('No worktree matches.'), findsOneWidget);
      expect(find.byType(MenuItemButton), findsNothing);

      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();

      expect(shell.address.worktree, '~');
    });
  });

  group('the readout is a row of live parts', () {
    testWidgets('the plugin segment jumps to the plugin root', (tester) async {
      var shell = await _pumpShell(tester);
      shell.go(
        Address.parse(
          'fw:///worktrees/~/a.deps/packages%2Fapp/lib?axis.theme=dark',
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('a.deps'));
      await tester.pumpAndSettle();

      expect(shell.address.toString(), 'fw:///worktrees/~/a.deps');
    });

    testWidgets('a middle segment truncates the address there', (tester) async {
      var shell = await _pumpShell(tester);
      shell.go(
        Address(
          worktree: '~',
          plugin: 'a.deps',
          segments: ['app', 'tool/demos', 'avatar.dart#members'],
          axes: {'axis.theme': 'dark'},
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('tool/demos'));
      await tester.pumpAndSettle();

      // The path up to the clicked segment; the leaf's axes do not describe
      // its parents, so they go too.
      expect(
        shell.address.toString(),
        'fw:///worktrees/~/a.deps/app/tool%2Fdemos',
      );
    });

    testWidgets('an axis chip removes its axis', (tester) async {
      var shell = await _pumpShell(tester);
      shell.go(
        Address.parse(
          'fw:///worktrees/~/a.deps/packages%2Fapp?axis.theme=dark',
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('theme dark'));
      await tester.pumpAndSettle();

      expect(
        shell.address.toString(),
        'fw:///worktrees/~/a.deps/packages%2Fapp',
      );
    });

    testWidgets('blank space still opens the editor', (tester) async {
      await _pumpShell(tester);

      // The middle of a bar showing only `fw:///worktrees/~` is empty strip.
      await tester.tap(find.byType(AddressBar));
      await tester.pumpAndSettle();

      expect(find.byType(TextField), findsOneWidget);
    });
  });
}
