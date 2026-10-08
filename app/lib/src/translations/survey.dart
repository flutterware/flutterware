/// A whole run's translations, joined against the catalogs on disk.
///
/// Pure Dart and pure data: it is handed what a run captured and what the
/// catalog files say, and answers questions about the pair. No IO, so the
/// export, the panel and a test all reason about the same object.
library;

/// One catalog's files, loaded — locale to key to value.
class LoadedCatalog {
  const LoadedCatalog({
    required this.name,
    required this.template,
    required this.byLocale,
    this.filesMatched = 0,
  });

  final String name;

  /// How many files the glob found, whatever they turned out to hold.
  ///
  /// Kept beside [keys] so an empty catalog can say *which* mistake it is: a
  /// glob that matched nothing, or files that were found and read as the wrong
  /// kind of catalog, yielding no key. The two are one sentence apart and send
  /// a reader to opposite ends of the declaration.
  final int filesMatched;

  /// The locale the source text is written in.
  final String template;

  final Map<String, Map<String, String>> byLocale;

  /// Every key the catalog defines anywhere — the denominator for "never
  /// reached", and deliberately the union rather than the template's alone: a
  /// key present only in a target locale is a key, and usually a stale one.
  Set<String> get keys => {for (var values in byLocale.values) ...values.keys};

  /// What this locale says, or null when it says nothing. Empty is nothing:
  /// catalogs spell a missing translation as `""` about as often as they
  /// leave the key out.
  String? valueOf(String locale, String key) {
    var value = byLocale[locale]?[key];
    return value == null || value.isEmpty ? null : value;
  }
}

/// One place a key was seen, on one captured screen.
class KeySighting {
  const KeySighting({
    required this.catalog,
    required this.key,
    required this.scenario,
    required this.step,
    required this.stepIndex,
    required this.position,
    required this.image,
    this.locale,
    this.device,
    this.rect,
    this.area = 0,
    this.screenArea = 0,
    this.charStart,
    this.charEnd,
    this.offstage = false,
    this.overflowed = false,
    this.stepFailed = false,
    this.textsOnScreen = 0,
  });

  final String catalog;
  final String key;

  /// `file/name`, as the run reports a scenario.
  final String scenario;
  final String step;
  final int stepIndex;

  /// The step's shape-stable position (`ScenarioRunStep.position`) — what
  /// pairs a cell across passes. Never the index: steps merge under adoption
  /// and a no-op scroll takes none in a pixel pass, so indices shift between
  /// the passes a probe compares, while a position is consumed either way.
  final String position;

  /// The captured frame this was seen on — what a translator is shown.
  final String image;

  final String? locale;
  final String? device;

  /// `x,y w×h` in logical pixels, as the capture recorded it. The export
  /// scales it into image pixels; nothing downstream should have to.
  final String? rect;
  final int area;

  /// The whole frame's area, in the same units as [area].
  ///
  /// Kept so the ranking can ask what *share* of the screen the words take
  /// rather than how many pixels they are. Absolute pixels made a desktop
  /// window beat a phone every time, whatever the string looked like on
  /// either — so a phone app with one desktop scenario sent translators
  /// desktop screenshots.
  final int screenArea;

  /// The span inside its paragraph — what lets a key sharing a `Text` with two
  /// others still be pointed at exactly.
  final int? charStart;
  final int? charEnd;

  final bool offstage;
  final bool overflowed;
  final bool stepFailed;

  /// How much else was on the screen — the difference between a string shown
  /// in its context and a string shown on a spinner.
  final int textsOnScreen;

  String get id => '$catalog/$key';
}

/// Words on a screen that belonged to no catalog.
class UnkeyedSighting {
  const UnkeyedSighting({
    required this.text,
    required this.scenario,
    required this.step,
    this.source,
    this.locale,
  });

  final String text;
  final String scenario;
  final String step;

  /// Where the widget was built — what turns this from a list into somewhere
  /// to go.
  final String? source;
  final String? locale;
}

/// What a key's value did, in one locale, on one run.
enum LocaleVerdict {
  /// The locale has its own text and that is what rendered.
  translated,

  /// The locale has nothing, so the template's text rendered instead — the
  /// app is showing untranslated words to a user who asked for this language.
  fallingBack,

  /// The locale has text, and something else rendered. The catalog on disk
  /// is not what the app ran with: a stale build, or a value overridden
  /// somewhere the files do not know about.
  disagrees,
}

class LocaleFinding {
  const LocaleFinding({
    required this.catalog,
    required this.key,
    required this.locale,
    required this.verdict,
    required this.rendered,
    this.expected,
  });

  final String catalog;
  final String key;
  final String locale;
  final LocaleVerdict verdict;
  final String rendered;
  final String? expected;
}

/// Layout overflow errors one step swallowed under a budget probe — a fact
/// about the screen, not about any one key, because every value on it was
/// expanded at once.
typedef ScreenOverflow = ({
  String scenario,
  String step,
  int stepIndex,
  String position,
  String? locale,
  int count,
});

/// A run's translations, and what the catalogs make of them.
class TranslationSurvey {
  TranslationSurvey({
    required this.catalogs,
    required List<KeySighting> sightings,
    required this.unkeyed,
    required this.read,
    this.screenOverflows = const [],
  }) : _sightings = sightings {
    for (var sighting in sightings) {
      (_byKey[sighting.id] ??= []).add(sighting);
    }
  }

  final Map<String, LoadedCatalog> catalogs;
  final List<KeySighting> _sightings;
  final Map<String, List<KeySighting>> _byKey = {};

  final List<UnkeyedSighting> unkeyed;

  /// Nonzero only on a probe pass's survey — an ordinary run fails on
  /// overflow instead of recording it.
  final List<ScreenOverflow> screenOverflows;

  /// What each catalog was asked for and answered, per locale:
  /// `locale -> catalog -> key -> value`.
  ///
  /// The keys a run *read*, which is a larger set than the keys it *showed*:
  /// a string read into a variable and never rendered is in here and in no
  /// sighting. That difference is the whole of [keysNotReached] being a claim
  /// about the product rather than about one screen.
  final Map<String, Map<String, Map<String, String>>> read;

  List<KeySighting> get sightings => List.unmodifiable(_sightings);

  /// Every key that was seen, most-seen first.
  List<String> get keysSeen {
    var ids = _byKey.keys.toList();
    ids.sort((a, b) => _byKey[b]!.length.compareTo(_byKey[a]!.length));
    return ids;
  }

  List<KeySighting> occurrencesOf(String catalog, String key) =>
      List.unmodifiable(_byKey['$catalog/$key'] ?? const []);

  /// Keys the catalogs define that this run never asked for.
  ///
  /// Phrased as "not reached", never as "unused". It is a statement about the
  /// suite's coverage as much as about the product: a key may still be in use
  /// on a screen no scenario covers.
  List<({String catalog, String key})> keysNotReached() {
    var found = <({String catalog, String key})>[];
    for (var catalog in catalogs.values) {
      var reached = <String>{
        for (var perCatalog in read.values) ...?perCatalog[catalog.name]?.keys,
      };
      for (var key in catalog.keys) {
        if (!reached.contains(key)) {
          found.add((catalog: catalog.name, key: key));
        }
      }
    }
    return found..sort((a, b) => a.key.compareTo(b.key));
  }

  /// Keys the run read that no declared catalog defines.
  ///
  /// Either the code asks for something stale, or a catalog's `files:` does
  /// not point where its keys actually live. Both are worth saying out loud —
  /// a half-declared catalog would otherwise show up as an export that
  /// quietly attributed nothing.
  List<({String catalog, String key})> keysAbsentFromCatalog() {
    var found = <({String catalog, String key})>{};
    for (var perCatalog in read.values) {
      for (var entry in perCatalog.entries) {
        var catalog = catalogs[entry.key];
        for (var key in entry.value.keys) {
          if (catalog == null || !catalog.keys.contains(key)) {
            found.add((catalog: entry.key, key: key));
          }
        }
      }
    }
    return found.toList()..sort((a, b) => a.key.compareTo(b.key));
  }

  /// Every key a target locale has no words for, and every key whose rendered
  /// words disagree with the file.
  ///
  /// The two halves come from different places, because only one source can
  /// establish each. Falling back is a fact about the *files*: the template
  /// has text, the target has none, so whatever renders there is the source
  /// language. It needs no run, which is why it is the same list the panel's
  /// empty cells show and why an export of one locale reports it in full.
  /// Disagreeing needs the run — it is the files against what actually
  /// reached the screen — so it is reported only for the locales that ran.
  List<LocaleFinding> localeFindings() {
    var found = <LocaleFinding>[];

    for (var catalog in catalogs.values) {
      for (var locale in catalog.byLocale.keys) {
        if (locale == catalog.template) continue;
        for (var key in catalog.keys) {
          var source = catalog.valueOf(catalog.template, key);
          // A key with no text in the source language either does not draw or
          // is a stale entry; either way there is nothing to fall back *to*.
          if (source == null) continue;
          if (catalog.valueOf(locale, key) != null) continue;
          found.add(
            LocaleFinding(
              catalog: catalog.name,
              key: key,
              locale: locale,
              verdict: LocaleVerdict.fallingBack,
              rendered: source,
            ),
          );
        }
      }
    }

    for (var perLocale in read.entries) {
      var locale = perLocale.key;
      for (var perCatalog in perLocale.value.entries) {
        var catalog = catalogs[perCatalog.key];
        if (catalog == null || locale == catalog.template) continue;
        for (var entry in perCatalog.value.entries) {
          if (!catalog.keys.contains(entry.key)) continue;
          var expected = catalog.valueOf(locale, entry.key);
          // Nothing on file is the fallback case above, already reported.
          if (expected == null || expected == entry.value) continue;
          if (entry.value.isEmpty) continue;
          found.add(
            LocaleFinding(
              catalog: perCatalog.key,
              key: entry.key,
              locale: locale,
              verdict: LocaleVerdict.disagrees,
              rendered: entry.value,
              expected: expected,
            ),
          );
        }
      }
    }

    return found..sort((a, b) => a.key.compareTo(b.key));
  }

  /// Every sighting where the words did not fit — the localisation bug list.
  List<KeySighting> overflowing() => [
    for (var sighting in _sightings)
      if (sighting.overflowed) sighting,
  ];

  /// The occurrence worth showing a translator, or null when a key was never
  /// seen.
  ///
  /// Ranked, not first-found. A key appears on a loading screen, clipped
  /// in a list, and once in the place it was designed for; only the last of
  /// those is worth a translator's time. In order: on screen at all, then not
  /// clipped, then the step succeeded, then the screen has other words on it
  /// (context beats a spinner), then the biggest box.
  KeySighting? representative(String catalog, String key) {
    var candidates = occurrencesOf(catalog, key);
    if (candidates.isEmpty) return null;
    var ranked = candidates.toList()
      ..sort((a, b) {
        var score = _score(b).compareTo(_score(a));
        if (score != 0) return score;
        // **Broken all the way down, on purpose.** Ties are common — two shots
        // of the same button on two screens score identically — and a
        // comparator that returns 0 for them leaves the winner to the order the
        // list happened to arrive in. That order changes when an unrelated
        // scenario is added, so the picture a translator was sent last week
        // silently becomes a different one. Scenario, then step, then index:
        // total, and stable against anything happening elsewhere in the suite.
        var scenario = a.scenario.compareTo(b.scenario);
        if (scenario != 0) return scenario;
        var step = a.step.compareTo(b.step);
        return step != 0 ? step : a.stepIndex.compareTo(b.stepIndex);
      });
    return ranked.first;
  }

  /// Prominence first, and prominence is a share of the screen.
  ///
  /// The weights were measured rather than guessed, on a suite that runs both
  /// phone and desktop scenarios. Two of them started out wrong and both
  /// pulled the same way — toward the desktop window, for a phone app:
  ///
  /// * clipping cost 500, and text ellipsizes far more often on a phone, so
  ///   the narrow device was penalised for being narrow. It is worth a
  ///   tiebreak between two shots of one screen and nothing more — which is
  ///   also all the confidence `didExceedMaxLines` deserves.
  /// * "how much else is on screen" was worth up to 80, and a desktop layout
  ///   shows more of everything at once. Its point was only to prefer a real
  ///   screen over a spinner, and a low cap makes that point just as well.
  static int _score(KeySighting sighting) {
    var score = 0;
    // Not on screen at all is disqualifying, not a preference.
    if (!sighting.offstage) score += 1000;
    if (sighting.screenArea > 0) {
      score += (sighting.area / sighting.screenArea * 2000).round().clamp(
        0,
        400,
      );
    }
    score += sighting.textsOnScreen.clamp(0, 12) * 3;
    if (!sighting.overflowed) score += 60;
    if (!sighting.stepFailed) score += 40;
    return score;
  }
}
