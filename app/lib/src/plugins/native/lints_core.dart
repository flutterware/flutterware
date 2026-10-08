import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:collection/collection.dart';
import 'package:crypto/crypto.dart';
import 'package:flutterware/plugins.dart';
import 'package:package_config/package_config.dart' hide findPackageConfig;
import 'package:path/path.dart' as p;

import '../../lints/model/classification.dart';
import '../../lints/model/issue_counts.dart';
import '../../lints/model/options_scan.dart';
import '../../lints/model/rule_catalog.dart';
import '../../previews/package_config_locator.dart';
import '../../session/job.dart';
import '../../utils/run_dir.dart';
import '../plugin_core.dart';
import '../plugin_host.dart';
import 'lints_results.dart';

/// The registered id — also what `tool/flutterware.dart` declares.
const lintsPluginId = 'flutterware.lints';

/// What this plugin is, for a reader who has only the id — see
/// `PluginReport.description`.
const _pluginDescription =
    'Which lint rules this repo evaluated and — the point — which it never '
    'did, across every `analysis_options.yaml` in it.';

PluginCore lintsCoreFactory(PluginHost host) => LintsCore(host);

/// Which lint rules this repo evaluated, and — the point — which it never did.
///
/// The subject is the *decision record*, not the diagnostics. `dart analyze`
/// already reports what the enabled rules find; nothing reports the rules
/// that exist for this SDK and are mentioned nowhere. This core scans every
/// `analysis_options.yaml` in the repo, resolves each `include:` chain, and
/// classifies the SDK's whole rule set against them: enabled, deliberately
/// dismissed, mentioned only in a comment, or never evaluated.
///
/// Repo-scoped rather than package-scoped: options files inherit across
/// package boundaries (a member includes the root), so the union is the only
/// view in which "mentioned nowhere" is a truthful sentence.
///
/// The rule universe comes from the SDK repository's own `rules.json`, fetched
/// once per Dart version and cached forever (see [LintCatalogStore]). Within
/// `computeAll` only the disk cache is consulted — the network is out of that
/// budget — so the first-ever look at a new SDK version happens through the
/// panel or an action.
class LintsCore extends PluginCore {
  LintsCore(
    super.host, {
    LintCatalogStore? catalogStore,
    LintIssueCounter? counter,
  }) : _catalogStore = catalogStore ?? LintCatalogStore(),
       _counter = counter ?? LintIssueCounter();

  final LintCatalogStore _catalogStore;
  final LintIssueCounter _counter;

  LintOptionsScan? _scan;
  LintsClassification? _classification;
  String? _dartVersion;
  String? _error;
  Future<void>? _pending;
  var _loadedWithNetwork = false;

  LintIssueCounts? _counts;
  String? _countError;
  var _counting = false;

  String get _root => host.workspace.root;

  LintOptionsScan? get scan => _scan;
  LintsClassification? get classification => _classification;
  String? get dartVersion => _dartVersion;
  String? get error => _error;
  LintIssueCounts? get issueCounts => _counts;
  String? get countError => _countError;
  bool get isCounting => _counting;

  /// Whether a scan is running *now*.
  ///
  /// Not "has never scanned", which is what a capture used to be told. Nothing
  /// scans until a panel mounts or an action asks, so a window showing some
  /// other plugin left this one claiming to be busy for as long as it was
  /// open — and `fw capture` believed it and waited for its whole timeout,
  /// every time, in every project that declares lints.
  bool get isScanning => _pending != null;

  /// True when the persisted counts were computed for a different candidate
  /// set than today's — still worth showing, worth re-running.
  bool get countsAreStale {
    var counts = _counts;
    var classification = _classification;
    if (counts == null || classification == null) return false;
    return counts.candidatesSignature !=
        LintIssueCounts.signatureOf(_candidates(classification));
  }

  /// Unevaluated rules the last run found nothing for — the ones that can be
  /// enabled today and nothing changes.
  int get unevaluatedWithoutIssues {
    var counts = _counts;
    var classification = _classification;
    if (counts == null || classification == null) return 0;
    return classification
        .inBucket(LintBucket.unevaluated)
        .where((rule) => counts.counts[rule.name] == 0)
        .length;
  }

  /// Scans and classifies, unless it already has. Idempotent; the panel calls
  /// this on mount. May fetch the rule catalog over the network — a panel is a
  /// person looking, which is the consent `computeAll` does not have.
  void track() => unawaited(_load(allowNetwork: true));

  /// Drops everything cached and loads again, completing when the new state is
  /// in — the shape a refresh button wants.
  Future<void> reload() {
    _scan = null;
    _classification = null;
    _error = null;
    _pending = null;
    notifyChanged();
    return _load(allowNetwork: true);
  }

  @override
  Future<void> computeAll() => _load(allowNetwork: false);

  Future<void> _load({required bool allowNetwork}) {
    if (_classification != null && (_loadedWithNetwork || !allowNetwork)) {
      return Future.value();
    }
    var pending = _pending;
    if (pending != null && (_loadedWithNetwork || !allowNetwork)) {
      return pending;
    }
    return _pending = _doLoad(allowNetwork: allowNetwork);
  }

  Future<void> _doLoad({required bool allowNetwork}) async {
    try {
      LintIssueCounter.recoverLeftovers(_root);

      var scanner = LintOptionsScanner(
        repoRoot: _root,
        resolvePackageUri: await _packageResolver(),
      );
      var scan = scanner.scan();

      var version = LintCatalogStore.dartVersionOf(
        host.workspace.flutterSdk.root,
      );
      LintCatalog? catalog;
      if (version != null) {
        catalog = allowNetwork
            ? await _catalogStore.fetch(version)
            : _catalogStore.cachedOnly(version);
      }

      if (isDisposed) return;
      _scan = scan;
      _dartVersion = version;
      _classification = LintsClassification.build(scan: scan, catalog: catalog);
      _loadedWithNetwork = allowNetwork;
      _error = null;
      _counts ??= _readPersistedCounts();
    } catch (e) {
      if (isDisposed) return;
      _error = '$e';
    } finally {
      _pending = null;
      notifyChanged();
    }
  }

  Future<String? Function(Uri)?> _packageResolver() async {
    var path = findPackageConfig(_root);
    if (path == null) return null;
    try {
      var config = await loadPackageConfig(File(path));
      return (Uri uri) => config.resolve(uri)?.toFilePath();
    } catch (e) {
      return null;
    }
  }

  /// Every rule an analyzer run can say something new about: unevaluated ones,
  /// and dismissed or commented-out ones — how many findings a dismissal is
  /// hiding is part of the record. A rule dismissed through `analyzer: errors:
  /// ignore` stays out: the overlay cannot undo a severity override, so its
  /// count would come back zero and read as clean.
  List<String> _candidates(LintsClassification classification) {
    var scan = _scan;
    var ignored = <String>{
      if (scan != null)
        for (var file in scan.files)
          for (var entry in file.severityOverrides.entries)
            if (entry.value == 'ignore') entry.key,
    };
    return [
      for (var rule in classification.rules)
        if (rule.bucket != LintBucket.enabled && !ignored.contains(rule.name))
          rule.name,
    ];
  }

  /// Runs one analyzer pass with every candidate rule enabled and records what
  /// each would report. Slow by nature — seconds to minutes — which is why it
  /// is an action and never runs on its own.
  Future<LintsCountResult> countIssues() async {
    await _load(allowNetwork: true);
    var classification = _classification;
    if (classification == null) {
      throw ActionRefusal(_error ?? 'The scan has not run.');
    }
    if (!classification.hasCatalog) {
      throw ActionRefusal(
        'No rule catalog for Dart $_dartVersion, and counting needs one. The '
        'first fetch needs a network connection.',
      );
    }
    if (_counting) {
      throw ActionRefusal('A counting run is already in progress.');
    }

    var candidates = _candidates(classification);
    _counting = true;
    _countError = null;
    notifyChanged();
    try {
      var counts = await _counter.count(
        repoRoot: _root,
        dartExecutable: host.workspace.flutterSdk.dart,
        candidates: candidates,
      );
      if (!isDisposed) {
        _counts = counts;
        _persistCounts(counts);
      }
      return LintsCountResult(
        candidates: candidates.length,
        unevaluatedWithoutIssues: unevaluatedWithoutIssues,
        elapsedMs: counts.elapsed.inMilliseconds,
        counts: counts.counts,
        samples: {
          for (var entry in counts.samples.entries)
            entry.key: [for (var sample in entry.value) '$sample'],
        },
      );
    } catch (e) {
      if (!isDisposed) _countError = '$e';
      rethrow;
    } finally {
      if (!isDisposed) {
        _counting = false;
        notifyChanged();
      }
    }
  }

  File get _countsFile {
    var key = sha1.convert(utf8.encode(p.canonicalize(_root))).toString();
    return File(p.join(flutterwareDir(), key, 'lints-issue-counts.json'));
  }

  LintIssueCounts? _readPersistedCounts() {
    try {
      var file = _countsFile;
      if (!file.existsSync()) return null;
      return LintIssueCounts.fromJson(
        (jsonDecode(file.readAsStringSync()) as Map).cast<String, Object?>(),
      );
    } catch (e) {
      return null;
    }
  }

  void _persistCounts(LintIssueCounts counts) {
    try {
      var file = _countsFile;
      file.parent.createSync(recursive: true);
      file.writeAsStringSync(jsonEncode(counts.toJson()));
    } catch (e) {
      // A count that does not survive a restart only costs a re-run.
    }
  }

  @override
  Future<Object?> invoke(
    String actionId, {
    Map<String, Object?> arguments = const {},
  }) async => switch (actionId) {
    'status' => _status(),
    'count' => countIssues(),
    _ => super.invoke(actionId, arguments: arguments),
  };

  Future<LintsStatusResult> _status() async {
    await _load(allowNetwork: true);
    var scan = _scan;
    var classification = _classification;
    if (scan == null || classification == null) {
      throw ActionRefusal(_error ?? 'The scan has not run.');
    }
    var counts = _counts;
    return LintsStatusResult(
      dartVersion: _dartVersion,
      catalogAvailable: classification.hasCatalog,
      universe: classification.universe,
      files: [
        for (var file in scan.files)
          LintsFileSummary(
            path: file.path,
            includeChain: file.includeChain,
            inheritsNothing: !file.hasInclude,
            includeErrors: file.includeErrors,
            configured: file.mentions.length,
            enabled: file.enabled.length,
          ),
      ],
      rules: [
        for (var rule in classification.rules.sorted(compareBySinceDesc))
          LintsRuleEntry(
            name: rule.name,
            bucket: rule.bucket.name,
            since: rule.rule?.sinceDartSdk,
            state: rule.rule?.state,
            fix: rule.rule?.fixStatus,
            description: rule.rule?.description,
            enabledVia: rule.enabledVia,
            comment: rule.comment,
            files: rule.files,
            incompatible: rule.rule?.incompatible ?? const [],
            issues: rule.bucket == LintBucket.enabled
                ? null
                : counts?.counts[rule.name],
          ),
      ],
      unknownNames: classification.unknownNames,
      issueCounts: counts == null
          ? null
          : LintsCountsSummary(
              at: counts.at.toIso8601String(),
              elapsedMs: counts.elapsed.inMilliseconds,
              unevaluatedWithoutIssues: unevaluatedWithoutIssues,
              stale: countsAreStale,
            ),
    );
  }

  @override
  PluginReport get report {
    var classification = _classification;
    return PluginReport(
      id: host.id,
      label: host.label,
      description: _pluginDescription,
      status: _statusLine(classification),
      badge: switch (classification?.count(LintBucket.unevaluated)) {
        null || 0 => StatusBadge.none,
        var count => StatusBadge.count(count),
      },
      actions: [
        PluginAction(
          'status',
          'Status',
          returns: LintsStatusResult,
          description:
              'Every rule the SDK offers this project, classified against '
              'every analysis_options.yaml in the repo: enabled, dismissed, '
              'mentioned in a comment, or never evaluated',
        ),
        PluginAction(
          'count',
          'Count issues',
          returns: LintsCountResult,
          description:
              'One dart analyze run with every unevaluated, dismissed and '
              'commented-out rule enabled — reports how many issues each '
              'would flag today, with sample locations. Costs a full '
              'analysis of the repo (seconds to minutes)',
        ),
      ],
      view: _view(classification),
    );
  }

  String? _itemDetail(ClassifiedLint rule, LintIssueCounts? counts) {
    var parts = [
      if (rule.rule?.sinceDartSdk case var since?) 'since $since',
      if (counts?.counts[rule.name] case var issues?)
        issues == 1 ? '1 issue' : '$issues issues',
    ];
    return parts.isEmpty ? null : parts.join(' · ');
  }

  Status _statusLine(LintsClassification? classification) {
    if (_counting) return const Status.info('counting issues…');
    if (_error != null) return Status.error(_error!);
    if (classification == null) {
      return _pending != null ? const Status.info('scanning…') : Status.none;
    }
    if (!classification.hasCatalog) {
      return const Status.warn('no rule catalog: first fetch needs network');
    }
    var unevaluated = classification.count(LintBucket.unevaluated);
    if (unevaluated == 0) return const Status.good('every rule evaluated');
    return Status.info(
      '$unevaluated unevaluated · ${classification.count(LintBucket.enabled)} on',
    );
  }

  PluginView _view(LintsClassification? classification) {
    if (classification == null) return PluginView.empty;
    var scan = _scan;
    var counts = _counts;
    var newest = classification
        .inBucket(LintBucket.unevaluated)
        .sorted(compareBySinceDesc)
        .take(12)
        .toList();
    return PluginView([
      ViewField('Dart', _dartVersion ?? 'unknown'),
      ViewField('Enabled', '${classification.count(LintBucket.enabled)}'),
      ViewField('Dismissed', '${classification.count(LintBucket.dismissed)}'),
      ViewField('Mentioned', '${classification.count(LintBucket.mentioned)}'),
      ViewField(
        'Unevaluated',
        '${classification.count(LintBucket.unevaluated)}',
        tone: classification.count(LintBucket.unevaluated) > 0
            ? Tone.info
            : Tone.good,
      ),
      if (scan != null) ViewField('Options files', '${scan.files.length}'),
      if (counts != null)
        ViewField(
          'Issue counts',
          '$unevaluatedWithoutIssues unevaluated rules report nothing'
              '${countsAreStale ? ' (stale: the rule set changed)' : ''}',
        ),
      if (classification.unknownNames.isNotEmpty)
        ViewField(
          'Unknown rules',
          classification.unknownNames.join(', '),
          tone: Tone.warn,
        ),
      if (newest.isNotEmpty)
        ViewItems([
          for (var rule in newest)
            ViewItem(rule.name, detail: _itemDetail(rule, counts)),
        ]),
    ]);
  }
}
