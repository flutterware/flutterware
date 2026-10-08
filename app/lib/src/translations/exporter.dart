/// Writing a survey out as a directory a translator can use.
///
/// The output is deliberately boring: whole screenshots, one JSON index, and a
/// page that reads it. Nothing is baked into the pixels — the highlight is
/// drawn from the rectangle at view time, by the page here and by whatever
/// service the JSON is pushed to. That is what lets **one frame serve every
/// key on it** instead of one cropped image per key, and it keeps the shot the
/// run captured rather than a derivative of it.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutterware/translations.dart';
import 'package:path/path.dart' as p;

import 'max_length.dart';
import 'index_html.dart';
import 'survey.dart';

/// What an export put on disk.
class WrittenExport {
  const WrittenExport({
    required this.output,
    required this.keysJson,
    required this.indexHtml,
    required this.export,
    required this.shots,
    required this.missingShots,
  });

  /// The directory, absolute.
  final String output;

  final String keysJson;
  final String indexHtml;

  final TranslationExport export;

  /// Frames copied in, deduplicated — several keys on one screen cost one
  /// file.
  final int shots;

  /// Frames a step named that were not on disk. Reported rather than thrown:
  /// an export missing one screenshot is worth more than no export.
  final int missingShots;
}

class TranslationExporter {
  TranslationExporter({required this.worktreeRoot});

  /// What a run's artifact paths are relative to.
  final String worktreeRoot;

  /// Where the export goes by default. Package-relative, and spelled
  /// with `/` because it is also what an action's help prints.
  static const defaultOutput = 'build/translations';

  static String defaultOutputIn(String packageRoot) =>
      p.join(packageRoot, 'build', 'translations');

  /// The frames' directory inside an export, relative to it.
  static const shotsDir = 'shots';

  /// Assembles and writes the whole thing.
  ///
  /// [captureScale] is what the run captured at, and turns the survey's
  /// logical rectangles into the image pixels the format promises. The
  /// exporter is the thing that chose the scale, so it is passed rather than
  /// inferred — measuring it back off a PNG header would be a second answer to
  /// a question already settled.
  /// [maxLengths] is what the probe proved, when one ran — attached per key
  /// and as findings. Probe shots (the box, the clip) come from probe-device
  /// runs whose scenario/step names collide with the main baseline's, so they
  /// are filed under their own subdirectories rather than sharing `shots/`.
  WrittenExport write({
    required TranslationSurvey survey,
    required String output,
    double captureScale = 1,
    TranslationMaxLengths? maxLengths,
  }) {
    var directory = Directory(output);
    // Cleared rather than merged into: a key deleted since the last export
    // would otherwise keep its screenshots here, where nothing links to them
    // and nothing ever removes them.
    if (directory.existsSync()) directory.deleteSync(recursive: true);
    directory.createSync(recursive: true);

    var copied = <String, String>{};
    // Distinct frames, not lookups: the same sighting is resolved twice — once
    // as the representative and again in the occurrence list — and counting
    // attempts reported one absent file as two.
    var missing = <String>{};

    /// Copies a frame in once, and answers with its export-relative path.
    ///
    /// [into] namespaces frames from a run other than the main baseline —
    /// the same scenario and step from two runs must not share one file.
    String? shotPath(KeySighting sighting, {String into = ''}) {
      var source = sighting.image;
      if (source.isEmpty) return null;
      if (copied[source] case var already?) return already;
      var from = File(p.join(worktreeRoot, source));
      if (!from.existsSync()) {
        missing.add(source);
        return null;
      }
      // Named for where it came from rather than hashed: somebody will open
      // this directory in a file browser, and `en/checkout_test.dart/3.png`
      // is the difference between browsing it and grepping the JSON.
      var relative = p.url.joinAll([
        shotsDir,
        if (into.isNotEmpty) into,
        _slug(sighting.locale ?? 'default'),
        _slug(sighting.scenario),
        '${sighting.stepIndex}${p.extension(source)}',
      ]);
      var to = File(p.join(output, relative.replaceAll('/', p.separator)));
      Directory(to.parent.path).createSync(recursive: true);
      from.copySync(to.path);
      copied[source] = relative;
      return relative;
    }

    ExportedShot? shotOf(KeySighting sighting, {String into = ''}) {
      var image = shotPath(sighting, into: into);
      if (image == null) return null;
      return ExportedShot(
        image: image,
        scenario: sighting.scenario,
        step: sighting.step,
        stepIndex: sighting.stepIndex,
        rect: ExportedRect.parse(sighting.rect, scale: captureScale),
        charStart: sighting.charStart,
        charEnd: sighting.charEnd,
        locale: sighting.locale,
        device: sighting.device,
        offstage: sighting.offstage,
        overflowed: sighting.overflowed,
      );
    }

    ExportedMaxLength? maxLengthOf(String id) {
      var measured = maxLengths?.byKey[id];
      if (measured == null) return null;
      return ExportedMaxLength(
        chars: measured.chars,
        fitsText: measured.fitsText,
        clipsChars: measured.clipsChars,
        clipsText: measured.clipsText,
        screen: switch (measured.screen) {
          var sighting? => shotOf(sighting, into: 'max-length'),
          _ => null,
        },
        clipped: switch (measured.clipped) {
          var sighting? => shotOf(sighting, into: 'max-length/clipped'),
          _ => null,
        },
        measuredOn: measured.screen?.device,
      );
    }

    var keys = <ExportedKey>[];
    var seen = <String>{};

    // Seen keys first, in the survey's own most-seen-first order — the order a
    // reader scrolling the page wants, and the order a push script should
    // upload in when it has a call budget.
    for (var id in survey.keysSeen) {
      var parts = id.split('/');
      var catalog = parts.first;
      var key = parts.skip(1).join('/');
      seen.add(id);
      var occurrences = survey.occurrencesOf(catalog, key);
      keys.add(
        ExportedKey(
          catalog: catalog,
          key: key,
          values: _valuesOf(survey, catalog, key),
          representative: switch (survey.representative(catalog, key)) {
            var pick? => shotOf(pick),
            _ => null,
          },
          occurrences: [
            for (var occurrence in occurrences) ?shotOf(occurrence),
          ],
          maxLength: maxLengthOf(id),
        ),
      );
    }

    // Then everything the catalogs declare that this run never showed, so
    // `keys` is the whole catalog rather than the part that photographed
    // well. A translator's list should not silently omit the untested screens.
    for (var catalog in survey.catalogs.values) {
      var sorted = catalog.keys.toList()..sort();
      for (var key in sorted) {
        if (seen.contains('${catalog.name}/$key')) continue;
        keys.add(
          ExportedKey(
            catalog: catalog.name,
            key: key,
            values: _valuesOf(survey, catalog.name, key),
          ),
        );
      }
    }

    var localeFindings = survey.localeFindings();
    var export = TranslationExport(
      directory: output,
      measuredMaxLengths: maxLengths != null,
      maxLengthDevices: maxLengths?.devices ?? const [],
      catalogs: [
        for (var catalog in survey.catalogs.values)
          ExportedCatalog(
            name: catalog.name,
            template: catalog.template,
            locales: catalog.byLocale.keys.toList()..sort(),
            keys: catalog.keys.length,
          ),
      ],
      keys: keys,
      findings: ExportFindings(
        fallingBack: [
          for (var finding in localeFindings)
            if (finding.verdict == LocaleVerdict.fallingBack) _finding(finding),
        ],
        disagrees: [
          for (var finding in localeFindings)
            if (finding.verdict == LocaleVerdict.disagrees) _finding(finding),
        ],
        notReached: [
          for (var key in survey.keysNotReached())
            ExportedKeyRef(catalog: key.catalog, key: key.key),
        ],
        absentFromCatalog: [
          for (var key in survey.keysAbsentFromCatalog())
            ExportedKeyRef(catalog: key.catalog, key: key.key),
        ],
        overflowing: [
          for (var sighting in survey.overflowing()) ?shotOf(sighting),
        ],
        unkeyed: [
          for (var word in survey.unkeyed)
            ExportedUnkeyed(
              text: word.text,
              scenario: word.scenario,
              step: word.step,
              source: word.source,
              locale: word.locale,
            ),
        ],
        expansionBreaks: [
          for (var broke in maxLengths?.breaks ?? const <MaxLengthBreak>[])
            ExportedExpansionBreak(
              scenario: broke.scenario,
              level: broke.level,
              step: broke.step,
              stepIndex: broke.stepIndex,
              overflows: broke.overflows,
              failure: broke.failure,
            ),
        ],
      ),
    );

    var keysJson = p.join(output, translationExportFile);
    // Indented, and this is not cosmetic: the format is deterministic on
    // purpose — no timestamp anywhere in it — so two exports of an unchanged
    // suite are byte-identical and `git diff` on the pair says what moved.
    // One line of JSON would make that diff useless.
    File(keysJson).writeAsStringSync(
      const JsonEncoder.withIndent('  ').convert(export.toJson()),
    );

    var indexHtml = p.join(output, 'index.html');
    File(indexHtml).writeAsStringSync(renderTranslationIndex(export));

    return WrittenExport(
      output: output,
      keysJson: keysJson,
      indexHtml: indexHtml,
      export: export,
      shots: copied.length,
      missingShots: missing.length,
    );
  }

  static ExportedLocaleFinding _finding(LocaleFinding finding) =>
      ExportedLocaleFinding(
        catalog: finding.catalog,
        key: finding.key,
        locale: finding.locale,
        rendered: finding.rendered,
        expected: finding.expected,
      );

  /// What every locale's file says for one key.
  static Map<String, String> _valuesOf(
    TranslationSurvey survey,
    String catalog,
    String key,
  ) {
    var loaded = survey.catalogs[catalog];
    if (loaded == null) return const {};
    return {
      for (var locale in loaded.byLocale.keys)
        locale: ?loaded.valueOf(locale, key),
    };
  }
}

/// A path segment safe on every filesystem, and still readable.
///
/// Readable is the requirement that rules out hashing: these directories are
/// browsed by hand.
String _slug(String value) => value
    .replaceAll(RegExp(r'[^A-Za-z0-9._/-]+'), '-')
    .replaceAll(RegExp(r'-+'), '-')
    .replaceAll(RegExp(r'^-|-$'), '');
