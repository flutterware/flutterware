import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutterware/plugins.dart';
import 'package:flutterware_app/src/shell/sidebar_row.dart';
import 'package:flutterware_app/src/ui/theme.dart';

/// The wall between a plugin's status and the row drawing it. A plugin writes
/// its own line — third-party ones included — so a row that trusted it to be
/// short was a row a plugin could take.
Future<void> _pump(WidgetTester tester, Status status, double maxWidth) =>
    tester.pumpWidget(
      MaterialApp(
        theme: appTheme,
        home: Material(
          child: Center(child: StatusText(status, maxWidth: maxWidth)),
        ),
      ),
    );

void main() {
  testWidgets('a status that fits takes its own width and no tooltip', (
    tester,
  ) async {
    await _pump(tester, const Status.info('live'), 100);

    expect(tester.getSize(find.text('live')).width, lessThan(100));
    // Nothing was lost, so a box repeating what is on screen would be noise.
    expect(find.byType(Tooltip), findsNothing);
  });

  testWidgets('a status too long is capped, on one line, and hoverable', (
    tester,
  ) async {
    await _pump(
      tester,
      const Status.info(
        '[tester] flutterware previews harness ready — 133 entries, '
        'fonts: MaterialIcons',
      ),
      100,
    );

    var size = tester.getSize(find.byType(Text));
    expect(size.width, lessThanOrEqualTo(100));
    expect(size.height, lessThan(24), reason: 'one line');
    // What the ellipsis took is a hover away, which is the same bargain a
    // worktree tab strikes with a name too long for it.
    expect(find.byType(Tooltip), findsOneWidget);
  });
}
