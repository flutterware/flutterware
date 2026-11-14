/// Assembling a [TranslationSurvey] out of a run and the catalog files.
///
/// The two halves reach this from different places — the run's artifacts
/// through whatever the panel or the export reads steps with, the catalogs
/// off the project's own directory — so both arrive as injected readers and
/// nothing here touches a filesystem. That is what lets the join be tested
/// against a run that was never written to disk.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutterware/plugins.dart';
import 'package:glob/glob.dart';
import 'package:path/path.dart' as p;

import '../plugins/native/scenarios_results.dart';
import 'survey.dart';

/// Reads one of a run's per-step artifacts, or null when it is not there.
///
/// A moved or deleted artifact must leave the survey buildable — the export
/// says a step has no keys, which is a better answer than no export.
typedef ArtifactReader = Future<String?> Function(String path);

/// Lists the files a catalog's glob matches, and reads them.
typedef CatalogReader = Future<Map<String, String>> Function(String filesGlob);

/// The locale a matrix point ran as, from the axes recorded on it.
///
/// `language` is what the axis is called on an address, and it is absent for a
/// run that named no language — which means the platform default rather than
/// an unknown, so it is reported as null and joined against nothing.
String? localeOf(Map<String, String>? axes) => axes?['language'];

/// Builds the whole-run index.
///
/// [readArtifact] is given each step's `keys` path verbatim, as the run
/// recorded it. [captureScale] is what the run captured at — a step reports
/// its size in image pixels and a rect arrives in logical ones, and the
/// ranking compares the two.
Future<TranslationSurvey> buildSurvey({
  required ScenarioRunResult run,
  required Map<String, LoadedCatalog> catalogs,
  required ArtifactReader readArtifact,
  double captureScale = 1,
}) async {
  var sightings = <KeySighting>[];
  var unkeyed = <UnkeyedSighting>[];
  var screenOverflows = <ScreenOverflow>[];
  var read = <String, Map<String, Map<String, String>>>{};

  for (var package in run.packages) {
    // The axis lives on the matrix point, not on the step: one package entry
    // is one assignment, which is exactly the scope a scenario's read set has.
    var locale = localeOf(package.axes) ?? localeOf(run.axes);
    for (var outcome in package.scenarios) {
      var scenario = '${outcome.file}/${outcome.name}';

      if (outcome.translations case var translations?) {
        // Merged rather than overwritten: two scenarios under the same locale
        // each read part of the catalog, and the union is what "this product
        // asks for" means. Two answers for one key cannot disagree within a
        // locale — the catalog is the same file — so first wins.
        var perLocale = read[locale ?? ''] ??= {};
        for (var entry in translations.entries) {
          var perCatalog = perLocale[entry.key] ??= {};
          for (var value in entry.value.entries) {
            perCatalog.putIfAbsent(value.key, () => value.value);
          }
        }
      }

      for (var step in outcome.steps) {
        var path = step.keys;
        if (path == null) continue;
        var source = await readArtifact(path);
        if (source == null) continue;
        var json = switch (jsonDecode(source)) {
          Map json => json.cast<String, Object?>(),
          _ => const <String, Object?>{},
        };
        var label = step.name ?? 'step ${step.index}';

        for (var entry in json['keys'] as List? ?? const []) {
          if (entry is! Map) continue;
          var key = entry.cast<String, Object?>();
          var rect = key['rect'] as String?;
          sightings.add(
            KeySighting(
              catalog: key['catalog'] as String? ?? '',
              key: key['key'] as String? ?? '',
              scenario: scenario,
              step: label,
              stepIndex: step.index,
              position: step.position,
              image: step.image ?? '',
              locale: locale,
              device: outcome.device ?? package.axes?['device'],
              rect: rect,
              area: _areaOf(rect),
              // Logical, to match the rect: the step's own size is in image
              // pixels, and a share computed against those would shift with
              // whatever the run was captured at.
              screenArea:
                  ((step.width ?? 0) *
                          (step.height ?? 0) /
                          (captureScale * captureScale))
                      .round(),
              charStart: key['start'] as int?,
              charEnd: key['end'] as int?,
              offstage: key['offstage'] as bool? ?? false,
              overflowed: key['overflowed'] as bool? ?? false,
              stepFailed: step.failure != null,
              textsOnScreen: step.texts.length,
            ),
          );
        }

        for (var entry in json['unkeyed'] as List? ?? const []) {
          if (entry is! Map) continue;
          var text = entry.cast<String, Object?>();
          unkeyed.add(
            UnkeyedSighting(
              text: text['text'] as String? ?? '',
              scenario: scenario,
              step: label,
              source: switch (text['source']) {
                Map source => _describeSource(source.cast<String, Object?>()),
                _ => null,
              },
              locale: locale,
            ),
          );
        }

        if (json['flexOverflows'] case num count when count > 0) {
          screenOverflows.add((
            scenario: scenario,
            step: label,
            stepIndex: step.index,
            position: step.position,
            locale: locale,
            count: count.toInt(),
          ));
        }
      }
    }
  }

  return TranslationSurvey(
    catalogs: catalogs,
    sightings: sightings,
    unkeyed: unkeyed,
    read: read,
    screenOverflows: screenOverflows,
  );
}

/// Loads every declared catalog.
///
/// A catalog whose glob matches nothing is **kept, empty**, rather than
/// dropped: a declaration pointing at the wrong place should show up as a
/// catalog with no keys and every read absent from it, which names the
/// problem, instead of vanishing and taking its keys' attribution with it.
Future<Map<String, LoadedCatalog>> loadCatalogs(
  List<TranslationCatalog> catalogs, {
  required CatalogReader read,
}) async {
  var loaded = <String, LoadedCatalog>{};
  for (var catalog in catalogs) {
    // Exhaustive over the variants, which is the point of the type: a format
    // added to the declaration cannot be forgotten here.
    var files = await switch (catalog) {
      FilePerLocaleCatalog(:var files) => read(files),
      LocalesPerKeyCatalog(:var file) => read(file),
    };
    var byLocale = <String, Map<String, String>>{};
    for (var entry in files.entries) {
      var json = switch (jsonDecode(entry.value)) {
        Map json => json,
        _ => const {},
      };
      switch (catalog) {
        case FilePerLocaleCatalog():
          var locale = _localeFromFileName(entry.key);
          if (locale == null) continue;
          byLocale[locale] = {
            for (var value in json.entries)
              if (value.value is String) '${value.key}': value.value as String,
          };
        case LocalesPerKeyCatalog():
          for (var row in json.entries) {
            if (row.value is! Map) continue;
            var key = '${row.key}';
            for (var perLocale in (row.value as Map).entries) {
              if (perLocale.value is! String) continue;
              // `@description` and its kin are notes for the translator, as
              // in an ARB file. Read as a locale, every key with a note would
              // add one more language that nobody declared.
              if ('${perLocale.key}'.startsWith('@')) continue;
              // Accumulated rather than assigned: a locale is spread across
              // every row here, where the other layout hands one whole locale
              // per file.
              (byLocale['${perLocale.key}'] ??= {})[key] =
                  perLocale.value as String;
            }
          }
      }
    }
    loaded[catalog.name] = LoadedCatalog(
      name: catalog.name,
      template: catalog.template,
      byLocale: byLocale,
      filesMatched: files.length,
    );
  }
  return loaded;
}

/// `…/en.json` to `en`, or null when the base name is not a locale tag.
///
/// A convention rather than a parse, and the null is deliberate: a stray file
/// beside the catalog — a schema, a README — should be skipped rather than
/// loaded as a locale called `schema`.
String? _localeFromFileName(String path) {
  var name = path.split(RegExp(r'[/\\]')).last;
  var dot = name.lastIndexOf('.');
  var base = dot < 0 ? name : name.substring(0, dot);
  return _localeTag.hasMatch(base) ? base : null;
}

final _localeTag = RegExp(r'^[a-z]{2,3}([-_][A-Za-z0-9]{2,8})*$');

int _areaOf(String? rect) {
  if (rect == null) return 0;
  var size = rect.split(' ').last.split('×');
  if (size.length != 2) return 0;
  var width = double.tryParse(size.first) ?? 0;
  var height = double.tryParse(size.last) ?? 0;
  return (width * height).round();
}

String _describeSource(Map<String, Object?> json) {
  var file = json['file'] as String? ?? '';
  var name = Uri.tryParse(file)?.pathSegments.lastOrNull ?? file;
  return '$name:${json['line'] ?? 0}:${json['column'] ?? 0}';
}

/// A [CatalogReader] over a project's own directory.
///
/// Split out from [loadCatalogs] rather than folded into it because the join
/// is worth testing against catalogs that were never written to disk — and
/// because the export will one day read a project it has only fetched.
CatalogReader catalogFilesUnder(String root) => (filesGlob) async {
  var found = <String, String>{};
  // Matched against paths relative to the project, always: a declared glob is
  // written by somebody looking at their own repository, and an absolute one
  // would only resolve on the machine it was written on.
  // **A path with no wildcard in it is a file, and naming one is ordinary** —
  // a whole catalog can be a single file. Left to the walk below it would be
  // opened as a directory, not exist, and read as nothing at all: an empty
  // catalog where the declaration was right.
  var literal = File(p.join(root, _literalPrefix(filesGlob)));
  if (literal.existsSync()) {
    return {p.relative(literal.path, from: root): literal.readAsStringSync()};
  }
  var glob = Glob(filesGlob);
  // **Start at the glob's own literal prefix.** `assets/i18n/*.json` is a walk
  // of one directory, and walking the package to find it is what made the
  // panel hang: a Flutter package's `build/` is enormous, and
  // `macos/Flutter/ephemeral/.symlinks` points back into the pub cache, so a
  // recursive listing of the root does not finish in any useful time — or at
  // all.
  var start = Directory(p.join(root, _literalPrefix(filesGlob)));
  if (!start.existsSync()) return found;
  await _walk(start, root, (file, relative) {
    if (!glob.matches(relative)) return;
    found[relative] = file.readAsStringSync();
  });
  return found;
};

/// The leading segments of [glob] that contain no wildcard.
///
/// `assets/i18n/*.json` is `assets/i18n`; `**/l10n/*.arb` is empty, and then
/// the walk below is what bounds the search instead.
String _literalPrefix(String glob) {
  var literal = <String>[];
  for (var segment in glob.split('/')) {
    if (segment.contains(RegExp(r'[*?\[{]'))) break;
    literal.add(segment);
  }
  return literal.join(Platform.pathSeparator);
}

/// Every file under [directory], **pruned**.
///
/// Hidden directories and `build/` are skipped whole, and links are not
/// followed. Not an optimisation: `.dart_tool` and the platform folders hold
/// symlinks into the pub cache and into each other, and a plain recursive
/// listing of a Flutter package walks them until something gives out.
Future<void> _walk(
  Directory directory,
  String root,
  void Function(File file, String relative) onFile,
) async {
  await for (var entity in directory.list(followLinks: false)) {
    var name = p.basename(entity.path);
    if (name.startsWith('.') || name == 'build') continue;
    if (entity is Directory) {
      await _walk(entity, root, onFile);
    } else if (entity is File) {
      onFile(entity, p.relative(entity.path, from: root));
    }
  }
}
