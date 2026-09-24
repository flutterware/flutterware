/// The listing's headlines — marketing copy, in a catalog of its own.
///
/// Decision 9. Not in `assets/i18n/`, where the app's own strings live: a
/// headline is never shown *in* the app, and mixing it in beside `Add to cart`
/// would send it to a translator as though it were UI. Its own directory, its
/// own catalog, declared separately in `tool/flutterware.dart` — which also
/// gives the Translations panel a second catalog to show.
///
/// This file is one project's answer, not an API. Decision 6 says flutterware
/// hands a frame `shot.slug` and `shot.locale` and has no opinion about where
/// the words live; this is what taking it up looks like.
///
/// **Read off disk, synchronously.** A frame's `build` cannot await, and a
/// composition that resolved its words a frame late would be captured before
/// they arrived. `rootBundle` is the usual answer and it is asynchronous, so
/// it is the wrong one here — the frame harness is a `flutter_tester` running
/// in the package root, and the catalog is a file. Read once, on the first
/// headline asked for, and the same JSON the Translations panel reads is the
/// only copy of these words that exists.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:ui';

import '../shop/shop_strings.dart';

/// The headline for a shot, or null where the listing has nothing to say about
/// that screen.
///
/// Null for a shot nobody wrote copy for: a listing that is not narrowed by a
/// tag takes every named shot in its file, and a frame that drew an empty band
/// for those would look worse than one that drew none.
String? storeHeadline(String slug, Locale locale) => _copy(slug, locale);

/// The line above the headline — what the shot is about, in two words.
String? storeKicker(String slug, Locale locale) =>
    _copy('$slug.kicker', locale);

String? _copy(String key, Locale locale) =>
    _catalog('assets/store', locale.languageCode)[key] ??
    _catalog('assets/store', 'en')[key];

/// The app's own strings, read the same way and for the same reason: a frame
/// that lifts one of the app's widgets out of the phone has to hand it the
/// words it reads, and `ShopStrings`' delegate reaches them through
/// `rootBundle`, which a frame cannot wait for.
ShopStrings shopStringsFor(Locale locale) => ShopStrings(
  locale,
  _catalog('assets/i18n', locale.languageCode),
  _catalog('assets/i18n', ShopStrings.template),
);

Map<String, String> _catalog(String directory, String locale) =>
    _loaded.putIfAbsent('$directory/$locale', () {
      var file = _find('$directory/$locale.json');
      if (file == null) return const {};
      return {
        for (var entry in (jsonDecode(file.readAsStringSync()) as Map).entries)
          '${entry.key}': '${entry.value}',
      };
    });

/// The catalog, from wherever the harness happens to have been started.
///
/// The frame harness runs in this package's root, so the plain relative path
/// is the answer there. A `previews` harness rendering the same frame may not
/// — and a headline silently missing from a preview is exactly the thing the
/// preview exists to check. Walking up a few levels costs three `stat`s and
/// removes the difference.
File? _find(String path) {
  var directory = Directory.current;
  for (var up = 0; up < 4; up++) {
    var candidate = File('${directory.path}/$path');
    if (candidate.existsSync()) return candidate;
    directory = directory.parent;
  }
  return null;
}

final _loaded = <String, Map<String, String>>{};
