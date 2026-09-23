import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutterware/src/ui_catalog/axes.dart';
import 'package:flutterware/src/ui_catalog/axes_controls.dart';

enum Flavor { dev, prod }

const _flavors = {'Dev': Flavor.dev, 'Production': Flavor.prod};

/// The top bar's switches, from the *page's* side.
///
/// A generated page has no VM service and no second process, so what the GUI
/// does over a wire this does by calling [CatalogAxes] directly. The tests
/// below are the two halves of that: what the shell declared reaches the bar,
/// and what the bar chose reaches the shell.
void main() {
  var entry = 0;

  setUp(() {
    CatalogAxes.instance
      ..apply({
        'app': {'flavor': null, 'compact': null},
      })
      ..resetFor('entry-${entry++}');
  });

  Widget shellWith(void Function(PreviewAxes) declare) => MaterialApp(
    home: Scaffold(
      body: Column(
        children: [
          const AxesControls(),
          PreviewShell(
            'app',
            builder: (context, axes) {
              declare(axes);
              return const SizedBox();
            },
          ),
        ],
      ),
    ),
  );

  testWidgets('what the shell declared arrives on the bar', (tester) async {
    await tester.pumpWidget(
      shellWith((axes) {
        axes.picker('flavor', _flavors, Flavor.dev);
      }),
    );
    // One frame for the shell to declare, and a second for the bar to read what
    // it declared — an axis exists because a build asked for it, so the bar
    // cannot know about it during the build that asks.
    await tester.pump();

    expect(find.text('flavor'), findsOneWidget);
    expect(find.text('Dev'), findsOneWidget);
  });

  testWidgets('choosing on the bar rebuilds the shell with it', (tester) async {
    // The whole point, and what a generated page could not do: the picker used
    // to render and the shell went on answering with the default it wrote.
    var built = <Flavor>[];
    await tester.pumpWidget(
      shellWith(
        (axes) => built.add(axes.picker('flavor', _flavors, Flavor.dev)),
      ),
    );
    await tester.pump();
    expect(built, [Flavor.dev]);

    await tester.tap(find.text('Dev'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Production').last);
    await tester.pumpAndSettle();

    expect(built.last, Flavor.prod);
    expect(find.text('Production'), findsOneWidget);
  });

  testWidgets('a flag is a switch, and moves the shell too', (tester) async {
    var built = <bool>[];
    await tester.pumpWidget(
      shellWith((axes) => built.add(axes.flag('compact', false))),
    );
    await tester.pump();
    expect(built, [false]);

    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();
    expect(built.last, isTrue);
  });

  testWidgets('one axis moving leaves the others where they are', (
    tester,
  ) async {
    // `apply` replaces a shell's map rather than merging it, so a bar that sent
    // only the control that moved would put every other axis back to its
    // default — the failure this sends the whole map to avoid.
    var flavors = <Flavor>[];
    var compacts = <bool>[];
    await tester.pumpWidget(
      shellWith((axes) {
        flavors.add(axes.picker('flavor', _flavors, Flavor.dev));
        compacts.add(axes.flag('compact', false));
      }),
    );
    await tester.pump();

    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();
    expect(compacts.last, isTrue);

    await tester.tap(find.text('Dev'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Production').last);
    await tester.pumpAndSettle();

    expect(flavors.last, Flavor.prod);
    expect(compacts.last, isTrue, reason: 'the switch was reset by the picker');
  });

  testWidgets('a shell that declares nothing draws no bar', (tester) async {
    await tester.pumpWidget(shellWith((_) {}));
    await tester.pump();

    expect(find.byType(DropdownButton<String>), findsNothing);
    expect(find.byType(Switch), findsNothing);
  });
}
