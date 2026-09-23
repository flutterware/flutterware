import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutterware/translations.dart';
import 'package:brewline/shop/mini_markdown.dart';
import 'package:brewline/shop/shop_app.dart';

/// Pins the shop's end of the translation seam.
///
/// The scenario runner wires this in `test/scenarios/*/flutter_test_config.dart`
/// and the export reads what it produces — a chain long enough that a break
/// anywhere in it shows up as an empty export rather than as a failure. This
/// test is the short way to tell whether the *app* half still holds.
void main() {
  setUp(() {
    TranslationIndex.reset();
    TranslationIndex.recording = true;
    ShopStrings.wrapValue = indexTranslations('shop');
    ShopStrings.wrapExpanded = indexExpansions('shop');
  });

  tearDown(() {
    ShopStrings.wrapValue = null;
    ShopStrings.wrapExpanded = null;
    TranslationIndex.recording = false;
    TranslationIndex.reset();
  });

  testWidgets('every string the shop renders can be traced to its key', (
    tester,
  ) async {
    await tester.pumpWidget(const ShopApp());
    await tester.pumpAndSettle();

    // What the catalog was asked for on the way to this screen.
    expect(TranslationIndex.read['shop'], contains('tagline'));
    expect(
      TranslationIndex.read['shop']!['tagline'],
      startsWith('Your coffee'),
    );

    // And the words on screen resolve back to the key that produced them —
    // by object identity, which is the whole mechanism.
    var rendered = tester.widget<Text>(find.text('Get started')).data!;
    expect(
      TranslationIndex.keyOf(rendered),
      TranslationKey('shop', 'getStarted'),
    );
  });

  testWidgets('a substituted string still names the key that built it', (
    tester,
  ) async {
    await tester.pumpWidget(
      Localizations(
        locale: const Locale('en'),
        delegates: const [
          ShopStrings.delegate,
          DefaultWidgetsLocalizations.delegate,
        ],
        child: const SizedBox(),
      ),
    );
    await tester.pumpAndSettle();

    var strings = ShopStrings.of(tester.element(find.byType(SizedBox)));
    var built = strings.thanks('Ada');

    expect(built, 'Thanks, **Ada**!');
    // Identity alone loses this one — the substitution allocated it. The key is
    // not gone though, and `thanks` routes it rather than leaving it to be
    // guessed back out of the words.
    expect(TranslationIndex.keyOf(built), TranslationKey('shop', 'thanks'));
    // And what the catalog *answered* is still the template, which is what
    // the export compares against the locale's file.
    expect(TranslationIndex.read['shop']!['thanks'], 'Thanks, **{name}**!');
  });

  testWidgets('the widget that reparses keeps the string on a property', (
    tester,
  ) async {
    // `MiniMarkdown` splits its source into fresh substrings and drops the
    // `**` entirely, so nothing below it is the object the catalog handed
    // out. `data` is, which is the whole of what the scenario declares.
    var built = 'Thanks, **Ada**!';
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: MiniMarkdown(built),
      ),
    );

    expect(tester.widget<MiniMarkdown>(find.byType(MiniMarkdown)).data, built);
    expect(find.text('Thanks, **Ada**!'), findsNothing);
  });

  testWidgets('a locale with nothing to say falls back to the source', (
    tester,
  ) async {
    await tester.pumpWidget(
      Localizations(
        locale: const Locale('fr'),
        delegates: const [
          ShopStrings.delegate,
          DefaultWidgetsLocalizations.delegate,
        ],
        child: const SizedBox(),
      ),
    );
    await tester.pumpAndSettle();

    var strings = ShopStrings.of(tester.element(find.byType(SizedBox)));

    expect(strings.getStarted, 'Commencer');
    // `fr.json` deliberately omits this one, so the demo has something for the
    // translations panel to report.
    expect(strings.onItsWay, 'Your order is on its way.');
  });
}
