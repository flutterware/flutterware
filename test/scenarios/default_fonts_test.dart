import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutterware/src/scenarios/fonts.dart';

/// `flutter test` runs its tester with `--use-test-fonts`, hardcoded, so text
/// naming no family — most of an app — draws every glyph as an identical box
/// and measures at the box's width. [loadDefaultScenarioFonts] registers real
/// Roboto under the platform-default family names from the SDK's own cache;
/// this suite runs under exactly that tester, so it can hold the claim
/// directly.
void main() {
  testWidgets('default-family text measures real once the defaults load', (
    tester,
  ) async {
    Future<Size> measure(String text) async {
      await tester.pumpWidget(MaterialApp(home: Scaffold(body: Text(text))));
      return tester.getSize(find.text(text));
    }

    // The box font gives every glyph the same advance, so a narrow string
    // and a wide one agree — the fingerprint of measuring in the wrong font.
    var narrowBoxed = await measure('iiiii');
    var wideBoxed = await measure('WWWWW');
    expect(narrowBoxed.width, wideBoxed.width);

    // The real bundle read inside must not run under fake time — same
    // reasoning as fonts_test.dart's plain-`test` choice.
    await tester.runAsync(loadDefaultScenarioFonts);

    await tester.pumpWidget(Container());
    var narrow = await measure('iiiii');
    var wide = await measure('WWWWW');
    expect(narrow.width, lessThan(wide.width));
  });
}
