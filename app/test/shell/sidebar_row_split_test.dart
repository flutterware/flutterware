import 'package:material_ui/material_ui.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutterware/plugins.dart';
import 'package:flutterware_app/src/shell/sidebar_row.dart';
import 'package:flutterware_app/src/ui/theme.dart';

/// How a rail row divides itself between a name and a status. The label is
/// served first and the status takes the rest — the flat cap this replaced gave
/// the status the same hundred pixels beside `app` as beside
/// `packages/design_system_foundations`, and truncated it next to three empty
/// centimetres of rail.
const _railWidth = 232.0;

/// A status long enough that it will take everything it is given.
const _long = Status.info(
  'compiling the catalog, the harness and everything else',
);

Future<void> _pump(
  WidgetTester tester,
  String label,
  Status status, {
  double width = _railWidth,
}) => tester.pumpWidget(
  MaterialApp(
    theme: appTheme,
    home: Material(
      child: Align(
        alignment: Alignment.topLeft,
        child: SizedBox(
          width: width,
          child: SidebarChildRow(
            label: label,
            status: status,
            selected: false,
            onTap: _noop,
          ),
        ),
      ),
    ),
  ),
);

void _noop() {}

double _statusWidth(WidgetTester tester, Status status) =>
    tester.getSize(find.text(status.message)).width;

/// Whether [text] lost characters to its ellipsis — the question a width alone
/// cannot answer, because a label that fits and a label that was cut to fit
/// both come back the width of the box they were given.
bool _clipped(WidgetTester tester, String text) =>
    tester.renderObject<RenderParagraph>(find.text(text)).didExceedMaxLines;

void main() {
  testWidgets('a short name leaves the status the rest of the row', (
    tester,
  ) async {
    await _pump(tester, 'app', _long);

    // Comfortably past the flat 100 the row used to stop at.
    expect(_statusWidth(tester, _long), greaterThan(130));
  });

  testWidgets('a long name takes what it needs, and the status gives it up', (
    tester,
  ) async {
    await _pump(tester, 'packages/design_system_foundations', _long);

    var narrow = _statusWidth(tester, _long);
    await _pump(tester, 'app', _long);
    expect(narrow, lessThan(_statusWidth(tester, _long)));
  });

  testWidgets('but never below the floor — a name cannot silence a status', (
    tester,
  ) async {
    // The floor is visibility, not completeness: enough that the row still
    // reads as having something to say, and the tooltip carries the rest.
    await _pump(tester, 'a' * 200, _long);

    expect(_statusWidth(tester, _long), 48);
    // And the name is the one that ellipsised, not the row that overflowed.
    expect(_clipped(tester, 'a' * 200), isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a name that fits is never truncated to widen a status', (
    tester,
  ) async {
    // The regression the flat cap kept producing: a package row reading
    // `examples/…` beside a status that had room to spare.
    //
    // On a rail wider than the real one, because the claim is about the rule
    // and the metrics here are not the app's: whether this particular name
    // fits at 232 is a question about the font the test binding loaded.
    await _pump(tester, 'fixtures/probe_app', _long, width: 400);

    expect(_clipped(tester, 'fixtures/probe_app'), isFalse);
    // The status is the one that gave, and it is still legible.
    expect(_statusWidth(tester, _long), greaterThanOrEqualTo(48));
  });

  testWidgets('a status shorter than the floor is never padded out to it', (
    tester,
  ) async {
    // The floor is the status's protection, not its allowance: `down` beside a
    // long name must still be `down`, with the name keeping everything else.
    await _pump(tester, 'packages/design_system_foundations', Status.none);
    var whole = tester.getSize(find.text('packages/design_system_foundations'));

    await _pump(
      tester,
      'packages/design_system_foundations',
      const Status.neutral('down'),
    );
    var beside = tester.getSize(
      find.text('packages/design_system_foundations'),
    );

    expect(whole.width - beside.width, lessThan(50));
  });
}
