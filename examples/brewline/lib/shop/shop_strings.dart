import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// The demo shop's copy — **a loader-based catalog**, which is the shape
/// this repository's translation tooling is built for.
///
/// The words live in `assets/i18n/<locale>.json` rather than in this file, and
/// every read goes through [read]. That one funnel is the whole integration
/// surface: hand it a wrapper and the words a screen renders can be traced
/// back to the keys they came from, by object identity, with nothing inserted
/// into the text and no pixel moved. See
/// `docs/superpowers/specs/2026-08-18-translation-index-design.md`, and
/// `test/scenarios/mobile/flutter_test_config.dart` for the two lines that
/// wire it.
///
/// Deliberately hand-rolled rather than codegen: a demo should show localized
/// scenarios without dragging in a pipeline, and a hand-rolled catalog is
/// also what most projects with a funnel actually have.
class ShopStrings {
  const ShopStrings(this.locale, this._values, this._fallback);

  /// The language the source text is written in — what a translator works
  /// *from*, and what a locale with nothing to say falls back to.
  static const template = 'en';

  static const supported = ['en', 'fr'];

  /// Wraps every value on its way out of the catalog.
  ///
  /// The seam, and the only thing a project has to add. Null in
  /// production, so this costs nothing there. A scenario run sets it to
  /// `indexTranslations('shop')`, and from then on each key renders a distinct
  /// string object that the capture can name.
  static String Function(String key, String value)? wrapValue;

  /// Wraps a value this class *built* rather than stored — see [thanks].
  ///
  /// The second half of the seam, and null in production like the first. A
  /// substitution allocates a new string, so the token [wrapValue] handed out
  /// is not what renders; this hands the key back at the one place that still
  /// knows it. A scenario sets it to `indexExpansions('shop')`.
  static String Function(String key, String expanded)? wrapExpanded;

  /// The package the strings are bundled under when the shop's screens are
  /// compiled into another app — flutterware's studio does that for its web
  /// demo — or null when this is the app. An asset of a dependency is
  /// addressed as `packages/<name>/…`, and only the host knows which it is.
  static String? assetPackage;

  static const LocalizationsDelegate<ShopStrings> delegate = _Delegate();

  static ShopStrings of(BuildContext context) =>
      Localizations.of<ShopStrings>(context, ShopStrings)!;

  final Locale locale;
  final Map<String, String> _values;

  /// The template's words, for keys this locale has none for. Falling back is
  /// ordinary and worth showing: `fr.json` omits two keys on purpose, so the
  /// demo has something for the translations panel to report.
  final Map<String, String> _fallback;

  String read(String key) {
    var value = _values[key] ?? _fallback[key] ?? '';
    var wrap = wrapValue;
    return wrap == null ? value : wrap(key, value);
  }

  String get title => read('title');
  String get tagline => read('tagline');
  String get getStarted => read('getStarted');
  String get menuTitle => read('menuTitle');
  String get addToCart => read('addToCart');
  String get size => read('size');
  String get sizeSmall => read('sizeSmall');
  String get sizeMedium => read('sizeMedium');
  String get sizeLarge => read('sizeLarge');
  String get yourOrder => read('yourOrder');
  String get total => read('total');
  String get nameOnCup => read('nameOnCup');
  String get placeOrder => read('placeOrder');
  String get emptyCart => read('emptyCart');
  String get onItsWay => read('onItsWay');
  String get backToMenu => read('backToMenu');
  String get perkOrderAhead => read('perkOrderAhead');
  String get perkSkipQueue => read('perkSkipQueue');
  String get perkReady => read('perkReady');
  String get pickupFrom => read('pickupFrom');
  String get seasonalLabel => read('seasonalLabel');
  String get categoryAll => read('categoryAll');
  String get categoryCoffee => read('categoryCoffee');
  String get categoryTea => read('categoryTea');
  String get categoryIced => read('categoryIced');
  String get milk => read('milk');
  String get milkWhole => read('milkWhole');
  String get milkOat => read('milkOat');
  String get milkAlmond => read('milkAlmond');
  String get extraShot => read('extraShot');
  String get pickup => read('pickup');
  String get pickupAsap => read('pickupAsap');
  String get pickupIn15 => read('pickupIn15');
  String get pickupIn30 => read('pickupIn30');
  String get orderLabel => read('orderLabel');
  String get counter => read('counter');
  String get stepReceived => read('stepReceived');
  String get stepBrewing => read('stepBrewing');
  String get stepReady => read('stepReady');

  /// The string that goes through a placeholder, and still resolves.
  ///
  /// Substituting allocates a new object, so identity alone loses it here. The
  /// key is not gone though — this method knew it one line ago — so it is
  /// routed rather than inferred: [wrapExpanded] takes the built string and
  /// says which key built it, which is exact where reading the words back
  /// would be a guess.
  ///
  /// Note where this lives. It is one method on the catalog, not a call
  /// site, which is what makes the hook cheap in a real project: a loader-based
  /// catalog substitutes in one place per key however many screens use it.
  ///
  /// The value carries `**` besides, so what renders it is [MiniMarkdown] —
  /// see there for the other half.
  String thanks(String name) =>
      _expand('thanks', read('thanks').replaceAll('{name}', name));

  /// A count of minutes, through a placeholder like [thanks].
  String readyIn(int minutes) =>
      _expand('readyIn', read('readyIn').replaceAll('{minutes}', '$minutes'));

  String _expand(String key, String expanded) =>
      wrapExpanded?.call(key, expanded) ?? expanded;

  String describe(String drinkId) => read('drink.$drinkId');
}

class _Delegate extends LocalizationsDelegate<ShopStrings> {
  const _Delegate();

  @override
  bool isSupported(Locale locale) =>
      ShopStrings.supported.contains(locale.languageCode);

  /// Reads this locale's file and the template's, once per locale.
  ///
  /// Asynchronous because that is what reading an asset is, and because
  /// `Localizations` is built for exactly this — no caller has to know the
  /// catalog is loaded rather than compiled in.
  @override
  Future<ShopStrings> load(Locale locale) async {
    var values = await _read(locale.languageCode);
    return ShopStrings(
      locale,
      values,
      locale.languageCode == ShopStrings.template
          ? values
          : await _read(ShopStrings.template),
    );
  }

  static final _cache = <String, Map<String, String>>{};

  static Future<Map<String, String>> _read(String locale) async {
    if (_cache[locale] case var cached?) return cached;
    var prefix = switch (ShopStrings.assetPackage) {
      var package? => 'packages/$package/',
      null => '',
    };
    var source = await rootBundle.loadString(
      '${prefix}assets/i18n/$locale.json',
    );
    return _cache[locale] = {
      for (var entry in (jsonDecode(source) as Map).entries)
        if (entry.value is String) '${entry.key}': entry.value as String,
    };
  }

  @override
  bool shouldReload(_Delegate old) => false;
}
