import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutterware/channels.dart';
import 'package:flutterware/devbar.dart';

class _FlagsPlugin implements DevbarPlugin, DevbarPanelSource {
  @override
  String get panelId => 'flags';

  @override
  String get panelLabel => 'Feature flags';

  @override
  void describePanel(Panel panel) => panel.feed('changes', 'Changes');

  @override
  void dispose() {}
}

/// The gate, in its own file because it needs an app nobody is watching.
///
/// `GuestChannels.install()` is process-wide and cannot be undone, so this has
/// to run in an isolate where it has not happened — which is what a separate
/// test file buys. Merged into `bridge_test.dart` it would silently become a
/// test of whatever ran first.
void main() {
  testWidgets('a devbar outside flutterware mirrors nothing', (tester) async {
    expect(GuestChannels.installed, isFalse);

    await tester.pumpWidget(
      Devbar(
        plugins: [(_) => _FlagsPlugin()],
        headless: true,
        child: const SizedBox(),
      ),
    );
    await tester.pumpAndSettle();

    // The plugin loaded and the devbar hosts it; there is simply no reader, so
    // no panel and no channel were created.
    expect(GuestChannels.panels.descriptors, isEmpty);
    expect(GuestChannels.core.channels, isNot(contains('flags')));
  });

  testWidgets('nor does a panel scoped to a subtree', (tester) async {
    expect(GuestChannels.installed, isFalse);

    await tester.pumpWidget(
      AddDevbarPanel(source: _FlagsPlugin(), child: const SizedBox()),
    );
    await tester.pumpAndSettle();

    // `AddDevbarPanel` asks the same gate the same question, so an app that
    // scopes a panel to a session still pays nothing for it outside
    // flutterware — including the part where it has no devbar above it to
    // find, which is not something it needs.
    expect(GuestChannels.panels.descriptors, isEmpty);
    expect(GuestChannels.core.channels, isNot(contains('flags')));
  });

  test('nor one served from code, and the handle is still safe to hold', () {
    var panel = DevbarPanels.add(_FlagsPlugin());

    // Inert rather than null: an app that opens a database at login writes the
    // same two lines whether or not anybody is watching.
    expect(panel.id, isNull);
    panel.remove();
    expect(GuestChannels.panels.descriptors, isEmpty);
  });
}
