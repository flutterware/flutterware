import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutterware/plugins.dart';
import 'package:flutterware_app/src/plugins/native/scenarios_results.dart';
import 'package:flutterware_app/src/translations/loader.dart';
import 'package:flutterware_app/src/translations/survey.dart';
import 'package:path/path.dart' as p;

ScenarioRunStep step({
  int index = 1,
  String? name = 'Home',
  String? keys = 'step.keys.json',
  List<String> texts = const ['a', 'b'],
  String? failure,
}) => ScenarioRunStep(
  index: index,
  position: 'root#$index',
  auto: false,
  image: 'step.png',
  format: 'png',
  width: 390,
  height: 844,
  tree: 'step.tree.json',
  keys: keys,
  texts: texts,
  address: 'fw:///x',
  name: name,
  failure: failure,
);

ScenarioRunResult run({
  List<ScenarioRunStep> steps = const [],
  Map<String, String>? axes,
  Map<String, Map<String, String>>? translations,
}) => ScenarioRunResult(
  packages: [
    ScenarioRunPackage(
      path: '.',
      output: '/out',
      axes: axes,
      ms: 1,
      scenarios: [
        ScenarioRunOutcome(
          file: 'home_test.dart',
          name: 'Home',
          ok: true,
          device: 'iphone-13',
          steps: steps,
          translations: translations,
        ),
      ],
    ),
  ],
);

String keysArtifact({
  List<Map<String, Object?>> keys = const [],
  List<Map<String, Object?>> unkeyed = const [],
}) => jsonEncode({'keys': keys, 'unkeyed': unkeyed});

void main() {
  group('building a survey from a run', () {
    test(
      "a step's keys become sightings carrying where they were seen",
      () async {
        var survey = await buildSurvey(
          run: run(steps: [step()], axes: {'language': 'nl'}),
          catalogs: const {},
          readArtifact: (path) async => keysArtifact(
            keys: [
              {
                'catalog': 'app',
                'key': 'save',
                'start': 0,
                'end': 4,
                'rect': '10,20 100×40',
              },
            ],
          ),
        );

        var sighting = survey.occurrencesOf('app', 'save').single;
        expect(sighting.scenario, 'home_test.dart/Home');
        expect(sighting.step, 'Home');
        expect(sighting.locale, 'nl');
        expect(sighting.device, 'iphone-13');
        expect(sighting.image, 'step.png');
        expect(sighting.area, 4000, reason: '100×40, for the ranking');
        expect(sighting.textsOnScreen, 2);
      },
    );

    test('a step with no keys artifact is skipped, not an error', () async {
      var survey = await buildSurvey(
        run: run(steps: [step(keys: null), step(index: 2)]),
        catalogs: const {},
        readArtifact: (path) async => null,
      );

      expect(survey.sightings, isEmpty);
    });

    test('a failed step marks its sightings', () async {
      var survey = await buildSurvey(
        run: run(steps: [step(failure: 'boom')]),
        catalogs: const {},
        readArtifact: (path) async => keysArtifact(
          keys: [
            {'catalog': 'app', 'key': 'save'},
          ],
        ),
      );

      expect(survey.sightings.single.stepFailed, isTrue);
    });

    test('unkeyed words carry where they were built', () async {
      var survey = await buildSurvey(
        run: run(steps: [step()]),
        catalogs: const {},
        readArtifact: (path) async => keysArtifact(
          unkeyed: [
            {
              'text': 'Fri, Dec 15',
              'node': '0/1',
              'source': {
                'file': 'file:///project/lib/home.dart',
                'line': 42,
                'column': 7,
              },
            },
          ],
        ),
      );

      expect(survey.unkeyed.single.text, 'Fri, Dec 15');
      expect(survey.unkeyed.single.source, 'home.dart:42:7');
    });

    test("the read set is filed under the point's locale", () async {
      var survey = await buildSurvey(
        run: run(
          axes: {'language': 'nl'},
          translations: {
            'app': {'save': 'Save'},
          },
        ),
        catalogs: {
          'app': const LoadedCatalog(
            name: 'app',
            template: 'en',
            byLocale: {
              'en': {'save': 'Save'},
              'nl': {},
            },
          ),
        },
        readArtifact: (path) async => null,
      );

      // The whole point of filing it by locale: this is only a finding
      // because the run was `nl` and `nl` has no text for the key.
      expect(survey.localeFindings().single.verdict, LocaleVerdict.fallingBack);
    });
  });

  group('loading catalogs', () {
    test('a file per locale becomes a locale per catalog', () async {
      var loaded = await loadCatalogs(
        [const TranslationCatalog(name: 'app', files: 'l10n/*.json')],
        read: (glob) async => {
          'l10n/en.json': '{"save":"Save"}',
          'l10n/nl.json': '{"save":"Opslaan"}',
        },
      );

      expect(loaded['app']!.byLocale.keys, containsAll(['en', 'nl']));
      expect(loaded['app']!.valueOf('nl', 'save'), 'Opslaan');
      expect(loaded['app']!.keys, {'save'});
    });

    test('a file that is not a locale is skipped, not loaded as one', () async {
      var loaded = await loadCatalogs(
        [const TranslationCatalog(name: 'app', files: 'l10n/*.json')],
        read: (glob) async => {
          'l10n/en.json': '{"save":"Save"}',
          'l10n/schema.json': '{"anything":"here"}',
        },
      );

      expect(loaded['app']!.byLocale.keys, ['en']);
    });

    test('a glob matching nothing keeps the catalog, empty', () async {
      var loaded = await loadCatalogs([
        const TranslationCatalog(name: 'app', files: 'nowhere/*.json'),
      ], read: (glob) async => {});

      // Kept rather than dropped: an empty catalog names the problem, a
      // missing one silently unattributes every key that belonged to it.
      expect(loaded, contains('app'));
      expect(loaded['app']!.keys, isEmpty);
    });

    test('a non-string value is left out rather than stringified', () async {
      var loaded = await loadCatalogs(
        [const TranslationCatalog(name: 'app', files: 'l10n/*.json')],
        read: (glob) async => {
          'l10n/en.json': '{"save":"Save","meta":{"note":"x"}}',
        },
      );

      expect(loaded['app']!.keys, {'save'});
    });

    test('every locale under each key becomes a locale per catalog', () async {
      var loaded = await loadCatalogs(
        [
          const TranslationCatalog.localesPerKey(
            name: 'server',
            file: 'strings.json',
          ),
        ],
        read: (glob) async => {
          'strings.json':
              '{"save":{"en":"Save","nl":"Opslaan"},'
              '"open":{"en":"Open"}}',
        },
      );

      expect(loaded['server']!.byLocale.keys, containsAll(['en', 'nl']));
      expect(loaded['server']!.valueOf('nl', 'save'), 'Opslaan');
      expect(loaded['server']!.keys, {'save', 'open'});
      // The locale that only one key answers for still holds only that key —
      // which is what makes the missing one a fallback rather than a silence.
      expect(loaded['server']!.valueOf('nl', 'open'), isNull);
    });

    test('a note beside the locales is not read as one', () async {
      var loaded = await loadCatalogs(
        [
          const TranslationCatalog.localesPerKey(
            name: 'server',
            file: 'strings.json',
          ),
        ],
        read: (glob) async => {
          'strings.json':
              '{"save":{"@description":"The button that saves the form",'
              '"en":"Save","nl":"Opslaan"},'
              '"open":{"@description":"Opens a file","en":"Open"}}',
        },
      );

      expect(loaded['server']!.byLocale.keys, unorderedEquals(['en', 'nl']));
      expect(loaded['server']!.keys, {'save', 'open'});
    });

    test('the file name carries nothing under localesPerKey', () async {
      var loaded = await loadCatalogs(
        [
          // Named for neither a locale nor anything else; under the other
          // layout this file is skipped for exactly that.
          const TranslationCatalog.localesPerKey(
            name: 'server',
            file: 'data/server_translations.json',
          ),
        ],
        read: (glob) async => {
          'data/server_translations.json': '{"save":{"en":"Save"}}',
        },
      );

      expect(loaded['server']!.keys, {'save'});
      expect(loaded['server']!.valueOf('en', 'save'), 'Save');
    });

    test('a key that is not an object is left out, not stringified', () async {
      var loaded = await loadCatalogs(
        [
          const TranslationCatalog.localesPerKey(
            name: 'server',
            file: 'strings.json',
          ),
        ],
        read: (glob) async => {
          'strings.json':
              '{"save":{"en":"Save"},"note":"a comment","n":{"en":1}}',
        },
      );

      // The same rule the other layout keeps, on both halves of the shape:
      // a value that is not text is not text.
      expect(loaded['server']!.keys, {'save'});
    });

    test('an empty catalog says which of the two mistakes it is', () async {
      var missing = await loadCatalogs([
        const TranslationCatalog(name: 'app', files: 'nowhere/*.json'),
      ], read: (glob) async => {});
      var misread = await loadCatalogs([
        const TranslationCatalog.localesPerKey(
          name: 'app',
          // The wrong one for this file, which is the mistake the count is
          // there to tell apart from a glob that found nothing.
          file: 'l10n/en.json',
        ),
      ], read: (glob) async => {'l10n/en.json': '{"save":"Save"}'});

      expect(missing['app']!.keys, isEmpty);
      expect(missing['app']!.filesMatched, 0);
      expect(misread['app']!.keys, isEmpty);
      expect(misread['app']!.filesMatched, 1);
    });

    test('the layouts are read as declared, not as the JSON looks', () async {
      var files = {'l10n/en.json': '{"save":"Save","meta":{"nl":"Opslaan"}}'};

      var perLocale = await loadCatalogs([
        const TranslationCatalog(name: 'app', files: 'l10n/*.json'),
      ], read: (glob) async => files);
      var perKey = await loadCatalogs([
        const TranslationCatalog.localesPerKey(
          name: 'app',
          file: 'l10n/en.json',
        ),
      ], read: (glob) async => files);

      // One file, two readings, and neither is wrong — which is the whole
      // reason the layout is declared. Sniffed, this file would have to be
      // one of them, and the `meta` object is exactly what a real catalog
      // carries beside its strings.
      expect(perLocale['app']!.byLocale.keys, ['en']);
      expect(perLocale['app']!.keys, {'save'});
      expect(perKey['app']!.byLocale.keys, ['nl']);
      expect(perKey['app']!.keys, {'meta'});
    });
  });

  group('reading a package off disk', () {
    late Directory package;

    setUp(() {
      package = Directory.systemTemp.createTempSync('fw-package');
      File(p.join(package.path, 'assets', 'i18n', 'en.json'))
        ..parent.createSync(recursive: true)
        ..writeAsStringSync('{"save":"Save"}');
    });
    tearDown(() => package.deleteSync(recursive: true));

    test('a path naming one file reads that file, not a directory', () async {
      File(p.join(package.path, 'tool', 'strings.json'))
        ..parent.createSync(recursive: true)
        ..writeAsStringSync('{"save":{"en":"Save"}}');

      var files = await catalogFilesUnder(package.path)('tool/strings.json');

      // A whole catalog can be one file, and a path with no wildcard in it is
      // the natural way to name it. The walk below starts at the glob's
      // literal prefix, which for this one is the file itself — opened as a
      // directory it does not exist, and the catalog reads as empty with the
      // declaration perfectly right.
      expect(files.keys, ['tool/strings.json']);
      expect(files.values.single, contains('Save'));
    });

    test('finds the catalog beside the package', () async {
      var files = await catalogFilesUnder(package.path)('assets/i18n/*.json');

      expect(files.keys, [p.join('assets', 'i18n', 'en.json')]);
    });

    test('does not descend into build or hidden directories', () async {
      // Not a tidiness rule — this is what made the panel hang. A Flutter
      // package's `build/` is enormous and `.dart_tool` holds links back into
      // the pub cache, so a plain recursive listing of the package root does
      // not finish.
      var decoy = File(p.join(package.path, 'build', 'i18n', 'en.json'))
        ..parent.createSync(recursive: true)
        ..writeAsStringSync('{"stale":"Stale"}');
      File(p.join(package.path, '.dart_tool', 'i18n', 'en.json'))
        ..parent.createSync(recursive: true)
        ..writeAsStringSync('{"stale":"Stale"}');

      var files = await catalogFilesUnder(package.path)('**/i18n/*.json');

      expect(
        files.keys,
        isNot(contains(p.relative(decoy.path, from: package.path))),
      );
      expect(files.keys, [p.join('assets', 'i18n', 'en.json')]);
    });

    test('a glob pointing nowhere reads as no files, not as a crawl', () async {
      var files = await catalogFilesUnder(package.path)('nowhere/*.json');

      expect(files, isEmpty);
    });
  });

  group('a probe pass artifact', () {
    test('surfaces its swallowed overflows as a screen fact', () async {
      var survey = await buildSurvey(
        run: run(steps: [step()]),
        catalogs: const {},
        readArtifact: (path) async =>
            jsonEncode({'keys': <Object?>[], 'flexOverflows': 3}),
      );

      var overflow = survey.screenOverflows.single;
      expect(overflow.scenario, 'home_test.dart/Home');
      expect(overflow.stepIndex, 1);
      expect(overflow.count, 3);
    });

    test('an ordinary artifact reports none', () async {
      var survey = await buildSurvey(
        run: run(steps: [step()]),
        catalogs: const {},
        readArtifact: (path) async => keysArtifact(),
      );

      expect(survey.screenOverflows, isEmpty);
    });
  });
}
