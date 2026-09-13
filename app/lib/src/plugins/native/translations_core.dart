import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutterware/plugins.dart';
import 'package:flutterware/translations.dart';
import 'package:path/path.dart' as p;

import '../../session/job.dart';
import '../../translations/max_length.dart';
import '../../translations/exporter.dart';
import '../../translations/loader.dart';
import '../../translations/row.dart';
import '../../translations/survey.dart';
import '../plugin_core.dart';
import '../plugin_host.dart';
import '../scan_cache.dart';
import 'scenarios_core.dart';
import 'scenarios_results.dart';
import 'translations_address.dart';
import 'translations_results.dart';

/// The registered id — also what `tool/flutterware.dart` declares.
const translationsPluginId = 'flutterware.translations';

/// What this plugin is, for a reader who has only the id — see
/// `PluginReport.description`.
const _pluginDescription =
    'Which translation key is on which screen, which locales are still missing '
    'one, and a picture of each string in the place it appeared.';

/// Which translation key is on which screen, and a picture of it.
///
/// Two halves that only answer together. A run knows **where a key appeared**,
/// because the app's catalog was funnelled through `indexTranslations` and
/// every string it rendered can be traced back by object identity. The files
/// on disk know **which keys exist and what each locale says**. Put them side
/// by side and the same pass that answers "show me this string in context"
/// also answers "where are we still showing English to a Dutch user" — for
/// free, because both halves were already needed.
///
/// Holds to the two rules every core holds to: the constructor allocates
/// nothing, and [report] only formats what a previous call caused to load.
/// Loading here is reading and parsing the catalog JSON — the run that
/// produces the screens is behind the `export` action, where a caller chose it
/// by name.
class TranslationsCore extends PluginCore {
  TranslationsCore(super.host, {TranslationSource? source})
    : source = source ?? const LiveTranslationSource();

  /// Where the catalogs, the export and its pictures are read from — the
  /// package's directory unless a recording is standing in for one.
  final TranslationSource source;

  /// Declared packages, filtered to those the workspace knows about, so a typo
  /// cannot make the plugin scan a directory that is not there.
  late final List<String> packages = [
    for (var path in host.packagePaths)
      if (host.workspace.exists(path)) path,
  ];

  /// Retries a failed load on the next look, deliberately: the panel has no
  /// refresh button, so a fixed ARB file coming back on remount is the only
  /// recovery it offers.
  late final _cache = ScanCache<String, Map<String, LoadedCatalog>>(
    scan: _scan,
    onChanged: notifyChanged,
    onSettled: _forget,
    retryAfterFailure: true,
  );

  /// The last export, **read back off disk** rather than kept from the run
  /// that produced it.
  ///
  /// Three things follow from reading it rather than remembering it. It
  /// survives a restart and a config reload — which swaps cores under mounted
  /// panels, so a core that only remembered would go permanently cold. It
  /// costs one JSON parse, which is inside [computeAll]'s budget. And it makes
  /// the panel the published reader's first consumer: if
  /// `package:flutterware/translations.dart` is wrong, it is wrong here, in
  /// front of whoever is about to ship it, rather than in somebody's script
  /// weeks later.
  final _exports = <String, ({TranslationExport export, DateTime at})>{};

  /// What `export` says while it is running.
  final _busy = <String, String>{};

  /// How far the pass named by [busyFor] has got, mirrored off the scenarios
  /// core that is running it.
  final _progress = <String, ({int done, int? total})>{};

  /// The catalogs declared for [path], dropping any whose layout this build
  /// cannot read — see [TranslationCatalog.fromJson]. [declaredCountFor] is
  /// what the config actually held, so the difference can be reported rather
  /// than read as "none declared".
  List<TranslationCatalog> declaredFor(String path) {
    return [
      for (var entry in _rawCatalogsFor(path))
        ?TranslationCatalog.fromJson(entry),
    ];
  }

  /// How many catalogs the config declared, readable or not.
  int declaredCountFor(String path) => _rawCatalogsFor(path).length;

  List<Map<String, Object?>> _rawCatalogsFor(String path) {
    for (var config in host.packageConfigs) {
      if (config['path'] != path) continue;
      return [
        for (var entry in config['catalogs'] as List? ?? const [])
          if (entry is Map) entry.cast<String, Object?>(),
      ];
    }
    return const [];
  }

  /// The loaded catalogs for [path], or null when nothing has read them yet.
  Map<String, LoadedCatalog>? catalogsFor(String path) => _cache[path];

  String? failureFor(String path) => _cache.failureFor(path);

  /// The last export for [path], or null when none has been written.
  TranslationExport? exportFor(String path) => _exports[path]?.export;

  /// When it was written. Off the file's own timestamp, deliberately: the
  /// format carries no time of its own so that two exports of an unchanged
  /// suite stay byte-identical, and the filesystem already knows this.
  DateTime? exportedAt(String path) => _exports[path]?.at;

  /// Where a row *is*.
  ///
  /// Built here rather than left to a reader to reassemble, which is how two
  /// surfaces come to disagree about what a thing is called.
  Address addressFor(
    String package, {
    String? catalog,
    String? key,
    String? locale,
    TranslationFilter filter = TranslationFilter.all,
  }) => Address(
    worktree: host.worktree.name,
    plugin: host.id,
    segments: translationSegments(package, catalog: catalog, key: key),
    axes: translationAxes(locale: locale, filter: filter),
  );

  /// Where an export for [path] is looked for.
  String exportDirectoryFor(String path) =>
      source.exportDirectoryIn(host.workspace.packageFor(path).directory.path);

  /// Every locale any of [path]'s catalogs has a file for, sorted.
  ///
  /// This is what an export runs across when the caller names no languages:
  /// the set the project actually ships, which is the only set for which
  /// "this locale is falling back" is a statement worth making.
  List<String> localesFor(String path) {
    var found = <String>{};
    for (var catalog in _cache[path]?.values ?? const <LoadedCatalog>[]) {
      found.addAll(catalog.byLocale.keys);
    }
    return found.toList()..sort();
  }

  void track(String path) => _cache.track(path);

  /// Drops the cached catalogs so the next read re-parses. What the panel
  /// calls when a translation file changes underneath it.
  void invalidate(String path) {
    _cache.invalidate(path);
    _forget(path);
  }

  @override
  Future<void> computeAll() async {
    await Future.wait([for (var path in packages) _cache.load(path)]);
  }

  Future<Map<String, LoadedCatalog>> _scan(String path) async {
    var root = host.workspace.packageFor(path).directory.path;
    var catalogs = await loadCatalogs(
      declaredFor(path),
      read: source.catalogsUnder(root),
    );
    await _loadExport(path);
    return catalogs;
  }

  /// Reads the export beside [path], if there is one.
  ///
  /// Best effort and quiet about it: an export that is absent, half-written or
  /// from a version this build cannot read must not take the catalogs down
  /// with it. The table is useful with no export at all, which is the whole
  /// reason the panel does not wait for one.
  Future<void> _loadExport(String path) async {
    ({TranslationExport export, DateTime at})? read;
    try {
      read = await source.readExport(exportDirectoryFor(path));
    } catch (_) {
      read = null;
    }
    if (read == null) {
      _exports.remove(path);
    } else {
      _exports[path] = read;
    }
    // Half the join moved, so the rows built from it are gone. This is the
    // half that moves outside a scan — the export written by the action above
    // is re-read here, with the panel already mounted over the old one.
    _forget(path);
  }

  /// Every key the catalogs define, with what each locale says and the shot
  /// the last export found for it.
  ///
  /// Values come from the files rather than from the export, because the files
  /// are what was just edited and the export is from whenever it last ran. A
  /// row whose text disagrees with its picture is a stale export, shown as
  /// one.
  ///
  /// **Held, not rebuilt.** One sidebar frame asks for this eight times — the
  /// badge, the child row and four readings in the view, then the panel and
  /// its strip — and every plugin's notification is a sidebar frame. Built
  /// each time it cost 324ms a frame on a 2000-key project once an export
  /// existed, which is a studio that does not scroll. Dropped by
  /// [_forget] wherever the two halves it joins can move.
  List<TranslationRow> rowsFor(String path) => _rows[path] ??= _buildRows(path);

  final _rows = <String, List<TranslationRow>>{};

  /// Drops what [path]'s catalogs and export were joined into. Called from
  /// both halves — a re-scan and a re-read of the export — because a row is
  /// only as fresh as the staler of the two.
  void _forget(String path) {
    _rows.remove(path);
    _missing.remove(path);
    _withoutPicture.remove(path);
  }

  List<TranslationRow> _buildRows(String path) {
    var catalogs = _cache[path];
    if (catalogs == null) return const [];
    var export = _exports[path]?.export;
    var rows = <TranslationRow>[];
    for (var catalog in catalogs.values) {
      var keys = catalog.keys.toList()..sort();
      for (var key in keys) {
        var exported = export?['${catalog.name}/$key'];
        rows.add(
          TranslationRow(
            catalog: catalog.name,
            key: key,
            template: catalog.template,
            values: {
              for (var locale in catalog.byLocale.keys)
                locale: ?catalog.valueOf(locale, key),
            },
            shot: exported?.representative,
            occurrences: exported?.occurrences ?? const [],
            maxLength: exported?.maxLength,
          ),
        );
      }
    }
    return rows;
  }

  /// The template locale of [path]'s first catalog — what a switch starts on
  /// and what stays pinned beside whatever it switches to.
  String templateFor(String path) =>
      _cache[path]?.values.firstOrNull?.template ?? 'en';

  /// Whether the last export measured max lengths — what gates the fragile
  /// filter and the column: an unprobed table must not offer a filter whose
  /// emptiness reads as room.
  bool measuredMaxLengthsFor(String path) =>
      _exports[path]?.export.measuredMaxLengths ?? false;

  /// Whether the panel's Export button measures max lengths for [path].
  ///
  /// Until the user says otherwise it follows the export on disk, so the
  /// button reproduces what the panel is showing: a table with a Max length
  /// column must not have its own control silently wipe that column. The
  /// override is not persisted — the next session reads the answer off the
  /// export again, which remembers the same thing.
  bool measureOnExport(String path) =>
      _measureOnExport[path] ?? measuredMaxLengthsFor(path);

  void setMeasureOnExport(String path, bool value) {
    if (measureOnExport(path) == value) return;
    _measureOnExport[path] = value;
    notifyChanged();
  }

  final _measureOnExport = <String, bool>{};

  /// What a running export is doing right now — "measuring max lengths —
  /// +40%" — for the strip that replaced its button with a spinner. A
  /// measuring export takes minutes rather than seconds, and a silent spinner
  /// that long reads as a hang.
  String? busyFor(String path) => _busy[path];

  /// Scenarios done out of scenarios to run, for the pass [busyFor] names.
  ///
  /// The pass, not the export: an export is a run per locale, and — when it
  /// measures — a baseline, up to ten padded passes and a photograph of each
  /// level that clipped. How many of those there will be is not knowable
  /// before they run, because the ladder stops as soon as every measurable key
  /// has clipped. So the bar fills once per pass and the phrase beside it says
  /// which pass, which is the pair that never lies.
  ({int done, int? total})? progressFor(String path) => _progress[path];

  /// Whether the last export traced nothing at all.
  ///
  /// Not "photographed nothing": no key was so much as *read*, which is what
  /// an unwired seam looks like from here — the export ran the suite, wrote
  /// its frames, and had nothing to attach them to. The panel says so, because
  /// the alternative is a table of "No picture" that a person reads as a
  /// coverage problem and goes looking for missing scenarios.
  bool untracedFor(String path) {
    var export = _exports[path]?.export;
    if (export == null || export.keys.isEmpty) return false;
    return export.seen.isEmpty &&
        export.findings.notReached.length == export.keys.length;
  }

  @override
  PluginReport get report => PluginReport(
    id: host.id,
    label: host.label,
    description: _pluginDescription,
    // Quiet when unconfigured. A project with no catalogs is not in trouble,
    // it just does not use the feature — the panel is where the setup
    // instructions live, and a permanent warning in the rail taught people to
    // stop reading the slot. Same policy as every other plugin's row.
    status: Status.none,
    badge: _badge,
    children: [
      for (var path in packages)
        PluginChild(
          id: path,
          label: path == '.' ? 'root' : path,
          status: _childStatus(path),
        ),
    ],
    actions: _actions,
    view: _view,
  );

  /// **Only what stops the plugin from working.** A catalog that will not
  /// read is the rail's business; how many keys are still untranslated is
  /// not. That count is a fact about the product, it is true for months at a
  /// time, and a permanent amber dot beside a working plugin is how a rail
  /// teaches people to stop reading it. It is on the panel, where someone
  /// went to look.
  StatusBadge get _badge {
    for (var path in packages) {
      if (_cache.failureFor(path) != null) {
        return const StatusBadge.dot(Tone.error);
      }
    }
    return StatusBadge.none;
  }

  /// Keys some target locale has no text for.
  int missingFor(String path) => _missing[path] ??= _countMissing(path);

  final _missing = <String, int>{};

  int _countMissing(String path) {
    var locales = localesFor(path);
    var count = 0;
    for (var row in rowsFor(path)) {
      if (row.missingAnywhere(locales)) count++;
    }
    return count;
  }

  /// Keys the last export has no shot for — including all of them when there
  /// is no export.
  int withoutPictureFor(String path) =>
      _withoutPicture[path] ??= _countWithoutPicture(path);

  final _withoutPicture = <String, int>{};

  int _countWithoutPicture(String path) {
    var count = 0;
    for (var row in rowsFor(path)) {
      if (!row.hasPicture) count++;
    }
    return count;
  }

  Status _childStatus(String path) {
    if (_busy[path] case var message?) return Status.info(message);
    if (_cache.failureFor(path) case var failure?) return Status.error(failure);
    var declared = declaredFor(path);
    // Dropped rather than guessed at, so the count is the only thing that can
    // tell "declared nothing" from "declared something this build is too old
    // to read". Silently, the second reads as the first.
    var unreadable = declaredCountFor(path) - declared.length;
    if (unreadable > 0) {
      return Status.error(
        unreadable == 1
            ? 'A catalog uses a layout this flutterware cannot read'
            : '$unreadable catalogs use a layout this flutterware cannot read',
      );
    }
    if (declared.isEmpty) return const Status.warn('No catalogs declared');
    var loaded = _cache[path];
    if (loaded == null) return Status.none;
    // A catalog that defines no key is the mistake worth shouting about:
    // everything downstream still works, and quietly attributes nothing. Which
    // mistake it is decides where to look, so the two are named apart — a glob
    // that found nothing is a path, and files that yielded nothing is almost
    // always the layout they were read under.
    var empty = [
      for (var catalog in loaded.values)
        if (catalog.keys.isEmpty) catalog,
    ];
    if (empty.isNotEmpty) {
      var unread = [
        for (var catalog in empty)
          if (catalog.filesMatched > 0) catalog.name,
      ];
      if (unread.isNotEmpty) {
        return Status.error(
          unread.length == 1
              ? 'Catalog "${unread.single}" read no keys from its files — '
                    'check its layout'
              : '${unread.length} catalogs read no keys from their files — '
                    'check their layout',
        );
      }
      return Status.error(
        empty.length == 1
            ? 'Catalog "${empty.single.name}" matched no files'
            : '${empty.length} catalogs matched no files',
      );
    }
    var rows = rowsFor(path);
    return Status.good('${rows.length} keys · ${localesFor(path).join(', ')}');
  }

  PluginView get _view => PluginView([
    if (packages.isEmpty)
      const ViewText(
        'Declare a package with its catalogs in tool/flutterware.dart:\n'
        'fw.use(Translations(packages: [TranslationsPackage(app, catalogs: '
        "[TranslationCatalog(name: 'app', files: 'assets/i18n/*.json')])]));",
      ),
    for (var path in packages)
      ViewSection(path == '.' ? 'root' : path, [
        if (_cache.failureFor(path) case var failure?)
          ViewText(failure)
        else ...[
          for (var catalog in _cache[path]?.values ?? const <LoadedCatalog>[])
            ViewField(
              catalog.name,
              '${catalog.keys.length} keys · '
              '${catalog.byLocale.keys.join(', ')} · '
              'from ${catalog.template}',
            ),
          if (missingFor(path) case var missing when missing > 0)
            ViewField('Untranslated somewhere', '$missing keys'),
          if (_exports[path] != null)
            ViewField(
              'Pictures',
              '${rowsFor(path).length - withoutPictureFor(path)} '
                  'of ${rowsFor(path).length} keys',
            )
          else
            const ViewText('No export yet — run it to add a picture per key.'),
        ],
      ]),
  ]);

  List<PluginAction> get _actions => [
    PluginAction(
      exportActionId,
      'Export',
      returns: TranslationExportResult,
      description:
          'Runs the scenarios across every locale the catalogs have, and '
          'writes a directory a translator can read: the screenshots, a '
          '`keys.json` of key to where it was seen, and a page that draws the '
          'box. Nothing is cropped and nothing is drawn into the pixels — the '
          'rectangle rides in the JSON, so the same file serves this page and '
          'a translation service. Read it back typed with '
          '`package:flutterware/translations.dart`.',
      parameters: [
        ActionParameter(
          'package',
          'Package',
          kind: ActionParameterKind.choice,
          required: false,
          description: 'Which declared package; the only one when there is one',
          options: [for (var path in packages) ActionOption(path)],
        ),
        const ActionParameter(
          'output',
          'Output',
          kind: ActionParameterKind.string,
          required: false,
          description:
              'Where the directory goes. Defaults to '
              '`${TranslationExporter.defaultOutput}` in the package, and is '
              'emptied first.',
        ),
        const ActionParameter(
          'languages',
          'Languages',
          kind: ActionParameterKind.string,
          required: false,
          description:
              'A matrix — `en,nl,fr`. Defaults to the source language alone, '
              'because that is the one a translator is shown: a service '
              'attaches the picture to the string id, not to a locale. Which '
              'locales are missing a key is read off the catalog files and '
              'needs no run. Name languages here when you want the target '
              'screens themselves — what German does to a button.',
        ),
        const ActionParameter(
          'device',
          'Device',
          kind: ActionParameterKind.string,
          required: false,
          description:
              'What the screens are captured on — `iphone-16`. One device, '
              'because a translator wants one picture per key and a second '
              'device only doubles the candidates.',
        ),
        const ActionParameter(
          'file',
          'File',
          kind: ActionParameterKind.string,
          required: false,
          description:
              'Narrow to one scenario file, package-relative. The export is '
              'only as complete as what it runs.',
        ),
        const ActionParameter(
          'capture-scale',
          'Capture scale',
          kind: ActionParameterKind.string,
          required: false,
          description:
              'Screenshot pixels per logical pixel, up to 4. Defaults to 1 — '
              'a phone screenshot at 1x is already 390 by 844 and the page '
              'draws the box over it, so the second pixel is only worth '
              'having where a translator zooms into small type. Pass `2` for '
              'that; measured on the example suite it costs 28% of the run.',
        ),
        const ActionParameter(
          'max-lengths',
          'Max lengths',
          kind: ActionParameterKind.string,
          required: false,
          description:
              '`true` to measure how long each string can get: the suite is '
              're-run with every value progressively padded, and each key '
              'gains `maxLength` — the longest string *proven* to fit its '
              'tightest box, in characters, with the tested strings and the '
              'clip photographed as evidence. Measured on the source '
              'language, so it holds for every locale at once. Off when '
              'omitted — the export costs what it always cost.',
        ),
        const ActionParameter(
          'max-length-device',
          'Max-length device',
          kind: ActionParameterKind.string,
          required: false,
          description:
              'The geometry the measurement is true for — `pixel-4a`. '
              'Separate from `device`, which only chooses what the '
              "translator's screenshots look like. Defaults to the narrowest "
              'device each scenario folder declares: the tightest screen the '
              'project itself claims to run on.',
        ),
      ],
    ),
  ];

  /// The internal ladder — ten even rungs of each value's own ceiling, which
  /// `TranslationIndex.expansionLength` sets higher the shorter the value is
  /// (+300% at ≤10 characters down to +100% for a sentence). Not API: the
  /// deliverable is characters, and the rung width (~a tenth of the ceiling)
  /// is the measurement's resolution, visible in the evidence rather than
  /// hidden in rounding.
  static const _ladder = [10, 20, 30, 40, 50, 60, 70, 80, 90, 100];

  @override
  Future<Object?> invoke(
    String actionId, {
    Map<String, Object?> arguments = const {},
  }) => switch (actionId) {
    exportActionId => export(arguments),
    _ => super.invoke(actionId, arguments: arguments),
  };

  /// Runs the suite and writes the export.
  ///
  /// Re-runs rather than reading the last run, for a reason the scenario web
  /// export shares and one it does not. Shared: an export is dated and
  /// distributed, and must not be a picture of the suite as it stood at some
  /// earlier, unrecorded moment. Its own: the questions worth asking are
  /// cross-locale, and the last run was almost certainly one language.
  Future<TranslationExportResult> export(Map<String, Object?> arguments) async {
    var stopwatch = Stopwatch()..start();
    var path = _requested(arguments);
    await _cache.load(path);
    if (_cache.failureFor(path) case var failure?) throw ActionRefusal(failure);

    var catalogs = _cache[path] ?? const <String, LoadedCatalog>{};
    if (catalogs.isEmpty) {
      throw ActionRefusal(
        'Package "$path" declares no translation catalogs. Add them to its '
        'TranslationsPackage in tool/flutterware.dart.',
      );
    }

    // **One language by default, and it is the source one.**
    //
    // A translation service attaches a screenshot to a *string id*, not to a
    // locale: the translator is shown the English in place and writes the
    // French. Shots of the French would be a picture of what they are about to
    // replace. And the questions the other locales could answer — which of
    // them is missing a key — are answered by the catalog files with no run
    // at all, which is what the panel's columns already read.
    //
    // So running every locale cost N passes over the whole suite and bought
    // almost nothing. Naming languages still runs them, for the case that does
    // want target-locale screens: seeing what German does to a button.
    var languages = switch (arguments['languages']) {
      String value when value.trim().isNotEmpty => [
        for (var tag in value.split(',')) tag.trim(),
      ],
      _ => [templateFor(path)],
    };
    if (languages.isEmpty) {
      throw ActionRefusal(
        'No locales to run. The declared catalogs matched no files — check '
        'their `files:` globs, which are relative to the package.',
      );
    }

    var captureScale = switch (arguments['capture-scale']) {
      num value => value.toDouble(),
      String value => double.tryParse(value),
      _ => null,
    };
    if (arguments['capture-scale'] != null &&
        (captureScale == null || captureScale <= 0 || captureScale > 4)) {
      throw ArgumentError.value(
        arguments['capture-scale'],
        'capture-scale',
        'a number in (0, 4]',
      );
    }
    // 1x, not the device's own ratio and not the 2 this used to take: the
    // capture is the one part of a scenario run that scales with the square
    // of this number — measured on the example suite, going from 1 to 2 took
    // the run from 3.4s to 4.8s, all of it in `toByteData`. What it buys is
    // legible small type under a zoom, which is a real want but not the
    // default one.
    captureScale ??= 1;

    var measureMaxLengths = switch (arguments['max-lengths']) {
      null || false || 'false' => false,
      true || 'true' || '' => true,
      var other => throw ArgumentError.value(
        other,
        'max-lengths',
        '`true` to measure',
      ),
    };
    var maxLengthDevice = arguments['max-length-device'];
    if (maxLengthDevice != null &&
        (maxLengthDevice is! String || !isDeviceId(maxLengthDevice))) {
      throw ArgumentError.value(
        maxLengthDevice,
        'max-length-device',
        'no such device. Accepted: ${deviceIds.join(', ')}',
      );
    }
    if (maxLengthDevice != null && !measureMaxLengths) {
      throw ArgumentError(
        '`max-length-device` frames the max-length probe — '
        'pass `max-lengths: true` with it.',
      );
    }

    var packageRoot = host.workspace.packageFor(path).directory.path;
    var output = switch (arguments['output']) {
      String value when value.trim().isNotEmpty =>
        p.isAbsolute(value) ? value : p.join(packageRoot, value),
      _ => TranslationExporter.defaultOutputIn(packageRoot),
    };

    var worktreeRoot = host.worktree.path;
    Future<String?> readArtifact(String artifact) async {
      var file = File(p.join(worktreeRoot, artifact));
      return file.existsSync() ? file.readAsString() : null;
    }

    // Named, not counted: "1 locales" was the old spelling of one, and the
    // scenario count runs beside this phrase now.
    _setBusy(
      path,
      languages.length == 1
          ? 'running ${languages.single}'
          : 'running ${languages.length} locales',
    );
    ScenarioRunResult run;
    ProbeBaseline? probeBaseline;
    var probePasses = <ProbePass>[];
    var evidencePasses = <({int level, TranslationSurvey survey})>[];
    var scenarios = _scenariosFor(path);
    // The count the bar draws. Mirrored rather than reinvented: the scenarios
    // core is the one running the suite, and it already counts the scenarios
    // that have announced a step against the ones its scan found.
    var watching = scenarios.changes.stream.listen((_) {
      var progress = scenarios.runProgressFor(path);
      if (progress == _progress[path]) return;
      if (progress == null) {
        _progress.remove(path);
      } else {
        _progress[path] = progress;
      }
      notifyChanged();
    });
    try {
      // `!`: the `??= 2` above settled it, but a closure capture defeats
      // the promotion.
      Future<TranslationSurvey> surveyOf(ScenarioRunResult it) => buildSurvey(
        run: it,
        catalogs: catalogs,
        readArtifact: readArtifact,
        captureScale: captureScale!,
      );
      Future<ScenarioRunResult> invoke(Map<String, Object?> arguments) async =>
          (await scenarios.invoke('run', arguments: arguments))!
              as ScenarioRunResult;

      run = await invoke({
        'package': path,
        'languages': languages.join(','),
        'device': ?arguments['device'],
        'file': ?arguments['file'],
        'capture-scale': captureScale,
        // The whole point: every step, so every screen a key was seen on is
        // in the result rather than only the failures.
        'steps': 'all',
        // But not every step's *picture*. An export files a shot against a
        // string id, so a screen showing no key can contribute none — and on
        // the example suite that was 23 of 62 steps rasterized, encoded and
        // written for a file nothing would link to. Text belonging to no
        // catalog does not count: the `unkeyed` finding carries the words and
        // the step, never a picture.
        'pixels': 'keyed',
      });

      if (measureMaxLengths) {
        // The probe's geometry is its own axis, deliberately not
        // `arguments['device']`: that one chooses what the translator's
        // screenshots look like, and a max length measured on a roomy screen
        // over-promises. Default is the narrowest device each folder
        // declares — the tightest screen the project itself claims.
        var probeArgs = {
          'package': path,
          'languages': templateFor(path),
          'file': ?arguments['file'],
          'capture-scale': captureScale,
          'steps': 'all',
          'pixels': 'keyed',
          if (maxLengthDevice != null)
            'device': maxLengthDevice
          else
            'device-choice': 'narrowest',
        };
        // Its own baseline, on its own device: the exclusion rule compares
        // padded against unpadded *on the same geometry* — a string clean on
        // the screenshot device may already ellipsize here, and pairing
        // against the wrong baseline would misread that pre-existing clip as
        // a flip at the first rung. Captured, because it also supplies the
        // `screen` evidence shots.
        _setBusy(path, 'measuring max lengths — baseline');
        probeBaseline = ProbeBaseline(await surveyOf(await invoke(probeArgs)));

        var remaining = probeBaseline.measurableIds;
        var firstClipLevels = <int>{};
        for (var level in _ladder) {
          // Every measurable key has clipped: the rest of the ladder can
          // only re-prove it.
          if (remaining.isEmpty) break;
          _setBusy(path, 'measuring max lengths — +$level%');
          var result = await invoke({
            ...probeArgs,
            'format': 'none',
            'expand': level,
          });
          var survey = await surveyOf(result);
          probePasses.add(
            ProbePass(
              level: level,
              survey: survey,
              failures: [
                for (var package in result.packages)
                  for (var outcome in package.scenarios)
                    if (!outcome.ok)
                      (
                        scenario: '${outcome.file}/${outcome.name}',
                        failure: outcome.errors.firstOrNull?.error ?? 'failed',
                      ),
              ],
            ),
          );
          var hit = {
            for (var cell in probeBaseline.flippedCells(survey).values) cell.id,
          };
          if (hit.intersection(remaining).isNotEmpty) {
            firstClipLevels.add(level);
          }
          remaining.removeAll(hit);
        }
        // The clip, photographed: one captured pass per level at which keys
        // first clipped, so every real limit gets a picture of the padded
        // string actually ellipsizing in place.
        for (var level in firstClipLevels.toList()..sort()) {
          _setBusy(path, 'measuring max lengths — photographing +$level%');
          evidencePasses.add((
            level: level,
            survey: await surveyOf(
              await invoke({...probeArgs, 'expand': level}),
            ),
          ));
        }
      }
    } finally {
      unawaited(watching.cancel());
      _progress.remove(path);
      _setBusy(path, 'building the export…');
      scenarios.dispose();
    }

    try {
      var survey = await buildSurvey(
        run: run,
        catalogs: catalogs,
        readArtifact: readArtifact,
        captureScale: captureScale,
      );

      TranslationMaxLengths? maxLengths;
      if (probeBaseline != null) {
        maxLengths = computeMaxLengths(
          baseline: probeBaseline,
          passes: probePasses,
          values: (catalog, key) {
            var loaded = catalogs[catalog];
            return loaded?.valueOf(loaded.template, key);
          },
          evidence: evidencePasses,
        );
      }

      var written = TranslationExporter(worktreeRoot: worktreeRoot).write(
        survey: survey,
        output: output,
        captureScale: captureScale,
        maxLengths: maxLengths,
      );

      var occurrences = 0;
      for (var key in written.export.keys) {
        occurrences += key.occurrences.length;
      }
      var failed = 0;
      for (var package in run.packages) {
        for (var outcome in package.scenarios) {
          if (!outcome.ok) failed++;
        }
      }

      var result = TranslationExportResult(
        output: _relative(written.output),
        keysJson: _relative(written.keysJson),
        indexHtml: _relative(written.indexHtml),
        catalogs: written.export.catalogs.length,
        locales: languages.length,
        keys: written.export.keys.length,
        keysSeen: written.export.seen.length,
        occurrences: occurrences,
        shots: written.shots,
        missingShots: written.missingShots,
        fallingBack: written.export.findings.fallingBack.length,
        disagrees: written.export.findings.disagrees.length,
        notReached: written.export.findings.notReached.length,
        absentFromCatalog: written.export.findings.absentFromCatalog.length,
        overflowing: written.export.findings.overflowing.length,
        unkeyed: written.export.findings.unkeyed.length,
        scenariosFailed: failed,
        maxLengths: maxLengths?.byKey.length ?? 0,
        maxLengthLimits: maxLengths?.bounded ?? 0,
        maxLengthDevices: maxLengths == null || maxLengths.devices.isEmpty
            ? null
            : maxLengths.devices.join(','),
        expansionBreaks: written.export.findings.expansionBreaks.length,
        durationMs: stopwatch.elapsedMilliseconds,
        open: 'open ${_relative(written.indexHtml)}',
      );
      // Re-read rather than keep what was just built: the panel must show the
      // same bytes a push script would, and the one way to be sure of that is
      // to go through the same door.
      await _loadExport(path);
      return result;
    } finally {
      _setBusy(path, null);
    }
  }

  /// A scenarios core over this plugin's own declaration.
  ///
  /// Synthesized rather than reached for. Two cores would otherwise have to
  /// find each other through the session, which is a coupling the plugin
  /// contract deliberately does not have — and the translations plugin
  /// declares its own packages anyway, so the config it would borrow is config
  /// it already has. What this buys is everything: the matrix, the axis
  /// slugs, the artifact layout and the failure reporting are the scenarios
  /// plugin's, unchanged, so an export cannot drift from what `scenarios run`
  /// does.
  ScenariosCore _scenariosFor(String path) => ScenariosCore(
    PluginHost(
      id: scenariosPluginId,
      label: 'Scenarios',
      worktree: host.worktree,
      workspace: host.workspace,
      config: {
        'packages': [
          {'path': path},
        ],
      },
    ),
  );

  String _requested(Map<String, Object?> arguments) {
    var requested = arguments['package'];
    if (requested != null && requested is! String) {
      throw ArgumentError.value(requested, 'package', 'must be a package path');
    }
    if (requested == null) {
      if (packages.length == 1) return packages.single;
      if (packages.isEmpty) {
        throw ActionRefusal(
          'No packages are declared for this plugin. Add one to '
          'Translations(packages: …) in tool/flutterware.dart.',
        );
      }
      throw ArgumentError(
        '`package` is required when more than one is declared. '
        'Declared: ${packages.join(', ')}',
      );
    }
    if (!packages.contains(requested)) {
      throw ArgumentError.value(
        requested,
        'package',
        'not declared for this plugin. Declared: ${packages.join(', ')}',
      );
    }
    return requested as String;
  }

  void _setBusy(String path, String? message) {
    if (message == null) {
      _busy.remove(path);
      _progress.remove(path);
    } else {
      _busy[path] = message;
    }
    notifyChanged();
  }

  /// A path as every surface reports it: relative to the worktree, so it
  /// survives being read on another machine.
  String _relative(String path) {
    var root = host.worktree.path;
    return p.isWithin(root, path) ? p.relative(path, from: root) : path;
  }
}

const exportActionId = 'export';

PluginCore translationsCoreFactory(PluginHost host) => TranslationsCore(host);

/// Where the translations plugin reads from: the catalog files, the last
/// export and the pictures it names.
///
/// [LiveTranslationSource] is the package's own directory, which is the plugin
/// as it always was. The recorded project hands the core a source that answers
/// from a recording instead — see `demo/recorded_translations.dart` — and
/// nothing above this line knows the difference, which is what lets the live
/// panel run where there is no filesystem.
abstract class TranslationSource {
  const TranslationSource();

  /// The reader `loadCatalogs` walks a package's declared globs with.
  CatalogReader catalogsUnder(String packageRoot);

  /// Where the export for the package at [packageRoot] sits. Every shot the
  /// export names is resolved under it, by the panel, through [readShot].
  String exportDirectoryIn(String packageRoot);

  /// The export in [directory], and when it was written — null when there is
  /// none. May throw for one that is there but unreadable; the caller treats
  /// that as none.
  Future<({TranslationExport export, DateTime at})?> readExport(
    String directory,
  );

  /// The bytes of a picture the export names, at the path the panel built
  /// under [exportDirectoryIn] — or null when it is gone.
  Future<Uint8List?> readShot(String path);
}

/// The package's directory on disk.
class LiveTranslationSource extends TranslationSource {
  const LiveTranslationSource();

  @override
  CatalogReader catalogsUnder(String packageRoot) =>
      catalogFilesUnder(packageRoot);

  @override
  String exportDirectoryIn(String packageRoot) =>
      TranslationExporter.defaultOutputIn(packageRoot);

  @override
  Future<({TranslationExport export, DateTime at})?> readExport(
    String directory,
  ) async {
    var file = File(p.join(directory, translationExportFile));
    if (!file.existsSync()) return null;
    // Off the file's own timestamp, deliberately: the format carries no time
    // of its own so that two exports of an unchanged suite stay
    // byte-identical, and the filesystem already knows this.
    return (
      export: await TranslationExport.read(directory),
      at: file.statSync().modified,
    );
  }

  @override
  Future<Uint8List?> readShot(String path) async {
    var file = File(path);
    if (!file.existsSync()) return null;
    return file.readAsBytes();
  }
}
