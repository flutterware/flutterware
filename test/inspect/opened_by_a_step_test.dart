import 'package:flutter_test/flutter_test.dart';
import 'package:flutterware/src/drive/drive.dart';
import 'package:flutterware/src/drive/guest_drive.dart';
import 'package:flutterware/src/drive/lane.dart';
import 'package:flutterware/src/inspect/guest_inspect.dart';
import 'package:flutterware/src/inspect/screen.dart';
import 'package:material_ui/material_ui.dart';

/// What a step opens is on the screen a reader gets, not only in the picture.
///
/// Most of it always was: a menu's items, a dialog's title and a snack bar's
/// message are the app's own `Text`s. A tooltip's is not — the design library
/// builds it out of the message string, in the overlay — and the walk dropped
/// every node the library created, so a hover put the tooltip in the
/// screenshot and nowhere `screen` or `find` could see it.
void main() {
  Future<({bool inTree, bool onScreen})> open(
    WidgetTester tester,
    Map<String, String> step,
    String words,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: Column(
              children: [
                const Tooltip(
                  message: 'Tip words',
                  waitDuration: Duration(milliseconds: 100),
                  child: Text('Hover'),
                ),
                PopupMenuButton<String>(
                  itemBuilder: (_) => const [
                    PopupMenuItem(value: 'a', child: Text('Menu words')),
                  ],
                  child: const Text('Menu'),
                ),
                TextButton(
                  onPressed: () => showDialog<void>(
                    context: context,
                    builder: (_) =>
                        const AlertDialog(title: Text('Dialog words')),
                  ),
                  child: const Text('Dialog'),
                ),
                TextButton(
                  onPressed: () => ScaffoldMessenger.of(
                    context,
                  ).showSnackBar(const SnackBar(content: Text('Snack words'))),
                  child: const Text('Snack'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    var drive = Drive.on(TesterLane(tester))
      ..settleBudget = const Duration(seconds: 5);
    await runWireVerb(drive, step);
    var tree = GuestInspector(
      rootOf: () => tester.binding.rootElement,
      entryIdOf: () => null,
    ).read();
    var screen = Screen.of(tree);
    if (drive.hovering != null) {
      await drive.unhover(hold: Duration.zero, settle: Duration.zero);
    }
    drive.dispose();
    return (
      inTree: tree.matching(words).isNotEmpty,
      onScreen: screen.items.any((item) => item.words == words),
    );
  }

  testWidgets('a tooltip a hover showed', (tester) async {
    var read = await open(tester, {
      'verb': 'hover',
      'target': 'Hover',
    }, 'Tip words');
    expect(read.inTree, isTrue);
    expect(read.onScreen, isTrue);
  });

  testWidgets('a menu a tap opened', (tester) async {
    var read = await open(tester, {
      'verb': 'tap',
      'target': 'Menu',
    }, 'Menu words');
    expect(read.onScreen, isTrue);
  });

  testWidgets('a dialog a tap opened', (tester) async {
    var read = await open(tester, {
      'verb': 'tap',
      'target': 'Dialog',
    }, 'Dialog words');
    expect(read.onScreen, isTrue);
  });

  testWidgets('a snack bar a tap showed', (tester) async {
    var read = await open(tester, {
      'verb': 'tap',
      'target': 'Snack',
    }, 'Snack words');
    expect(read.onScreen, isTrue);
  });
}
